import AppKit
import CoreGraphics
@preconcurrency import Vision

/// Scrolling capture: pick a region, scroll the content yourself, press Done —
/// SnapDesk grabs a frame whenever the content changes and stitches the frames
/// into one tall image by matching the overlap between consecutive shots.
final class ScrollCapture: NSObject, @unchecked Sendable {
    private static var current: ScrollCapture?

    private let selection: RegionSelection
    private weak var settings: SettingsStore?
    private var frames: [CGImage] = []
    private var signatures: [[Float]] = []
    private var timer: Timer?
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var barWindow: NSWindow?
    private var borderWindow: NSWindow?
    private var countLabel: NSTextField?
    private var autoButton: NSButton?
    private var autoRunning = false
    private var autoTask: Task<Void, Never>?
    private var capturing = false
    private var bytesStored = 0
    private var lastGrab = Date.distantPast
    private var limitNotified = false
    /// Vision offsets computed DURING capture (serial queue) so Done stitches
    /// instantly instead of running 100+ registrations at the end.
    private var visionOffsets: [Int?] = []          // [i] = scroll px frame i-1 → i
    private let alignQueue = DispatchQueue(label: "snapdesk.scroll.align", qos: .userInitiated)

    /// True while a session is running — the hotkey toggles Done.
    static var isActive: Bool { current != nil }

    @MainActor
    static func finishActive() { current?.finish(save: true) }

    @MainActor
    static func begin(selection: RegionSelection, settings: SettingsStore) {
        guard current == nil else { return }
        let s = ScrollCapture(selection: selection, settings: settings)
        current = s
        s.start()
    }

    private init(selection: RegionSelection, settings: SettingsStore) {
        self.selection = selection
        self.settings = settings
        super.init()
    }

    // MARK: - Session

