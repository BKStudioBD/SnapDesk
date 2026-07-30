import SwiftUI

/// Removes an app and the files it scattered around the Library.
///
/// Dragging an app to the Trash leaves its caches, preferences, containers and
/// launch agents behind; this finds them, shows exactly what it proposes to
/// remove, and moves the lot to the Trash so the whole thing stays undoable.
struct UninstallTab: View {
    var playSound: () -> Void

    @State private var apps: [AppUninstaller.App] = []
    @State private var search = ""
    @State private var chosen: AppUninstaller.App?
    @State private var isLoadingApps = true

    private var filtered: [AppUninstaller.App] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            list
                .navigationDestination(item: $chosen) { app in
                    UninstallDetail(app: app, playSound: playSound) {
                        apps.removeAll { $0.id == app.id }
                        chosen = nil
                    }
                }
        }
        // Reading every bundle's Info.plist and icon is disk work; it used to
        // run on the main actor while this view drew its first frame.
        .task {
            apps = await AppUninstaller.installedAppsInBackground()
            isLoadingApps = false
        }
    }

    private var list: some View {
        Group {
            if isLoadingApps {
                ProgressView("Reading your applications…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(filtered) { app in
                    Button { chosen = app } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                Text(app.bundleID.isEmpty ? app.url.path : app.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Uninstall \(app.name)")
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
    }
}

/// One app: everything it left behind, ticked and sized, and the one button
/// that moves the lot to the Trash.
private struct UninstallDetail: View {
    let app: AppUninstaller.App
    var playSound: () -> Void
    /// Called once the app bundle itself has gone, so the list drops it.
    var onRemoved: () -> Void

    @State private var leftovers: [AppUninstaller.Leftover] = []
    @State private var selected: Set<String> = []
    @State private var isRunning = false
    @State private var isLoading = true
    @State private var isRemoving = false
    @State private var result: String?

    private var picked: [AppUninstaller.Leftover] {
        leftovers.filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if isLoading {
                ProgressView("Finding everything it left behind…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if leftovers.isEmpty {
                ContentUnavailableView("Nothing Left Behind",
                                       systemImage: "checkmark.circle",
                                       description: Text("\(app.name) has already been removed."))
            } else {
                List(leftovers) { leftover in
                    CleanerRow(symbol: leftover.url == app.url ? "app.badge" : "folder",
                               title: leftover.name,
                               detail: leftover.location,
                               size: SystemStats.format(leftover.size),
                               isSelected: binding(leftover.id))
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            CleanerActionBar(summary: result ?? "\(picked.count) of \(leftovers.count) items",
                             title: "Move to Trash",
                             isEnabled: !picked.isEmpty, isBusy: isRemoving) {
                Task { await uninstall() }
            }
        }
        .navigationTitle(app.name)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).fontWeight(.semibold)
                if isRunning {
                    Label("Running — it will be quit first", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(SystemStats.format(leftovers.reduce(0) { $0 + $1.size }))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { isOn in
                    if isOn { selected.insert(id) } else { selected.remove(id) }
                })
    }

    private func load() async {
        // `isRunning` used to be read inside the body — an NSWorkspace scan of
        // every running process, on every redraw of this view.
        isRunning = AppUninstaller.isRunning(app)
        let found = await AppUninstaller.leftoversInBackground(for: app)
        leftovers = found
        // System-wide files under /Library may belong to another account on
        // this Mac, so they are listed unticked.
        selected = Set(found.filter(\.preselected).map(\.id))
        isLoading = false
    }

    private func uninstall() async {
        isRemoving = true
        let removingBundle = picked.contains { $0.url == app.url }
        if removingBundle { await AppUninstaller.quit(app) }

        let outcome = await AppUninstaller.trashInBackground(picked)
        let removed = Set(picked.map(\.id))
        leftovers.removeAll { removed.contains($0.id) }
        selected = []
        isRemoving = false
        isRunning = false
        result = outcome.failed == 0
            ? "Moved \(outcome.moved) items · \(SystemStats.format(outcome.freed))"
            : "Moved \(outcome.moved) · \(outcome.failed) couldn't be removed"
        playSound()
        if removingBundle && outcome.failed == 0 { onRemoved() }
    }
}
