import AppKit
import AVKit

/// Review window shown when a recording finishes: plays the video with a
/// Screen-Studio-style trim TIMELINE below it — drag on the strip to select any
/// range (middle included), Cut it, adjust by the edge handles, Undo, then
/// Export writes the kept parts as one file (in place). Playback skips cuts.
final class RecordingPreviewWindow: NSWindowController, NSWindowDelegate {
    private static var open = Set<RecordingPreviewWindow>()
    private let url: URL
    /// Sibling file (e.g. the raw original of a subtitled copy) that Delete
    /// should also trash — otherwise the user "deletes" and a copy remains.
    private let companion: URL?
    private let player: AVPlayer
    private let strip = TimelineStripView()

    private var duration: Double = 0
    private var kept: [ClosedRange<Double>] = []
    private var undoStack: [[ClosedRange<Double>]] = []
    private var timeObserver: Any?

    private var exporting = false
    private var cutButton: NSButton?
    private var undoButton: NSButton?
    private var exportButton: NSButton?

    static func show(_ url: URL, alsoTrashing companion: URL? = nil) {
        let controller = RecordingPreviewWindow(url: url, companion: companion)
        open.insert(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(url: URL, companion: URL? = nil) {
        self.url = url
        self.companion = companion
        self.player = AVPlayer(url: url)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 400)
        window.center()
        super.init(window: window)
        window.delegate = self

        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.translatesAutoresizingMaskIntoConstraints = false

        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.onSeek = { [weak self] t in
            self?.player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
        strip.onSelectionChanged = { [weak self] sel in
            self?.cutButton?.isEnabled = sel != nil
        }
        strip.onDeleteSelection = { [weak self] in self?.cutTapped() }

        let cut = NSButton(title: "Cut Selection", target: self, action: #selector(cutTapped))
        cut.bezelStyle = .texturedRounded
        cut.toolTip = "Remove the selected range from the video (drag on the timeline to select)"
        cut.isEnabled = false
        cutButton = cut
        let undo = NSButton(title: "Undo", target: self, action: #selector(undoTapped))
        undo.bezelStyle = .texturedRounded
        undo.isEnabled = false
        undoButton = undo
        let export = NSButton(title: "Export", target: self, action: #selector(exportTapped))
        export.bezelStyle = .texturedRounded
        export.toolTip = "Save the video with the cuts applied (replaces the file)"
        export.isEnabled = false
        exportButton = export
        let reveal = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealTapped))
        reveal.bezelStyle = .texturedRounded
        let trash = NSButton(title: "Delete", target: self, action: #selector(deleteTapped))
        trash.bezelStyle = .texturedRounded
        trash.hasDestructiveAction = true
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .texturedRounded
        done.keyEquivalent = "\r"

        let bar = NSStackView(views: [cut, undo, export, NSView(), reveal, trash, done])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 10, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(playerView)
        container.addSubview(strip)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: container.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            strip.topAnchor.constraint(equalTo: playerView.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 64),
            bar.topAnchor.constraint(equalTo: strip.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 42),
        ])
        window.contentView = container

        loadAsset()
        player.play()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func loadAsset() {
        let asset = AVURLAsset(url: url)
        strip.loadThumbnails(from: asset)
        Task { @MainActor [weak self] in
            guard let self, let dur = try? await asset.load(.duration).seconds else { return }
            self.duration = dur
            self.kept = dur > 0 ? [0...dur] : []
            self.strip.duration = dur
            self.strip.kept = self.kept
        }
        // Playhead sync + skip over cut ranges during playback.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            guard let self else { return }
            let s = t.seconds
            self.strip.playhead = s
            guard self.player.rate > 0 else { return }
            // Inside a removed range → jump to the next kept segment.
            let sorted = self.kept.sorted { $0.lowerBound < $1.lowerBound }
            let inKept = sorted.contains { $0.lowerBound - 0.03 <= s && s <= $0.upperBound + 0.03 }
            if !inKept, self.duration > 0 {
                if let next = sorted.first(where: { $0.lowerBound > s }) {
                    self.player.seek(to: CMTime(seconds: next.lowerBound, preferredTimescale: 600),
                                     toleranceBefore: .zero, toleranceAfter: .zero)
                } else {
                    self.player.pause()
                }
            }
        }
    }

    // MARK: - Editing

    @objc private func cutTapped() {
        guard !exporting, let sel = strip.selection else { return }
        undoStack.append(kept)
        kept = Self.subtract(sel, from: kept)
        strip.kept = kept
        strip.clearSelection()
        undoButton?.isEnabled = true
        exportButton?.isEnabled = true
        exportButton?.title = "Export (\(max(0, cutsCount())) cut\(cutsCount() == 1 ? "" : "s"))"
    }

    @objc private func undoTapped() {
        guard !exporting, let prev = undoStack.popLast() else { return }
        kept = prev
        strip.kept = kept
        undoButton?.isEnabled = !undoStack.isEmpty
        let n = cutsCount()
        exportButton?.isEnabled = n > 0
        exportButton?.title = n > 0 ? "Export (\(n) cut\(n == 1 ? "" : "s"))" : "Export"
    }

    private func cutsCount() -> Int {
        guard duration > 0 else { return 0 }
        // Cuts = gaps in kept (incl. leading/trailing).
        let sorted = kept.sorted { $0.lowerBound < $1.lowerBound }
        var n = 0
        var cursor = 0.0
        for k in sorted {
            if k.lowerBound > cursor + 0.001 { n += 1 }
            cursor = max(cursor, k.upperBound)
        }
        if cursor < duration - 0.001 { n += 1 }
        return n
    }

    /// Remove `cut` from every kept range (splitting where needed).
    private static func subtract(_ cut: ClosedRange<Double>,
                                 from ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in ranges {
            if cut.upperBound <= r.lowerBound || cut.lowerBound >= r.upperBound {
                out.append(r)                                      // no overlap
            } else {
                if cut.lowerBound > r.lowerBound + 0.01 { out.append(r.lowerBound...cut.lowerBound) }
                if cut.upperBound < r.upperBound - 0.01 { out.append(cut.upperBound...r.upperBound) }
            }
        }
        return out
    }

    @objc private func exportTapped() {
        guard !kept.isEmpty else {
            Notifier.error("Nothing to export", "Every part of the video was cut.")
            return
        }
        player.pause()
        // Lock every mutation while the export runs — cutting/undoing/deleting
        // under an in-flight export corrupts the result or orphans files.
        exporting = true
        exportButton?.isEnabled = false
        cutButton?.isEnabled = false
        undoButton?.isEnabled = false
        exportButton?.title = "Exporting…"
        let segments = kept
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let tmp = try await TimelineExporter.export(source: self.url, kept: segments) { [weak self] pct in
                    self?.exportButton?.title = "Exporting… \(pct)%"
                }
                _ = try FileManager.default.replaceItemAt(self.url, withItemAt: tmp)
                self.exporting = false
                self.undoStack = []
                self.undoButton?.isEnabled = false
                self.exportButton?.title = "Export"
                self.player.replaceCurrentItem(with: AVPlayerItem(url: self.url))
                self.loadAssetAfterExport()
                self.player.play()
                Notifier.info("Exported", "Cuts applied and saved.")
            } catch {
                self.exporting = false
                self.exportButton?.isEnabled = true
                self.undoButton?.isEnabled = !self.undoStack.isEmpty
                self.exportButton?.title = "Export"
                Notifier.error("Export failed", error.localizedDescription)
            }
        }
    }

    private func loadAssetAfterExport() {
        let asset = AVURLAsset(url: url)
        strip.loadThumbnails(from: asset)
        Task { @MainActor [weak self] in
            guard let self, let dur = try? await asset.load(.duration).seconds else { return }
            self.duration = dur
            self.kept = dur > 0 ? [0...dur] : []
            self.strip.duration = dur
            self.strip.kept = self.kept
            self.strip.clearSelection()
        }
    }

    // MARK: - File actions

    @objc private func revealTapped() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func deleteTapped() {
        guard !exporting else { return }
        player.pause()
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if let companion { try? FileManager.default.trashItem(at: companion, resultingItemURL: nil) }
        close()
    }

    @objc private func doneTapped() { close() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if exporting {
            Notifier.info("Export in progress", "Wait for the export to finish before closing.")
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        Self.open.remove(self)
    }
}
