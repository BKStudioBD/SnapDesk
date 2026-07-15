import AppKit
import Carbon.HIToolbox

/// Pastes the current clipboard into another app by synthesizing ⌘V — the
/// "Double-Click to Paste" behavior. Requires Accessibility permission (the app
/// already registers for it); if missing, prompts and does nothing this time.
enum Paster {

    /// Activates `target` (if requested) and sends ⌘V to it.
    ///
    /// The item is already on the clipboard before this runs, so paste degrades
    /// gracefully: we ALWAYS attempt the keystroke (AXIsProcessTrusted() caches
    /// stale `false` within a process, so gating on it would wrongly block paste
    /// right after the user grants permission). If access is missing we prompt
    /// once and tell the user the item is copied — they can ⌘V manually.
    /// Open the Accessibility pane at most once per session when paste is
    /// blocked — the system's own prompt only appears the very first time ever.
    private static var openedAccessibilityPane = false

    static func paste(to target: NSRunningApplication?, activate: Bool) {
        let trusted = Permissions.hasAccessibility
        if !trusted { _ = Permissions.ensureAccessibility(prompt: true) }   // ask once, non-blocking
        let followUp = {
            if !trusted {
                Notifier.info("Copied — allow paste once",
                              "Turn ON SnapDesk under Accessibility (Settings just opened), then double-click again. For now press ⌘V.")
                if !openedAccessibilityPane {
                    openedAccessibilityPane = true
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        if activate, let target {
            // Activation is async (heavy app / other Space) — a fixed delay can
            // fire ⌘V into the WRONG app. Wait for the target to actually become
            // active, with a timeout fallback.
            target.activate()
            waitForActivation(of: target, timeout: 1.2) {
                // Activated in time → HID tap (frontmost = target). Timed out →
                // post to the target's PID so ⌘V never lands in the wrong app.
                sendCommandV(target.isActive ? nil : target)
                followUp()
            }
        } else {
            // Not activating: post straight to the target's PID so the keystroke
            // can't land in whatever happens to be frontmost (often SnapDesk
            // itself, mid-window-close).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                sendCommandV(target)
                followUp()
            }
        }
    }

    private static func waitForActivation(of target: NSRunningApplication,
                                          timeout: TimeInterval,
                                          then body: @escaping () -> Void) {
        var token: NSObjectProtocol?
        var done = false
        let fire = {
            guard !done else { return }
            done = true
            if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
            // One beat so the app's key window is ready for the keystroke.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: body)
        }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == target.processIdentifier { fire() }
        }
        if target.isActive { fire(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { fire() }   // fallback
    }

    /// Synthesize ⌘V. `target != nil` → post to that PID; else the HID tap
    /// (frontmost app). NOTE: do NOT set keyboardSetUnicodeString here — a
    /// ⌘-event carrying a unicode string is not recognized as the paste
    /// shortcut (verified empirically); plain virtual-key ⌘V works.
    private static func sendCommandV(_ target: NSRunningApplication?) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        if let target {
            down?.postToPid(target.processIdentifier)
            up?.postToPid(target.processIdentifier)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
