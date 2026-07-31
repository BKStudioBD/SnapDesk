import AppKit

/// Pre-record options bar. Appears right after the user picks
/// the recording area: quick toggles (system audio · mic · camera · captions ·
/// blur) + a big Record button, no trip to Settings needed. Toggles write
/// straight to SettingsStore, so they persist. Return records, Esc cancels.
final class PreRecordPanel: NSObject {
    private static var current: PreRecordPanel?

    private let selection: RegionSelection
    private let settings: SettingsStore
    private var completion: ((Bool, [CGRect]) -> Void)?
    /// Blur boxes the user dragged (screen-local top-left coords).
    private var blurRects: [CGRect] = []
    private var blurOverlay: NSWindow?
    private let onGear: () -> Void
    private var window: KeyPanel?
    private var borderWindow: NSWindow?
    private var toggles: [(NSButton, () -> Bool)] = []
    /// Live input level, so "is the mic actually hearing me" is answered here
    /// instead of after the recording is uploaded.
    private var meter: AudioLevelMeterView?
    private let micMonitor = MicLevelMonitor()

    @MainActor
    static func present(selection: RegionSelection, settings: SettingsStore,
                        onGear: @escaping () -> Void,
                        completion: @escaping (Bool, [CGRect]) -> Void) {
        current?.finish(false)
        let p = PreRecordPanel(selection: selection, settings: settings, onGear: onGear)
        p.completion = completion
        current = p
        p.show()
    }

    private init(selection: RegionSelection, settings: SettingsStore, onGear: @escaping () -> Void) {
        self.selection = selection
        self.settings = settings
        self.onGear = onGear
        super.init()
    }

    // MARK: - UI

    @MainActor
    private func show() {
        showBorder()

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)

        addToggle(to: stack, symbol: "speaker.wave.2.fill", help: "System audio",
                  get: { [weak self] in self?.settings.recordSystemAudio ?? false },
                  set: { [weak self] in self?.settings.recordSystemAudio = $0 })
        addToggle(to: stack, symbol: "mic.fill", help: "Microphone",
                  get: { [weak self] in self?.settings.recordMic ?? false },
                  set: { [weak self] on in
                      guard let self else { return }
                      self.settings.recordMic = on
                      self.refreshMicMonitor()
                  })
        addToggle(to: stack, symbol: "waveform.badge.magnifyingglass",
                  help: "Noise cancellation on your voice",
                  get: { [weak self] in self?.settings.recordNoiseCancellation ?? false },
                  set: { [weak self] on in
                      guard let self else { return }
                      self.settings.recordNoiseCancellation = on
                      // Re-open the mic through the other backend, so the meter
                      // keeps showing what will actually be recorded.
                      self.refreshMicMonitor()
                  })

        // Always in the stack, even with the mic off: the panel window is sized
        // once from `fittingSize`, so a view that came and went would leave a hole
        // or push the Record button off the end.
        let meterView = AudioLevelMeterView(frame: NSRect(x: 0, y: 0, width: 56, height: 14))
        meterView.widthAnchor.constraint(equalToConstant: 56).isActive = true
        meterView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        meterView.toolTip = "Microphone input level"
        stack.addArrangedSubview(meterView)
        meter = meterView
        micMonitor.onLevel = { [weak self] level in self?.meter?.update(level) }
        addToggle(to: stack, symbol: "web.camera.fill", help: "Webcam bubble",
                  get: { [weak self] in self?.settings.recordCamera ?? false },
                  set: { [weak self] in self?.settings.recordCamera = $0 })
        addToggle(to: stack, symbol: "captions.bubble.fill", help: "Auto captions",
                  get: { [weak self] in self?.settings.recordSubtitles ?? false },
                  set: { [weak self] in self?.settings.recordSubtitles = $0 })
        addToggle(to: stack, symbol: "circle.grid.3x3.fill",
                  help: "Hide passwords or private info (pixelated in the video)",
                  get: { [weak self] in self?.settings.recordBlurEnabled ?? false },
                  set: { [weak self] on in
                      guard let self else { return }
                      self.settings.recordBlurEnabled = on
                      if on {
                          self.showBlurOverlay()
                          self.addStarterBoxIfNeeded()
                      } else {
                          self.blurRects = []
                          self.hideBlurOverlay()
                      }
                  })

