import SwiftUI
import AppKit

// MARK: - AntiFreeze app entry (Prompt 1)
//
// Menu-bar-only app (LSUIElement): no dock icon, no main window. The
// NSStatusItem owns an NSPopover hosting the SwiftUI dashboard; the
// SystemTelemetryEngine starts on launch.

@main
struct AntiFreezeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Menu-bar-only: no windows. Settings scene keeps SwiftUI happy.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let engine = SystemTelemetryEngine()
    private var permissionsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "snowflake",
                                   accessibilityDescription: "AntiFreeze")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        let view = MenuBarView(engine: engine, onOpenPermissions: { [weak self] in
            self?.openPermissions()
        })
        popover.contentViewController = NSHostingController(rootView: view)
        popover.behavior = .transient

        engine.start()

        // First-run permissions flow, once.
        if !UserDefaults.standard.bool(forKey: "af.onboardingDone") {
            openPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openPermissions() {
        if let w = permissionsWindow {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = PermissionsOnboardingView(onDone: { [weak self] in
            UserDefaults.standard.set(true, forKey: "af.onboardingDone")
            self?.permissionsWindow?.close()
            self?.permissionsWindow = nil
        })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "AntiFreeze — Permissions"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        permissionsWindow = window
    }
}
