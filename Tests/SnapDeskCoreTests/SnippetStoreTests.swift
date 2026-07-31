import Testing
import Foundation
@testable import SnapDeskCore

/// A snippet is something the person typed by hand, so the two ways to lose one are
/// the ones that matter: a reorder that lands on the wrong index, and a budget that
/// silently drops entries.
///
/// Storage is injected, so nothing here touches the real defaults domain: a test
/// must not leave anything in the plist of the person running the suite.
struct SnippetStoreTests {

    /// Stands in for UserDefaults: the store's `load`/`save` pair, in memory.
    private final class Storage {
        var data: Data?
        var writes = 0
    }

    private func makeStore(_ storage: Storage) -> SnippetStore {
        SnippetStore(load: { storage.data }, save: { storage.data = $0; storage.writes += 1 })
    }

    private func list(_ titles: [String]) -> [Snippet] {
        titles.map { Snippet(title: $0, body: "body of \($0)") }
    }

    // MARK: - Store

    @Test("A new snippet goes to the top and is written through immediately")
    func addWritesAndOrdersNewestFirst() {
        let storage = Storage()
        let store = makeStore(storage)
        store.add(title: "first", body: "one")
        store.add(title: "second", body: "two")
        #expect(store.snippets.map(\.title) == ["second", "first"])
        #expect(storage.writes == 2, "a hand-written snippet is never left to a debounce")
        #expect(storage.data != nil)
    }

    @Test("What was written comes back on the next launch")
    func roundTripsThroughStorage() {
        let storage = Storage()
        makeStore(storage).add(title: "kept", body: "text")
        #expect(makeStore(storage).snippets.map(\.title) == ["kept"])
    }

    @Test("Garbage in storage reads as no snippets rather than crashing a launch")
    func decodesGarbageAsEmpty() {
        #expect(SnippetStore.decode(Data([0x00, 0x01, 0x02])).isEmpty)
        #expect(SnippetStore.decode(nil).isEmpty)
    }

    @Test("An edit keeps the row where it was")
    func updateDoesNotReorder() throws {
        let storage = Storage()
        let store = makeStore(storage)
        store.add(title: "a", body: "1")
        store.add(title: "b", body: "2")
        let target = try #require(store.snippets.last)
        store.update(id: target.id, title: "a fixed", body: "1")
        #expect(store.snippets.map(\.title) == ["b", "a fixed"],
                "re-sorting the list because someone fixed a typo would be its own bug")
        #expect(store.snippets.last?.date == target.date)
    }

    // MARK: - Reordering (pure)

    @Test("A reorder is clamped at BOTH ends, never wrapped", .tags(.regression))
    func movingClampsAtBothEnds() {
        let items = list(["one", "two", "three"])
        let up = SnippetStore.moving(id: items[0].id, by: -1, in: items)
        #expect(up.map(\.title) == ["one", "two", "three"],
                "move-up on the first row must do nothing, not wrap it to the bottom")
        let down = SnippetStore.moving(id: items[2].id, by: 1, in: items)
        #expect(down.map(\.title) == ["one", "two", "three"], "and the same at the bottom")
        let far = SnippetStore.moving(id: items[0].id, by: 99, in: items)
        #expect(far.map(\.title) == ["two", "three", "one"],
                "an overshoot lands on the last row rather than off the end")
    }

    @Test("A reorder moves exactly one row, by exactly one place")
    func movingByOnePlace() {
        let items = list(["one", "two", "three"])
        #expect(SnippetStore.moving(id: items[2].id, by: -1, in: items).map(\.title)
                == ["one", "three", "two"])
        #expect(SnippetStore.moving(id: items[0].id, by: 1, in: items).map(\.title)
                == ["two", "one", "three"])
    }

    @Test("An id that is not in the list leaves it alone")
    func movingAnUnknownIDIsANoOp() {
        let items = list(["one", "two"])
        #expect(SnippetStore.moving(id: UUID(), by: 1, in: items).map(\.title) == ["one", "two"])
        #expect(SnippetStore.moving(id: items[0].id, by: 0, in: items).map(\.title) == ["one", "two"])
    }

    // MARK: - Budget

    @Test("One runaway paste is capped instead of making the stored blob unbounded")
    func withinBudgetCapsAHugeBody() throws {
        let huge = String(repeating: "x", count: SnippetStore.bodyByteCap + 5_000)
        let out = SnippetStore.withinBudget([Snippet(title: "big", body: huge)])
        let kept = try #require(out.first)
        #expect(kept.body.utf8.count <= SnippetStore.bodyByteCap)
        #expect(kept.title == "big", "capping the body must not rename the row")
    }

    @Test("Past the aggregate budget the OLDEST entries are the ones dropped")
    func withinBudgetKeepsTheNewest() {
        // 24 × 256 KB is ~6 MB against a 4 MB budget, and the list is newest-first.
        let body = String(repeating: "y", count: SnippetStore.bodyByteCap)
        let items = (0..<24).map { Snippet(title: "row \($0)", body: body) }
        let out = SnippetStore.withinBudget(items)
        #expect(out.isEmpty == false, "the budget must not throw everything away")
        #expect(out.count < items.count, "got \(out.count). The budget has to bite")
        #expect(out.first?.title == "row 0", "the newest are what the person is working with")
    }

    // MARK: - Titles

    @Test("A nameless snippet takes its name from the body. A blank row is unfindable")
    func derivesATitle() {
        #expect(Snippet(title: "   ", body: "\n\n  hello there\nmore").title == "hello there")
        #expect(Snippet(title: "", body: "   \n  ").title == Snippet.untitled)
        let long = Snippet(title: "", body: String(repeating: "z", count: 200)).title
        #expect(long.count <= 61, "got \(long.count)")
        #expect(long.hasSuffix("…"))
    }
}
