import AppKit
import AVFoundation

/// Advanced trim timeline: a filmstrip of the video where
/// the user drags to select ANY range, cuts it (middle cuts included), adjusts
/// the selection by its edge handles, and exports the kept parts as one video.
///
/// Pure view — owns no AVPlayer. The preview window feeds it duration/playhead
/// and reacts to callbacks.
final class TimelineStripView: NSView {
    // MARK: - Model (seconds)
    var duration: Double = 0 { didSet { needsDisplay = true } }
    /// Ranges that remain in the exported video (sorted, non-overlapping).
    var kept: [ClosedRange<Double>] = [] { didSet { needsDisplay = true } }
    /// Current drag selection (candidate cut).
    private(set) var selection: ClosedRange<Double>? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)   // handle zones moved
        }
    }
    var playhead: Double = 0 {
        didSet {
            // Player time observers fire many times per second; skip the redraw
            // unless the playhead actually moved a whole pixel on this strip.
            guard Int(x(for: playhead).rounded()) != Int(x(for: oldValue).rounded()) else { return }
            needsDisplay = true
        }
    }

    var onSeek: ((Double) -> Void)?
    var onSelectionChanged: ((ClosedRange<Double>?) -> Void)?
    /// ⌫ / delete with an active selection → cut it.
    var onDeleteSelection: (() -> Void)?

    // MARK: - Thumbnails
    private var thumbs: [CGImage] = []
    private var thumbGen: AVAssetImageGenerator?
    /// Bumped per load — a stale (pre-export) load must not overwrite a fresh one.
    private var thumbGeneration = 0

    func loadThumbnails(from asset: AVAsset, count: Int = 16) {
        thumbGen?.cancelAllCGImageGeneration()   // stop the superseded (pre-export) run
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 0, height: 120)
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        thumbGen = gen
        thumbGeneration += 1
        let generation = thumbGeneration
        Task { [weak self] in
            guard let dur = try? await asset.load(.duration).seconds, dur > 0 else { return }
            var imgs: [CGImage] = []
            for i in 0..<count {
                let t = CMTime(seconds: dur * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
                if let img = try? await gen.image(at: t).image { imgs.append(img) }
            }
            let done = imgs
            await MainActor.run { [weak self] in
                guard let self, self.thumbGeneration == generation else { return }
                self.thumbs = done
                self.needsDisplay = true
            }
        }
    }

    func clearSelection() {
        selection = nil
        onSelectionChanged?(nil)
    }

    // MARK: - Geometry
    private var stripRect: NSRect { bounds.insetBy(dx: 8, dy: 6) }
    private func x(for t: Double) -> CGFloat {
        guard duration > 0 else { return stripRect.minX }
        return stripRect.minX + stripRect.width * CGFloat(t / duration)
    }
    private func time(at x: CGFloat) -> Double {
        guard duration > 0, stripRect.width > 0 else { return 0 }
        let f = Double((x - stripRect.minX) / stripRect.width)
        return min(max(f, 0), 1) * duration
    }

    // MARK: - Drawing
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = stripRect
        // Base + filmstrip.
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        if !thumbs.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).setClip()
            let tw = r.width / CGFloat(thumbs.count)
            for (i, t) in thumbs.enumerated() {
                let dst = NSRect(x: r.minX + CGFloat(i) * tw, y: r.minY, width: tw, height: r.height)
                NSImage(cgImage: t, size: dst.size).draw(in: dst)
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // Cut (removed) ranges = darkened + red hatch.
        if duration > 0 {
            for cut in cutRanges() {
                let cr = NSRect(x: x(for: cut.lowerBound), y: r.minY,
                                width: max(1, x(for: cut.upperBound) - x(for: cut.lowerBound)),
                                height: r.height)
                NSColor.black.withAlphaComponent(0.62).setFill()
                cr.fill(using: .sourceOver)
                NSColor.systemRed.withAlphaComponent(0.55).setStroke()
                let hatch = NSBezierPath(); hatch.lineWidth = 1
                var hx = cr.minX - cr.height
                while hx < cr.maxX {
                    hatch.move(to: NSPoint(x: max(hx, cr.minX), y: hx < cr.minX ? cr.minY + (cr.minX - hx) : cr.minY))
                    hatch.line(to: NSPoint(x: min(hx + cr.height, cr.maxX),
                                           y: hx + cr.height > cr.maxX ? cr.minY + (cr.maxX - hx) : cr.maxY))
                    hx += 8
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: cr).setClip()
                hatch.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        // Selection = accent overlay + edge handles.
        if let sel = selection {
            let sr = NSRect(x: x(for: sel.lowerBound), y: r.minY,
                            width: max(2, x(for: sel.upperBound) - x(for: sel.lowerBound)),
                            height: r.height)
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            sr.fill(using: .sourceOver)
            NSColor.controlAccentColor.setStroke()
            let box = NSBezierPath(rect: sr); box.lineWidth = 2; box.stroke()
            NSColor.white.setFill()
            for hx in [sr.minX, sr.maxX] {
                NSBezierPath(roundedRect: NSRect(x: hx - 2.5, y: sr.midY - 9, width: 5, height: 18),
                             xRadius: 2.5, yRadius: 2.5).fill()
            }
        }

        // Playhead.
        if duration > 0 {
            let px = x(for: playhead)
            NSColor.white.setFill()
            NSRect(x: px - 1, y: r.minY - 3, width: 2, height: r.height + 6).fill()
        }

        // Border.
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let b = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        b.lineWidth = 1; b.stroke()
    }

    /// Complement of `kept` within [0, duration].
    private func cutRanges() -> [ClosedRange<Double>] {
        guard duration > 0 else { return [] }
        var cuts: [ClosedRange<Double>] = []
        var cursor = 0.0
        for k in kept.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if k.lowerBound > cursor + 0.001 { cuts.append(cursor...k.lowerBound) }
            cursor = max(cursor, k.upperBound)
        }
        if cursor < duration - 0.001 { cuts.append(cursor...duration) }
        return cuts
    }

    // MARK: - Mouse
    private enum Drag { case none, new(anchor: Double), resizeLow, resizeHigh }
    private var drag: Drag = .none
    private var downX: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downX = p.x
        if let sel = selection {
            if abs(p.x - x(for: sel.lowerBound)) < 7 { drag = .resizeLow; return }
            if abs(p.x - x(for: sel.upperBound)) < 7 { drag = .resizeHigh; return }
        }
        drag = .new(anchor: time(at: p.x))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = time(at: p.x)
        switch drag {
        case .new(let anchor):
            guard abs(p.x - downX) > 3 else { return }
            selection = min(anchor, t)...max(anchor, t)
        case .resizeLow:
            if let sel = selection, t < sel.upperBound { selection = t...sel.upperBound }
        case .resizeHigh:
            if let sel = selection, t > sel.lowerBound { selection = sel.lowerBound...t }
        case .none: break
        }
        onSelectionChanged?(selection)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .new = drag, abs(p.x - downX) <= 3 {
            // Plain click → seek + clear selection.
            selection = nil
            onSelectionChanged?(nil)
            onSeek?(time(at: p.x))
        } else if selection != nil {
            // ⌫ cuts the selection — but AppKit never hands first-responder status
            // to a plain NSView on its own, so the key went to the player and the
            // shortcut did nothing at all. Claim focus only once there IS something
            // to delete, so a plain click-to-seek leaves the player's own keys alone.
            window?.makeFirstResponder(self)
        }
        drag = .none
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        // ⌫ or forward-delete cuts the current selection.
        if selection != nil, event.keyCode == 51 || event.keyCode == 117 {
            onDeleteSelection?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if let sel = selection {
            for hx in [x(for: sel.lowerBound), x(for: sel.upperBound)] {
                addCursorRect(NSRect(x: hx - 7, y: 0, width: 14, height: bounds.height),
                              cursor: .resizeLeftRight)
            }
        }
    }
}

