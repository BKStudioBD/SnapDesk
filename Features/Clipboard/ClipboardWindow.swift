import AppKit
import SwiftUI

/// Hosts the SwiftUI clipboard history in a small floating panel.
final class ClipboardWindowController: NSWindowController {
    /// App that was frontmost before the history opened — the paste target.
    var previousApp: NSRunningApplication?
    private let settings: SettingsStore
    private let manager: ClipboardManager
    /// Owned here, not by the root view: `willShow` rebuilds that view on every
    /// open (to reset @State), and a store rebuilt with it would drop an edit the
    /// person made in the sheet a moment earlier. This controller lives as long as
    /// the app does.
    private let snippets = SnippetStore()

    /// Titled window that closes on Esc — standard for clipboard managers.
    private final class EscWindow: NSWindow {
        override func cancelOperation(_ sender: Any?) { close() }
    }

    /// The default IS the floor: the window can grow bigger but never shrink
    /// below its default size. (Also rejects a transient 1×1 as garbage.)
    private static let defaultSize = NSSize(width: 400, height: 560)
    private static let minSize = defaultSize

    /// The size to open at: the user's last (sane) resize, else the default.
    private static func savedContentSize() -> NSSize {
        guard let d = UserDefaults.standard.dictionary(forKey: sizeKey),
              let w = d["w"] as? Double, let h = d["h"] as? Double,
              w >= minSize.width, h >= minSize.height else { return defaultSize }
        return NSSize(width: w, height: h)
    }

    init(manager: ClipboardManager, settings: SettingsStore) {
        self.settings = settings
        self.manager = manager
        // Reopen at the size the user last dragged it to. Only the SIZE is
        // remembered — position always follows the mouse's screen in willShow.
        let start = Self.savedContentSize()
        let window = EscWindow(
            contentRect: NSRect(x: 0, y: 0, width: start.width, height: start.height),
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
        // Floor the size so a stray drag / transient layout can't collapse it —
        // and so a garbage 1×1 can never be produced to persist in the first place.
        window.contentMinSize = Self.minSize
        window.center()
        super.init(window: window)

        window.delegate = self

        // The paste target was captured once, when the window opened. But this
        // window floats, doesn't hide on deactivate, and stays clickable while
        // the user switches apps: open the history over Mail, ⌘-Tab to Slack,
        // click a row — and the paste went into Mail, activating it. Track the
        // front app for as long as the window is up. (Never SnapDesk itself:
        // that would paste into the history window.)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.window?.isVisible == true,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self.previousApp = app
        }
        window.contentViewController = makeHosting()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let sizeKey = "clip.windowSize"

    /// Host the SwiftUI view WITHOUT letting it drive the window size. Default
    /// `sizingOptions` includes `.preferredContentSize`, which snaps the window
    /// back to the view's fitting size every time the content controller is
    /// (re)assigned — that's what threw away the user's resized frame on reopen.
    private func makeHosting() -> NSHostingController<ClipboardHistoryView> {
        let hc = NSHostingController(rootView: makeRootView())
        hc.sizingOptions = []
        return hc
    }

    private func makeRootView() -> ClipboardHistoryView {
        ClipboardHistoryView(
            manager: manager, settings: settings, snippets: snippets,
            onPaste: { [weak self] item in
                // One paste per opening, whatever the rows do. Click row A then
                // row B inside the double-click window and BOTH rows queue a
                // paste; A's fires, closes the window, and B's would otherwise
                // rewrite the pasteboard and send a second Command-V into the
                // app the user is now looking at. The closed window is the latch.
                guard let self, self.window?.isVisible == true else { return }
                // No `movingToTop:` here — a paste leaves the history order alone.
                self.manager.copyToPasteboard(item)
                self.window?.close()
                Paster.paste(to: self.previousApp, activate: self.settings.activateAfterPaste)
            })
    }

    /// Record the paste target and apply the chosen appearance before showing.
    func willShow(prev: NSRunningApplication?) {
        previousApp = prev
        // Fresh view every open. Closing this window does NOT release it
        // (isReleasedWhenClosed = false) and the controller lives as long as the
        // app, so SwiftUI @State survives close → reopen: the history used to
        // come back still filtered by the search you typed an hour ago, showing
        // a fraction of the list. Rebuilding also guarantees no per-row state
        // can outlive a session and quietly disable a row.
        window?.contentViewController = makeHosting()
        // Solid background follows the system appearance — always crisp & readable.
        window?.appearance = nil
        // FORCE the intended size every open. Swapping the content controller
        // (for the @State reset) can nudge the frame, so don't trust whatever
        // it is now — set it to the user's last saved size (or default), then
        // center on the mouse's screen. This is what makes reopen == last size.
        if let w = window {
            let size = Self.savedContentSize()
            w.setContentSize(size)
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                ?? NSScreen.main
            if let f = screen?.visibleFrame {
                let frame = w.frame   // after setContentSize → real outer size
                w.setFrameOrigin(NSPoint(x: f.midX - frame.width / 2,
                                         y: f.midY - frame.height / 2))
            }
        }
    }
}

extension ClipboardWindowController: NSWindowDelegate {
    /// Hard floor on every live resize (corner drag included). `contentMinSize`
    /// proved unreliable under `.fullSizeContentView`; intercepting the proposed
    /// frame here and clamping it is authoritative — the window can grow but
    /// never shrink below its default size.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        // minSize is CONTENT size → convert to the matching FRAME floor.
        let minFrame = sender.frameRect(forContentRect:
            NSRect(origin: .zero, size: Self.minSize)).size
        return NSSize(width: max(frameSize.width, minFrame.width),
                      height: max(frameSize.height, minFrame.height))
    }

