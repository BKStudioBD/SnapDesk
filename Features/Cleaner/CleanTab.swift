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
            header
            Divider().overlay(CleanerTheme.line)

            if isScanning {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…").font(.system(size: 12)).foregroundStyle(CleanerTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                CleanerEmptyState(symbol: "checkmark.circle", title: "Nothing to clean",
                                  detail: "No caches, logs or temporary files worth removing right now.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(groups) { group in
                            let rows = visible.filter { $0.group == group }
                            CleanerGroupHeader(title: group.rawValue,
                                               state: state(of: rows),
                                               size: SystemStats.format(bytes(of: rows))) {
                                toggle(rows)
                            }
                            ForEach(rows) { category in
                                CleanerRow(symbol: category.symbol, title: category.name,
                                           detail: category.detail,
                                           size: SystemStats.format(sizes[category.id] ?? 0),
                                           isSelected: selected.contains(category.id)) {
                                    toggle([category])
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            CleanerActionBar(summary: summary,
                             title: selectedBytes > 0 ? "Clean \(SystemStats.format(selectedBytes))" : "Clean",
                             isEnabled: selectedBytes > 0, isBusy: isCleaning) {
                Task { await clean() }
            }
        }
        .task { await scan() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(SystemStats.format(totalBytes))
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(CleanerTheme.accent)
                Text("reclaimable in \(visible.count) place\(visible.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(CleanerTheme.muted)
            }
            Spacer()
            Button(selected.isEmpty ? "Select all" : "Deselect all") {
                selected = selected.isEmpty ? Set(visible.map(\.id)) : []
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(CleanerTheme.accent)
            .disabled(visible.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var summary: String {
        if let result { return result }
        let count = visible.filter { selected.contains($0.id) }.count
        return count == 0 ? "Nothing selected" : "\(count) selected"
    }

    // MARK: - Selection

    private func bytes(of rows: [CacheCategory]) -> UInt64 {
        rows.reduce(0) { $0 + (sizes[$1.id] ?? 0) }
    }

    private func state(of rows: [CacheCategory]) -> SelectionState {
        SelectionState(selected: rows.filter { selected.contains($0.id) }.count, total: rows.count)
    }

    private func toggle(_ rows: [CacheCategory]) {
        let ids = rows.map(\.id)
        if state(of: rows).clickSelects {
            selected.formUnion(ids)
        } else {
            selected.subtract(ids)
        }
    }

    // MARK: - Work

    private func scan() async {
        let catalog = CacheCleaner.present(in: CacheCleaner.catalog(
            home: FileManager.default.homeDirectoryForCurrentUser))
        categories = catalog
        sizes = await CacheCleaner.measure(catalog)
        // Trash is the one category that deletes for good, so it is never
        // pre-ticked no matter how big it is.
        selected = Set(catalog.filter { $0.defaultOn && (sizes[$0.id] ?? 0) > 0 }.map(\.id))
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
