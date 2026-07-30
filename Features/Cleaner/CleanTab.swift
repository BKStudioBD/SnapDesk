import SwiftUI

/// Caches, temporary files, logs and the Trash — grouped, sized, and ticked
/// before anything is removed.
struct CleanTab: View {
    var playSound: () -> Void

    @State private var categories: [CacheCategory] = []
    @State private var sizes: [String: UInt64] = [:]
    @State private var selected: Set<String> = []
    @State private var isScanning = true
    @State private var isCleaning = false
    @State private var result: String?

    /// Only what exists AND has something in it. A row reading "0 bytes" is a
    /// row nobody can act on.
    private var visible: [CacheCategory] {
        categories.filter { (sizes[$0.id] ?? 0) > 0 }
    }

    private var groups: [CacheCategory.Group] {
        CacheCategory.Group.allCases.filter { group in visible.contains { $0.group == group } }
    }

    private var selectedBytes: UInt64 {
        visible.filter { selected.contains($0.id) }.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }

    private var totalBytes: UInt64 {
        visible.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            CleanerListHeader(total: SystemStats.format(totalBytes),
                              caption: "reclaimable in \(visible.count) place\(visible.count == 1 ? "" : "s")",
                              hasRows: !visible.isEmpty,
                              allSelected: !visible.isEmpty && selected.count >= visible.count) {
                selected = selected.isEmpty ? Set(visible.map(\.id)) : []
            }

            Divider()

            if isScanning {
                ProgressView("Measuring…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView("Nothing to Clean",
                                       systemImage: "checkmark.circle",
                                       description: Text("No caches, logs or temporary files worth removing right now."))
            } else {
                List {
                    ForEach(groups) { group in
                        let rows = visible.filter { $0.group == group }
                        Section {
                            ForEach(rows) { category in
                                CleanerRow(symbol: category.symbol,
                                           title: category.name,
                                           detail: category.detail,
                                           size: SystemStats.format(sizes[category.id] ?? 0),
                                           isSelected: binding(category.id))
                            }
                        } header: {
                            CleanerGroupHeader(title: group.rawValue,
                                               size: SystemStats.format(bytes(of: rows)),
                                               selection: rows.map { binding($0.id) })
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            CleanerActionBar(summary: summary,
                             title: selectedBytes > 0 ? "Clean \(SystemStats.format(selectedBytes))" : "Clean",
                             isEnabled: selectedBytes > 0, isBusy: isCleaning) {
                Task { await clean() }
            }
        }
        .task { await scan() }
    }

    private var summary: String {
        if let result { return result }
        let count = visible.filter { selected.contains($0.id) }.count
        return count == 0 ? "Nothing selected" : "\(count) selected"
    }

    // MARK: - Selection

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { isOn in
                    if isOn { selected.insert(id) } else { selected.remove(id) }
                })
    }

    private func bytes(of rows: [CacheCategory]) -> UInt64 {
        rows.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }

    // MARK: - Work

    private func scan() async {
        // Building the catalog is a stat() per path; measuring walks whole
        // directory trees. Both belong off the main actor — the window is
        // drawing while they run.
        let catalog = await CacheCleaner.presentCatalogInBackground()
        let measured = await CacheCleaner.measure(catalog)
        categories = catalog
        sizes = measured
        // Trash is the one category that deletes for good, so it is never
        // pre-ticked no matter how big it is.
        selected = Set(catalog.filter { $0.defaultOn && (measured[$0.id] ?? 0) > 0 }.map(\.id))
        isScanning = false
    }

    private func clean() async {
        isCleaning = true
        let picked = visible.filter { selected.contains($0.id) }
        let freed = await CacheCleaner.clean(picked)
        sizes = await CacheCleaner.measure(categories)
        selected.subtract(picked.filter { (sizes[$0.id] ?? 0) == 0 }.map(\.id))
        isCleaning = false
        result = "Freed \(SystemStats.format(freed))"
        playSound()
    }
}