    /// Persist the size the user dragged to, so the next open matches it.
    func windowDidResize(_ notification: Notification) {
        guard let w = window, w.isVisible else { return }   // ignore setup/teardown transients
        // Save CONTENT size (what init/willShow restore) — not the outer frame,
        // whose title-bar height would otherwise accumulate on every reopen.
        let size = w.contentRect(forFrameRect: w.frame).size
        guard size.width >= Self.minSize.width, size.height >= Self.minSize.height else { return }
        UserDefaults.standard.set(["w": Double(size.width), "h": Double(size.height)],
                                  forKey: Self.sizeKey)
    }
}

/// The one sheet slot this window has.
///
/// A single slot rather than two `.sheet` modifiers on one view: a view presents
/// one sheet, and stacking the modifiers makes which of them wins depend on
/// modifier order.
private struct ClipboardSheet: Identifiable {
    enum Mode {
        /// Edit-before-paste. `source` is the row it came from.
        case paste
        /// Snippet editor. nil = a new snippet; otherwise the one being edited.
        case snippet(UUID?)
    }
    let id = UUID()
    var mode: Mode
    var source: ClipboardItem?
    var title: String = ""
    var body: String
}

struct ClipboardHistoryView: View {
    @ObservedObject var manager: ClipboardManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var snippets: SnippetStore
    var onPaste: (ClipboardItem) -> Void = { _ in }

    @State private var search = ""
    @State private var filter: ClipboardRows.Filter = .all
    /// Shared across every row so a click on ANY row supersedes a paste queued by
    /// another — see `ClickCoordinator`.
    @State private var clicks = ClickCoordinator()
    /// Keyboard cursor into the filtered rows. A clipboard manager is a
    /// keyboard tool: reach for the mouse and it's already slower than ⌘V.
    @State private var selected = 0
    /// The row `selected` points at, by id, so the cursor can be put back on the
    /// same row after the list re-sorts.
    @State private var selectedID: UUID?
    /// Multi-row selection for merge — ids, not indexes. See `ClipboardSelection`.
    @State private var selection = ClipboardSelection()
    @State private var sheet: ClipboardSheet?

    private var filtered: [ClipboardItem] {
        ClipboardRows.compose(history: manager.items, snippets: snippets.snippets,
                              filter: filter, search: search)
    }

