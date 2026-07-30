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
            CleanerListHeader(total: SystemStats.format(totalBytes),
                              caption: "across \(items.count) build folder\(items.count == 1 ? "" : "s")",
                              hasRows: !items.isEmpty,
                              allSelected: !items.isEmpty && selected.count >= items.count) {
                selected = selected.isEmpty ? Set(items.map(\.id)) : []
            }

            Divider()

            if isScanning {
                ProgressView("Looking through your projects…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView("No Build Folders Found",
                                       systemImage: "checkmark.circle",
                                       description: Text("Nothing rebuildable is taking up space in your home folder."))
            } else {
                List {
                    ForEach(items) { item in
                        CleanerRow(symbol: item.kind.symbol,
                                   title: "\(item.kind.label) · \(item.url.lastPathComponent)",
                                   detail: item.project,
                                   size: SystemStats.format(item.size),
                                   isSelected: binding(item.id))
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            CleanerActionBar(summary: summary,
                             title: selectedBytes > 0
                                ? "Move \(SystemStats.format(selectedBytes)) to Trash" : "Move to Trash",
                             isEnabled: selectedBytes > 0, isBusy: isTrashing) {
                Task { await trashSelected() }
            }
        }
        .task { await scan() }
    }

    private var summary: String {
        if let result { return result }
        if selectedItems.isEmpty { return "Nothing selected" }
        return "\(selectedItems.count) selected"
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { isOn in
                    if isOn { selected.insert(id) } else { selected.remove(id) }
                })
    }

    private func scan() async {
        items = await ProjectJunkScanner.scanInBackground()
        // A folder called `build` or `dist` might be somebody's source; those
        // are listed but never pre-ticked.
        selected = Set(items.filter { $0.kind.safeToPreselect }.map(\.id))
        isScanning = false
    }

    private func trashSelected() async {
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
