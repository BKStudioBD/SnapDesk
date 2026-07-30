import SwiftUI
import AppKit

// Entry point. The real work is wired up in AppDelegate so the app can live in
// the menu bar (LSUIElement) and own its global hotkeys + windows.
@main
struct SnapDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI's Settings scene binds ⌘, for free — but SnapDesk already has
        // its own fully-wired settings window (deep-links from Help and the
        // pre-record gear). Rather than show a SECOND, competing settings window,
        // this scene immediately hands ⌘, off to that one window and closes
        // itself, so there is exactly one settings window however it's opened.
        Settings {
            SettingsRedirect { appDelegate.coordinator.openSettings() }
        }
    }
}

/// Zero-size bridge: as soon as SwiftUI shows the Settings window, close it and
/// open SnapDesk's real settings window instead.
private struct SettingsRedirect: NSViewRepresentable {
    let open: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { [weak v] in
            v?.window?.close()
            open()
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
