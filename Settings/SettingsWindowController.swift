import AppKit
import SwiftUI

/// A real, app-owned settings window. The SwiftUI `Settings` scene is unreliable
/// in menu-bar (`.accessory`) apps, it often refuses to open or focus, so we
/// host `SettingsView` in a normal NSWindow we control directly.
final class SettingsWindowController: NSWindowController {
    init(settings: SettingsStore) {
        // Normal, solid, fully draggable + closable + minimizable window. (The
        // earlier transparent-titlebar + clear background hid the traffic-light
        // buttons and the drag area, so the window couldn't be moved or closed.)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "SnapDesk Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        window.contentViewController = NSHostingController(
            rootView: SettingsView().environmentObject(settings))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Activation can be refused for an accessory app, and then this window
        // opened BEHIND a full-screen frontmost app. The menu item and the
        // pre-record gear both looked dead. Force it visible, the same way the
        // welcome window and the permission alerts already do.
        window?.orderFrontRegardless()
    }
}
