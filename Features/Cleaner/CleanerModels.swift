import AppKit
import Observation

/// The cleaner's state, owned by the window rather than by the tab views.
///
/// A `switch` in a ViewBuilder produces `_ConditionalContent`, so every tab
/// change tore down the tab's `@State` and its `.task`: ticks were lost and
/// every cache was measured again from scratch. The measuring now happens once
/// per window, and a tab can be left and come back to.
///
/// `@MainActor` sits on the members rather than on the type. That is a
/// precaution, not a proven fix: a main-actor-isolated CLASS gets an isolated
/// `deinit`, and three of this app's crashes are the runtime hopping executors
/// inside one (`swift_task_deinitOnExecutorImpl` under `_swift_release_dealloc`).
/// Checked afterwards, though: the binary references that symbol zero times
/// either way, because isolated deinit is a Swift 6 feature and this ships in
/// Swift 5 mode. So the isolated deinit in those crashes belongs to a framework
/// type, not to this one. Keeping the annotation on the members costs nothing
/// and removes the class from the list of candidates for good.
@Observable
final class CleanModel {
    var categories: [CacheCategory] = []
    var sizes: [String: UInt64] = [:]
    var selected: Set<String> = []
    var isScanning = true
    var isCleaning = false
    var confirmingTrash = false
    var result: String?
    private var scanned = false

    /// Only what exists AND has something in it. A row reading "0 bytes" is a
    /// row nobody can act on.
    @MainActor var visible: [CacheCategory] { categories.filter { (sizes[$0.id] ?? 0) > 0 } }
    @MainActor var picked: [CacheCategory] { visible.filter { selected.contains($0.id) } }
    @MainActor var selectedBytes: UInt64 { picked.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }
    @MainActor var totalBytes: UInt64 { visible.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }

    /// Everything Select All would tick, never the Trash, so the button
    /// doesn't sit on "Deselect All" forever.
    @MainActor var allSelected: Bool {
        let selectable = visible.filter { !$0.isTrash }
        return !selectable.isEmpty && selectable.allSatisfy { selected.contains($0.id) }
    }

    @MainActor func bytes(of rows: [CacheCategory]) -> UInt64 {
        rows.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }

    @MainActor func scanIfNeeded() async {
        guard !scanned else { return }
        scanned = true
        // Building the catalog is a stat() per path; measuring walks whole
        // directory trees. Both belong off the main actor.
        let catalog = await CacheCleaner.presentCatalogInBackground()
        let measured = await CacheCleaner.measure(catalog)
        categories = catalog
        sizes = measured
        // Trash is the one category that deletes for good, so it is never
        // pre-ticked no matter how big it is.
        selected = Set(catalog.filter { $0.defaultOn && (measured[$0.id] ?? 0) > 0 }.map(\.id))
        isScanning = false
    }

    @MainActor func clean(playSound: () -> Void) async {
        isCleaning = true
        let picked = self.picked
        let freed = await CacheCleaner.clean(picked)
        sizes = await CacheCleaner.measure(categories)
        selected.subtract(picked.filter { (sizes[$0.id] ?? 0) == 0 }.map(\.id))
        isCleaning = false
        // Only the Trash gives the space back immediately; everything else is
        // now IN the Trash, so "freed" would be a claim the disk doesn't back.
        result = picked.contains { !$0.isTrash }
            ? "Moved \(SystemStats.format(freed)) to the Trash. Empty it to get the space back"
            : "Emptied \(SystemStats.format(freed))"
        playSound()
    }
}

