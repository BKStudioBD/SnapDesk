import AppKit
import Observation

/// The cleaner's state, owned by the window rather than by the tab views.
///
/// A `switch` in a ViewBuilder produces `_ConditionalContent`, so every tab
/// change tore down the tab's `@State` and its `.task`: ticks were lost and the
/// scans ran again — for Developer that is a full walk of the home directory.
/// The scans now happen once per window, and a tab can be left and come back to.

@MainActor
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
    var visible: [CacheCategory] { categories.filter { (sizes[$0.id] ?? 0) > 0 } }
    var picked: [CacheCategory] { visible.filter { selected.contains($0.id) } }
    var selectedBytes: UInt64 { picked.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }
    var totalBytes: UInt64 { visible.reduce(0) { $0 + (sizes[$1.id] ?? 0) } }

    /// Everything Select All would tick — never the Trash, so the button
    /// doesn't sit on "Deselect All" forever.
    var allSelected: Bool {
        let selectable = visible.filter { !$0.isTrash }
        return !selectable.isEmpty && selectable.allSatisfy { selected.contains($0.id) }
    }

    func bytes(of rows: [CacheCategory]) -> UInt64 {
        rows.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }

    func scanIfNeeded() async {
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

    func clean(playSound: () -> Void) async {
        isCleaning = true
        let picked = self.picked
        let freed = await CacheCleaner.clean(picked)
        sizes = await CacheCleaner.measure(categories)
        selected.subtract(picked.filter { (sizes[$0.id] ?? 0) == 0 }.map(\.id))
        isCleaning = false
        // Only the Trash gives the space back immediately; everything else is
        // now IN the Trash, so "freed" would be a claim the disk doesn't back.
        result = picked.contains { !$0.isTrash }
            ? "Moved \(SystemStats.format(freed)) to the Trash — empty it to get the space back"
            : "Emptied \(SystemStats.format(freed))"
        playSound()
    }
}

@MainActor
@Observable
final class DeveloperModel {
    var items: [JunkItem] = []
    var selected: Set<String> = []
    var isScanning = true
    var isTrashing = false
    var result: String?
    private var scanned = false

    var selectedItems: [JunkItem] { items.filter { selected.contains($0.id) } }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.size } }

    func scanIfNeeded() async {
        guard !scanned else { return }
        scanned = true
        items = await ProjectJunkScanner.scanInBackground()
        // A folder called `build` or `dist` might be somebody's source, and a
        // dot-directory straight under ~ is a tool's home rather than a
        // project's output — both are listed, neither is pre-ticked.
        selected = Set(items.filter(\.safeToPreselect).map(\.id))
        isScanning = false
    }

    func trashSelected(playSound: () -> Void) async {
        isTrashing = true
        let picked = selectedItems
        // A node_modules tree is tens of thousands of files; moving it on the
        // main actor froze the window until the last one landed.
        let freed = await ProjectJunkScanner.trashInBackground(picked)
        let removed = Set(picked.map(\.id))
        items.removeAll { removed.contains($0.id) }
        selected.subtract(removed)
        isTrashing = false
        result = "Moved \(SystemStats.format(freed)) to the Trash"
        playSound()
    }
}

@MainActor
@Observable
final class UninstallModel {
    var apps: [AppUninstaller.App] = []
    var search = ""
    var isLoading = true
    private var loaded = false

    var filtered: [AppUninstaller.App] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        // Reading every bundle's Info.plist and icon is disk work; it used to
        // run on the main actor while the view drew its first frame.
        apps = await AppUninstaller.installedAppsInBackground()
        isLoading = false
    }

    func forget(_ app: AppUninstaller.App) {
        apps.removeAll { $0.id == app.id }
    }
}
