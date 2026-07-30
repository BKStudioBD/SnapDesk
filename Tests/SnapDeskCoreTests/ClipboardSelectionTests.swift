import Testing
import Foundation
@testable import SnapDeskCore

/// The multi-row selection keeps IDS, not indexes, because the list re-sorts under
/// the person constantly — a copy arrives, a star floats a row up, the search text
/// changes. These pin the gestures, and the pruning that stops a merge from acting
/// on a row nobody can see any more.
struct ClipboardSelectionTests {

    private let rows = (0..<5).map { _ in UUID() }

    @Test("Command-click adds, and a second one takes it back out")
    func toggleAddsAndRemoves() {
        var selection = ClipboardSelection()
        selection.apply(.toggle, to: rows[1], in: rows)
        #expect(selection.contains(rows[1]))
        #expect(selection.count == 1)
        selection.apply(.toggle, to: rows[1], in: rows)
        #expect(selection.isEmpty)
        #expect(selection.anchor == rows[1],
                "the anchor follows the last row touched either way, so a toggle then a Shift-click reads as one gesture")
    }

    @Test("Shift-click reaches from the anchor, in either direction")
    func extendRunsBothWays() {
        var down = ClipboardSelection()
        down.apply(.toggle, to: rows[1], in: rows)
        down.apply(.extend, to: rows[3], in: rows)
        #expect(down.ids == Set([rows[1], rows[2], rows[3]]))

        var up = ClipboardSelection()
        up.apply(.toggle, to: rows[3], in: rows)
        up.apply(.extend, to: rows[1], in: rows)
        #expect(up.ids == Set([rows[1], rows[2], rows[3]]),
                "reaching upwards selects the same run")
    }

    @Test("A Shift-click with no anchor yet selects that one row instead of nothing")
    func extendWithoutAnAnchor() {
        var selection = ClipboardSelection()
        selection.apply(.extend, to: rows[2], in: rows)
        #expect(selection.ids == Set([rows[2]]))
        #expect(selection.anchor == rows[2])
    }

    @Test("Extending ADDS, so scattered Command-clicks survive a following run")
    func extendKeepsWhatWasAlreadyThere() {
        var selection = ClipboardSelection()
        selection.apply(.toggle, to: rows[0], in: rows)
        selection.apply(.toggle, to: rows[4], in: rows)
        selection.apply(.extend, to: rows[3], in: rows)
        #expect(selection.ids == Set([rows[0], rows[3], rows[4]]))
    }

    @Test("A row that isn't on screen can't be extended to")
    func extendIgnoresUnknownRows() {
        var selection = ClipboardSelection()
        selection.apply(.toggle, to: rows[0], in: rows)
        selection.apply(.extend, to: UUID(), in: rows)
        #expect(selection.ids == Set([rows[0]]))
    }

    @Test("Pruning drops rows that vanished, and a stale anchor with them",
          .tags(.regression))
    func pruneFollowsWhatIsVisible() {
        // A selection must never survive as invisible state: rows the person can no
        // longer see would still be merged by the next ⌘⇧M.
        var selection = ClipboardSelection()
        selection.apply(.toggle, to: rows[0], in: rows)
        selection.apply(.extend, to: rows[2], in: rows)
        selection.prune(to: [rows[2], rows[3]])
        #expect(selection.ids == Set([rows[2]]), "row 0 and row 1 are gone from the list")
        // The ANCHOR was row 0 — extending doesn't move it — and row 0 just vanished.
        // A Shift-click reaching from a row nobody can see would select a run nobody
        // asked for, so the anchor has to go with it.
        #expect(selection.anchor == nil)

        // An anchor that is still on screen stays, so the gesture continues normally.
        var survivor = ClipboardSelection()
        survivor.apply(.toggle, to: rows[2], in: rows)
        survivor.prune(to: [rows[2], rows[3]])
        #expect(survivor.ids == Set([rows[2]]))
        #expect(survivor.anchor == rows[2])
    }

    @Test("Clearing forgets the anchor too")
    func clearResetsEverything() {
        var selection = ClipboardSelection()
        selection.apply(.toggle, to: rows[1], in: rows)
        selection.clear()
        #expect(selection.isEmpty)
        #expect(selection.anchor == nil)
    }
}