        stack.addArrangedSubview(separator())

        let gear = NSButton(image: Self.symbol("gearshape.fill"), target: self, action: #selector(gearTapped))
        gear.isBordered = false; gear.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        gear.toolTip = "All recording settings"
        gear.setAccessibilityLabel("Recording settings")
        stack.addArrangedSubview(gear)

        let record = NSButton(title: "  Record", target: self, action: #selector(recordTapped))
        record.bezelStyle = .texturedRounded
        record.image = Self.symbol("record.circle.fill", size: 14)
        record.imagePosition = .imageLeft
        record.contentTintColor = .systemRed
        record.keyEquivalent = "\r"
        record.toolTip = "Start recording (↵)"
        stack.addArrangedSubview(record)

        let cancel = NSButton(image: Self.symbol("xmark"), target: self, action: #selector(cancelTapped))
        cancel.isBordered = false; cancel.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        cancel.toolTip = "Cancel (Esc)"
        cancel.setAccessibilityLabel("Cancel")
        stack.addArrangedSubview(cancel)

        let fx = NSVisualEffectView()
        fx.material = .hudWindow; fx.blendingMode = .behindWindow; fx.state = .active
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 13; fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1
        fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        let size = stack.fittingSize

        let g = globalRect
        var origin = NSPoint(x: g.midX - size.width / 2, y: g.minY - size.height - 12)
        let vis = selection.screen.visibleFrame
        if origin.y < vis.minY { origin.y = g.maxY + 12 }
        // Full-screen selection: no room below OR above, so float inside near the bottom.
        if origin.y + size.height > vis.maxY { origin.y = vis.minY + 24 }
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)

        let win = KeyPanel(contentRect: NSRect(origin: origin, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear
        win.level = .statusBar; win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.onEsc = { [weak self] in self?.finish(false) }
        fx.frame = NSRect(origin: .zero, size: size)
        win.contentView = fx
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        if settings.recordBlurEnabled { showBlurOverlay() }
        refreshMicMonitor()
    }

    /// Open (or re-open, or close) the level monitor to match the toggles.
    ///
    /// This DOES light the system microphone indicator while the panel is up,
    /// which is the honest thing: the meter is only shown when the user has
    /// already switched the mic on for this recording. It never triggers a
    /// permission prompt; the recording flow owns that request, and an
    /// unauthorized mic simply leaves the meter dark.
    private func refreshMicMonitor() {
        micMonitor.stop()
        guard settings.recordMic else {
            meter?.isActive = false
            return
        }
        // Optimistic: `start` returns BEFORE the device is open, because opening it
        // (an AVCaptureDevice discovery pass, VPIO init and a CoreAudio walk that
        // queries every device's UID one at a time) runs 100–500 ms and blocking the
        // main thread on it made this panel appear late and freeze on every mic /
        // noise-cancellation click with the button stuck in its old state. Light the
        // meter now and take it back only if the open actually failed.
        meter?.isActive = true
        micMonitor.start(deviceID: settings.micDeviceID,
                         noiseCancellation: settings.recordNoiseCancellation) { [weak self] opened in
            guard opened == false else { return }
            self?.meter?.isActive = false
        }
    }

    // MARK: - Blur drag overlay (screenshot-editor style)

    /// Transparent layer over the chosen area: drag to add blur boxes,
    /// double-click a box to remove it. Boxes burn into the video.
    @MainActor
    private func showBlurOverlay() {
        guard blurOverlay == nil else { return }
        let g = globalRect
        let win = NSWindow(contentRect: g, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear
        win.level = .statusBar; win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = BlurSelectView(frame: NSRect(origin: .zero, size: g.size))
        v.existing = { [weak self] in self?.localBlurRects() ?? [] }
        v.onAdd = { [weak self] localRect in self?.addBlur(localRect) }
        v.onRemove = { [weak self] i in self?.removeBlur(at: i) }
        v.onMove = { [weak self] i, localRect in self?.moveBlur(at: i, to: localRect) }
        win.contentView = v
        // Freeze the area once → boxes preview with the REAL pixelation the
        // video will get, not an abstract grey grid.
        Task { @MainActor [weak self, weak v] in
            guard let self else { return }
            if let cg = try? await CaptureService.capture(self.selection) {
                v?.frozen = cg
                v?.needsDisplay = true
            }
        }
        // Below the options panel: on a full-screen selection the panel sits
        // INSIDE the overlay's area and its clicks must win.
        if let panel = window {
            win.order(.below, relativeTo: panel.windowNumber)
        } else {
            win.orderFront(nil)
        }
        blurOverlay = win
    }

    /// Blur just turned on → drop one ready-made box in the middle of the
    /// area. The user immediately SEES the pixelation and only has to drag it
    /// onto whatever needs hiding: nothing to figure out.
    private func addStarterBoxIfNeeded() {
        guard blurRects.isEmpty else { return }
        let a = selection.rectInScreenPoints
        let w = min(280, a.width * 0.45), h = min(150, a.height * 0.3)
        addBlur(CGRect(x: (a.width - w) / 2, y: (a.height - h) / 2, width: w, height: h))
    }

    private func hideBlurOverlay() {
        blurOverlay?.orderOut(nil); blurOverlay = nil
    }

    /// Screen-local top-left blur rects → overlay-local (bottom-left) rects.
    private func localBlurRects() -> [CGRect] {
        let s = selection.rectInScreenPoints
        return blurRects.map { b in
            CGRect(x: b.minX - s.minX, y: s.maxY - b.maxY, width: b.width, height: b.height)
        }
    }

    private func addBlur(_ local: CGRect) {
        let s = selection.rectInScreenPoints
        // Overlay-local (bottom-left) → screen-local top-left space.
        let r = CGRect(x: s.minX + local.minX, y: s.minY + (s.height - local.maxY),
                       width: local.width, height: local.height)
        blurRects.append(r)
        blurOverlay?.contentView?.needsDisplay = true
    }

    private func removeBlur(at i: Int) {
        guard blurRects.indices.contains(i) else { return }
        blurRects.remove(at: i)
        blurOverlay?.contentView?.needsDisplay = true
    }

    private func moveBlur(at i: Int, to local: CGRect) {
        guard blurRects.indices.contains(i) else { return }
        let s = selection.rectInScreenPoints
        blurRects[i] = CGRect(x: s.minX + local.minX, y: s.minY + (s.height - local.maxY),
                              width: local.width, height: local.height)
        blurOverlay?.contentView?.needsDisplay = true
    }

    /// Spotlight while the user picks options: only the chosen area stays
    /// live/bright, the rest of the screen dims (premium tint).
    @MainActor
    private func showBorder() {
        let win = SpotlightOverlay.window(around: globalRect,
                                          on: selection.screen, border: .controlAccentColor)
        win.orderFront(nil)
        borderWindow = win
    }

    private var globalRect: NSRect {
        let s = selection.screen.frame
        let r = selection.rectInScreenPoints
        return NSRect(x: s.minX + r.minX, y: s.minY + s.height - r.maxY,
                      width: r.width, height: r.height)
    }

    // MARK: - Toggles

    private func addToggle(to stack: NSStackView, symbol: String, help: String,
                           get: @escaping () -> Bool, set: @escaping (Bool) -> Void) {
        let b = NSButton(image: Self.symbol(symbol), target: self, action: #selector(toggleTapped(_:)))
        b.isBordered = false
        b.setButtonType(.momentaryChange)
        b.toolTip = help
        // Icon-only button: give VoiceOver the same words the tooltip shows.
        b.setAccessibilityLabel(help)
        b.tag = toggles.count
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        toggles.append((b, get))
        toggleActions.append(set)
        style(b, on: get())
        stack.addArrangedSubview(b)
    }

    private var toggleActions: [(Bool) -> Void] = []

    private func separator() -> NSView {
        let v = NSBox(); v.boxType = .separator
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    @objc private func toggleTapped(_ sender: NSButton) {
        let i = sender.tag
        guard i < toggles.count else { return }
        let newValue = !toggles[i].1()
        toggleActions[i](newValue)
        style(sender, on: newValue)
    }

    private func style(_ b: NSButton, on: Bool) {
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.layer?.backgroundColor = on ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        b.contentTintColor = on ? .white : NSColor.white.withAlphaComponent(0.55)
    }

    // MARK: - Actions

    @objc private func recordTapped() { finish(true) }
    @objc private func cancelTapped() { finish(false) }
    @objc private func gearTapped() { onGear() }

    private func finish(_ proceed: Bool) {
        // Release the microphone before anything else, leaving it open would keep
        // the system indicator lit AND hand the recording a device already in use.
        micMonitor.stop()
        micMonitor.onLevel = nil
        meter = nil
        window?.orderOut(nil); window = nil
        borderWindow?.orderOut(nil); borderWindow = nil
        hideBlurOverlay()
        Self.current = nil
        let c = completion; completion = nil
        c?(proceed, proceed ? blurRects : [])
    }

    // MARK: - Helpers

    private static func symbol(_ name: String, size: CGFloat = 14) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: size, height: size))
        return img.withSymbolConfiguration(cfg) ?? img
    }

    private final class KeyPanel: NSWindow {
        var onEsc: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEsc?() } else { super.keyDown(with: event) }
        }
    }

}

/// Drag-to-mark privacy-blur boxes over the recording area. Boxes preview with
/// the REAL pixelation the video will get (frozen screenshot of the area),
/// can be dragged to reposition, and double-click removes one.
private final class BlurSelectView: NSView {
    var existing: () -> [CGRect] = { [] }
    var onAdd: ((CGRect) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onMove: ((Int, CGRect) -> Void)?
    /// Frozen capture of the area: powers the live-look pixelation preview.
    var frozen: CGImage?

    private var dragStart: CGPoint?
    private var current: CGRect = .zero
    private var movingIndex: Int?
    private var moveGrab: CGPoint = .zero      // grab offset inside the box
    private var movingRect: CGRect = .zero
    private var selected: Int?
    /// Corner being resized (anchor = opposite corner), else nil.
    private var resizeAnchor: CGPoint?
    private var resizeIndex: Int?

    /// CRITICAL: without this the FIRST click only activates the window and the
    /// drag never reaches the view: blur boxes seemed "not to work".
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        for r in existing() { addCursorRect(r, cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, r) in existing().enumerated() {
            let active = movingIndex == i || resizeIndex == i
            drawBox(active ? movingRect : r, selected: selected == i || active)
        }
        if current.width > 1 { drawBox(current, selected: true) }
        drawHint()
    }

    /// Cached pixelation per box rect. `drawBox` runs for EVERY box on every
    /// mouse-moved event during a drag, and each uncached call is a CoreImage
    /// pixelate plus a GPU→CPU readback. So dragging one box re-rendered all of
    /// them, every frame. Keyed by the rect, so only the box actually changing
    /// re-renders.
    ///
    /// Keyed by an explicit struct, NOT by CGRect: `CGRect: Hashable` only exists
    /// on macOS 15+, and this app targets 14.
    private struct RectKey: Hashable {
        let x: Int, y: Int, w: Int, h: Int
        init(_ r: CGRect) {
            x = Int(r.origin.x.rounded()); y = Int(r.origin.y.rounded())
            w = Int(r.width.rounded());    h = Int(r.height.rounded())
        }
    }
    private var pixelCache: [RectKey: NSImage] = [:]

    /// Real pixelation preview (falls back to a soft grey fill until the
    /// frozen capture arrives).
    private func drawBox(_ r: CGRect, selected: Bool) {
        if let frozen {
            let key = RectKey(r)
            let cached = pixelCache[key]
                ?? AnnotationRenderer.pixelate(frozen, rectInPoints: r, viewSize: bounds.size)
            if let cached {
                if pixelCache[key] == nil {
                    // Bound the cache: a long drag would otherwise keep an image
                    // for every intermediate rect it passed through.
                    if pixelCache.count > 24 { pixelCache.removeAll() }
                    pixelCache[key] = cached
                }
                cached.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            } else {
                NSColor(white: 0.5, alpha: 0.55).setFill()
                NSBezierPath(rect: r).fill()
            }
        } else {
            NSColor(white: 0.5, alpha: 0.55).setFill()
            NSBezierPath(rect: r).fill()
        }
        (selected ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.9)).setStroke()
        let b = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        b.lineWidth = selected ? 2 : 1.25
        b.stroke()
        // Corner handles: visible grab points teach that boxes are editable.
        NSColor.white.setFill()
        NSColor.controlAccentColor.setStroke()
        for c in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let h = NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
            h.fill(); h.lineWidth = 1; h.stroke()
        }
    }

