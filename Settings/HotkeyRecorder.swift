import SwiftUI
import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// Posted while a shortcut is being recorded so the app can suspend its
    /// global hotkeys (otherwise pressing e.g. ⌃1 to REBIND it would fire the
    /// screenshot instead of being captured by the recorder).
    static let hotkeyRecordingBegan = Notification.Name("SnapDeskHotkeyRecordingBegan")
    static let hotkeyRecordingEnded = Notification.Name("SnapDeskHotkeyRecordingEnded")
}

extension Hotkey {
    /// Builds a Hotkey from a key-down event. Returns nil if no real key.
    init?(event: NSEvent) {
        var mods: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        if f.contains(.shift)   { mods |= UInt32(shiftKey) }
        if f.contains(.option)  { mods |= UInt32(optionKey) }
        if f.contains(.control) { mods |= UInt32(controlKey) }
        // Require at least one modifier so global hotkeys don't eat plain keys.
        guard mods != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }
}

/// Click to record a new global shortcut. Shows the current combo; while
/// recording, the next key press (with modifiers) becomes the binding. Esc
/// cancels. Combos already used by another action are rejected with a brief
/// "In use" flash instead of silently breaking the other shortcut.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var hotkey: Hotkey
    /// Returns true when the combo is already taken by ANOTHER action.
    var isConflict: (Hotkey) -> Bool = { _ in false }

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onCapture = { hotkey = $0 }
        b.isConflict = isConflict
        b.refresh(hotkey)
        return b
    }

    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.isConflict = isConflict
        if !nsView.isRecording { nsView.refresh(hotkey) }
    }
}

final class RecorderButton: NSButton {
    var onCapture: ((Hotkey) -> Void)?
    var isConflict: ((Hotkey) -> Bool) = { _ in false }
    private(set) var isRecording = false
    private var monitor: Any?
    private var blurObserver: NSObjectProtocol?
    private var current: Hotkey?

    init() {
        super.init(frame: .zero)
        bezelStyle = .roundRect
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { endRecording() }

    func refresh(_ hk: Hotkey) { current = hk; title = hk.displayString }

    @objc private func begin() {
        guard !isRecording else { return }
        isRecording = true
        title = "Press keys…"
        // Suspend the app's global hotkeys so they can be re-assigned.
        NotificationCenter.default.post(name: .hotkeyRecordingBegan, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            // A click outside this button while armed = cancel (otherwise every
            // ⌘-shortcut in the window kept getting captured as the binding).
            if event.type == .leftMouseDown {
                let p = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(p) { self.cancel() }
                return event
            }
            if event.keyCode == 53 { self.cancel(); return nil } // Esc cancels
            if let hk = Hotkey(event: event) {
                if self.isConflict(hk) {
                    self.flashInUse()
                    return nil
                }
                self.onCapture?(hk)
                self.refresh(hk)
                self.endRecording()
                return nil
            }
            return event
        }
        // If the window loses focus while armed, stop — otherwise the next
        // ⌘-combo anywhere in the app gets silently captured.
        blurObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.cancel() }
    }

    private func flashInUse() {
        title = "In use ✕"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.isRecording else { return }
            self.title = "Press keys…"
        }
    }

    private func cancel() {
        if let current { refresh(current) }
        endRecording()
    }

    private func endRecording() {
        guard isRecording || monitor != nil else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let blurObserver { NotificationCenter.default.removeObserver(blurObserver) }
        blurObserver = nil
        NotificationCenter.default.post(name: .hotkeyRecordingEnded, object: nil)
    }
}
