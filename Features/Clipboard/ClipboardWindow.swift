import AppKit
import SwiftUI

/// Hosts the SwiftUI clipboard history in a small floating panel.
final class ClipboardWindowController: NSWindowController {
    /// App that was frontmost before the history opened — the paste target.
    var previousApp: NSRunningApplication?
    private let settings: SettingsStore

    /// Titled window that closes on Esc — standard for clipboard managers.
    private final class EscWindow: NSWindow {
        override func cancelOperation(_ sender: Any?) { close() }
    }

    init(manager: ClipboardManager, settings: SettingsStore) {
        self.settings = settings
        let window = EscWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Clipboard"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        // Follow the user: join the ACTIVE Space — including another app's
        // full-screen Space — instead of yanking them back to the desktop.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.level = .floating
        window.center()
        super.init(window: window)

        let view = ClipboardHistoryView(
            manager: manager, settings: settings,
            onPaste: { [weak self] item in
                guard let self else { return }
                manager.copyToPasteboard(item)
                self.window?.close()
                Paster.paste(to: self.previousApp, activate: settings.activateAfterPaste)
            })
        window.contentViewController = NSHostingController(rootView: view)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Record the paste target and apply the chosen appearance before showing.
    func willShow(prev: NSRunningApplication?) {
        previousApp = prev
        // Solid background follows the system appearance — always crisp & readable.
        window?.appearance = nil
        // ALWAYS open on the screen the user is on (mouse position) — full
        // screen or not — centered there, never on some other display.
        if let w = window {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                ?? NSScreen.main
            if let f = screen?.visibleFrame {
                let size = w.frame.size
                w.setFrameOrigin(NSPoint(x: f.midX - size.width / 2,
                                         y: f.midY - size.height / 2))
            }
        }
    }
}

private enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "All", text = "Text", link = "Links", image = "Images", pinned = "Pinned"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: "square.grid.2x2"; case .text: "text.alignleft"
        case .link: "link"; case .image: "photo"; case .pinned: "pin.fill"
        }
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject var manager: ClipboardManager
    @ObservedObject var settings: SettingsStore
    var onPaste: (ClipboardItem) -> Void = { _ in }

    @State private var search = ""
    @State private var filter: ClipFilter = .all

    private var filtered: [ClipboardItem] {
        let base = manager.items.filter { item in
            switch filter {
            case .all:    break
            case .text:   if item.isImage { return false }
            case .link:   if item.contentType != .link { return false }
            case .image:  if !item.isImage { return false }
            case .pinned: if !item.pinned { return false }
            }
            if search.isEmpty { return true }
            if case .text(let s) = item.kind { return s.localizedCaseInsensitiveContains(search) }
            return false
        }
        // Pinned float to the top, recency preserved within each group.
        return base.filter { $0.pinned } + base.filter { !$0.pinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            filterChips
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)

            if filtered.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: search.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(manager.items.isEmpty ? "Nothing copied yet" : "No matches")
                        .foregroundStyle(.secondary).font(.callout)
                    if manager.items.isEmpty {
                        Text("Copy any text, image or link — it shows up here.\nOne click copies & pastes it back.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                            ClipboardRow(item: item, index: idx + 1, manager: manager,
                                         settings: settings, onPaste: onPaste)
                            Rectangle().fill(Color(nsColor: .separatorColor))
                                .frame(height: 1).padding(.horizontal, 12)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Clipboard").font(.headline)
            Text("\(manager.items.count)")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.primary.opacity(0.12)))
            Spacer()
            Menu {
                Button("Clear unpinned", action: manager.clearUnpinned)
                Button("Clear everything", role: .destructive, action: manager.clearAll)
            } label: {
                Image(systemName: "ellipsis.circle.fill").font(.system(size: 16))
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search clipboard", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Capsule().fill(.primary.opacity(0.10)))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ClipFilter.allCases) { f in
                    FilterChip(title: f.rawValue, icon: f.icon, active: filter == f) { filter = f }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }
}

private struct FilterChip: View {
    let title: String; let icon: String; let active: Bool; let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.10)))
                .foregroundStyle(active ? Color.white : Color.primary.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}

/// Solid, full-width list row (CopyEm-style): star · content · index.
private struct ClipboardRow: View {
    let item: ClipboardItem
    let index: Int
    @ObservedObject var manager: ClipboardManager
    @ObservedObject var settings: SettingsStore
    var onPaste: (ClipboardItem) -> Void

    @State private var flash = false
    @State private var pasteInFlight = false

    /// Single-click → copy + sound + flash. The window STAYS OPEN (CopyEm-style)
    /// so several items can be copied in a row; close with Esc / the red dot.
    private func doCopy() {
        manager.copyToPasteboard(item)
        if settings.playSound { Sounds.play(settings.soundName) }
        triggerFlash()
    }

    /// Copy + paste into the previous app + distinct sound + flash.
    private func doPaste() {
        guard !pasteInFlight else { return }   // ignore rapid double-fire
        pasteInFlight = true
        if settings.playSound { Sounds.play("SnapPop") }
        triggerFlash()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onPaste(item) }
    }

    private func triggerFlash() {
        flash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { flash = false }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Button { manager.togglePin(item) } label: {
                Image(systemName: item.pinned ? "star.fill" : "star")
                    .font(.system(size: 13))
                    .foregroundStyle(item.pinned ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain).frame(width: 18).help(item.pinned ? "Unstar" : "Star")

            content.frame(maxWidth: .infinity, alignment: .leading)

            Text("\(index)")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.accentColor.opacity(flash ? 0.35 : 0))   // CopyEm-style click flash (instant, no animation)
        .contentShape(Rectangle())
        // ONE click = copy + paste into the previous app (setting ON, default).
        // clickCount guard: the 2nd click of an accidental double must not
        // fire a second paste. Setting OFF → click just copies.
        .onTapGesture {
            guard (NSApp.currentEvent?.clickCount ?? 1) == 1 else { return }
            if settings.doubleClickToPaste { doPaste() } else { doCopy() }
        }
        .help(settings.doubleClickToPaste ? "Click to copy & paste into the previous app" : "Click to copy")
        .contextMenu {
            Button("Copy") { doCopy() }
            Button("Paste into previous app") { doPaste() }
            Button(item.pinned ? "Unstar" : "Star") { manager.togglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { manager.delete(item) }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .image(_, let img):
            HStack {
                Spacer(minLength: 0)
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxHeight: 120).clipShape(RoundedRectangle(cornerRadius: 6))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        case .text:
            switch item.contentType {
            case .link:
                Text(item.preview).foregroundStyle(.blue).underline().lineLimit(1)
                    .font(.system(size: 13))
            case .color:
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: item.hexString ?? "#000000"))
                        .frame(width: 20, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary.opacity(0.25), lineWidth: 1))
                    Text(item.preview).font(.system(size: 13, design: .monospaced))
                }
            case .code:
                Text(item.preview).font(.system(size: 12, design: .monospaced)).lineLimit(3)
            default:
                Text(item.preview).font(.system(size: 13)).lineLimit(2)
            }
        }
    }
}