    @MainActor
    private func start() {
        showBorder()
        showBar()
        Notifier.info("Scrolling capture",
                      "Press Auto-Scroll — or scroll yourself — then Done.")
        // Steady cadence + an immediate grab on every scroll tick — the capture
        // keeps up with the user instead of lagging 1/3 s behind (smoothness).
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.tick()
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.tick()
        }
        // Esc anywhere cancels the session (the tiny ✕ was the only way out).
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(save: false) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(save: false); return nil }
            return e
        }
        tick()   // grab the first frame right away
    }

    private func tick() {
        // Cap by real memory use (~400 MB of frames), not a blind frame count.
        // Throttle: scroll events arrive in storms — one grab per 0.12 s max.
        if frames.count >= 240 || bytesStored >= 400_000_000 {
            if !limitNotified {
                limitNotified = true
                Notifier.info("Capture limit reached", "Press Done to stitch what you have.")
            }
            return
        }
        guard !capturing, Date().timeIntervalSince(lastGrab) > 0.12 else { return }
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            guard let full = try? await CaptureService.captureScreen(selection.screen) else { return }
            let k = selection.screen.backingScaleFactor
            let r = selection.rectInScreenPoints
            let px = CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
                .integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
            guard !px.isEmpty, let shared = full.cropping(to: px) else { return }
            // Signature + dedup on the CHEAP shared crop first — only frames we
            // actually keep pay for the full-buffer deepCopy (idle 0.18s ticks
            // on a paused page were allocating + discarding a full crop each).
            let sig = Self.rowSignature(shared)
            if let last = signatures.last, Self.meanDiff(last, sig) < 1.5 { return }
            guard let crop = Self.deepCopy(shared) else { return }
            let prev = frames.last
            frames.append(crop)
            signatures.append(sig)
            bytesStored += crop.bytesPerRow * crop.height
            lastGrab = Date()
            countLabel?.stringValue = "\(frames.count)"
            // Align this pair NOW (off-main, serial → ordered) — stitching at
            // Done becomes instant instead of running 100+ registrations.
            if let prev {
                alignQueue.async { [weak self] in
                    let off = Self.visionScroll(prev, crop)
                    self?.visionOffsets.append(off)   // serial queue owns the array
                }
            }
        }
    }

    private func finish(save: Bool) {
        guard Self.current === self else { return }   // ignore double/stale finish
        autoRunning = false
        autoTask?.cancel(); autoTask = nil
        timer?.invalidate(); timer = nil
        if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        barWindow?.orderOut(nil); barWindow = nil
        borderWindow?.orderOut(nil); borderWindow = nil
        let frames = self.frames
        let sigs = self.signatures
        let settings = self.settings
        let scale = selection.screen.backingScaleFactor
        Self.current = nil
        guard save, !frames.isEmpty else { return }

        Notifier.info("Stitching…", "\(frames.count) frames")
        let alignQueue = self.alignQueue
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Serial queue: sync waits for every in-flight alignment, then the
            // array is complete and safe to read.
            var offs: [Int?] = []
            alignQueue.sync { offs = self.visionOffsets }
            guard let stitched = Self.stitch(frames: frames, signatures: sigs, offsets: offs) else {
                DispatchQueue.main.async { Notifier.error("Scrolling capture failed", "Couldn't stitch the frames.") }
                return
            }
            DispatchQueue.main.async {
                Self.deliver(stitched, settings: settings, scale: scale)
            }
        }
    }

    @MainActor
    private static func deliver(_ cg: CGImage, settings: SettingsStore?, scale: CGFloat) {
        // Clipboard.
        let ns = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale,
                                                   height: CGFloat(cg.height) / scale))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([ns])
        // File.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var dir = settings?.autoSaveFolder ?? (NSHomeDirectory() + "/Desktop")
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) {
            dir = NSHomeDirectory() + "/Desktop"
        }
        let url = URL(fileURLWithPath: dir)
            .appendingPathComponent("SnapDesk Scroll \(f.string(from: Date())).png")
        var savedTo: String? = nil
        if let data = AnnotationRenderer.encode(cg, format: .png, quality: 1),
           (try? data.write(to: url, options: .atomic)) != nil {
            savedTo = url.lastPathComponent
            NSWorkspace.shared.open(url)   // show the result immediately
        }
        if settings?.playSound == true { Sounds.play(settings?.soundName ?? "SnapBlip") }
        Notifier.info("Scrolling capture ready",
                      savedTo.map { "Copied to clipboard · \($0)" } ?? "Copied to clipboard")
    }

    /// CGImage.cropping() shares the ENTIRE source backing store — a small
    /// crop of a 5K screenshot pins ~60 MB. Redraw into a right-sized buffer.
    private static func deepCopy(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    // MARK: - Stitching

    /// Per-row signature: 3 horizontal bands (left/mid/right thirds) of a
    /// 96-wide grayscale downsample → 3 floats per row. Bands keep horizontal
    /// structure a single row-mean loses, so alignment is far less likely to
    /// snap to the wrong offset on repetitive content. Layout: [l,m,r] * rows.
    static let bandsPerRow = 3
    private static func rowSignature(_ img: CGImage) -> [Float] {
        let w = 96, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sig = [Float](repeating: 0, count: h * bandsPerRow)
        let third = w / 3
        for y in 0..<h {
            for b in 0..<bandsPerRow {
                var sum = 0
                let x0 = b * third, x1 = (b == bandsPerRow - 1) ? w : (b + 1) * third
                for x in x0..<x1 { sum += Int(buf[y * w + x]) }
                sig[y * bandsPerRow + b] = Float(sum) / Float(x1 - x0)
            }
        }
        return sig   // row 0 = image TOP
    }

    /// Rows in a signature.
    private static func rows(_ sig: [Float]) -> Int { sig.count / bandsPerRow }

    /// Mean abs diff between the same row of two signatures.
    @inline(__always)
    private static func rowDiff(_ a: [Float], _ ra: Int, _ b: [Float], _ rb: Int) -> Float {
        var s: Float = 0
        for k in 0..<bandsPerRow { s += abs(a[ra * bandsPerRow + k] - b[rb * bandsPerRow + k]) }
        return s / Float(bandsPerRow)
    }

    /// Sticky header height (rows): rows at the top that stayed identical
    /// across EVERY frame (site nav bars, toolbars). They must be ignored when
    /// aligning, or the header stitches into the image over and over.
    private static func stickyHeaderRows(_ sigs: [[Float]]) -> Int {
        guard sigs.count >= 3, let first = sigs.first else { return 0 }
        let h = rows(first)
        let maxHeader = h * 2 / 5
        var header = maxHeader
        for sig in sigs.dropFirst() {
            guard rows(sig) == h else { return 0 }
            var match = 0
            while match < header, rowDiff(first, match, sig, match) < 2.0 { match += 1 }
            header = min(header, match)
            if header == 0 { break }
        }
        return header
    }

    private static func meanDiff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var s: Float = 0
        for i in 0..<a.count { s += abs(a[i] - b[i]) }
        return s / Float(a.count)
    }

    /// Row contrast (max band spread) — flat rows (whitespace) carry no
    /// alignment information and are down-weighted in matching.
    @inline(__always)
    private static func rowContrast(_ a: [Float], _ r: Int) -> Float {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for k in 0..<bandsPerRow {
            let v = a[r * bandsPerRow + k]
            lo = min(lo, v); hi = max(hi, v)
        }
        return hi - lo
    }

    /// Find how many rows at the BOTTOM of `prev` match the TOP of `next`,
    /// ignoring `header` sticky rows at the top of both frames. Contrast-
    /// weighted SAD: flat (whitespace) rows contribute little, so alignment
    /// locks onto real content edges instead of blank space.
    private static func bestOverlap(_ prev: [Float], _ next: [Float], header: Int) -> Int? {
        let h = min(rows(prev), rows(next)) - header
        guard h > 40 else { return nil }
        var bestO = 0
        var bestScore = Float.infinity
        let minO = max(12, h / 20)
        var o = h - 1
        while o >= minO {
            var s: Float = 0
            var wsum: Float = 0
            let step = max(1, o / 160)   // sample rows for speed
            var i = 0
            while i < o {
                let rp = header + h - o + i     // row in prev
                let rn = header + i             // row in next
                let w = max(0.15, min(1, rowContrast(prev, rp) / 24))
                s += rowDiff(prev, rp, next, rn) * w
                wsum += w
                i += step
            }
            let score = s / max(0.001, wsum)
            if score < bestScore { bestScore = score; bestO = o }
            o -= 1
        }
        return bestScore < 4.0 ? bestO + header : nil   // weak match → new content
    }

    /// Vision translational registration between two frames — the ScrollSnap /
    /// macshot technique (proven smoother than hand-rolled matching). 5 full-
    /// width bands; ≥4 of 5 must agree within 3 px (bands over a sticky header
    /// report ~0 and get outvoted). Returns scroll amount in pixels (down > 0).
    private static func visionScroll(_ prev: CGImage, _ next: CGImage) -> Int? {
        let h = prev.height, w = prev.width
        guard h == next.height, w == next.width, h > 120 else { return nil }
        let bandH = max(80, h / 3)
        let bandCount = 5
        var tys: [CGFloat] = []
        for i in 0..<bandCount {
            let maxY = h - bandH
            let y = maxY <= 0 ? 0 : (maxY * i) / (bandCount - 1)
            let rect = CGRect(x: 0, y: CGFloat(y), width: CGFloat(w), height: CGFloat(bandH))
            guard let pBand = prev.cropping(to: rect), let nBand = next.cropping(to: rect) else { continue }
            let req = VNTranslationalImageRegistrationRequest(targetedCGImage: nBand)
            let handler = VNImageRequestHandler(cgImage: pBand)
            guard (try? handler.perform([req])) != nil,
                  let obs = req.results?.first as? VNImageTranslationAlignmentObservation else { continue }
            let t = obs.alignmentTransform
            guard abs(t.tx) <= 3 else { continue }        // horizontal jitter → distrust
            tys.append(t.ty)
        }
        guard !tys.isEmpty else { return nil }
        // Consensus: largest group agreeing within 3 px; need ≥4 (of 5) votes.
        var best: [CGFloat] = []
        for v in tys {
            let group = tys.filter { abs($0 - v) <= 3 }
            if group.count > best.count { best = group }
        }
        guard best.count >= max(2, Int((Double(bandCount) * 0.75).rounded(.up))) else { return nil }  // ≥4 of 5
        let ty = best.reduce(0, +) / CGFloat(best.count)
        // Vision cgImage coords: content scrolled down (moved up on screen) →
        // ty magnitude = scroll in pixels. Sign varies by orientation handling;
        // caller verifies against signatures, so return magnitude.
        let scroll = Int(abs(ty).rounded())
        return (scroll > 2 && scroll < h) ? scroll : nil
    }

    /// SAD score of a specific overlap (rows) between prev-bottom and next-top.
    private static func overlapScore(_ prev: [Float], _ next: [Float], overlap: Int, header: Int) -> Float {
        let h = min(rows(prev), rows(next)) - header
        let o = overlap - header
        guard h > 0, o > 4, o < h else { return .infinity }
        var s: Float = 0, wsum: Float = 0
        let step = max(1, o / 160)
        var i = 0
        while i < o {
            let rp = header + h - o + i, rn = header + i
            let w = max(0.15, min(1, rowContrast(prev, rp) / 24))
            s += rowDiff(prev, rp, next, rn) * w
            wsum += w
            i += step
        }
        return s / max(0.001, wsum)
    }

    private static func stitch(frames: [CGImage], signatures: [[Float]], offsets: [Int?] = []) -> CGImage? {
        guard let first = frames.first else { return nil }
        guard frames.count > 1 else { return first }
        let w = first.width
        // Sticky site header (nav bar etc.) present in every frame → ignore it
        // while aligning and never re-append it mid-image.
        let sigHeader = stickyHeaderRows(signatures)
        let scaleY = first.height > 0 ? Float(first.height) / Float(rows(signatures[0])) : 1
        let headerPx = Int(Float(sigHeader) * scaleY)
        // Row ranges of each frame to append (frame, fromRow).
        var pieces: [(CGImage, Int)] = [(first, 0)]
        var total = first.height
        var ref = 0   // last appended frame — skipped frames must not shift the chain
        for i in 1..<frames.count {
            let h = min(rows(signatures[ref]), rows(signatures[i]))
            // 1) Vision registration candidate (precomputed during capture),
            //    verified ±2 rows against the signature score…
            var overlap: Int? = nil
            if ref == i - 1, let scroll = (i - 1) < offsets.count
                ? offsets[i - 1] : visionScroll(frames[i - 1], frames[i]) {
                var bestO: Int? = nil
                var bestS = Float(4.0)
                for d in -2...2 {
                    let o = h - scroll + d
                    let sc = overlapScore(signatures[ref], signatures[i], overlap: o, header: sigHeader)
                    if sc < bestS { bestS = sc; bestO = o }
                }
                overlap = bestO
            }
            // 2) …else the full contrast-weighted SAD search.
            if overlap == nil {
                overlap = bestOverlap(signatures[ref], signatures[i], header: sigHeader)
            }
            // No alignment (scrolled back up / jumped) → SKIP the frame: blindly
            // appending duplicates or garbles content. The next frame usually
            // re-overlaps with the last appended one.
            guard let ov = overlap else { continue }
            let from = max(Int(Float(ov) * scaleY), headerPx)
            let add = frames[i].height - from
            guard add > 0 else { ref = i; continue }   // fully-overlapping frame
            pieces.append((frames[i], from))
            total += add
            ref = i
            // Cap by BYTES too (w×total×4) — 60k rows of a wide capture would
            // be a ~gigabyte single allocation.
            if total > 60_000 || total * w * 4 > 700_000_000 { break }
        }
        guard total > 0,
              let ctx = CGContext(data: nil, width: w, height: total, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // CG origin bottom-left; lay pieces top-down. Draw ONLY each frame's
        // new rows [from..h) — drawing the full frame would stamp its top rows
        // (incl. any sticky header) over the previous piece at every seam.
        var yTop = 0
        for (img, from) in pieces {
            let visible = img.height - from
            guard visible > 0 else { continue }
            let slice: CGImage? = from == 0 ? img
                : img.cropping(to: CGRect(x: 0, y: from, width: img.width, height: visible))
            guard let slice else { continue }
            let y = total - yTop - visible
            ctx.draw(slice, in: CGRect(x: 0, y: y, width: img.width, height: visible))
            yTop += visible
        }
        return ctx.makeImage()
    }

    /// Selection rect in global AppKit coords.
    private var globalRect: NSRect {
        let s = selection.screen.frame
        let r = selection.rectInScreenPoints
        return NSRect(x: s.minX + r.minX, y: s.minY + s.height - r.maxY,
                      width: r.width, height: r.height)
    }

    /// Spotlight for the whole session: only the captured area stays live.
    @MainActor
    private func showBorder() {
        let win = SpotlightOverlay.window(around: globalRect,
                                          on: selection.screen, border: .controlAccentColor)
        win.orderFront(nil)
        borderWindow = win
    }

    // MARK: - Auto-scroll

    /// The area's centre in GLOBAL CG (top-left origin) coords — scroll events
    /// are delivered to the window under this point.
    private var scrollPointCG: CGPoint {
        let primaryH = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? selection.screen.frame.height
        let g = globalRect
        return CGPoint(x: g.midX, y: primaryH - g.midY)
    }

    @objc private func autoTapped() {
        if autoRunning {
            autoRunning = false
            autoTask?.cancel(); autoTask = nil
            autoButton?.title = "  Auto-Scroll"
            return
        }
        autoRunning = true
        autoButton?.title = "  Pause"
        let pt = scrollPointCG
        // Cursor over the content so the scroll events land on it.
        CGWarpMouseCursorPosition(pt)
        let stepPx = Int32(max(120, globalRect.height * 0.55))
        autoTask = Task { @MainActor [weak self] in
            var stale = 0
            while let self, self.autoRunning, !Task.isCancelled, ScrollCapture.isActive {
                let before = self.frames.count
                // Smooth sub-steps — big single jumps break lazy-loading pages.
                for _ in 0..<3 where self.autoRunning {
                    if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                       wheelCount: 1, wheel1: -(stepPx / 3), wheel2: 0, wheel3: 0) {
                        e.location = pt
                        e.post(tap: .cghidEventTap)
                    }
                    try? await Task.sleep(nanoseconds: 140_000_000)
                }
                try? await Task.sleep(nanoseconds: 320_000_000)   // let content settle
                self.tick()
                try? await Task.sleep(nanoseconds: 220_000_000)
                // No new frame twice in a row → reached the bottom → stitch.
                if self.frames.count == before { stale += 1 } else { stale = 0 }
                if stale >= 2 {
                    self.finish(save: true)
                    return
                }
            }
        }
    }

    // MARK: - Control bar

    @MainActor
    private func showBar() {
        let g: NSRect = {
            let s = selection.screen.frame
            let r = selection.rectInScreenPoints
            return NSRect(x: s.minX + r.minX, y: s.minY + s.height - r.maxY,
                          width: r.width, height: r.height)
        }()

        let auto = NSButton(title: "  Auto-Scroll", target: self, action: #selector(autoTapped))
        auto.bezelStyle = .texturedRounded
        auto.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        auto.imagePosition = .imageLeft
        auto.contentTintColor = .controlAccentColor
        auto.keyEquivalent = "\r"
        auto.toolTip = "SnapDesk scrolls the area for you and stitches automatically (↵)"
        autoButton = auto
        let label = NSTextField(labelWithString: "or scroll it yourself")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.75)
        let count = NSTextField(labelWithString: "1")
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        count.textColor = NSColor.systemGreen
        count.toolTip = "Captured frames"
        countLabel = count
        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .texturedRounded
        done.toolTip = "Stitch what's captured"
        let cancel = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel")
                                ?? NSImage(), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .texturedRounded
        cancel.toolTip = "Cancel (Esc)"

        let stack = NSStackView(views: [auto, label, count, done, cancel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 10)

        let fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true; fx.layer?.cornerRadius = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        let size = stack.fittingSize
        var origin = NSPoint(x: g.midX - size.width / 2, y: g.minY - size.height - 12)
        let vis = selection.screen.visibleFrame
        if origin.y < vis.minY { origin.y = g.maxY + 12 }
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)

        let win = NSWindow(contentRect: NSRect(origin: origin, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear
        win.level = .statusBar; win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        fx.frame = NSRect(origin: .zero, size: size)
        win.contentView = fx
        win.orderFront(nil)
        barWindow = win
    }

    @objc private func doneTapped() { finish(save: true) }
    @objc private func cancelTapped() { finish(save: false) }
}
