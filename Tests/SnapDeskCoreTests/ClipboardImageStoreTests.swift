import Testing
import AppKit
import Foundation
@testable import SnapDeskCore

/// A clipboard image is whatever was on screen: a password manager, a banking
/// page, a private message. The text half of that promise was already pinned by
/// `PersistSnapshotTests.pinnedOnlyModeWritesNoUnpinnedText`; the image half had no
/// test at all, so deleting the `pinnedOnly` gate in `plan` would have started
/// writing unpinned screenshot bytes to disk with a green suite.
struct ClipboardImageStorePlanTests {

    private func image(_ bytes: Int, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(kind: .image(data: Data(count: bytes),
                                   thumb: NSImage(size: NSSize(width: 1, height: 1))),
                      pinned: pinned)
    }

    @Test("With clear-on-quit ON, unpinned image bytes NEVER reach disk", .tags(.regression))
    func pinnedOnlyModeWritesNoUnpinnedImage() {
        let secret = image(1024)
        let kept = image(1024, pinned: true)
        let plan = ClipboardImageStore.plan([secret, kept], pinnedOnly: true)
        #expect(plan.count == 1)
        #expect(plan.first?.id == kept.id)
        #expect(plan.contains { $0.id == secret.id } == false,
                "an unpinned screenshot must not be written at all. A crash never runs the quit path")
    }

    @Test("Text rows are not images and never enter the plan")
    func ignoresTextRows() {
        let plan = ClipboardImageStore.plan([ClipboardItem(kind: .text("hello"))], pinnedOnly: false)
        #expect(plan.isEmpty)
    }

    @Test("An item past the per-item cap is skipped without shutting the door behind it")
    func skipsOversizedItemsOnly() {
        let huge = image(ClipboardImageStore.perItemByteCap + 1)
        let small = image(1024)
        let plan = ClipboardImageStore.plan([huge, small], pinnedOnly: false)
        #expect(plan.map(\.id) == [small.id],
                "the oversized item is dropped, the one behind it still gets written")
    }

    @Test("Pinned images are written first and survive the aggregate budget",
          .tags(.regression))
    func pinnedFirstUnderTheBudget() {
        // Nine 4 MB items is 36 MB against a 32 MB directory budget, so something has
        // to be dropped. And it must never be the starred one.
        let each = 4_000_000
        var items = (0..<8).map { _ in image(each) }
        let starred = image(each, pinned: true)
        items.append(starred)
        let plan = ClipboardImageStore.plan(items, pinnedOnly: false)
        #expect(plan.first?.id == starred.id, "pinned entries are planned first")
        #expect(plan.count == 8, "got \(plan.count). The 32 MB budget has to bite")
        let total = plan.reduce(0) { $0 + $1.data.count }
        #expect(total <= ClipboardImageStore.byteBudget, "got \(total) bytes")
        #expect(plan.isEmpty == false, "the budget must not throw everything away")
    }
}

/// The disk half. Everything here writes into a fresh temporary directory and
/// removes it again: a test must never leave clipboard images on the disk of the
/// person running the suite, and must never touch the real Application Support one.
struct ClipboardImageStoreDiskTests {

    private func withStore(_ body: (ClipboardImageStore, URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapDeskImageStoreTests-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(ClipboardImageStore(directory: dir), dir)
    }

    private func entry(_ byte: UInt8) -> ClipboardImageStore.Entry {
        ClipboardImageStore.Entry(id: UUID(), data: Data([byte, byte, byte]))
    }

    private func jpgNames(in dir: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".jpg") })
    }

    private func mode(of path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    }

    @Test("The directory holds exactly the planned files, and they read back")
    func writesExactlyThePlan() throws {
        try withStore { store, dir in
            let a = entry(1), b = entry(2)
            store.synchronize([a, b], prune: true)
            #expect(jpgNames(in: dir) == [ClipboardImageStore.fileName(for: a.id),
                                          ClipboardImageStore.fileName(for: b.id)])
            #expect(store.data(for: a.id) == a.data)
            #expect(store.data(for: b.id) == b.data)
        }
    }

    @Test("Bytes that were on someone's screen are owner-only on disk", .tags(.regression))
    func directoryAndFilesArePrivate() throws {
        try withStore { store, dir in
            let a = entry(7)
            store.synchronize([a], prune: true)
            #expect(mode(of: dir.path) == 0o700, "got \(String(describing: mode(of: dir.path)))")
            let file = store.url(for: a.id).path
            #expect(mode(of: file) == 0o600,
                    "got \(String(describing: mode(of: file))). Data.write uses the process umask")
        }
    }

    @Test("A shrunken plan removes only what it dropped")
    func prunesOnlyOrphans() throws {
        try withStore { store, dir in
            let keep = entry(1), drop = entry(2)
            store.synchronize([keep, drop], prune: true)
            store.synchronize([keep], prune: true)
            #expect(jpgNames(in: dir) == [ClipboardImageStore.fileName(for: keep.id)])
            #expect(store.data(for: keep.id) == keep.data, "a planned file is never deleted")
            #expect(store.data(for: drop.id) == nil,
                    "a row that is gone must not leave its bytes behind")
        }
    }

    @Test("An empty plan only deletes when the caller asks it to", .tags(.regression))
    func emptyPlanIsNotAutomaticallyDeleteEverything() throws {
        // An empty plan used to be routed to `removeAll()`, so "nothing to write"
        // silently meant "delete every image the person has", which is exactly what
        // a plan built before the asynchronous image restore had merged its rows says.
        try withStore { store, dir in
            let a = entry(9)
            store.synchronize([a], prune: true)
            store.synchronize([], prune: false)
            #expect(jpgNames(in: dir).isEmpty == false, "nothing was asked to be pruned")
            store.synchronize([], prune: true)
            #expect(jpgNames(in: dir).isEmpty, "asked in as many words, it clears out")
        }
    }
}
