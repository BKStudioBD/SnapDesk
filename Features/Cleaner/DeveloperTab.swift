import SwiftUI

/// Build folders that can be rebuilt from source — `node_modules`, DerivedData,
/// `.build`, Pods and friends — found across the whole home directory.
///
/// Everything here goes to the Trash rather than being deleted, because a wrong
/// guess about somebody's `build` folder has to be undoable. State lives in
/// `DeveloperModel` so a tab change doesn't throw away the scan or the ticks.
struct DeveloperTab: View {
    let model: DeveloperModel
    var playSound: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            CleanerListHeader(total: SystemStats.format(model.totalBytes),
                              caption: "across \(model.items.count) build folder\(model.items.count == 1 ? "" : "s")",
                              hasRows: !model.items.isEmpty,
                              allSelected: model.allSelected) { selectAll in
                // Select All arms only what the scan was willing to tick itself.
                // The rest — a `build` folder that might be somebody's source,
                // `~/.gradle` with its signing passwords — stays for the person
                // to choose one row at a time.
                model.selected = selectAll
                    ? Set(model.items.filter(\.safeToPreselect).map(\.id))
                    : []
            }

            Divider()

            if model.isScanning {
                ProgressView("Looking through your projects…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView("No Build Folders Found",
                                       systemImage: "checkmark.circle",
                                       description: Text("Nothing rebuildable is taking up space in your home folder."))
            } else {
                List {
                    ForEach(model.items) { item in
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
                             title: model.selectedBytes > 0
                                ? "Move \(SystemStats.format(model.selectedBytes)) to Trash" : "Move to Trash",
                             isEnabled: model.selectedBytes > 0, isBusy: model.isTrashing) {
                Task { await model.trashSelected(playSound: playSound) }
            }
        }
        .task { await model.scanIfNeeded() }
    }

    private var summary: String {
        if let result = model.result { return result }
        if model.selectedItems.isEmpty { return "Nothing selected" }
        return "\(model.selectedItems.count) selected"
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selected.contains(id) },
                set: { isOn in
                    if isOn { model.selected.insert(id) } else { model.selected.remove(id) }
                })
    }
}
