import AppKit
import CoreGraphics
import ApplicationServices

/// One place for every macOS privacy permission SnapDesk touches, written to
/// match how TCC actually behaves (verified against Apple's model):
///
/// • **Screen Recording** (`kTCCServiceScreenCapture`): needed by screenshots,
///   OCR, recording and scrolling capture. macOS keys the grant on the app's
///   code-signing *designated requirement*, not the binary hash, so with
///   SnapDesk's stable signing the grant persists across launches and updates.
///   Whether it is really live is decided by trying: a capture that comes back
///   blank is the only reliable signal, so `captureState` reports
///   `.needsRestart` after one, and clears itself after a capture that works.
///
/// • **Accessibility** (`AXIsProcessTrusted`): only needed to synthesize the
///   ⌘V keystroke for "paste from clipboard history". `AXIsProcessTrusted()`
///   caches its result for the process lifetime, so an in-process poll can't
///   see a fresh grant; we prompt + open Settings and let the next launch pick
///   it up (paste already degrades gracefully until then).
///
/// **Nothing here quits or relaunches the app.** It used to: a watcher polled
/// for the grant and restarted SnapDesk the moment it flipped on. For a
/// menu-bar app with no window that is indistinguishable from quitting by
/// itself, and on macOS Sequoia (15) / Tahoe (26) the system re-confirms Screen
/// Recording for *every* app periodically, so it happened on its own schedule
/// rather than the user's. The state is now reported to the menu bar and the
/// restart is a menu item the user clicks.
enum Permissions {

    /// Whether the five capture features can run right now, and if not, why.
    enum CaptureState: Equatable {
        /// Capture is working, or has not been shown otherwise.
        case ready
        /// Not granted. The user has to turn it on in System Settings.
        case needsGrant
        /// The grant says yes and a capture still came back blank, which is how
        /// macOS reports a permission it has not honoured for this process. A
        /// new process is the only fix; the next capture that works clears it.
        case needsRestart

        /// One line, in the user's terms, for the menu and the notification.
        var summary: String {
            switch self {
            case .ready: "Screen Recording is on"
            case .needsGrant: "Screen Recording is off"
            case .needsRestart: "Screen Recording is on. Restart to use it"
            }
        }
    }

    /// Posted whenever `captureState` changes, so the menu bar can say so.
    static let captureStateChanged = Notification.Name("SnapDeskCaptureStateChanged")

    // MARK: - State (cheap, never prompts)

    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Kept for the record at startup. Deliberately NOT a gate any more: see
    /// `state(hasGrant:blankCaptureSeen:)` for why the launch-time answer is
    /// the wrong thing to refuse on.
    private static let grantAtLaunch: Bool = CGPreflightScreenCaptureAccess()

    /// Call once at app startup, before any grant can change.
    static func primeLaunchState() { _ = grantAtLaunch }

    /// Set when a capture came back blank while the grant said yes. Cleared by
    /// the first capture that works again.
    private static var sawBlankCapture = false

    static var captureState: CaptureState {
        state(hasGrant: hasScreenRecording, blankCaptureSeen: sawBlankCapture)
    }

    /// The rule on its own, so it can be checked without a TCC grant.
    ///
    /// Judged on EVIDENCE, not on when the grant arrived. The old rule refused
    /// every capture for the whole life of a process that started before the
    /// grant did, on the theory that only a new process can use it. A menu-bar
    /// app runs for days: one instance here had been up for two and a half of
    /// them, and macOS re-confirms Screen Recording on its own schedule, so a
    /// single re-confirm left five shortcuts refusing to even try until someone
    /// restarted the app. Now it tries, and a frame that comes back blank is
    /// what says the permission is not really live.
    static func state(hasGrant: Bool, blankCaptureSeen: Bool) -> CaptureState {
        guard hasGrant else { return .needsGrant }
        return blankCaptureSeen ? .needsRestart : .ready
    }

    /// A capture came back empty though the grant says yes. That combination is
    /// how macOS reports a permission it has not actually honoured yet.
    static func noteBlankCapture() {
        guard !sawBlankCapture else { return }
        sawBlankCapture = true
        publish(captureState)
    }

    /// A capture worked, so whatever was wrong is over. Lets the app recover on
    /// its own instead of holding a complaint until someone restarts it.
    static func noteCaptureSucceeded() {
        guard sawBlankCapture else { return }
        sawBlankCapture = false
        publish(captureState)
    }

    // MARK: - Screen Recording

    /// True if capture is allowed right now. Callers abort when it returns
    /// false; the reason is already on the menu bar, and `stateDetail` gives
    /// them a sentence to put in front of the user.
    ///
    /// Deliberately silent otherwise: this runs on every ⌃1, ⌃2, ⌃5, ⌃6 and
    /// ⌃7, and a modal alert on each press was how one lapsed grant turned into
    /// a stack of dialogs.
    @discardableResult
    static func ensureScreenRecording() -> Bool {
        let state = captureState
        publish(state)
        // A known-bad state still lets the attempt through: the grant may have
        // become real since, and the capture itself is the only honest test.
        guard state != .needsGrant else {
            // Registers SnapDesk in the Screen Recording list so there is a row
            // to switch on. Prompts at most once per launch; macOS ignores the
            // rest, and the menu bar is carrying the message anyway.
            if !requestedThisLaunch {
                requestedThisLaunch = true
                CGRequestScreenCaptureAccess()
            }
            return false
        }
        return true
    }

    private static var requestedThisLaunch = false

    /// What to tell the user when a capture was refused, including the fix.
    static var stateDetail: String {
        switch captureState {
        case .ready:
            "Screen Recording is on."
        case .needsGrant:
            "Turn SnapDesk on in System Settings → Privacy & Security → Screen Recording, then restart SnapDesk from its menu."
        case .needsRestart:
            "The permission is on, but this copy of SnapDesk is still being handed empty frames. Restart SnapDesk from its menu."
        }
    }

    /// Just trigger the system request + open the pane. For UI (the Welcome
    /// window, the menu) that already guides the user.
    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        openScreenRecordingSettings()
    }

    // MARK: - Watching

    private static var watcher: Timer?
    private static var lastPublished: CaptureState?

    /// Keep the menu bar honest without anyone pressing anything. A grant can
    /// be revoked or re-confirmed by macOS at any time, and the only thing that
    /// changes here is what the icon and the menu say.
    ///
    /// Five seconds: `CGPreflightScreenCaptureAccess` is a TCC lookup, not a
    /// capture, and this is the difference between a dead hotkey the user has
    /// to guess about and one the menu bar has already explained.
    @MainActor
    static func startWatching() {
        guard watcher == nil else { return }
        publish(captureState)
        let timer = Timer(timeInterval: 5, repeats: true) { _ in publish(captureState) }
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    /// Posts only on a real change, so observers can rebuild a menu freely.
    private static func publish(_ state: CaptureState) {
        guard state != lastPublished else { return }
        lastPublished = state
        NotificationCenter.default.post(name: captureStateChanged, object: nil)
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
}
