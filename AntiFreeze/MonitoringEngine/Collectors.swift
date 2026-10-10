import Foundation
import Darwin
import IOKit
import AppKit

// MARK: - Collector protocol

/// Poll-based sampler. Returns one or more events, or an empty array when the
/// signal is genuinely unavailable on this hardware — never a fabricated value.
protocol TelemetryCollector {
    var category: TelemetryCategory { get }
    var source: String { get }
    func collect() -> [TelemetryEvent]
}

// MARK: - CPU

final class CPUCollector: TelemetryCollector {
    let category: TelemetryCategory = .cpu
    let source = "host_processor_info"
    private var previousTicks: [UInt32]?

    func collect() -> [TelemetryEvent] {
        guard let ticks = cpuTicks() else { return [] }
        defer { previousTicks = ticks }
        guard let prev = previousTicks, prev.count == ticks.count else {
            return [] // first sample establishes the baseline; no event yet
        }
        let coreCount = ticks.count / 4
        guard coreCount > 0 else { return [] }
        var totalDelta: UInt64 = 0
        var idleDelta: UInt64 = 0
        var maxCoreUsage = 0.0
        for c in 0..<coreCount {
            var coreTotal: UInt64 = 0
            var coreIdle: UInt64 = 0
            for s in 0..<4 {
                let d = UInt64(ticks[c * 4 + s]) - UInt64(prev[c * 4 + s])
                coreTotal += d
                if s == 2 { coreIdle = d } // CPU_STATE_IDLE == 2
            }
            totalDelta += coreTotal
            idleDelta += coreIdle
            if coreTotal > 0 {
                maxCoreUsage = max(maxCoreUsage, 1.0 - Double(coreIdle) / Double(coreTotal))
            }
        }
        guard totalDelta > 0 else { return [] }
        let usage = 1.0 - Double(idleDelta) / Double(totalDelta)
        return [
            TelemetryEvent(category: .cpu, value: usage, source: source,
                           metadata: ["metric": "usage"]),
            TelemetryEvent(category: .cpu, value: maxCoreUsage, source: source,
                           metadata: ["metric": "max_core"]),
        ]
    }

    private func cpuTicks() -> [UInt32]? {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &cpuInfo, &cpuInfoCount)
        guard kr == KERN_SUCCESS, let cpuInfo else { return nil }
        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }
        return cpuInfo.withMemoryRebound(to: processor_cpu_load_info.self,
                                         capacity: Int(cpuCount)) { ptr in
            var out: [UInt32] = []
            out.reserveCapacity(Int(cpuCount) * 4)
            for i in 0..<Int(cpuCount) {
                let t = ptr[i].cpu_ticks
                out.append(contentsOf: [t.0, t.1, t.2, t.3])
            }
            return out
        }
    }
}

// MARK: - Memory

final class MemoryCollector: TelemetryCollector {
    let category: TelemetryCategory = .memory
    let source = "host_statistics64 + dispatch_memory_pressure"
    private var pressureSource: DispatchSourceMemoryPressure?
    private var didLogPressureUnavailable = false

    /// Event-driven pressure monitoring. The handler receives 0/1/2
    /// (normal/warning/critical). This is the PRIMARY memory signal — raw
    /// free-memory numbers are misleading on macOS, so we don't sample those.
    func startPressureMonitoring(handler: @escaping (Int) -> Void) {
        let q = DispatchQueue(label: "com.luckyclover.antifreeze.mempressure", qos: .utility)
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: q)
        src.setEventHandler {
            let data = src.data
            if data.contains(.critical) { handler(2) }
            else if data.contains(.warning) { handler(1) }
            else { handler(0) }
        }
        src.setCancelHandler { [weak self] in
            if self?.didLogPressureUnavailable == false {
                self?.didLogPressureUnavailable = true
            }
        }
        src.resume()
        pressureSource = src
    }

    func stopPressureMonitoring() {
        pressureSource?.cancel()
        pressureSource = nil
    }

    /// Poll-based: swap + compressor page counts. Trends matter, not points.
    func collect() -> [TelemetryEvent] {
        var events: [TelemetryEvent] = []
        let pageSize = Double(vm_kernel_page_size)
        var vmInfo = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            events.append(TelemetryEvent(
                category: .memory, value: Double(vmInfo.compressor_page_count),
                source: source, metadata: ["metric": "compressor_pages"]))
        }
        var su = xsw_usage()
        var suSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &su, &suSize, nil, 0) == 0 {
            let pages = Double(su.xsu_used) / pageSize
            events.append(TelemetryEvent(
                category: .memory, value: pages,
                source: "sysctl vm.swapusage", metadata: ["metric": "swap_pages"]))
        }
        return events
    }
}

