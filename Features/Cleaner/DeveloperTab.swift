import SwiftUI

/// Build folders that can be rebuilt from source — `node_modules`, DerivedData,
/// `.build`, Pods and friends — found across the whole home directory.
///
/// Everything here goes to the Trash rather than being deleted, because a wrong
/// guess about somebody's `build` folder has to be undoable.
struct DeveloperTab: View {
    var playSound: () -> Void

    @State private var items: [JunkItem] = []
    @State private var selected: Set<String> = []
    @State private var isScanning = true
    @State private var isTrashing = false
    @State private var result: String?

    private var selectedItems: [JunkItem] { items.filter { selected.contains($0.id) } }
    private var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.size } }
    private var totalBytes: UInt64 { items.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CleanerTheme.line)

            if isScanning {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking through your projects…")
                        .font(.system(size: 12)).foregroundStyle(CleanerTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                CleanerEmptyState(symbol: "checkmark.circle", title: "No build folders found",
                                  detail: "Nothing rebuildable is taking up space in your home folder.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            CleanerRow(symbol: item.kind.symbol,
                                       title: "\(item.kind.label) · \(item.url.lastPathComponent)",
                                       detail: item.project,
                                       size: SystemStats.format(item.size),
                                       isSelected: selected.contains(item.id)) {
                                toggle(item)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            CleanerActionBar(summary: summary,
                             title: selectedBytes > 0
                                ? "Move \(SystemStats.format(selectedBytes)) to Trash" : "Move to Trash",
                             isEnabled: selectedBytes > 0, isBusy: isTrashing) {
                trashSelected()
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
                Text("across \(items.count) build folder\(items.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(CleanerTheme.muted)
            }
            Spacer()
            Button(selected.isEmpty ? "Select all" : "Deselect all") {
                selected = selected.isEmpty ? Set(items.map(\.id)) : []
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(CleanerTheme.accent)
            .disabled(items.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var summary: String {
        if let result { return result }
        if selectedItems.isEmpty { return "Nothing selected" }
        return "\(selectedItems.count) selected"
    }

    private func toggle(_ item: JunkItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }

    private func scan() async {
        items = await ProjectJunkScanner.scanInBackground()
        // A folder called `build` or `dist` might be somebody's source; those
        // are listed but never pre-ticked.
        selected = Set(items.filter { $0.kind.safeToPreselect }.map(\.id))
        isScanning = false
    }

    private func trashSelected() {
        isTrashing = true
        let picked = selectedItems
        let freed = ProjectJunkScanner.trash(picked)
        let removed = Set(picked.map(\.id))
        items.removeAll { removed.contains($0.id) }
        selected.subtract(removed)
        isTrashing = false
        result = "Moved \(SystemStats.format(freed)) to the Trash"
        playSound()
    }
}
