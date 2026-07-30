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
    @State private var leftovers: [AppUninstaller.Leftover] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = false
    @State private var isRemoving = false
    @State private var result: String?

    private var filtered: [AppUninstaller.App] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var picked: [AppUninstaller.Leftover] {
        leftovers.filter { selected.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let chosen {
                detail(for: chosen)
            } else {
                list
            }
        }
        .task { apps = AppUninstaller.installedApps() }
    }

    // MARK: - App list

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                    .foregroundStyle(CleanerTheme.muted)
                TextField("Search apps", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(CleanerTheme.text)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(CleanerTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider().overlay(CleanerTheme.line)

            if filtered.isEmpty {
                CleanerEmptyState(symbol: "magnifyingglass", title: "No matching app",
                                  detail: "Nothing in Applications matches “\(search)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { app in
                            Button { choose(app) } label: {
                                HStack(spacing: 11) {
                                    Image(nsImage: app.icon).resizable()
                                        .frame(width: 26, height: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(app.name).font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(CleanerTheme.text)
                                        Text(app.bundleID.isEmpty ? app.url.path : app.bundleID)
                                            .font(.system(size: 11)).foregroundStyle(CleanerTheme.muted)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right").font(.system(size: 11))
                                        .foregroundStyle(CleanerTheme.muted)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Uninstall \(app.name)")
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    // MARK: - One app

    private func detail(for app: AppUninstaller.App) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button {
                    chosen = nil; leftovers = []; selected = []; result = nil
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CleanerTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the app list")

                Image(nsImage: app.icon).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CleanerTheme.text)
                    if AppUninstaller.isRunning(app) {
                        Text("Running — it will be quit first")
                            .font(.system(size: 11)).foregroundStyle(CleanerTheme.warning)
                    } else {
                        Text(SystemStats.format(leftovers.reduce(0) { $0 + $1.size }))
                            .font(.system(size: 11)).foregroundStyle(CleanerTheme.muted)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            Divider().overlay(CleanerTheme.line)

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finding everything it left behind…")
                        .font(.system(size: 12)).foregroundStyle(CleanerTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(leftovers) { leftover in
                            CleanerRow(symbol: leftover.url == app.url ? "app.badge" : "folder",
                                       title: leftover.name, detail: leftover.location,
                                       size: SystemStats.format(leftover.size),
                                       isSelected: selected.contains(leftover.id)) {
                                if selected.contains(leftover.id) { selected.remove(leftover.id) }
                                else { selected.insert(leftover.id) }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            CleanerActionBar(summary: result ?? "\(picked.count) of \(leftovers.count) items",
                             title: "Move to Trash",
                             isEnabled: !picked.isEmpty, isBusy: isRemoving) {
                Task { await uninstall(app) }
            }
        }
    }

    // MARK: - Work

    private func choose(_ app: AppUninstaller.App) {
        chosen = app
        isLoading = true
        result = nil
        Task {
            let found = await AppUninstaller.leftoversInBackground(for: app)
            leftovers = found
            // System-wide files under /Library may belong to another account on
            // this Mac, so they are listed unticked.
            selected = Set(found.filter(\.preselected).map(\.id))
            isLoading = false
        }
    }

    private func uninstall(_ app: AppUninstaller.App) async {
        isRemoving = true
        let removingBundle = picked.contains { $0.url == app.url }
        if removingBundle { await AppUninstaller.quit(app) }

        let outcome = AppUninstaller.trash(picked)
        let removed = Set(picked.map(\.id))
        leftovers.removeAll { removed.contains($0.id) }
        selected = []
        if removingBundle { apps.removeAll { $0.id == app.id } }
        isRemoving = false
        result = outcome.failed == 0
            ? "Moved \(outcome.moved) items · \(SystemStats.format(outcome.freed))"
            : "Moved \(outcome.moved) · \(outcome.failed) couldn't be removed"
        playSound()
    }
}