// MARK: - Thermal

final class ThermalCollector: TelemetryCollector {
    let category: TelemetryCategory = .thermal
    let source = "ProcessInfo.thermalState"

    func collect() -> [TelemetryEvent] {
        // Stable, App-Store-safe entry point: nominal/fair/serious/critical.
        // Raw sensor reads via IOKit are deliberately NOT used — they vary
        // across hardware generations and add fragility for no signal gain.
        let level = Double(ProcessInfo.processInfo.thermalState.rawValue)
        return [TelemetryEvent(category: .thermal, value: level, source: source,
                               metadata: ["metric": "state"])]
    }
}

// MARK: - Disk

final class DiskCollector: TelemetryCollector {
    let category: TelemetryCategory = .disk
    let source = "URL resource values + IOKit storage statistics"
    private var previousIO: (reads: UInt64, readTimeNS: UInt64, date: Date)?
    private var didLogLatencyUnavailable = false

    func collect() -> [TelemetryEvent] {
        var events: [TelemetryEvent] = []
        do {
            let url = URL(fileURLWithPath: "/")
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeTotalCapacityKey,
            ])
            if let avail = values.volumeAvailableCapacityForImportantUsage,
               let total = values.volumeTotalCapacity, total > 0 {
                let freeFraction = Double(avail) / Double(total)
                events.append(TelemetryEvent(
                    category: .disk, value: freeFraction, source: source,
                    metadata: ["metric": "free_fraction"]))
            }
        } catch {
            // Boot volume unreadable — genuinely exceptional; no event.
        }
        if let latencyMs = sampleIOLatency() {
            events.append(TelemetryEvent(
                category: .disk, value: latencyMs, source: source,
                metadata: ["metric": "io_latency_ms"]))
        } else if !didLogLatencyUnavailable {
            didLogLatencyUnavailable = true
            NSLog("[AntiFreeze] Disk I/O latency unavailable on this hardware; metric disabled.")
        }
        return events
    }

    /// Best-effort average read latency from IOBlockStorageDriver statistics.
    /// Returns nil (no event) when the service or keys aren't present.
    private func sampleIOLatency() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: (reads: UInt64, timeNS: UInt64)?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let reads = stats["Reads"] as? UInt64,
               let readTime = stats["Total Read Time"] as? UInt64, reads > 0 {
                best = (reads, readTime)
                break // first usable driver is enough for a system-level signal
            }
            service = IOIteratorNext(iterator)
        }
        guard let cur = best else { return nil }
        defer { previousIO = (cur.reads, cur.timeNS, Date()) }
        guard let prev = previousIO, cur.reads > prev.reads else { return nil }
        let deltaReads = Double(cur.reads - prev.reads)
        let deltaNS = Double(cur.timeNS > prev.timeNS ? cur.timeNS - prev.timeNS : 0)
        guard deltaReads > 0 else { return nil }
        return (deltaNS / deltaReads) / 1_000_000.0 // ns -> ms
    }
}

// MARK: - Power

final class PowerCollector: TelemetryCollector {
    let category: TelemetryCategory = .power
    let source = "IOPSCopyPowerSourcesInfo"
    private var didLogNoBattery = false

    func collect() -> [TelemetryEvent] {
        var events: [TelemetryEvent] = []
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              // "Get" rule: the list is NOT retained; do not takeRetainedValue.
              let list = IOPSGetPowerSourceList(blob)?.takeUnretainedValue() as? [CFTypeRef]
        else { return [] }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?
                    .takeUnretainedValue() as? [String: Any] else { continue }
            // Only batteries carry health data; AC-only Macs (desktops) skip.
            guard let maxCap = desc[kIOPSMaxCapacityKey as String] as? Double,
                  let designCap = desc[kIOPSDesignCapacityKey as String] as? Double,
                  designCap > 0 else { continue }
            let health = maxCap / designCap
            events.append(TelemetryEvent(
                category: .power, value: health, source: source,
                metadata: ["metric": "battery_health"]))
            if let charging = desc[kIOPSIsChargingKey as String] as? Bool {
                events.append(TelemetryEvent(
                    category: .power, value: charging ? 1 : 0, source: source,
                    metadata: ["metric": "is_charging"]))
            }
            if let cycles = desc[kIOPSCycleCountKey as String] as? Int {
                // Cycle count rides along as context, not a scored metric.
                events.append(TelemetryEvent(
                    category: .power, value: Double(cycles), source: source,
                    metadata: ["metric": "cycle_count", "scored": "false"]))
            }
        }
        if events.isEmpty && !didLogNoBattery {
            didLogNoBattery = true
            NSLog("[AntiFreeze] No battery power source found (desktop Mac); battery metrics disabled.")
        }
        return events
    }
}

