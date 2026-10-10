import Foundation

// MARK: - Telemetry schema (Phase 1)
//
// The common contract every later phase reads from. One event = one sampled
// metric at one point in time. `metric` (in metadata["metric"]) disambiguates
// the unit of `value`; the unit/threshold table below is the single source of
// truth so "value" is never ambiguous downstream.

enum TelemetryCategory: String, Codable, CaseIterable {
    case cpu
    case memory
    case gpu
    case disk
    case thermal
    case power
    case process
}

enum Severity: String, Codable, Comparable {
    case info
    case watch
    case warning
    case critical

    // Comparable so the adaptive sampler can rank "worst current severity".
    private var rank: Int {
        switch self {
        case .info: return 0
        case .watch: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rank < rhs.rank
    }
}

struct TelemetryEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: TelemetryCategory
    /// Normalized numeric value. Units are defined per (category, metric) in
    /// `TelemetryUnits.table` — never assume a unit from the category alone.
    let value: Double
    /// Computed at capture time from the threshold table, not reinterpreted
    /// downstream.
    let severity: Severity
    /// Which API/subsystem produced this (debugging + audit trail).
    let source: String
    /// Must contain "metric" (the unit-table key). May carry extra context
    /// such as "process" for process-category events.
    let metadata: [String: String]?

    var metric: String { metadata?["metric"] ?? "default" }

    init(
        timestamp: Date = Date(),
        category: TelemetryCategory,
        value: Double,
        source: String,
        metadata: [String: String]? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.category = category
        self.value = value
        self.source = source
        self.metadata = metadata
        let metric = metadata?["metric"] ?? "default"
        self.severity = TelemetryUnits.severity(for: category, metric: metric, value: value)
    }
}

// MARK: - Unit + threshold table
//
// direction: "high" means larger values are worse (usage, pressure);
// "low" means smaller values are worse (free disk fraction, battery health).

struct TelemetryUnits {
    struct Entry {
        let unit: String
        let description: String
        let direction: String // "high" | "low"
        let watch: Double
        let warning: Double
        let critical: Double
    }

    // Key: "<category>.<metric>"
    static let table: [String: Entry] = [
        "cpu.usage": Entry(
            unit: "fraction 0..1", description: "Aggregate CPU usage across all cores",
            direction: "high", watch: 0.75, warning: 0.88, critical: 0.96),
        "cpu.max_core": Entry(
            unit: "fraction 0..1", description: "Hottest single core's usage",
            direction: "high", watch: 0.85, warning: 0.93, critical: 0.98),
        "memory.pressure": Entry(
            unit: "level 0/1/2", description: "Memory pressure: 0 normal, 1 warning, 2 critical",
            direction: "high", watch: 1, warning: 2, critical: 3),
        "memory.swap_pages": Entry(
            unit: "pages", description: "Pages currently swapped out (trend matters, not point value)",
            direction: "high", watch: 250_000, warning: 750_000, critical: 1_500_000),
        "memory.compressor_pages": Entry(
            unit: "pages", description: "Pages held by the memory compressor (early-warning signal)",
            direction: "high", watch: 500_000, warning: 1_250_000, critical: 2_500_000),
        "thermal.state": Entry(
            unit: "level 0..3", description: "ProcessInfo.thermalState: 0 nominal, 1 fair, 2 serious, 3 critical",
            direction: "high", watch: 1, warning: 2, critical: 3),
        "disk.free_fraction": Entry(
            unit: "fraction 0..1", description: "Free space on the boot volume",
            direction: "low", watch: 0.15, warning: 0.08, critical: 0.03),
        "disk.io_latency_ms": Entry(
            unit: "milliseconds", description: "Average storage I/O latency (best-effort via IOKit)",
            direction: "high", watch: 25, warning: 75, critical: 200),
        "power.battery_health": Entry(
            unit: "fraction 0..1", description: "Max capacity / design capacity",
            direction: "low", watch: 0.85, warning: 0.75, critical: 0.60),
        "power.is_charging": Entry(
            unit: "0/1", description: "Whether the Mac is currently on charger power",
            direction: "high", watch: 2, warning: 2, critical: 2), // informational only
        "gpu.utilization": Entry(
            unit: "fraction 0..1", description: "GPU utilization (best-effort; often unavailable)",
            direction: "high", watch: 0.80, warning: 0.90, critical: 0.97),
        "process.cpu": Entry(
            unit: "fraction 0..1", description: "Per-process CPU usage (fraction of one core's capacity x cores)",
            direction: "high", watch: 1.5, warning: 2.5, critical: 3.5),
    ]

    static func severity(for category: TelemetryCategory, metric: String, value: Double) -> Severity {
        guard let entry = table["\(category.rawValue).\(metric)"] else { return .info }
        if entry.direction == "high" {
            if value >= entry.critical { return .critical }
            if value >= entry.warning { return .warning }
            if value >= entry.watch { return .watch }
        } else {
            if value <= entry.critical { return .critical }
            if value <= entry.warning { return .warning }
            if value <= entry.watch { return .watch }
        }
        return .info
    }

    /// Human-readable unit for a metric, for UI display.
    static func unit(for category: TelemetryCategory, metric: String) -> String {
        table["\(category.rawValue).\(metric)"]?.unit ?? ""
    }
}
