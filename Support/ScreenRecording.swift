import AppKit
import CoreGraphics

/// Screen Recording permission gate. Screenshots and OCR both capture the
/// screen, so they need this TCC permission. The color picker and clipboard do
/// not — which is exactly why those keep working when permission is missing.
enum ScreenRecording {
    private static var watching = false

    /// Returns true if capture is allowed. If not, prompts the user, opens the
    /// right Settings pane, and starts watching for the grant so it can auto-
    /// relaunch the moment permission is turned on (macOS only honors the grant
    /// on a fresh process — the #1 "I allowed it but nothing works" cause).
    @discardableResult
    static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }

        // Triggers the system permission prompt / adds SnapDesk to the list.
        CGRequestScreenCaptureAccess()

        let alert = NSAlert()
        alert.messageText = "Turn on Screen Recording for SnapDesk"
        alert.informativeText = """
        SnapDesk needs Screen Recording to take screenshots and read text.

        1. In the window that opens, turn ON SnapDesk.
        2. That's it — SnapDesk restarts itself automatically so the permission \
        takes effect. (No need to quit or reopen anything.)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            watchForGrantThenRelaunch()
        }
        return false
    }

    /// Poll for the grant after the user opens Settings; the instant it flips
    /// on, relaunch so capture actually works — no manual quit-and-reopen.
    private static func watchForGrantThenRelaunch() {
        guard !watching else { return }
        watching = true
        let start = Date()
        let timer = Timer(timeInterval: 1.0, repeats: true) { t in
            // Give up quietly after 3 minutes (user closed Settings / gave up).
            if Date().timeIntervalSince(start) > 180 { t.invalidate(); watching = false; return }
            if CGPreflightScreenCaptureAccess() {
                t.invalidate(); watching = false
                let a = NSAlert()
                a.messageText = "Screen Recording enabled"
                a.informativeText = "SnapDesk will restart now so it can start capturing."
                a.addButton(withTitle: "Restart SnapDesk")
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
                InstallHelper.relaunchSelf()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
