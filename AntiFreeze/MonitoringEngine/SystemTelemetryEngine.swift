import Foundation
import AppKit

// MARK: - SystemTelemetryEngine (Phase 1)
//
// The single source of truth every later phase reads from. Owns one timer
// per category at a category-appropriate cadence, writes everything into
// TelemetryStore, publishes the latest values for the UI, and adapts its
// sampling rate to current risk:
//
// - Any event at .watch or worse  -> sample faster (scale 0.4, floor 1s)
// - All .info for 60s sustained    -> back to baseline cadence
//
// Fast categories (CPU/memory/process) sample every few seconds; slow ones
// (disk/power) every minute. Sampling everything at the same cadence would
// waste battery for no signal gain.

final class SystemTelemetryEngine: ObservableObject {
    /// Latest event per "category.metric", for the menu-bar UI.
    @Published private(set) var latest: [String: TelemetryEvent] = [:]

    @Published private(set) var isRunning = false

    private struct CategoryConfig {
        let collector: TelemetryCollector
        let baseInterval: TimeInterval
    }

    private let configs: [CategoryConfig]
    private let memoryCollector = MemoryCollector()
    private var timers: [Timer] = []
    private var scale: Double = 1.0
    private var lastElevated: Date?
    private let store = TelemetryStore.shared
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var retentionTimer: Timer?

    init() {
        configs = [
            CategoryConfig(collector: CPUCollector(), baseInterval: 2),
            CategoryConfig(collector: memoryCollector, baseInterval: 5),
            CategoryConfig(collector: ThermalCollector(), baseInterval: 10),
            CategoryConfig(collector: ProcessCollector(), baseInterval: 5),
            CategoryConfig(collector: GPUCollector(), baseInterval: 15),
            CategoryConfig(collector: DiskCollector(), baseInterval: 60),
            CategoryConfig(collector: PowerCollector(), baseInterval: 60),
        ]
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        _ = store.open()
        rebuildTimers()

        // Memory pressure is event-driven, not polled — wire it directly.
        memoryCollector.startPressureMonitoring { [weak self] level in
            let event = TelemetryEvent(
                category: .memory, value: Double(level),
                source: "dispatch_memory_pressure",
                metadata: ["metric": "pressure"])
            self?.ingest([event])
        }

        // Wake latency: time between wake notification and first successful
        // sample is itself a stability-relevant metric.
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "af.lastSleep")
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.recordWakeLatency()
        }

        // Daily retention/downsampling pass.
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            TelemetryStore.shared.enforceRetention()
        }
        // And once at launch, so a machine that's been running for weeks
        // trims promptly.
        store.enforceRetention()
    }

    func stop() {
        isRunning = false
        timers.forEach { $0.invalidate() }
        timers = []
        retentionTimer?.invalidate()
        retentionTimer = nil
        memoryCollector.stopPressureMonitoring()
        if let o = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObserver = nil
        wakeObserver = nil
        store.close()
    }

    // MARK: - Sampling

    private func rebuildTimers() {
        timers.forEach { $0.invalidate() }
        timers = []
        for config in configs {
            let interval = max(1.0, config.baseInterval * scale)
            let collector = config.collector
            // Prime immediately so the UI isn't empty for a full interval.
            sample(collector)
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.sample(collector)
            }
            timers.append(timer)
        }
    }

    private func sample(_ collector: TelemetryCollector) {
        let events = collector.collect()
        ingest(events)
    }

    private func ingest(_ events: [TelemetryEvent]) {
        guard !events.isEmpty else { return }
        store.insert(events)
        var worst: Severity = .info
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for e in events {
                self.latest["\(e.category.rawValue).\(e.metric)"] = e
                worst = max(worst, e.severity)
            }
            self.adaptSampling(worst: worst)
        }
    }

    /// Adaptive sampling: speed up when anything looks off, relax after a
    /// sustained all-clear. This is what lets later prediction phases catch
    /// fast-developing instability without max-frequency sampling 24/7.
    private func adaptSampling(worst: Severity) {
        if worst >= .watch {
            lastElevated = Date()
            if scale != 0.4 {
                scale = 0.4
                rebuildTimers()
            }
        } else if scale != 1.0,
                  let last = lastElevated,
                  Date().timeIntervalSince(last) > 60 {
            scale = 1.0
            lastElevated = nil
            rebuildTimers()
        }
    }

    private func recordWakeLatency() {
        let sleptAt = UserDefaults.standard.double(forKey: "af.lastSleep")
        guard sleptAt > 0 else { return }
        let t0 = Date()
        // First successful lightweight sample after wake.
        DispatchQueue.global(qos: .utility).async {
            _ = ThermalCollector().collect()
            let latency = Date().timeIntervalSince(t0)
            let event = TelemetryEvent(
                category: .power, value: latency, source: "wake_latency",
                metadata: ["metric": "wake_latency_s",
                           "slept_at": String(sleptAt)])
            // Value semantics differ from the unit table (seconds, unbounded),
            // so severity is informational by construction here.
            self.ingest([event])
        }
    }
}
