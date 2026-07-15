import AppKit
import ApplicationServices

/// Accessibility (AX) permission gate. macOS grants this via
/// System Settings → Privacy & Security → Accessibility. Unlike Screen
/// Recording there is no Info.plist usage string — an app only appears in that
/// list once it calls one of the `AXIsProcessTrusted*` APIs. SnapDesk's global
/// hotkeys use Carbon and do not strictly require this, but having the grant
/// available unlocks deeper system interaction and lets the user pre-approve.
enum Accessibility {

    /// Current trust state. Cheap, no prompt.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Returns true if Accessibility is already granted. Otherwise shows the
    /// system prompt (which adds SnapDesk to the Accessibility list and offers
    /// an "Open System Settings" button) and returns false. Non-blocking.
    @discardableResult
    static func ensure(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Opens the Accessibility pane directly (used from a manual alert / menu).
    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
