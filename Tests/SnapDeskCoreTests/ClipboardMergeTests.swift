import Testing
import AppKit
import Foundation
@testable import SnapDeskCore

/// Merging is for collecting a list by copying: three copies made A then B then C
/// have to come back as "A\nB\nC". The list is newest-first, so merging in ROW
/// order would reverse the text of every list anybody builds this way.
struct ClipboardMergeTests {

    private func text(_ s: String, at offset: TimeInterval) -> ClipboardItem {
        ClipboardItem(kind: .text(s), date: Date(timeIntervalSince1970: 1_000_000 + offset))
    }

    @Test("Oldest first — the order things were actually copied", .tags(.regression))
    func mergesInCopyOrder() {
        // Handed over newest-first, the way the window lists them.
        let rows = [text("C", at: 2), text("B", at: 1), text("A", at: 0)]
        #expect(ClipboardMerge.merged(rows) == "A\nB\nC")
    }

    @Test("Rows with identical timestamps still come out oldest-first")
    func tiesFallBackToTheReverseOfTheGivenOrder() {
        // Two copies inside the same tick, or a restored list where every date is
        // equal: the given order is newest-first, so the reverse is copy order.
        let rows = [text("second", at: 0), text("first", at: 0)]
        #expect(ClipboardMerge.merged(rows) == "first\nsecond")
    }

    @Test("Each piece loses its trailing newlines and keeps its inner ones")
    func trimsOnlyTrailingNewlines() {
        let rows = [text("one\ntwo\n", at: 0), text("three\n\n", at: 1)]
        #expect(ClipboardMerge.merged(rows) == "one\ntwo\nthree",
                "a trailing newline per piece would become a blank line mid-block")
    }

    @Test("An image row is skipped rather than dropping the whole merge")
    func skipsImageRows() {
        let picture = ClipboardItem(kind: .image(data: Data([0]),
                                                thumb: NSImage(size: NSSize(width: 1, height: 1))),
                                    date: Date(timeIntervalSince1970: 1_000_001))
        let rows = [text("b", at: 2), picture, text("a", at: 0)]
        #expect(ClipboardMerge.merged(rows) == "a\nb")
    }

    @Test("Nothing textual means nil, so no empty row is added")
    func nilWhenThereIsNothingToJoin() {
        #expect(ClipboardMerge.merged([]) == nil)
        #expect(ClipboardMerge.merged([text("\n\n", at: 0)]) == nil,
                "a piece that is nothing but newlines contributes nothing")
    }

    @Test("A single row merges to itself")
    func singleRow() {
        #expect(ClipboardMerge.merged([text("only", at: 0)]) == "only")
    }
}
