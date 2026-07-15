import AppKit
import CoreGraphics

/// Screen Recording permission gate. Screenshots and OCR both capture the
/// screen, so they need this TCC permission. The color picker and clipboard do
/// not — which is exactly why those keep working when permission is missing.
enum ScreenRecording {

    /// Returns true if capture is allowed. If not, prompts the user and opens
    /// the right Settings pane, then returns false (caller should abort).
    @discardableResult
    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }

        // Triggers the system permission prompt / adds SnapDesk to the list.
        CGRequestScreenCaptureAccess()

        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        SnapDesk needs Screen Recording to take screenshots and read text.

        1. Open System Settings → Privacy & Security → Screen Recording
        2. Turn ON SnapDesk
        3. Quit SnapDesk and open it again (required by macOS)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