    var body: some View {
        let rows = filtered   // compute once per render (was evaluated twice)
        // Built once per render, not once per row: it captures `rows` and every row
        // gets the same value.
        let actions = rowActions(rows: rows)
        return VStack(spacing: 0) {
            header
            searchBar
            filterChips
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)

            if rows.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: search.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(manager.items.isEmpty ? "Nothing copied yet" : "No matches")
                        .foregroundStyle(.secondary).font(.callout)
                    if manager.items.isEmpty {
                        Text("Copy any text, image or link — it shows up here.\nOne click pastes it back; double-click copies it to the top.\n⌘N saves a snippet of your own.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, item in
                                ClipboardRow(item: item, index: idx + 1, manager: manager,
                                             settings: settings, clicks: clicks,
                                             isSelected: idx == selected,
                                             isMultiSelected: selection.contains(item.id),
                                             actions: actions, onPaste: onPaste)
                                    .id(item.id)
                                Rectangle().fill(Color(nsColor: .separatorColor))
                                    .frame(height: 1).padding(.horizontal, 16)
                            }
                        }
                    }
                    // Keep the keyboard cursor on screen as it moves.
                    .onChange(of: selected) {
                        guard rows.indices.contains(selected) else { return }
                        // Remember WHICH row the cursor is on, not just where it
                        // sat — see the re-anchor below.
                        selectedID = rows[selected].id
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(rows[selected].id, anchor: .center)
                        }
                    }
                }
            }

            if selection.isEmpty == false { selectionBar(rows: rows) }
        }
        // Default is the minimum — grow only, never shrink below it.
        .frame(minWidth: 400, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(KeyCommands { action in handle(action, rows: rows) })
        .sheet(item: $sheet) { sheetContent($0) }
        // A selection must never survive as invisible state: rows the person can no
        // longer see would still be merged by the next ⌘⇧M.
        // The keyboard cursor has to follow the list it points into. Only the
        // multi-selection was pruned, so after ↓↓↓ and a search that narrows to
        // one row, `selected` still pointed at row 3: nothing was highlighted
        // and ↵ did nothing.
        .onChange(of: search) { selection.prune(to: filtered.map(\.id)); moveCursorToTop(filtered) }
        .onChange(of: filter) { selection.prune(to: filtered.map(\.id)); moveCursorToTop(filtered) }
        // The list re-sorts under the person: a copy arrives every half second and
        // lands at the top, a star floats a row up. The cursor is an INDEX, so it
        // used to stay in slot 8 while a different row slid into it — and ↵ pasted,
        // ⌘⌫ deleted, that row instead. Follow the row itself. `ClipboardSelection`
        // already works by id for exactly this reason.
        .onChange(of: rows.map(\.id)) { _, ids in
            guard let selectedID else { return }
            if let index = ids.firstIndex(of: selectedID) { selected = index }
            else { selected = min(selected, max(0, ids.count - 1)) }
        }
    }

    /// Cursor back to the first row, id included — a plain `selected = 0` left the
    /// remembered id pointing at a row that is no longer in the list.
    private func moveCursorToTop(_ rows: [ClipboardItem]) {
        selected = 0
        selectedID = rows.first?.id
    }

    // MARK: - Multi-selection

    /// The mouse route to merge, and the only place the selection count is stated.
    /// On screen only while a selection exists.
    private func selectionBar(rows: [ClipboardItem]) -> some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { selection.clear() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            Button("Merge") { mergeSelection(rows: rows) }
                .help("Join the selected rows into one new item, oldest first (⌘⇧M)")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.primary.opacity(0.06))
    }

    /// Joins the selected rows into ONE new history entry — `ClipboardMerge` owns
    /// the separator and the order. With nothing selected it merges the row under
    /// the cursor, which is how a single item gets its trailing newline stripped
    /// into a clean entry.
    private func mergeSelection(rows: [ClipboardItem]) {
        var chosen = rows.filter { selection.contains($0.id) }
        if chosen.isEmpty, rows.indices.contains(selected) { chosen = [rows[selected]] }
        guard let text = ClipboardMerge.merged(chosen) else { return }
        manager.add(text: text)
        selection.clear()
    }

    /// Shift+arrow: move the cursor and take the row it lands on into the
    /// selection, anchored on the row it left.
    private func extendSelection(by step: Int, rows: [ClipboardItem]) {
        guard rows.indices.contains(selected) else { return }
        if selection.isEmpty { selection.toggle(rows[selected].id) }
        selected = min(max(selected + step, 0), rows.count - 1)
        selection.extend(to: rows[selected].id, in: rows.map(\.id))
    }

    // MARK: - Sheets

    @ViewBuilder private func sheetContent(_ sheet: ClipboardSheet) -> some View {
        switch sheet.mode {
        case .paste:
            PasteEditView(text: sheet.body) { edited in
                self.sheet = nil
                guard let source = sheet.source,
                      let item = ClipboardEdit.transientItem(editing: source, to: edited) else { return }
                // Next turn of the loop: pasting CLOSES this window, and closing a
                // window that still has a sheet attached leaves the sheet behind.
                DispatchQueue.main.async { onPaste(item) }
            } cancel: {
                self.sheet = nil
            }
        case .snippet(let existing):
            SnippetEditorView(title: sheet.title, text: sheet.body, isNew: existing == nil) { title, text in
                self.sheet = nil
                if let existing {
                    snippets.update(id: existing, title: title, body: text)
                } else {
                    snippets.add(title: title, body: text)
                }
            } cancel: {
                self.sheet = nil
            }
        }
    }

    /// Text only — there is nothing to type at an image. The stored row is never
    /// rewritten either way; see `ClipboardEdit`.
    private func beginEditThenPaste(_ item: ClipboardItem) {
        guard let text = item.text else { return }
        sheet = ClipboardSheet(mode: .paste, source: item, body: text)
    }

    /// Prefilled from a row when there is one — "keep this one" is the usual reason
    /// to reach for a snippet in the first place.
    private func beginNewSnippet(from item: ClipboardItem?) {
        let text = item?.text ?? ""
        sheet = ClipboardSheet(mode: .snippet(nil), title: Snippet.derivedTitle(from: text), body: text)
    }

    private func beginEditSnippet(_ item: ClipboardItem) {
        guard let title = item.title else { return }
        sheet = ClipboardSheet(mode: .snippet(item.id), title: title, body: item.text ?? "")
    }

    /// A snippet row routes to `SnippetStore`, a captured row to the history —
    /// same key, same context-menu item, told apart by the row itself.
    private func deleteRow(_ item: ClipboardItem) {
        if item.isSnippet { snippets.delete(id: item.id) } else { manager.delete(item) }
    }

    private func rowActions(rows: [ClipboardItem]) -> RowActions {
        RowActions(
            select: { item, change in
                selection.apply(change, to: item.id, in: rows.map(\.id))
            },
            editThenPaste: { beginEditThenPaste($0) },
            saveAsSnippet: { beginNewSnippet(from: $0) },
            editSnippet: { beginEditSnippet($0) },
            moveSnippet: { item, offset in snippets.move(id: item.id, by: offset) },
            delete: { deleteRow($0) })
    }

    // MARK: - Keyboard

    /// ↑↓ move · ⇧↑↓ extend the selection · ↵ paste · ⌘1–9 paste by row number ·
    /// ⌘⌫ delete · ⌘⇧M merge · ⌘E edit then paste · ⌘N new snippet · ⌘R edit the
    /// snippet · ⌘⌥↑↓ reorder a snippet · ⌘⇧S show only snippets.
    ///
    /// Returns true when the key was consumed (so it never also reaches the search
    /// field).
    private func handle(_ action: KeyCommands.Action, rows: [ClipboardItem]) -> Bool {
        switch action {
        // ⌘N and ⌘⇧S are the two actions that are not about a row, and gating them on
        // a non-empty list killed them exactly where they matter most. The empty
        // state's own copy says "⌘N saves a snippet of your own" — a line that can
        // only be read while the list IS empty — and once the Snippets filter was on
        // with nothing in it, ⌘⇧S could no longer toggle back to All, leaving no
        // keyboard way out. Every case below that dereferences a row bounds-checks
        // itself, so the emptiness test belongs here rather than over everything.
        case .newSnippet, .snippetsFilter: break
        default: guard !rows.isEmpty else { return false }
        }
        switch action {
        case .down:
            selected = min(selected + 1, rows.count - 1)
        case .up:
            // Typing filters, so the search field keeps ⌥/⌘ text editing; plain
            // arrows belong to the list.
            selected = max(selected - 1, 0)
        case .extendDown:
            extendSelection(by: 1, rows: rows)
        case .extendUp:
            extendSelection(by: -1, rows: rows)
        case .paste:
            guard rows.indices.contains(selected) else { return false }
            onPaste(rows[selected])
        case .delete:
            guard rows.indices.contains(selected) else { return false }
            deleteRow(rows[selected])
            selected = min(selected, max(0, rows.count - 2))
        case .number(let n):
            guard rows.indices.contains(n - 1) else { return false }
            onPaste(rows[n - 1])
        case .merge:
            mergeSelection(rows: rows)
        case .edit:
            guard rows.indices.contains(selected) else { return false }
            beginEditThenPaste(rows[selected])
        case .newSnippet:
            beginNewSnippet(from: rows.indices.contains(selected) ? rows[selected] : nil)
        case .editSnippet:
            guard rows.indices.contains(selected), rows[selected].isSnippet else { return false }
            beginEditSnippet(rows[selected])
        case .moveSnippet(let offset):
            guard rows.indices.contains(selected), rows[selected].isSnippet else { return false }
            let id = rows[selected].id
            snippets.move(id: id, by: offset)
            // Follow the row that moved. Snippet rows are the FIRST block of the
            // list, so with no search text a snippet's index in the store IS its
            // row index; with a search active some are filtered out and the cursor
            // is left where it was rather than guessing.
            if search.isEmpty, filter.showsSnippets,
               let moved = snippets.snippets.firstIndex(where: { $0.id == id }) {
                selected = min(moved, max(0, rows.count - 1))
            }
        case .snippetsFilter:
            filter = filter == .snippets ? .all : .snippets
            selected = 0
        }
        return true
    }

    private var header: some View {
        HStack {
            Text("Clipboard").font(.headline)
            Text("\(manager.items.count)")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(.primary.opacity(0.12)))
            Spacer()
            Button { beginNewSnippet(from: nil) } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New snippet")
            .help("New snippet — a named entry of your own (⌘N)")
            Menu {
                Button("New snippet…") { beginNewSnippet(from: nil) }
                Button("Merge selected") { mergeSelection(rows: filtered) }
                    .disabled(selection.isEmpty)
                Divider()
                Button("Clear unpinned", action: manager.clearUnpinned)
                Button("Clear everything", role: .destructive, action: manager.clearAll)
            } label: {
                Image(systemName: "ellipsis.circle.fill").font(.system(size: 16))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("History actions")
            .help("Snippets, merge and clearing")
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search clipboard", text: $search).textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(.primary.opacity(0.10)))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var filterChips: some View {
        // Six chips are wider than the window's 400pt floor, and a hidden
        // scrollbar meant the last chip and a half — Pinned among them — simply
        // weren't there, with no cue that anything was off-screen. Fit them when
        // they fit; scroll visibly when they don't.
        ViewThatFits(in: .horizontal) {
            chipRow.padding(.horizontal, 16)
            ScrollView(.horizontal) { chipRow.padding(.horizontal, 16) }
        }
        .padding(.bottom, 8)
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            ForEach(ClipboardRows.Filter.allCases) { f in
                FilterChip(title: f.rawValue, icon: f.icon, active: filter == f) { filter = f }
            }
        }
    }
}

