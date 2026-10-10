import Foundation

// MARK: - Privacy (Phase 15, foundation)
//
// Consent architecture, wired in from the first phase that collects real
// data — not retrofitted later. Default is fully local-only; nothing leaves
// the device unless the user explicitly opts into a higher tier.

enum PrivacyTier: String, Codable, CaseIterable, Identifiable {
    case localOnly
    case anonymousAggregate
    case fullDiagnostic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localOnly: return "Local only"
        case .anonymousAggregate: return "Anonymous aggregate telemetry"
        case .fullDiagnostic: return "Full diagnostic sharing"
        }
    }

    var explanation: String {
        switch self {
        case .localOnly:
            return "Everything stays on this Mac. No telemetry ever leaves the device."
        case .anonymousAggregate:
            return "Contributes aggregated, anonymized signals (never app names, file paths, or log text) to improve AntiFreeze's models."
        case .fullDiagnostic:
            return "For a specific support interaction: time-boxed, per-instance consent. Not a standing setting."
        }
    }
}

final class PrivacySettings: ObservableObject {
    static let shared = PrivacySettings()

    /// Hard allowlist of what may EVER leave the device under the
    /// anonymous-aggregate tier. Enforced at serialization time; the
    /// ingestion boundary must enforce it server-side too (Phase 13).
    /// Never: raw process names of non-system apps, file paths, raw log text.
    static let exportAllowlist: Set<String> = [
        "category", "metric", "value", "severity", "timestamp", "source",
    ]

    @Published var tier: PrivacyTier {
        didSet {
            UserDefaults.standard.set(tier.rawValue, forKey: "af.privacyTier")
            if tier == .localOnly {
                // Consent changes take effect immediately: halt anything
                // that would upload the now-disallowed category.
                NotificationCenter.default.post(name: .afPrivacyDowngraded, object: nil)
            }
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "af.privacyTier")
        self.tier = PrivacyTier(rawValue: raw ?? "") ?? .localOnly
    }

    /// Serialize one event for export, stripping everything outside the
    /// allowlist. Used by any future diagnostic-export path (Phase 11).
    func sanitizedForExport(_ event: TelemetryEvent) -> [String: String] {
        var out: [String: String] = [:]
        let candidates: [String: String] = [
            "category": event.category.rawValue,
            "metric": event.metric,
            "value": String(event.value),
            "severity": event.severity.rawValue,
            "timestamp": String(event.timestamp.timeIntervalSince1970),
            "source": event.source,
        ]
        for (k, v) in candidates where Self.exportAllowlist.contains(k) {
            out[k] = v
        }
        return out
    }
}

extension Notification.Name {
    static let afPrivacyDowngraded = Notification.Name("com.luckyclover.antifreeze.privacyDowngraded")
}
