import AppKit
import CoreGraphics
import ApplicationServices

/// One place for every macOS privacy permission SnapDesk touches, written to
/// match how TCC actually behaves (verified against Apple's model):
///
/// • **Screen Recording** (`kTCCServiceScreenCapture`) — needed by screenshots
///   and OCR. macOS keys the grant on the app's code-signing *designated
///   requirement*, not the binary hash, so with SnapDesk's stable signing the
///   grant persists across launches and updates. The one catch: a freshly-
///   granted permission is only honored by a NEW process — so after the user
///   flips it on we detect that and relaunch automatically (the #1 cause of
///   "I allowed it but nothing works" is the missing relaunch).
///
/// • **Accessibility** (`AXIsProcessTrusted`) — only needed to synthesize the
///   ⌘V keystroke for "paste from clipboard history". `AXIsProcessTrusted()`
///   caches its result for the process lifetime, so an in-process poll can't
///   see a fresh grant; we prompt + open Settings and let the next launch pick
///   it up (paste already degrades gracefully until then).
///
/// Note: on macOS Sequoia (15) / Tahoe (26) the system re-confirms Screen
/// Recording for *every* app periodically — that's Apple's design and can't be
/// disabled by any app (only MDM), so an occasional re-prompt is expected and
/// is NOT a lost grant.
enum Permissions {

    // MARK: - State (cheap, never prompts)

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    // MARK: - Screen Recording

    /// True if capture is allowed right now. If not, requests it, opens the
    /// Settings pane, and starts watching so SnapDesk can relaunch itself the
    /// instant the user turns it on — no manual quit-and-reopen. Callers should
    /// abort the current capture when this returns false.
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        if hasScreenRecording { return true }
        CGRequestScreenCaptureAccess()            // registers SnapDesk / prompts
        guideThenRelaunch(
            title: "Turn on Screen Recording for SnapDesk",
            body: """
            SnapDesk needs Screen Recording to take screenshots and read text.

            1. In the window that opens, turn ON SnapDesk.
            2. That's it — SnapDesk restarts itself so the permission takes \
            effect. No need to quit or reopen anything.
            """,
            pane: "Privacy_ScreenCapture",
            isGranted: { CGPreflightScreenCaptureAccess() })
        return false
    }

    /// Just trigger the system request + open the pane — NO alert or auto-
    /// relaunch. For UI (the Welcome window) that already guides the user and
    /// has its own "Relaunch" control.
    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        openScreenRecordingSettings()
    }

    // MARK: - Accessibility

    /// - Parameter prompt: false = silently register SnapDesk in the
    ///   Accessibility list (no dialog); true = show the system prompt + open
    ///   Settings. Returns the current trust state.
    @discardableResult
    static func ensureAccessibility(prompt: Bool = true) -> Bool {
        if hasAccessibility { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        // Passing the prompt option both registers the app and (when true) shows
        // the system's "open Accessibility settings" prompt.
        let granted = AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        if prompt && !granted { openPane("Privacy_Accessibility") }
        return granted
    }

    // MARK: - Open a Settings pane directly

    static func openScreenRecordingSettings() { openPane("Privacy_ScreenCapture") }
    static func openAccessibilitySettings() { openPane("Privacy_Accessibility") }

    private static func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Shared: guide the user, then auto-relaunch on grant

    private static var watching = false

    /// Show a one-time alert, open the Settings pane, then poll for the grant
    /// and relaunch the moment it flips on (Screen Recording only — the grant
    /// needs a fresh process to be honored). Safe to call repeatedly.
    private static func guideThenRelaunch(title: String, body: String, pane: String,
                                          isGranted: @escaping () -> Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openPane(pane)
        watchForGrant(isGranted: isGranted)
    }

    private static func watchForGrant(isGranted: @escaping () -> Bool) {
        guard !watching else { return }
        watching = true
        let start = Date()
        let timer = Timer(timeInterval: 1.0, repeats: true) { t in
            if Date().timeIntervalSince(start) > 180 {          // give up after 3 min
                t.invalidate(); watching = false; return
            }
            guard isGranted() else { return }
            t.invalidate(); watching = false
            let a = NSAlert()
            a.messageText = "Permission enabled"
            a.informativeText = "SnapDesk will restart now so it can start working."
            a.addButton(withTitle: "Restart SnapDesk")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            InstallHelper.relaunchSelf()
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