/// Keyboard driving for the history list.
///
/// A LOCAL NSEvent monitor, not SwiftUI's `onKeyPress`: the search field owns
/// focus so the user can filter by typing, and a focused TextField consumes the
/// arrow keys (caret movement) before any focus-based key modifier would see
/// them. Intercepting at the event level is the only way both behaviours can
/// coexist — and it's the same pattern `HotkeyRecorder` already uses here.
///
/// Only these exact keys are claimed; everything else falls through to the field.
private struct KeyCommands: NSViewRepresentable {
    enum Action {
        case up, down, paste, delete, number(Int)
        /// Shift+arrow — grow the multi-selection.
        case extendUp, extendDown
        case merge, edit, newSnippet, editSnippet, snippetsFilter
        /// Reorder a snippet: -1 up, +1 down.
        case moveSnippet(Int)
    }
    /// Return true to consume the event.
    let handle: (Action) -> Bool

    func makeNSView(context: Context) -> Catcher {
        let v = Catcher()
        v.handle = handle
        v.install()
        return v
    }
    func updateNSView(_ nsView: Catcher, context: Context) { nsView.handle = handle }
    static func dismantleNSView(_ nsView: Catcher, coordinator: ()) { nsView.remove() }

    final class Catcher: NSView {
        var handle: ((Action) -> Bool)?
        private var monitor: Any?

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                // Only while OUR window is the key window. A local monitor sees every
                // keyDown in the app, and this view outlives a close (the window is
                // not released), so an installed monitor would otherwise swallow ↵ /
                // ⌘E / ⌘N typed into Settings — or into this window's own sheet,
                // which is a separate key window.
                guard let self, self.window?.isKeyWindow == true,
                      let action = Self.action(for: e) else { return e }
                return self.handle?(action) == true ? nil : e
            }
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { remove() }

