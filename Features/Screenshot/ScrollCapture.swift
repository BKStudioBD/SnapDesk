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
    private var stageLabel: NSTextField?
    private var autoButton: NSButton?
    private var autoRunning = false
    private var autoTask: Task<Void, Never>?
    /// Bumped on each Full Page start; a task's teardown only resets shared state
    /// if it's still the current generation.
    private var autoGen = 0
    private var capturing = false
    /// While the auto engine runs it OWNS capture: the passive timer/scroll-wheel
    /// ticks are ignored. They used to race the engine's own grabs — a dropped
    /// tick reads as "no new content", which is exactly how a long page got cut
    /// short before it reached the bottom.
    private var autoMode = false
    private var bytesStored = 0
    private var lastGrab = Date.distantPast
    private var limitNotified = false
    /// Vision offsets computed DURING capture so Done stitches instantly instead
    /// of running 100+ registrations at the end. `visionOffsets[i]` = scroll px
    /// between frame i and i+1; the slot is appended (nil) on the main actor the
    /// moment its frame lands, so the array can never desync from `frames` —
    /// a not-yet-computed slot just falls back to the signature search.
    private var visionOffsets: [Int?] = []
    private let alignQueue = DispatchQueue(label: "snapdesk.scroll.align", qos: .userInitiated)
    /// Bumped whenever the frame list is reset (Full Page rewinds and starts
    /// over) and when the session ends, so alignment for frames nobody will read
    /// is abandoned. Read from `alignQueue` as well as the main actor, so unlike
    /// the rest of the state here it carries its own lock.
    private let genLock = NSLock()
    private var _generation = 0
    private var generation: Int {
        get { genLock.lock(); defer { genLock.unlock() }; return _generation }
        set { genLock.lock(); defer { genLock.unlock() }; _generation = newValue }
    }

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
                      "Press Full Page for the whole page — or scroll yourself, then Done.")
        // Steady cadence + an immediate grab on every scroll tick — the capture
        // keeps up with the user instead of lagging 1/3 s behind (smoothness).
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            self?.tick()
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.tick()
        }
        // Esc cancels — a global monitor so it works while the user is scrolling
        // the OTHER app. Return is deliberately NOT global: the user is typing in
        // that other app, and hijacking its Return (submitting forms, inserting
        // newlines) is worse than the convenience. Full Page starts/pauses from
        // the control-bar button (a mouse click, which a borderless window still
        // receives) or from Return while SnapDesk itself is active (local, below).
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.finish(save: false) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.finish(save: false); return nil }
            if e.keyCode == 36 { self.autoTapped(); return nil }
            return e
        }
        tick()   // grab the first frame right away
    }

    /// What one capture attempt produced. The auto engine steers on this instead
    /// of on `frames.count`, which is an indirect signal that also moves when a
    /// tick is throttled or dropped.
    private enum Grab {
        case stored          // new content captured
        case unchanged       // the area looks identical → nothing scrolled
        case failed          // capture error
        case limit           // memory/frame cap reached
    }

    /// Passive path: the 0.18 s timer and every scroll-wheel event. Fire and
    /// forget — while the auto engine is running it owns capture and these are
    /// ignored, so the two can't race for the same frame.
    private func tick() {
        guard !autoMode else { return }
        guard !capturing else { return }
        capturing = true
        Task { @MainActor in
            defer { capturing = false }
            _ = await captureFrame(minChange: 1.5)
        }
    }

    /// Capture the area once and store it if the content actually changed.
    /// Awaitable on purpose: the auto engine needs to know the OUTCOME of this
    /// exact grab before deciding to scroll again or call it the bottom.
    ///
    /// - Parameter minChange: signature distance below which the frame counts as
    ///   "same content". Lower while auto-scrolling — we know we just scrolled,
    ///   so a small but real change must not be mistaken for a still page.
    @MainActor
    @discardableResult
    private func captureFrame(minChange: Float) async -> Grab {
        // Cap by real memory use (~400 MB of frames), not a blind frame count.
        if frames.count >= 240 || bytesStored >= 400_000_000 {
            if !limitNotified {
                limitNotified = true
                Notifier.info("Capture limit reached", "Press Done to stitch what you have.")
            }
            return .limit
        }
        guard let full = try? await CaptureService.captureScreen(selection.screen) else { return .failed }
        let k = selection.screen.backingScaleFactor
        let r = selection.rectInScreenPoints
        let px = CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
            .integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !px.isEmpty, let shared = full.cropping(to: px) else { return .failed }
        // Signature + dedup on the CHEAP shared crop first — only frames we
        // actually keep pay for the full-buffer deepCopy (idle ticks on a paused
        // page were allocating + discarding a full crop each).
        // Both are full-resolution pixel passes — a downsample, then a redraw of
        // a buffer that is ~65 MB on a large Retina selection — and they run on
        // every timer tick and every scroll event, up to 8 Hz. On the main thread
        // that stutters every window on the Mac. Order is unaffected: only one
        // capture is ever in flight (the `capturing` latch; the auto engine awaits
        // each grab), so the frame list is still appended in capture order.
        let sig = await BackgroundWork.run { ScrollStitcher.rowSignature(shared) }
        if let last = signatures.last, ScrollStitcher.meanDiff(last, sig) < minChange { return .unchanged }
        guard let crop = await BackgroundWork.run({ Self.deepCopy(shared) }) else { return .failed }
        let prev = frames.last
        frames.append(crop)
        signatures.append(sig)
        bytesStored += crop.bytesPerRow * crop.height
        lastGrab = Date()
        countLabel?.stringValue = "\(frames.count)"

        // Pre-align this pair off-main. The slot is reserved NOW, in order, on
        // the main actor — the Vision result is written back into that exact
        // index later, so `visionOffsets` stays index-aligned with `frames` no
        // matter how the async work interleaves.
        if let prev {
            let slot = frames.count - 2
            visionOffsets.append(nil)
            let gen = generation
            alignQueue.async { [weak self] in
                // A registration pass costs real CPU and pins BOTH frames until
                // it returns. If the session ended or the run was discarded while
                // this waited its turn, nobody will read the answer — bail here so
                // the frames are released with it instead of after.
                guard let self, self.generation == gen else { return }
                let off = Self.visionScroll(prev, crop)
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen, slot < self.visionOffsets.count else { return }
                    self.visionOffsets[slot] = off
                }
            }
        }
        return .stored
    }

    private func finish(save: Bool) {
        guard Self.current === self else { return }   // ignore double/stale finish
        // Whatever is still queued on the align queue is now working for nobody,
        // and holding the two frames it was handed while it does. The offsets
        // snapshot below is taken without suspending, so a result that lands
        // after this point could never have been used anyway.
        generation += 1
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
        // Offsets are main-actor state, so this snapshot is race-free — no
        // blocking wait on the align queue. A pair whose Vision result hasn't
        // landed yet is simply nil and falls back to the signature search.
        let offs = visionOffsets
        DispatchQueue.global(qos: .userInitiated).async {
            guard let stitched = ScrollStitcher.stitch(frames: frames, signatures: sigs, offsets: offs,
                                                  visionOffset: { Self.visionScroll($0, $1) }) else {
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
        // The sound is the one thing cheap enough to fire NOW. Handing an NSImage
        // to the pasteboard serialises an UNCOMPRESSED TIFF synchronously, and the
        // PNG for the file is another full-image encode — on a stitch that can be
        // tens of thousands of rows tall, both froze the UI for seconds at the
        // exact moment the app said it was finished. Encode off the main thread
        // and hand the pasteboard finished bytes; the "copied" toast waits for the
        // real write, so it is never announced before it is true. Back-to-back on
        // one queue rather than two: only one encode's pixels are alive at a time.
        if settings?.playSound == true { Sounds.playIn() }
        DispatchQueue.global(qos: .userInitiated).async {
            let ns = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale,
                                                       height: CGFloat(cg.height) / scale))
            let tiff = ns.tiffRepresentation
            DispatchQueue.main.async {
                // `clearContents()` has already run by the time a write can fail,
                // so an unchecked failure leaves the clipboard EMPTY under a toast
                // that claims a copy — say what actually happened instead.
                var copied = false
                if let tiff {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setData(tiff, forType: .tiff)
                }
                Notifier.info("Scrolling capture ready",
                              copied ? "Copied to clipboard" : "Saving it to a file")
            }
            // Both of these used to fail in SILENCE, straight after a toast that
            // said the shot was being saved to a file — and the clipboard write
            // above may have failed too, so that could be the only copy. A stitch
            // is minutes of scrolling nobody can repeat from memory, so a lost one
            // has to say it is lost.
            guard let data = AnnotationRenderer.encode(cg, format: .png, quality: 1) else {
                DispatchQueue.main.async {
                    Notifier.error("Scrolling capture not saved",
                                   "Couldn't encode the stitched image.")
                }
                return
            }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    Notifier.error("Scrolling capture not saved", error.localizedDescription)
                }
                return
            }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)   // show the result
                Notifier.info("Scrolling capture saved", url.lastPathComponent)
            }
        }
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
            autoButton?.title = "  Full Page"
            autoButton?.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            return
        }
        autoRunning = true
        autoMode = true                 // the engine owns capture from here
        autoButton?.title = "  Pause"
        autoButton?.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
        let pt = scrollPointCG
        focusPointer(at: pt)
        let stepPx = Int32(max(120, globalRect.height * 0.55))
        autoGen &+= 1
        let myGen = autoGen
        autoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Owner-checked: a cancelled run's `defer` must not clear autoMode
            // out from under a NEWER run the user just started. Only the current
            // generation may reset it.
            defer { if self.autoGen == myGen { self.autoMode = false } }
            // "Full Page": rewind to the very TOP first, then capture straight
            // down to the bottom — so one press grabs the WHOLE page regardless
            // of where the user was scrolled to. Manual scrolling stays partial.
            Self.log("=== Full Page pressed · area \(Int(self.globalRect.width))×\(Int(self.globalRect.height))pt · scrollPoint \(pt) · step \(stepPx)px")
            self.stage("Rewinding to top…")
            let moved = await self.scrollToTop(pt)
            // NOT a failure signal: a page that's already at the top can't move
            // during the rewind, which is the most common way Full Page is used.
            // Whether scrolling works at all is decided by the descent below.
            Self.log("rewind done: contentMoved=\(moved)")
            guard self.autoRunning, !Task.isCancelled else { return }
            self.resetCapture()                        // discard the rewind's frames
            self.stage("Capturing…")
            await self.captureFrame(minChange: 0)      // first frame = top of the page

            // Bottom detection is driven by the OUTCOME of each grab, not by a
            // frame count: `.unchanged` means the area genuinely looks identical
            // after a full scroll burst. Two of those in a row = bottom. (A frame
            // count also moves when a tick is throttled, which used to end the
            // run early and lose the rest of the page.)
            var still = 0
            // A descent has to be able to END on its own. `.failed` resets the
            // bottom counter, so a screen that can no longer be captured — a
            // stale `selection.screen` after a display slept or was unplugged
            // throws every single time — left this looping forever, posting
            // scroll wheel events into whatever app is under the pointer twice a
            // second. A consecutive-failure cap and a wall clock (as `scrollToTop`
            // already has) end the session with a message instead.
            var fails = 0
            let deadline = Date().addingTimeInterval(300)
            while self.autoRunning, !Task.isCancelled, ScrollCapture.isActive {
                guard Date() < deadline else {
                    self.stage("Stopped — took too long")
                    Notifier.info("Full Page stopped",
                                  "Five minutes is the limit — stitching what's captured.")
                    self.finish(save: true)
                    return
                }
                // Smooth sub-steps — one big jump breaks lazy-loading pages.
                for _ in 0..<3 where self.autoRunning {
                    Self.postScroll(-(stepPx / 3), at: pt)
                    try? await Task.sleep(nanoseconds: 140_000_000)
                }
                try? await Task.sleep(nanoseconds: 380_000_000)   // let content (incl. lazy loads) settle
                guard self.autoRunning, !Task.isCancelled else { return }
                let outcome = await self.captureFrame(minChange: 0.4)
                Self.log("round: outcome=\(outcome) frames=\(self.frames.count) still=\(still)")
                switch outcome {
                case .stored:
                    still = 0
                    fails = 0
                case .unchanged:
                    still += 1
                    // Give a slow lazy-load one extra beat before believing it.
                    if still == 1 { try? await Task.sleep(nanoseconds: 500_000_000) }
                    if still >= 2 {
                        self.stage("Bottom reached")
                        self.finish(save: true)
                        return
                    }
                case .failed:
                    still = 0
                    fails += 1
                    if fails >= 5 {
                        self.stage("Can't read the screen")
                        Notifier.error("Full Page stopped",
                                       "Couldn't capture the screen — keeping the frames it got.")
                        self.finish(save: true)
                        return
                    }
                case .limit:
                    self.finish(save: true)
                    return
                }
            }
        }
    }

    /// Put the pointer over the content AND make the window server notice.
    /// `CGWarpMouseCursorPosition` moves the cursor without generating a move
    /// event, so the "window under the pointer" that scroll events are routed to
    /// can stay stale — the wheel events then land on whatever was hovered
    /// before, and nothing scrolls at all.
    private func focusPointer(at pt: CGPoint) {
        CGWarpMouseCursorPosition(pt)
        if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: pt, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
    }

    /// Post one pixel scroll event at `pt`. Positive = up, negative = down.
    private static func postScroll(_ dy: Int32, at pt: CGPoint) {
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                           wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) {
            e.location = pt
            e.post(tap: .cghidEventTap)
        }
    }

    /// Rewind the content to its TOP with big upward scrolls, until the area
    /// stops changing. Nothing is stored. Returns whether the content EVER moved
    /// — false means our scroll events aren't reaching it, which the caller
    /// reports instead of capturing a bogus single-screen "full page".
    @MainActor
    private func scrollToTop(_ pt: CGPoint) async -> Bool {
        let up = Int32(max(400, globalRect.height * 1.5))
        var prev: [Float]? = nil
        var still = 0
        var everMoved = false
        let deadline = Date().addingTimeInterval(12)
        while autoRunning, !Task.isCancelled, Date() < deadline {
            Self.postScroll(up, at: pt)
            try? await Task.sleep(nanoseconds: 130_000_000)
            guard let sig = await areaSignatureNow() else { continue }
            if let p = prev {
                if ScrollStitcher.meanDiff(p, sig) < 0.6 {
                    still += 1
                    // THREE consecutive still reads, not two: a page can look
                    // unchanged for one step across a band of whitespace, and
                    // stopping there starts the capture in the middle of the page.
                    if still >= 3 { break }
                } else {
                    still = 0
                    everMoved = true
                }
            }
            prev = sig
        }
        return everMoved
    }

    /// One-line status in the control bar. The rewind takes seconds and used to
    /// look like nothing was happening at all.
    @MainActor
    private func stage(_ text: String) {
        stageLabel?.stringValue = text
        Self.log("stage: \(text)")
    }

    /// Temporary diagnostic trail for the auto engine. `log show` returns nothing
    /// for this app, so a plain file is the only thing readable after a run that
    /// went wrong. Written under the user's own ~/Library/Logs/SnapDesk (0600,
    /// not world-readable /tmp), and capped so it can't grow unbounded.
    static func log(_ message: String) {
        let dir = MissLog.directory   // ~/Library/Logs/SnapDesk, created 0700
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("scroll.log")
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            // Cap at ~1 MB: truncate and restart rather than grow forever.
            if h.seekToEndOfFile() > 1_048_576 { try? h.truncate(atOffset: 0); h.seek(toFileOffset: 0) }
            h.write(data); try? h.close()
        } else if (try? data.write(to: url, options: .atomic)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// A cheap row-signature of the area right now (no dedup, no store) — used
    /// to detect when scroll-to-top has bottomed out at the top.
    @MainActor
    private func areaSignatureNow() async -> [Float]? {
        guard let full = try? await CaptureService.captureScreen(selection.screen) else { return nil }
        let k = selection.screen.backingScaleFactor
        let r = selection.rectInScreenPoints
        let px = CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
            .integral.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
        guard !px.isEmpty, let crop = full.cropping(to: px) else { return nil }
        // A full-resolution downsample, run every ~130 ms for as long as the
        // rewind lasts. On the main actor that stutters every window on the Mac,
        // exactly as it did on the capture path before the same hop was added
        // there. Nothing about frame ORDER moves with it: the rewind stores no
        // frames at all, and its caller already awaits this one answer at a time.
        return await BackgroundWork.run { ScrollStitcher.rowSignature(crop) }
    }

    /// Discard everything captured so far and start fresh (used after rewinding
    /// to the top). Bumping the generation makes any alignment still running for
    /// the discarded frames drop its result instead of writing it into the new
    /// run's offsets — that mismatch used to garble the seam it landed on.
    @MainActor
    private func resetCapture() {
        generation += 1
        frames.removeAll(); signatures.removeAll(); visionOffsets.removeAll()
        bytesStored = 0; lastGrab = .distantPast; limitNotified = false
        countLabel?.stringValue = "0"
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

        let auto = NSButton(title: "  Full Page", target: self, action: #selector(autoTapped))
        auto.bezelStyle = .texturedRounded
        auto.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        auto.imagePosition = .imageLeft
        auto.contentTintColor = .controlAccentColor
        auto.keyEquivalent = "\r"
        auto.toolTip = "Jump to the top and capture the whole page automatically (↵)"
        autoButton = auto
        // Live stage text: "or scroll it yourself" → "Rewinding to top…" →
        // "Capturing…" → "Bottom reached". A multi-second rewind with no feedback
        // reads as a dead button.
        let label = NSTextField(labelWithString: "or scroll it yourself")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.75)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stageLabel = label
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
