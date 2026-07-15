import SwiftUI

// Entry point. The real work is wired up in AppDelegate so the app can live in
// the menu bar (LSUIElement) and own its global hotkeys + windows.
@main
struct SnapDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No primary window — SnapDesk is a menu-bar utility. The Settings scene
        // gives us the standard ⌘, settings window for free.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.coordinator.settings)
        }
    }
}