        private static func action(for e: NSEvent) -> Action? {
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmd = flags.contains(.command)
            let shift = flags.contains(.shift)
            // ⌥ stays with the search field for word-wise text editing, so an ⌥
            // combination is only claimed together with ⌘.
            let option = flags.contains(.option)
            switch e.keyCode {
            case 126:                                       // ↑
                if cmd && option { return .moveSnippet(-1) }
                if cmd { return nil }
                return shift ? .extendUp : .up
            case 125:                                       // ↓
                if cmd && option { return .moveSnippet(1) }
                if cmd { return nil }
                return shift ? .extendDown : .down
            case 36, 76: return cmd ? nil : .paste          // ↵ / numpad ↵
            case 51: return cmd ? .delete : nil             // ⌘⌫ — plain ⌫ edits the search text
            default: break
            }
            guard cmd, let ch = e.charactersIgnoringModifiers, ch.count == 1 else { return nil }
            // ⌘1…⌘9 → paste that numbered row (the number shown on each row).
            if let n = Int(ch), n >= 1, n <= 9 { return .number(n) }
            // `charactersIgnoringModifiers` still applies Shift, so "M" arrives for
            // ⌘⇧M — match lowercased and read the flag instead. ⌘A/C/V/X/Z are
            // deliberately absent: they belong to the search field.
            switch ch.lowercased() {
            case "m" where shift: return .merge
            case "s" where shift: return .snippetsFilter
            case "e" where !shift: return .edit
            case "n" where !shift: return .newSnippet
            case "r" where !shift: return .editSnippet
            default: return nil
            }
        }
    }
}

