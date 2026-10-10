import SwiftUI

// MARK: - Menu bar dashboard (Phase 9, Phase-1 scope)
//
// Proves the foundation runs: live per-metric values with severity dots,
// short trend sparklines from the local store, privacy tier control, and
// honest capability notes when permissions are missing.

struct MenuBarView: View {
    @ObservedObject var engine: SystemTelemetryEngine
    @ObservedObject var privacy = PrivacySettings.shared
    @State private var cpuHistory: [(Date, Double)] = []
    @State private var memHistory: [(Date, Double)] = []
    @State private var fdaGranted: Bool?
    var onOpenPermissions: () -> Void = {}

    private let shownMetrics: [(TelemetryCategory, String, String)] = [
        (.cpu, "usage", "CPU"),
        (.cpu, "max_core", "Hottest core"),
        (.memory, "pressure", "Memory pressure"),
        (.memory, "swap_pages", "Swap"),
        (.thermal, "state", "Thermal"),
        (.disk, "free_fraction", "Disk free"),
        (.power, "battery_health", "Battery health"),
        (.gpu, "utilization", "GPU"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            metricsList
            Divider()
            sparkline(title: "CPU — last samples", history: cpuHistory,
                      format: { String(format: "%.0f%%", $0 * 100) })
            sparkline(title: "Memory pressure — last samples", history: memHistory,
                      format: { ["Normal", "Warning", "Critical"][min(2, Int($0))] })
            Divider()
            capabilityNotes
            Divider()
            privacyRow
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            refreshHistories()
            PermissionStatus.isGranted(.fullDiskAccess) { fdaGranted = $0 }
        }
        .onReceive(engine.$latest) { _ in refreshHistories() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "snowflake").foregroundColor(.blue)
            Text("AntiFreeze").font(.headline)
            Spacer()
            Circle()
                .fill(engine.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(engine.isRunning ? "Monitoring" : "Stopped")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var metricsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shownMetrics, id: \.1) { cat, metric, label in
                let key = "\(cat.rawValue).\(metric)"
                if let event = engine.latest[key] {
                    HStack {
                        severityDot(event.severity)
                        Text(label).font(.callout)
                        Spacer()
                        Text(formatted(event)).font(.callout).monospacedDigit()
                    }
                }
            }
            if engine.latest.isEmpty {
                Text("Collecting first samples…").font(.callout)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func sparkline(title: String, history: [(Date, Double)],
                           format: (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            SparklineView(values: history.map(\.1))
                .frame(height: 36)
            if let last = history.first {
                Text("now: \(format(last.1))").font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var capabilityNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if fdaGranted == false {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Crash & panic analysis limited")
                            .font(.callout).bold()
                        Text("Full Disk Access not granted — live telemetry unaffected.")
                            .font(.caption).foregroundColor(.secondary)
                        Button("Open permissions") { onOpenPermissions() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            Text("Local-only mode: nothing leaves this Mac.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var privacyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Telemetry sharing").font(.caption).foregroundColor(.secondary)
            Picker("", selection: $privacy.tier) {
                ForEach(PrivacyTier.allCases) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .pickerStyle(.radioGroup)
            Text(privacy.tier.explanation).font(.caption2)
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshHistories() {
        cpuHistory = TelemetryStore.shared.recentSamples(
            category: .cpu, metric: "usage", limit: 60)
        memHistory = TelemetryStore.shared.recentSamples(
            category: .memory, metric: "pressure", limit: 60)
    }

    private func severityDot(_ s: Severity) -> some View {
        Circle()
            .fill(severityColor(s))
            .frame(width: 8, height: 8)
    }

    private func severityColor(_ s: Severity) -> Color {
        switch s {
        case .info: return .green
        case .watch: return .yellow
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func formatted(_ e: TelemetryEvent) -> String {
        switch (e.category, e.metric) {
        case (.cpu, _): return String(format: "%.0f%%", e.value * 100)
        case (.memory, "pressure"):
            return ["Normal", "Warning", "Critical"][min(2, Int(e.value))]
        case (.memory, _): return "\(Int(e.value).formatted()) pages"
        case (.thermal, _):
            return ["Nominal", "Fair", "Serious", "Critical"][min(3, Int(e.value))]
        case (.disk, "free_fraction"): return String(format: "%.0f%%", e.value * 100)
        case (.disk, _): return String(format: "%.1f ms", e.value)
        case (.power, "battery_health"): return String(format: "%.0f%%", e.value * 100)
        case (.power, _): return String(format: "%.0f", e.value)
        case (.gpu, _): return String(format: "%.0f%%", e.value * 100)
        case (.process, _): return String(format: "%.1f cores", e.value)
        }
    }
}

// MARK: - Sparkline

struct SparklineView: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                Path { path in
                    let maxV = max(values.max() ?? 1, 0.0001)
                    let stepX = geo.size.width / CGFloat(values.count - 1)
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height - (CGFloat(v) / CGFloat(maxV)) * geo.size.height
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.blue, lineWidth: 1.5)
            } else {
                Text("—").foregroundColor(.secondary)
            }
        }
    }
}
