import Testing
import AppKit
@testable import SnapDeskCore

/// These cover the PURE parts of `ClipboardManager` only — deliberately nothing
/// that touches `NSPasteboard.general`. A test that wrote to the real pasteboard
/// would clobber whatever the person running it had copied.

/// The trailing-newline trim. Copy a whole line out of a terminal, an editor or a
/// table cell and the app appends "\n"; pasting that verbatim drops the caret to
/// the START OF THE NEXT LINE, and in a message field it SENDS.
struct PasteboardTextTests {
    @Test("A trailing newline is removed", .tags(.regression), arguments: [
        ("hello\n", "hello"),
        ("hello\r\n", "hello"),      // one grapheme
        ("hello\r", "hello"),
        ("a\n\n\n", "a"),            // however many
        ("hello\u{2028}", "hello"),  // Unicode line separator
        ("hello\u{2029}", "hello"),  // Unicode paragraph separator
    ])
    func stripsTrailingNewlines(_ input: String, _ expected: String) {
        #expect(ClipboardManager.pasteboardText(input) == expected)
    }

    @Test("Only the END is trimmed — indentation and inner breaks survive",
          .tags(.regression), arguments: [
        ("line1\nline2\n", "line1\nline2"),
        ("    indented\n", "    indented"),
        ("func f() {\n  x\n}\n", "func f() {\n  x\n}"),
        ("hello \n", "hello "),      // a trailing SPACE is not a newline
        ("hello", "hello"),          // nothing to do
        ("", ""),
    ])
    func leavesEverythingElseAlone(_ input: String, _ expected: String) {
        #expect(ClipboardManager.pasteboardText(input) == expected)
    }

    @Test("An item that is nothing but newlines pastes as-is, not as nothing")
    func neverPastesEmpty() {
        #expect(ClipboardManager.pasteboardText("\n\n\n") == "\n\n\n")
        #expect(ClipboardManager.pasteboardText("\n") == "\n")
    }
}

/// The in-memory text cap. Counting Characters instead of bytes let multi-byte
/// text (CJK, emoji) keep roughly 4× the intended budget.
struct ByteCapTests {
    @Test func leavesShortTextUntouched() {
        #expect(ClipboardManager.cappedByBytes("hello", 1024) == "hello")
    }

    @Test("The cap is on BYTES, not characters", .tags(.regression))
    func capsOnBytes() {
        // Each of these is 3 UTF-8 bytes, so 10 of them is 30 bytes.
        let cjk = String(repeating: "漢", count: 10)
        #expect(cjk.count == 10)
        #expect(cjk.utf8.count == 30)
        let capped = ClipboardManager.cappedByBytes(cjk, 12)
        #expect(capped.utf8.count <= 12)
        #expect(capped.count == 4, "12 bytes fits four 3-byte characters")
    }

    @Test("Truncation never splits a character, even mid-emoji")
    func neverSplitsAScalar() {
        // A family emoji is a single Character of many bytes.
        let emoji = "👨‍👩‍👧‍👦"
        let capped = ClipboardManager.cappedByBytes(emoji + emoji, emoji.utf8.count + 3)
        #expect(capped.utf8.count <= emoji.utf8.count + 3)
        // Whatever survived must still be valid, whole characters.
        #expect(capped.unicodeScalars.allSatisfy { $0.value != 0xFFFD },
                "no replacement characters — nothing was cut in half")
        #expect(capped == emoji, "the second one didn't fit, so only the first is kept")
    }

    @Test func handlesAZeroBudget() {
        #expect(ClipboardManager.cappedByBytes("hello", 0) == "")
    }
}

/// The two structural promises about snippets: the history cap never evicts one, and
/// "clear history when SnapDesk quits" never touches one. Both are single `||`
/// clauses in one-line filters, so without a test either could be deleted in a
/// refactor and start silently destroying something the person typed by hand.
struct ClipboardRetentionTests {
    private func history(_ s: String, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(kind: .text(s), pinned: pinned)
    }
    private func snippet(_ title: String) -> ClipboardItem {
        ClipboardItem(snippet: Snippet(title: title, body: "body"))
    }

    @Test("The cap counts captured, unstarred rows only", .tags(.regression))
    func trimKeepsSnippetsAndStars() {
        let items = [snippet("address"), history("kept", pinned: true),
                     history("one"), history("two"), history("three")]
        let out = ClipboardManager.trimmed(items, cap: 2)
        #expect(out.count == 4, "got \(out.map(\.preview))")
        #expect(out.contains { $0.isSnippet }, "a snippet is not a trace of copying")
        #expect(out.contains { $0.pinned }, "starring is exactly a request not to evict")
        #expect(out.contains { $0.preview == "three" } == false, "the oldest unstarred goes")
    }