private struct FilterChip: View {
    let title: String; let icon: String; let active: Bool; let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.semibold))
                // 8pt vertical padding on a ~11pt label clears a 24pt target;
                // the old 5pt left the chip about 21pt tall.
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.10)))
                // Hard-coded white failed contrast against a light accent colour
                // (yellow, light green). This system colour is defined as the
                // readable foreground for an accent-filled selection in BOTH
                // appearances and for every accent the user can pick.
                .foregroundStyle(active ? Color(nsColor: .selectedMenuItemTextColor)
                                        : Color.primary.opacity(0.85))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// Window-wide click epoch. A single-click paste is deferred to tell it from a
/// double-click; while it waits, a click on ANY row (or the double-click that
/// turns into a copy) bumps `epoch`, and a deferred paste only fires if its
/// captured epoch still matches. That stops a paste queued on row A from firing
/// after the user moved on to copy row B — the window would otherwise close and
/// paste the wrong item. Reference type so all rows share one counter.
private final class ClickCoordinator {
    private(set) var epoch = 0
    /// Start a new click; returns the epoch this click owns.
    func bump() -> Int { epoch &+= 1; return epoch }
}

/// The row's outward-facing verbs, bundled so `ClipboardRow` takes one parameter
/// instead of six closures. The row knows WHEN each happens; the list knows what
/// each one means for a snippet versus a captured entry.
private struct RowActions {
    var select: (ClipboardItem, ClipboardSelection.Change) -> Void
    var editThenPaste: (ClipboardItem) -> Void
    var saveAsSnippet: (ClipboardItem) -> Void
    var editSnippet: (ClipboardItem) -> Void
    var moveSnippet: (ClipboardItem, Int) -> Void
    var delete: (ClipboardItem) -> Void
}

/// Solid, full-width list row: star · content · index.
private struct ClipboardRow: View {
    let item: ClipboardItem
    let index: Int
    @ObservedObject var manager: ClipboardManager
    @ObservedObject var settings: SettingsStore
    let clicks: ClickCoordinator
    /// True when the keyboard cursor is on this row.
    let isSelected: Bool
    /// True when this row is part of the multi-selection a merge would act on.
    let isMultiSelected: Bool
    let actions: RowActions
    var onPaste: (ClipboardItem) -> Void

    @State private var flash = false

    /// The queued single-click paste, kept so a second click can cancel it.
    ///
    /// NEVER let this outlive the row. It is nil-checked to tell a first click
    /// from a second, so a stale non-nil value would make every later click read
    /// as a double-click and the row would refuse to paste, forever, silently.
    /// Two things prevent that: the window rebuilds its root view on every open
    /// (`willShow`), and `onDisappear` cancels and clears this.
    @State private var pendingPaste: Task<Void, Never>?

    /// How long a click waits to find out whether it is really a double-click.
    ///
    /// Deliberately NOT `NSEvent.doubleClickInterval` (0.5 s by default): that
    /// value is the ceiling for how SLOW a double-click may be, and making every
    /// paste sit through it feels broken. 0.25 s catches real double-clicks, and
    /// costs nothing here — the old code already spent 0.22 s letting the click
    /// flash register before pasting, so this replaces that wait rather than
    /// adding to it.
    private static let doubleClickWindow = Duration.milliseconds(250)

