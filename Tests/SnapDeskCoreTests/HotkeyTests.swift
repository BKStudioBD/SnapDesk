import Testing
import AppKit
import Carbon.HIToolbox
@testable import SnapDeskCore

/// How a binding is displayed and how it maps to a menu item.
struct HotkeyDisplay {
    @Test("Modifier glyphs render in the macOS order ⌃⌥⇧⌘",
          arguments: [
            (UInt32(controlKey), "⌃2"),
            (UInt32(cmdKey | shiftKey), "⇧⌘2"),
            (UInt32(controlKey | optionKey | shiftKey | cmdKey), "⌃⌥⇧⌘2"),
          ])
    func displaysModifiers(_ mods: UInt32, _ expected: String) {
        let hk = Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: mods)
        #expect(hk.displayString == expected)
    }

    @Test func menuEquivalentLowercasesSingleCharacters() {
        let hk = Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
        let (key, mask) = hk.menuKeyEquivalent
        #expect(key == "s", "NSMenuItem expects the lowercase character")
        #expect(mask.contains(.command))
        #expect(mask.contains(.shift))
    }

    @Test("A multi-character key name yields no menu key equivalent")
    func multiCharacterKeysHaveNoEquivalent() {
        let hk = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        #expect(hk.menuKeyEquivalent.0.isEmpty)
    }

    @Test("Bindings survive the JSON round-trip used to persist them")
    func codableRoundTrip() throws {
        let hk = Hotkey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
        let data = try JSONEncoder().encode(hk)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == hk)
    }
}

/// What the shortcut recorder will and won't accept. A global hotkey with a weak
/// modifier eats ordinary typing system-wide, so these are guard rails, not taste.
struct HotkeyRecording {
    /// `keyEvent` really can return nil; a `!` here traps the run instead of
    /// failing this one test.
    private func event(_ key: Int, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "x", charactersIgnoringModifiers: "x",
                                      isARepeat: false, keyCode: UInt16(key)))
    }

    @Test("Combos without a ⌘/⌃/⌥ modifier are refused", .tags(.regression),
          arguments: [NSEvent.ModifierFlags(), .shift, .capsLock])
    func refusesWeakModifiers(_ flags: NSEvent.ModifierFlags) throws {
        // Shift-only would swallow every capital letter the user types.
        #expect(Hotkey(event: try event(kVK_ANSI_S, flags)) == nil)
    }

    @Test("A real modifier is accepted, with or without Shift alongside it",
          arguments: [NSEvent.ModifierFlags.command, .control, .option,
                      [.command, .shift], [.control, .option]])
    func acceptsRealModifiers(_ flags: NSEvent.ModifierFlags) throws {
        #expect(Hotkey(event: try event(kVK_ANSI_S, flags)) != nil)
    }

    @Test func capturesTheKeyCodeAndModifiers() throws {
        let hk = try #require(Hotkey(event: try event(kVK_ANSI_S, [.command, .shift])))
        #expect(hk.keyCode == UInt32(kVK_ANSI_S))
        #expect(hk.modifiers & UInt32(cmdKey) != 0)
        #expect(hk.modifiers & UInt32(shiftKey) != 0)
        #expect(hk.modifiers & UInt32(controlKey) == 0)
    }
}
