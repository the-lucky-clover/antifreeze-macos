import SwiftUI
import AppKit
import UserNotifications

// MARK: - Permissions onboarding (Phase 12, scaffold)
//
// Each permission gets one screen: what it is, why AntiFreeze wants it, a
// direct link to the right System Settings pane, and a live status check.
// The app remains useful with a subset granted — the dashboard shows which
// capabilities are limited, with a one-tap path back here.

enum PermissionKind: String, CaseIterable, Identifiable {
    case fullDiskAccess
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .notifications: return "Notifications"
        }
    }

    var why: String {
        switch self {
        case .fullDiskAccess:
            return "AntiFreeze reads crash and panic reports macOS already saves " +
                "(~/Library/Logs/DiagnosticReports and /Library/Logs/DiagnosticReports) " +
                "to tell you why your Mac froze. Without it, crash/panic analysis " +
                "(Phase 2–3) can't run — live telemetry still works."
        case .notifications:
            return "So AntiFreeze can warn you — \"your Mac is likely to freeze " +
                "within 5 minutes\" — instead of making you stare at a menu bar icon."
        }
    }

    /// Direct link to the relevant System Settings pane.
    var settingsURL: URL? {
        switch self {
        case .fullDiskAccess:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        }
    }
}

/// Live status check per permission. Full Disk Access has no query API, so
/// the honest check is attempting the actual read it gates.
struct PermissionStatus {
    static func isGranted(_ kind: PermissionKind, completion: @escaping (Bool) -> Void) {
        switch kind {
        case .fullDiskAccess:
            DispatchQueue.global(qos: .utility).async {
                let fm = FileManager.default
                let granted = (try? fm.contentsOfDirectory(
                    atPath: "/Library/Logs/DiagnosticReports")) != nil
                DispatchQueue.main.async { completion(granted) }
            }
        case .notifications:
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                DispatchQueue.main.async {
                    completion(settings.authorizationStatus == .authorized)
                }
            }
        }
    }

    static func request(_ kind: PermissionKind, completion: @escaping (Bool) -> Void) {
        switch kind {
        case .fullDiskAccess:
            // No programmatic request exists; the user grants it in Settings.
            // Open the pane and let them re-check.
            if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
            completion(false)
        case .notifications:
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
        }
    }
}

struct PermissionsOnboardingView: View {
    @State private var step = 0
    @State private var granted: [PermissionKind: Bool] = [:]
    @State private var checking = false
    var onDone: () -> Void = {}

    private var kinds: [PermissionKind] { PermissionKind.allCases }

    var body: some View {
        VStack(spacing: 0) {
            if step < kinds.count {
                permissionScreen(kinds[step])
            } else {
                doneScreen
            }
        }
        .frame(width: 420, height: 340)
        .onAppear { check(kinds[step]) }
    }

    private func permissionScreen(_ kind: PermissionKind) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step + 1) of \(kinds.count + 1)")
                .font(.caption).foregroundColor(.secondary)
            Text(kind.title).font(.title2).bold()
            Text(kind.why).font(.body).fixedSize(horizontal: false, vertical: true)
            HStack {
                if checking {
                    ProgressView().scaleEffect(0.8)
                    Text("Checking…").font(.caption).foregroundColor(.secondary)
                } else if granted[kind] == true {
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green).font(.callout)
                } else {
                    Label("Not granted", systemImage: "xmark.circle")
                        .foregroundColor(.secondary).font(.callout)
                }
                Spacer()
                Button("Re-check") { check(kind) }.buttonStyle(.link)
            }
            Spacer()
            HStack {
                Button("Skip for now") { advance() }
                    .buttonStyle(.link)
                Spacer()
                Button(granted[kind] == true ? "Continue" : "Grant access") {
                    if granted[kind] == true { advance() }
                    else {
                        PermissionStatus.request(kind) { _ in
                            // Re-check after the user visits Settings.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                check(kind)
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            Text("AntiFreeze stays useful without this — the dashboard will show what's limited.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(24)
    }

    private var doneScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "snowflake").font(.system(size: 48)).foregroundColor(.blue)
            Text("You're set").font(.title2).bold()
            Text("AntiFreeze is now watching your Mac's stability. " +
                 "Open this anytime from the menu bar to review permissions.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            Button("Start monitoring") { onDone() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }

    private func check(_ kind: PermissionKind) {
        checking = true
        PermissionStatus.isGranted(kind) { ok in
            granted[kind] = ok
            checking = false
        }
    }

    private func advance() {
        step += 1
        if step < kinds.count { check(kinds[step]) }
    }
}
