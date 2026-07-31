import SwiftUI

/// Caches, temporary files, logs and the Trash: grouped, sized, and ticked
/// before anything is removed.
///
/// The state lives in `CleanModel`, owned by the window, so leaving this tab
/// and coming back keeps the measurement and the ticks.
struct CleanTab: View {
    let model: CleanModel
    var playSound: () -> Void

    private var groups: [CacheCategory.Group] {
        CacheCategory.Group.allCases.filter { group in model.visible.contains { $0.group == group } }
    }

    var body: some View {
        VStack(spacing: 0) {
            CleanerListHeader(total: SystemStats.format(model.totalBytes),
                              caption: "reclaimable in \(model.visible.count) place\(model.visible.count == 1 ? "" : "s")",
                              hasRows: !model.visible.isEmpty,
                              allSelected: model.allSelected) { selectAll in
                // Select All never arms the Trash: everything else is moved TO
                // the Trash and can be put back, and emptying it is the one
                // thing in here that cannot.
                model.selected = selectAll
                    ? Set(model.visible.filter { !$0.isTrash }.map(\.id))
                    : []
            }

            Divider()

            if model.isScanning {
                ProgressView("Measuring…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visible.isEmpty {
                ContentUnavailableView("Nothing to Clean",
                                       systemImage: "checkmark.circle",
                                       description: Text("No caches, logs or temporary files worth removing right now."))
            } else {
                List {
                    ForEach(groups) { group in
                        let rows = model.visible.filter { $0.group == group }
                        Section {
                            ForEach(rows) { category in
                                CleanerRow(symbol: category.symbol,
                                           title: category.name,
                                           detail: category.detail,
                                           size: SystemStats.format(model.sizes[category.id] ?? 0),
                                           isSelected: binding(category.id))
                            }
                        } header: {
                            CleanerGroupHeader(title: group.rawValue,
                                               size: SystemStats.format(model.bytes(of: rows)),
                                               selection: rows.map { binding($0.id) })
                        }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            CleanerActionBar(summary: summary,
                             title: model.selectedBytes > 0
                                ? "Clean \(SystemStats.format(model.selectedBytes))" : "Clean",
                             isEnabled: model.selectedBytes > 0, isBusy: model.isCleaning) {
                // The Trash is the only permanent delete in the app; say so
                // before doing it, the way Finder does.
                if model.picked.contains(where: \.isTrash) { model.confirmingTrash = true }
                else { Task { await model.clean(playSound: playSound) } }
            }
        }
        .confirmationDialog("Empty the Trash?", isPresented: Bindable(model).confirmingTrash) {
            Button("Empty the Trash", role: .destructive) {
                Task { await model.clean(playSound: playSound) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Emptying the Trash deletes those items for good. They can't be put back. Everything else you ticked is moved to the Trash and can be.")
        }
        .task { await model.scanIfNeeded() }
    }

    private var summary: String {
        if let result = model.result { return result }
        let count = model.picked.count
        return count == 0 ? "Nothing selected" : "\(count) selected"
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.selected.contains(id) },
                set: { isOn in
                    if isOn { model.selected.insert(id) } else { model.selected.remove(id) }
                })
    }
}