// MARK: - Multi-segment export

enum TimelineExporter {
    /// Build a composition of the kept ranges and export it. Tries lossless
    /// passthrough first; falls back to re-encode if passthrough can't handle
    /// the cuts. Returns the exported temp URL.
    static func export(source: URL, kept: [ClosedRange<Double>],
                       progress: (@MainActor (Int) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let comp = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let srcVideo = videoTracks.first else {
            throw NSError(domain: "SnapDesk", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No video track."])
        }
        // Not optional-chained: the caller REPLACES the user's recording with what
        // comes back here, so a composition that quietly ended up without a video
        // track would export an empty movie, report success, and overwrite the take.
        guard let compVideo = comp.addMutableTrack(withMediaType: .video,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "SnapDesk", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't build the trimmed video."])
        }
        if let transform = try? await srcVideo.load(.preferredTransform) {
            compVideo.preferredTransform = transform   // keep rotation metadata
        }
        // Paired with `audioTracks` BY INDEX below, so a track that couldn't be
        // added has to keep its slot rather than shift every later one onto the
        // wrong source.
        let compAudios: [AVMutableCompositionTrack?] = audioTracks.map { _ in
            comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        // The audio track is routinely SHORTER than the picture — it begins at the
        // first mixed chunk and ends at the stop flush, while the video spans the
        // whole take — so a kept range measured from the ASSET duration can reach
        // past its end. Clip to what each track actually holds, and let a real
        // failure surface: the `try?` this replaces turned a rejected insert into a
        // SILENT video that then overwrote the recording, without a word.
        var audioRanges: [CMTimeRange] = []
        for track in audioTracks { audioRanges.append(try await track.load(.timeRange)) }
        var cursor = CMTime.zero
        for seg in kept.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let range = CMTimeRange(
                start: CMTime(seconds: seg.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: seg.upperBound, preferredTimescale: 600))
            try compVideo.insertTimeRange(range, of: srcVideo, at: cursor)
            for (i, a) in audioTracks.enumerated() {
                guard let target = compAudios[i] else { continue }
                let clipped = range.intersection(audioRanges[i])
                guard clipped.isValid, clipped.duration > .zero else { continue }
                // Clipping the FRONT of a range must not slide the audio forward:
                // keep it where it belongs inside the segment.
                try target.insertTimeRange(clipped, of: a,
                                           at: CMTimeAdd(cursor, CMTimeSubtract(clipped.start, range.start)))
            }
            cursor = cursor + range.duration
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapDesk-edit-\(UUID().uuidString).mov")
        // Re-encode is the SAFE choice for multi-segment cuts: passthrough
        // represents cuts as edit lists that freeze/glitch on non-Apple players
        // (Chrome, Windows). Passthrough stays as a last-resort fallback only.
        var lastError: Error?
        for preset in [AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough] {
            guard let ex = AVAssetExportSession(asset: comp, presetName: preset) else { continue }
            ex.outputURL = out
            ex.outputFileType = .mov
            try? FileManager.default.removeItem(at: out)
            // Poll progress (KVO on .progress is unreliable) while exporting.
            let poll = Task { @MainActor in
                while !Task.isCancelled {
                    progress?(Int(ex.progress * 100))
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            await ex.export()
            poll.cancel()
            if ex.status == .completed { return out }
            lastError = ex.error
        }
        // Say WHY. Throwing away the session's own error left "Export failed." as
        // the whole story, so a full disk and an unplayable source read identically
        // and neither one told the user what to do next. The half-written output has
        // to go too — a long take leaves hundreds of megabytes nothing points at.
        try? FileManager.default.removeItem(at: out)
        throw lastError ?? NSError(domain: "SnapDesk", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "Export failed."])
    }
}
