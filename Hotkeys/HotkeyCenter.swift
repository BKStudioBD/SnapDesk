import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut described with a Carbon virtual key code and
/// Carbon modifier mask. Codable so it can be saved in user settings.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier flags: cmdKey, shiftKey, optionKey, controlKey

    /// Human-readable, e.g. "⌘⇧2".
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyName(keyCode)
        return s
    }

    /// (keyEquivalent, modifierMask) for displaying this shortcut in an NSMenuItem.
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags) {
        var m: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        if modifiers & UInt32(optionKey)  != 0 { m.insert(.option) }
        if modifiers & UInt32(shiftKey)   != 0 { m.insert(.shift) }
        if modifiers & UInt32(cmdKey)     != 0 { m.insert(.command) }
        let name = Hotkey.keyName(keyCode)
        return (name.count == 1 ? name.lowercased() : "", m)
    }

    private static let keyNameMap: [UInt32: String] = [
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_Minus): "-", UInt32(kVK_ANSI_Equal): "=",
            UInt32(kVK_ANSI_Comma): ",", UInt32(kVK_ANSI_Period): ".",
            UInt32(kVK_ANSI_Slash): "/", UInt32(kVK_ANSI_Semicolon): ";",
            UInt32(kVK_Space): "Space", UInt32(kVK_Tab): "\u{21E5}", UInt32(kVK_Return): "\u{21A9}",
            UInt32(kVK_UpArrow): "\u{2191}", UInt32(kVK_DownArrow): "\u{2193}",
            UInt32(kVK_LeftArrow): "\u{2190}", UInt32(kVK_RightArrow): "\u{2192}",
            UInt32(kVK_ANSI_LeftBracket): "[", UInt32(kVK_ANSI_RightBracket): "]",
            UInt32(kVK_ANSI_Quote): "'", UInt32(kVK_ANSI_Backslash): "\\",
            UInt32(kVK_ANSI_Grave): "`", UInt32(kVK_Delete): "\u{232B}",
            UInt32(kVK_ForwardDelete): "\u{2326}", UInt32(kVK_Escape): "\u{238B}",
            UInt32(kVK_Home): "\u{2196}", UInt32(kVK_End): "\u{2198}",
            UInt32(kVK_PageUp): "\u{21DE}", UInt32(kVK_PageDown): "\u{21DF}",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
    static func keyName(_ code: UInt32) -> String {
        return keyNameMap[code] ?? "Key\(code)"
    }
}

/// Registers global hotkeys via Carbon's `RegisterEventHotKey`. Carbon hotkeys
/// are the most reliable way to grab system-wide shortcuts and do NOT require
/// Accessibility permission.
final class HotkeyCenter {
    private struct Registration {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        installHandlerIfNeeded()
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Registers `hotkey`; the returned id can be used to unbind later.
    @discardableResult
    func bind(_ hotkey: Hotkey, action: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("SnapDesk: failed to register hotkey \(hotkey.displayString) (status \(status))")
            // Silent failure looked like the app was broken — tell the user the
            // combo is owned by another app so they rebind it.
            Notifier.error("Shortcut unavailable",
                           "\(hotkey.displayString) is used by another app — pick a different combo in Settings → Shortcuts.")
            return 0
        }
        registrations[id] = Registration(ref: ref, action: action)
        return id
    }

    func unbind(_ id: UInt32) {
        if let reg = registrations[id] {
            UnregisterEventHotKey(reg.ref)
            registrations[id] = nil
        }
    }

    func unregisterAll() {
        for (_, reg) in registrations { UnregisterEventHotKey(reg.ref) }
        registrations.removeAll()
    }

    fileprivate func handle(id: UInt32) {
        registrations[id]?.action()
    }

    // MARK: - Carbon plumbing

    private static let signature: OSType = {
        // Four-char code 'SNPD'.
        let chars = Array("SNPD".utf8)
        return chars.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { center.handle(id: hkID.id) }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }
}