// MARK: - Processes

final class ProcessCollector: TelemetryCollector {
    let category: TelemetryCategory = .process
    let source = "libproc proc_pidinfo"
    /// pid -> (total user+system nanoseconds, sample date)
    private var previous: [pid_t: (UInt64, Date)] = [:]
    private let maxReported = 8

    func collect() -> [TelemetryEvent] {
        let now = Date()
        var pids = [pid_t](repeating: 0, count: 4096)
        let found = pids.withUnsafeMutableBytes { buf -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress,
                          Int32(buf.count))
        }
        guard found > 0 else { return [] }
        let n = min(Int(found) / MemoryLayout<pid_t>.size, pids.count)
        var usage: [(pid: pid_t, name: String, cores: Double)] = []
        var current: [pid_t: (UInt64, Date)] = [:]
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for i in 0..<n {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var taskInfo = proc_taskinfo()
            let ret = withUnsafeMutableBytes(of: &taskInfo) { buf -> Int32 in
                proc_pidinfo(pid, Int32(PROC_PIDTASKINFO), 0,
                             buf.baseAddress!, taskSize)
            }
            guard ret == taskSize else { continue }
            let totalNS = taskInfo.pti_total_user + taskInfo.pti_total_system
            current[pid] = (totalNS, now)
            if let (prevNS, prevDate) = previous[pid] {
                let wallS = now.timeIntervalSince(prevDate)
                guard wallS > 0.5, totalNS >= prevNS else { continue }
                let cores = Double(totalNS - prevNS) / 1_000_000_000.0 / wallS
                if cores > 0.05 { // ignore idle noise; bounds event volume
                    usage.append((pid, processName(pid: pid), cores))
                }
            }
        }
        previous = current
        let top = usage.sorted { $0.cores > $1.cores }.prefix(maxReported)
        return top.map { entry in
            TelemetryEvent(
                category: .process, value: entry.cores, source: source,
                metadata: ["metric": "cpu", "process": entry.name,
                           "pid": String(entry.pid)])
        }
    }

    private func processName(pid: pid_t) -> String {
        var bsdInfo = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ret = withUnsafeMutableBytes(of: &bsdInfo) { buf -> Int32 in
            proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, buf.baseAddress!, size)
        }
        guard ret == size else { return "pid-\(pid)" }
        // pbi_comm is a 16-byte C string, always NUL-terminated by the kernel.
        return withUnsafeBytes(of: bsdInfo.pbi_comm) { buf -> String in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
    }
}

// MARK: - GPU (best-effort)

final class GPUCollector: TelemetryCollector {
    let category: TelemetryCategory = .gpu
    let source = "IOAccelerator PerformanceStatistics"
    private var didLogUnavailable = false

    func collect() -> [TelemetryEvent] {
        // GPU introspection is the least standardized of these APIs across
        // Apple Silicon vs Intel. Best-effort: emit when present, stay silent
        // (with one log line) when not. Never synthesize a value.
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else {
            logOnce(); return []
        }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                // Key names vary by GPU/driver; try the known ones.
                for key in ["Device Utilization %", "GPU Utilization %", "utilization"] {
                    if let v = stats[key] as? Double {
                        return [TelemetryEvent(
                            category: .gpu, value: v / 100.0, source: source,
                            metadata: ["metric": "utilization"])]
                    }
                    if let v = stats[key] as? Int {
                        return [TelemetryEvent(
                            category: .gpu, value: Double(v) / 100.0, source: source,
                            metadata: ["metric": "utilization"])]
                    }
                }
            }
            service = IOIteratorNext(iterator)
        }
        logOnce()
        return []
    }

    private func logOnce() {
        if !didLogUnavailable {
            didLogUnavailable = true
            NSLog("[AntiFreeze] GPU utilization unavailable on this hardware; metric disabled.")
        }
    }
}