    @Test("A list of nothing but snippets is never trimmed, whatever the cap")
    func trimNeverEvictsASnippet() {
        let items = (0..<50).map { snippet("row \($0)") }
        #expect(ClipboardManager.trimmed(items, cap: 1).count == 50)
    }

    @Test("Clear-on-quit keeps starred rows and everything authored", .tags(.regression))
    func quitKeepsStarsAndSnippets() {
        let items = [history("copied"), history("starred", pinned: true), snippet("reply")]
        let out = ClipboardManager.retainedOnQuit(items)
        #expect(out.count == 2)
        #expect(out.contains { $0.preview == "copied" } == false,
                "traces of copying are what the setting is about")
        #expect(out.contains { $0.isSnippet })
        #expect(out.contains { $0.pinned })
    }
}

/// What reaches disk. Two shipped fixes are pinned here: the plaintext-after-crash
/// hole, and the unbounded plist.
struct PersistSnapshotTests {
    private func text(_ s: String, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(kind: .text(s), pinned: pinned)
    }

    @Test func keepsTextAndDropsImages() {
        let blank = NSImage(size: NSSize(width: 1, height: 1))
        let items = [text("a"), ClipboardItem(kind: .image(data: Data([0]), thumb: blank)), text("b")]
        let out = ClipboardManager.persistSnapshot(items, cap: 100, pinnedOnly: false)
        #expect(out.count == 2, "images are session-only")
        #expect(out.map(\.text) == ["a", "b"])
    }

    @Test("With clear-on-quit ON, unpinned text NEVER reaches disk", .tags(.regression))
    func pinnedOnlyModeWritesNoUnpinnedText() {
        // The bug: unpinned text was written during the session, so a crash or
        // force-quit (where stop() never runs) left the full plaintext history
        // behind — exactly what the setting promises to prevent.
        let items = [text("secret note"), text("kept", pinned: true), text("another secret")]
        let out = ClipboardManager.persistSnapshot(items, cap: 100, pinnedOnly: true)
        #expect(out.count == 1)
        #expect(out.first?.text == "kept")
        #expect(out.contains { $0.text.contains("secret") } == false)
    }

    @Test("Pinned items are never sacrificed to the unpinned cap")
    func pinnedSurviveTheCap() {
        var items = [ClipboardItem]()
        for i in 0..<400 { items.append(text("row \(i)")) }
        items.append(text("starred", pinned: true))
        let out = ClipboardManager.persistSnapshot(items, cap: 20, pinnedOnly: false)
        #expect(out.contains { $0.text == "starred" })
        #expect(out.first?.pinned == true, "pinned are written first")
    }

    @Test("A single huge item is capped so one paste can't bloat the plist")
    func capsGiantItems() {
        let huge = String(repeating: "x", count: 1_000_000)
        let out = ClipboardManager.persistSnapshot([text(huge)], cap: 100, pinnedOnly: false)
        let stored = try! #require(out.first).text
        #expect(stored.utf8.count <= 524_288)
    }

    @Test("The whole snapshot stays inside an aggregate byte budget", .tags(.regression))
    func respectsTheTotalBudget() {
        // 40 × 512 KB = ~20 MB of text, well past the 8 MB budget. Before the fix
        // there was no aggregate limit at all — the plist could reach hundreds of MB
        // and was decoded synchronously at launch.
        let chunk = String(repeating: "y", count: 520_000)
        let items = (0..<40).map { _ in text(chunk) }
        let out = ClipboardManager.persistSnapshot(items, cap: 500, pinnedOnly: false)
        let total = out.reduce(0) { $0 + $1.text.utf8.count }
        #expect(total < 9_000_000, "got \(total) bytes across \(out.count) items")
        #expect(out.isEmpty == false, "the budget must not throw everything away")
    }

    @Test func persistedRoundTripsThroughJSON() throws {
        let out = ClipboardManager.persistSnapshot([text("hello", pinned: true)],
                                                  cap: 10, pinnedOnly: false)
        let data = try JSONEncoder().encode(out)
        let back = try JSONDecoder().decode([ClipboardManager.Persisted].self, from: data)
        #expect(back.count == 1)
        #expect(back.first?.text == "hello")
        #expect(back.first?.pinned == true)
    }
}
