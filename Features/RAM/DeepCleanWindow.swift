import AppKit
import SwiftUI

/// Cleaner: one-click force RAM clean + itemized junk clear (caches/temp/logs/
/// trash) — no app-quitting (blocked by the App Sandbox anyway), so every
/// action here always works. Solid, movable, closable window.
final class DeepCleanWindow: NSWindowController, NSWindowDelegate {
    private static var shared: DeepCleanWindow?

    static func show(playSound: @escaping () -> Void) {
        if let w = shared { w.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let controller = DeepCleanWindow(playSound: playSound)
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(playSound: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 470),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "SnapDesk Cleaner"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: CleanerRootView(playSound: playSound))
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

private struct DeepCleanView: View {
    var playSound: () -> Void

    @State private var freeNow: UInt64 = 0
    @State private var busy = false
    @State private var resultText: String?
    /// Junk categories the user ticked (CleanMyMac-style itemized clean).
    @State private var kinds: Set<CacheCleaner.Kind> =
        Set(CacheCleaner.Kind.allCases.filter(\.defaultOn))
    @State private var sizes: [CacheCleaner.Kind: UInt64] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            // Big live RAM readout — the "before" number the clean improves.
            VStack(spacing: 4) {
                Image(systemName: "memorychip")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.accentColor)
                Text(RAMCleaner.format(freeNow))
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                Text("RAM free").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            cleanupOptions
                .padding(.horizontal, 24)

            Button {
                run()
            } label: {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 130)
                } else {
                    Text("Clean").font(.system(size: 14, weight: .semibold)).frame(width: 130)
                }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(busy)
            .padding(.top, 14)

            Group {
                if let resultText {
                    Text(resultText).font(.caption).foregroundStyle(.green)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Frees inactive memory + clears the ticked junk.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, 10).padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reload)
    }

    /// Itemized junk categories: RAM is always cleaned; caches/temp/logs/trash
    /// are per-category checkboxes with live sizes.
    private var cleanupOptions: some View {
        VStack(spacing: 3) {
            ForEach(CacheCleaner.Kind.allCases) { kind in
                HStack(spacing: 9) {
                    Toggle("", isOn: Binding(
                        get: { kinds.contains(kind) },
                        set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } }))
                    .labelsHidden()
                    Image(systemName: kind.symbol)
                        .frame(width: 16)
                        .foregroundStyle(kind == .trash ? Color.red : Color.accentColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.rawValue == "Trash" ? "Empty Trash" : kind.rawValue)
                            .font(.system(size: 12))
                        Text(kind.subtitle).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(sizes[kind].map(RAMCleaner.format) ?? "…")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture {
                    if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
                }
            }
        }
        .padding(.vertical, 7)
    }

    private func reload() {
        freeNow = RAMCleaner.freeBytes()
        CacheCleaner.measureAll { sizes = $0 }
    }

    /// One pass: clear the ticked junk categories, then force RAM clean.
    /// Both work in-process — no app-quitting, nothing the sandbox can block.
    private func run() {
        busy = true; resultText = nil
        let picked = CacheCleaner.Kind.allCases.filter { kinds.contains($0) }
        let done: (UInt64) -> Void = { junkFreed in
            RAMCleaner.clean { before, after in
                busy = false
                let freedRAM = after > before ? after - before : 0
                resultText = "Freed \(RAMCleaner.format(freedRAM + junkFreed)) — \(RAMCleaner.format(after)) RAM free."
                playSound()
                reload()
            }
        }
        if picked.isEmpty { done(0) } else { CacheCleaner.cleanAsync(picked, done) }
    }
}

// MARK: - Cleaner root (tabs)

private struct CleanerRootView: View {
    var playSound: () -> Void
    var body: some View {
        TabView {
            DeepCleanView(playSound: playSound)
                .tabItem { Label("Clean", systemImage: "sparkles") }
            UninstallView(playSound: playSound)
                .tabItem { Label("Uninstall", systemImage: "trash") }
        }
        .frame(width: 440, height: 470)
    }
}

// MARK: - Uninstall tab

private struct UninstallView: View {
    var playSound: () -> Void
    @State private var apps: [AppUninstaller.App] = []
    @State private var chosen: AppUninstaller.App?
    @State private var related: [URL] = []
    @State private var checked: Set<URL> = []
    @State private var relatedSize: UInt64 = 0
    @State private var busy = false
    @State private var scanning = false
    @State private var result: String?