    /// One click pastes, two clicks copy.
    ///
    /// The single click CANNOT act immediately: pasting closes the window, so the
    /// second click would never arrive to be seen. It queues the paste and waits
    /// out `doubleClickWindow` instead — while the highlight comes up at once, so
    /// the click still feels instant.
    ///
    /// This and the two `commit` methods below are deliberately NOT `@MainActor`:
    /// every caller is already on the main thread (the tap gesture, the context
    /// menu, a VoiceOver action, and the `@MainActor` Task inside), and the
    /// annotation would only make each closure conversion lose the isolation and
    /// warn about it.
    private func handleClick() {
        // A modifier-click is a SELECTION gesture and never a paste. Checked first
        // and returning immediately, so none of the click timing below is reached
        // — that discrimination is tuned and must stay exactly as it is.
        //
        // `NSEvent.modifierFlags` (live keyboard state) rather than the tap's own
        // event: SwiftUI's tap gesture carries no modifier information, and this
        // runs synchronously inside the click, so the live state IS the click's.
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) || flags.contains(.command) {
            // A modifier-click can't fire a paste, but it must also KILL one already
            // queued by an earlier plain click — which is the standard range gesture:
            // click the first row, Shift-click the last. The first row's paste used to
            // wake 250 ms later, close the window and send ⌘V into the app behind,
            // pasting a row nobody chose into (in a chat field) a message that then
            // gets sent — and the multi-selection being built was thrown away with the
            // window. Bumping the SHARED epoch is the load-bearing half: the queued
            // paste almost always belongs to a different row, whose `pendingPaste`
            // this view cannot reach.
            pendingPaste?.cancel()
            self.pendingPaste = nil
            _ = clicks.bump()
            actions.select(item, flags.contains(.shift) ? .extend : .toggle)
            return
        }
        if let pendingPaste {
            // Second click inside the window → this was a double-click. Bump the
            // epoch so any OTHER row's queued paste is invalidated too.
            pendingPaste.cancel()
            self.pendingPaste = nil
            _ = clicks.bump()
            commitCopy()
            return
        }
        flash = true   // acknowledge the press; nothing is copied yet
        let epoch = clicks.bump()   // this click supersedes any pending paste elsewhere
        // `@MainActor` explicitly: this method is nonisolated, so a plain
        // `Task {}` would inherit that and run the body off the main actor —
        // where touching @State, the pasteboard and NSSound is a race.
        pendingPaste = Task { @MainActor in
            try? await Task.sleep(for: Self.doubleClickWindow)
            // Fire only if still the latest click: cancelled (our own row's
            // double-click) OR superseded (another row was clicked) both abort.
            guard !Task.isCancelled, clicks.epoch == epoch else { flash = false; return }
            pendingPaste = nil
            commitPaste()
        }
    }

    /// Two clicks: copy only, and promote the item to the top — a deliberate
    /// re-copy IS a copy event, so the history should show it as the newest
    /// thing. The window STAYS OPEN so several items can be collected in a row;
    /// close with Esc / the red dot. Told apart from a paste by its own sound and
    /// by the window not going away.
    private func commitCopy() {
        manager.copyToPasteboard(item, movingToTop: true)
        if settings.playSound { Sounds.playIn() }
        endFlashSoon()
    }

    /// One click: copy, close the window, paste into the app the user came from.
    /// No extra delay before the paste — the double-click window already gave the
    /// highlight its moment on screen.
    private func commitPaste() {
        if settings.playSound { Sounds.playOut() }
        onPaste(item)
    }

    /// Drop the highlight a beat later. GCD on purpose: a 0.12 s un-highlight
    /// needs no cancellation, and a Task nobody cancels is the pattern this file
    /// is otherwise careful to avoid.
    private func endFlashSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { flash = false }
    }

    /// What the tooltip says, and the VoiceOver hint.
    private var actionHint: String {
        return "Click to paste into the previous app, double-click to copy. "
            + "Command-click or Shift-click selects rows to merge."
    }

    /// The VoiceOver LABEL for the row. `children: .combine` picks up the text of
    /// a text/link/colour row on its own, but an image row is nothing but an
    /// `Image(nsImage:)` — with no label it announces as an unnamed button.
    private var accessibilityDescription: String {
        if let title = item.title { return "Snippet, \(title)" }
        return item.isImage ? "Image" : item.preview
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if item.isSnippet {
                // No star on a snippet: it is permanent already, and a control that
                // looks like it does something but can't would be worse than none.
                // The mark says which rows are the person's own.
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Snippet")
            } else {
                // 28×28 tappable area around the 13pt glyph. At the old 18×16 a
                // near-miss fell through to the row and PASTED-and-closed instead of
                // starring — the most destructive possible mis-hit here.
                Button { manager.togglePin(item) } label: {
                    Image(systemName: item.pinned ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(item.pinned ? Color.yellow : Color.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.pinned ? "Unstar" : "Star")
                .accessibilityLabel(item.pinned ? "Unstar this item" : "Star this item")
            }

            // The accessible "button" is the CONTENT, not the whole row: putting
            // it on the row would need `children: .combine`, which swallows the
            // star button beside it and leaves pinning unreachable to VoiceOver.
            // A double-click is also not something VoiceOver can ask for, so both
            // actions are exposed by name — and neither is a modifier-click, so
            // selecting for a merge gets its own named action too.
            content.frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isMultiSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityLabel(accessibilityDescription)
                .accessibilityHint(actionHint)
                .accessibilityAction(named: "Paste") { commitPaste() }
                .accessibilityAction(named: "Copy") { commitCopy() }
                .accessibilityAction(named: isMultiSelected ? "Deselect" : "Select") {
                    actions.select(item, .toggle)
                }

            if isMultiSelected {
                // Not colour alone: the tint below is invisible to anyone who can't
                // rely on it, and this is the difference between one item pasting
                // and five items merging.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            } else {
                // Position number — useful to look at, noise to listen to.
                Text("\(index)")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        // Click flash (instant, no animation) sits ON TOP of the multi-selection and
        // keyboard-cursor tints, so a keyboard paste still reads as a distinct event.
        .background(Color.accentColor.opacity(
            flash ? 0.35 : (isMultiSelected ? 0.22 : (isSelected ? 0.16 : 0))))
        .overlay(alignment: .leading) {
            // A leading accent bar, not just a tint: the tint alone is invisible
            // to anyone who can't rely on colour.
            Rectangle().fill(Color.accentColor)
                .frame(width: isSelected ? 3 : 0)
        }
        .contentShape(Rectangle())
        // ONE click = paste into the previous app. TWO = copy only.
        // Counted by us, in `handleClick`, NOT by reading
        // NSApp.currentEvent's clickCount: that returns whatever event AppKit
        // happens to be dispatching, so a stale or non-mouse event silently ate
        // the click. Two stacked onTapGesture(count:) modifiers are no good
        // either — SwiftUI still delivers the single tap alongside the double.
        .onTapGesture(perform: handleClick)
        // An unstructured Task nobody cancels keeps running; and a pending paste
        // left over from a window the user dismissed would fire into whatever
        // they moved on to.
        .onDisappear {
            pendingPaste?.cancel()
            pendingPaste = nil
            // Clear the highlight too. It is switched on by the FIRST click and
            // only switched off by whichever commit follows — so a click on a row
            // that then leaves the lazy stack (scrolled away, filtered out) would
            // leave this row lit for the rest of the session.
            flash = false
        }
        .help(actionHint)
        .contextMenu {
            Button("Copy") { commitCopy() }
            Button("Paste into previous app") { commitPaste() }
            // Transforms act on the way OUT only — the stored history entry is a
            // log of what was copied and is never rewritten.
            if case .text(let raw) = item.kind {
                let options = TextTransform.available(for: raw)
                if options.isEmpty == false {
                    Menu("Copy as") {
                        ForEach(options) { transform in
                            Button(transform.rawValue) {
                                guard let out = transform.apply(to: raw) else { return }
                                // Through the manager, so the change is claimed:
                                // a direct pasteboard write came back through the
                                // poll half a second later as a brand new row.
                                manager.writeToPasteboard(out)
                                if settings.playSound { Sounds.playIn() }
                            }
                        }
                    }
                }
            }
            if ClipboardEdit.isEditable(item) {
                // Edit-before-paste. Named "…and paste" because it does not touch
                // the stored entry, same as the transforms above.
                Button("Edit and paste…") { actions.editThenPaste(item) }
            }
            Divider()
            if item.isSnippet {
                Button("Edit snippet…") { actions.editSnippet(item) }
                Button("Move up") { actions.moveSnippet(item, -1) }
                Button("Move down") { actions.moveSnippet(item, 1) }
            } else {
                Button("Save as snippet…") { actions.saveAsSnippet(item) }
                Button(item.pinned ? "Unstar" : "Star") { manager.togglePin(item) }
            }
            Button(isMultiSelected ? "Deselect" : "Select for merge") {
                actions.select(item, .toggle)
            }
            Divider()
            Button(item.isSnippet ? "Delete snippet" : "Delete", role: .destructive) {
                actions.delete(item)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let title = item.title {
            // A snippet leads with the name the person gave it; the body underneath
            // is the reminder of what that name means.
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(item.preview).font(.system(size: 11))
                    .foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            capturedContent
        }
    }

    @ViewBuilder private var capturedContent: some View {
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