    private func drawHint() {
        let n = existing().count
        let hint = n == 0
            ? "Click on anything you want to hide"
            : "Move the box onto the secret  ·  click elsewhere = another box  ·  double-click removes"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white]
        let sz = hint.size(withAttributes: attrs)
        let bg = NSRect(x: bounds.midX - sz.width / 2 - 10, y: bounds.maxY - sz.height - 22,
                        width: sz.width + 20, height: sz.height + 10)
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        hint.draw(at: NSPoint(x: bg.minX + 10, y: bg.minY + 5), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let rects = existing()
        if event.clickCount == 2 {
            // Remove the box under the double-click: hit-test the box OR its
            // corner grab zone (double-clicking a corner should delete too).
            let i = rects.lastIndex(where: { $0.contains(p) })
                ?? rects.lastIndex(where: { r in
                    [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                     CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
                        .contains { abs($0.x - p.x) < 9 && abs($0.y - p.y) < 9 } })
            if let i {
                selected = nil
                onRemove?(i)
                window?.invalidateCursorRects(for: self)
            }
            return
        }
        // Corner of a box → resize it (anchor = opposite corner).
        for (i, r) in rects.enumerated().reversed() {
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
            if let c = corners.first(where: { abs($0.x - p.x) < 9 && abs($0.y - p.y) < 9 }) {
                resizeIndex = i
                resizeAnchor = CGPoint(x: c.x == r.minX ? r.maxX : r.minX,
                                       y: c.y == r.minY ? r.maxY : r.minY)
                movingRect = r
                selected = i
                needsDisplay = true
                return
            }
        }
        // Grab an existing box → move it.
        if let i = rects.lastIndex(where: { $0.contains(p) }) {
            movingIndex = i
            movingRect = rects[i]
            moveGrab = CGPoint(x: p.x - rects[i].minX, y: p.y - rects[i].minY)
            selected = i
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        selected = nil
        dragStart = p
        current = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if resizeIndex != nil, let a = resizeAnchor {
            movingRect = CGRect(x: min(a.x, p.x), y: min(a.y, p.y),
                                width: abs(p.x - a.x), height: abs(p.y - a.y))
                .intersection(bounds)
            needsDisplay = true
            return
        }
        if movingIndex != nil {
            var r = movingRect
            r.origin = CGPoint(x: p.x - moveGrab.x, y: p.y - moveGrab.y)
            // Keep the box inside the recorded area.
            r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)
            r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
            movingRect = r
            needsDisplay = true
            return
        }
        guard let s = dragStart else { return }
        current = CGRect(x: min(s.x, p.x), y: min(s.y, p.y),
                         width: abs(p.x - s.x), height: abs(p.y - s.y)).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let i = resizeIndex {
            if movingRect.width > 6, movingRect.height > 6 { onMove?(i, movingRect) }
            resizeIndex = nil
            resizeAnchor = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        if let i = movingIndex {
            onMove?(i, movingRect)
            movingIndex = nil
            NSCursor.openHand.set()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        if current.width > 6, current.height > 6 {
            onAdd?(current)
            selected = existing().count - 1
            window?.invalidateCursorRects(for: self)
        } else if let s = dragStart {
            // Plain CLICK on empty space → drop a ready-made box right there.
            // Easiest possible interaction: point at the secret, click, done.
            let w = min(220, bounds.width * 0.4), h = min(120, bounds.height * 0.3)
            var r = CGRect(x: s.x - w / 2, y: s.y - h / 2, width: w, height: h)
            r.origin.x = min(max(r.origin.x, 0), bounds.width - r.width)
            r.origin.y = min(max(r.origin.y, 0), bounds.height - r.height)
            onAdd?(r)
            selected = existing().count - 1
            window?.invalidateCursorRects(for: self)
        }
        dragStart = nil
        current = .zero
        needsDisplay = true
    }
}