    var body: some View {
        VStack(spacing: 0) {
            if let app = chosen { detail(app) } else { picker }
        }
        .onAppear { if apps.isEmpty { reloadApps() } }
    }

    /// Enumerating /Applications (Bundle + icon disk IO per app) blocks the
    /// main thread — do it on a background queue, assign back on main.
    private func reloadApps() {
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppUninstaller.installedApps()
            DispatchQueue.main.async { apps = list }
        }
    }

    // MARK: - App picker

    private var picker: some View {
        Group {
            HStack { Text("Uninstall App").font(.headline); Spacer() }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(apps) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: app.icon).resizable().frame(width: 26, height: 26)
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                        .onTapGesture { choose(app) }
                    }
                }.padding(10)
            }
            if let result {
                Divider()
                Text(result).font(.caption).foregroundStyle(.green).lineLimit(2)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
    }

    // MARK: - Leftovers detail

    private func detail(_ app: AppUninstaller.App) -> some View {
        Group {
            HStack(spacing: 10) {
                Button { chosen = nil; related = []; checked = [] } label: {
                    Image(systemName: "chevron.left")
                }.buttonStyle(.borderless)
                Image(nsImage: app.icon).resizable().frame(width: 26, height: 26)
                Text(app.name).font(.headline).lineLimit(1)
                if AppUninstaller.isRunning(app) {
                    Text("running — will be force-quit")
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider()
            if scanning {
                Spacer(); ProgressView("Finding app data, caches & leftovers…"); Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(related, id: \.self) { url in fileRow(url, appURL: app.url) }
                    }.padding(10)
                }
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text("\(checked.count) of \(related.count) items · \(RAMCleaner.format(relatedSize))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Uninstall (to Trash)") { uninstall(app) }
                    .keyboardShortcut(.defaultAction).disabled(checked.isEmpty || busy || scanning)
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func fileRow(_ url: URL, appURL: URL) -> some View {
        let isBundle = url == appURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = url.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
        return HStack(spacing: 9) {
            Toggle("", isOn: Binding(
                get: { checked.contains(url) },
                set: { on in
                    if on { checked.insert(url) } else { checked.remove(url) }
                    recountSize()
                }))
            .labelsHidden()
            Image(systemName: isBundle ? "app.fill" : "folder")
                .foregroundStyle(isBundle ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                Text(folder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            if checked.contains(url) { checked.remove(url) } else { checked.insert(url) }
            recountSize()
        }
    }

    // MARK: - Actions

    private func choose(_ app: AppUninstaller.App) {
        chosen = app; result = nil; related = []; checked = []; relatedSize = 0; scanning = true
        DispatchQueue.global(qos: .utility).async {
            let files = AppUninstaller.relatedFiles(for: app)
            let sz = AppUninstaller.size(of: files)
            DispatchQueue.main.async {
                related = files; checked = Set(files); relatedSize = sz; scanning = false
            }
        }
    }

    private func recountSize() {
        let picked = related.filter { checked.contains($0) }
        DispatchQueue.global(qos: .utility).async {
            let sz = AppUninstaller.size(of: picked)
            DispatchQueue.main.async { relatedSize = sz }
        }
    }

    private func uninstall(_ app: AppUninstaller.App) {
        busy = true
        let files = related.filter { checked.contains($0) }
        let removingBundle = checked.contains(app.url)
        let finish: () -> Void = {
            DispatchQueue.global(qos: .userInitiated).async {
                let n = AppUninstaller.uninstall(files)
                DispatchQueue.main.async {
                    busy = false
                    // Honest report: count what actually landed in the Trash.
                    let skipped = files.count - n
                    result = skipped == 0
                        ? "Moved \(n) item\(n == 1 ? "" : "s") to Trash"
                        : "Moved \(n) to Trash · \(skipped) couldn't be removed"
                    chosen = nil; related = []; checked = []
                    playSound()
                    reloadApps()
                }
            }
        }
        // Force-quit ONLY when the app bundle itself is being removed —
        // clearing leftovers alone must not kill a running app.
        if removingBundle { AppUninstaller.forceQuit(app, completion: finish) } else { finish() }
    }
}
