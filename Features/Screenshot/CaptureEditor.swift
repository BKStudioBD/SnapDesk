import AppKit

/// In-place screenshot annotation editor with a modern "glass" toolbar.
///
/// The screen is frozen up-front, a dimmed overlay shows it, the user drags out a
/// selection (with a live magnifier loupe), then annotates directly on the overlay
/// using a floating glass toolbar docked to the selection. Resize handles adjust
/// the region; Copy / Save / Close finish. All on one overlay — no second window.
/// Text uses an inline field and colors use inline swatches, so nothing ever opens
/// a panel *behind* the full-screen overlay.
enum CaptureEditor {
    private static var session: Session?

    @MainActor
    static func begin(shots: [(NSScreen, CGImage)], windowRects: [CGRect], settings: SettingsStore) {
        guard session == nil else { return }
        session = Session(shots: shots, windowRects: windowRects, settings: settings) { session = nil }
        session?.start()
    }

    // MARK: - Session (owns the overlay windows for every display)

    final class Session {
        private let settings: SettingsStore
        private let onEnd: () -> Void
        private var windows: [NSWindow] = []
        weak var activeView: EditorView?

        init(shots: [(NSScreen, CGImage)], windowRects: [CGRect], settings: SettingsStore, onEnd: @escaping () -> Void) {
            self.settings = settings
            self.onEnd = onEnd
            for (screen, cg) in shots {
                let view = EditorView(frozen: cg, screen: screen, windowRects: windowRects, settings: settings, session: self)
                let win = OverlayWindow(screen: screen)
                win.contentView = view
                windows.append(win)
            }
        }

        func start() {
            windows.forEach { $0.makeKeyAndOrderFront(nil) }
            windows.first?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }

        func claim(_ view: EditorView) {
            guard activeView == nil else { return }
            activeView = view
            windows.forEach { ($0.contentView as? EditorView)?.passiveDismiss(except: view) }
        }

        /// Temporarily hide overlays (so a Save panel appears above them).
        func hideOverlays() { windows.forEach { $0.orderOut(nil) } }
        func showOverlays() { windows.forEach { $0.orderFront(nil) }; NSApp.activate(ignoringOtherApps: true) }

        func finish() {
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()
            activeView = nil
            onEnd()
        }
    }
}

// MARK: - Overlay window

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: true)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Swatch button

private final class SwatchButton: NSButton {
    let swatch: NSColor
    var picked = false { didSet { needsDisplay = true } }
    init(color: NSColor) {
        self.swatch = color
        super.init(frame: .zero)
        isBordered = false; title = ""; setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        swatch.setFill(); p.fill()
        NSColor.white.withAlphaComponent(0.25).setStroke(); p.lineWidth = 0.5; p.stroke()
        if picked {
            NSColor.controlAccentColor.setStroke()
            let q = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            q.lineWidth = 2; q.stroke()
        }
    }
}

// MARK: - Editor view

final class EditorView: NSView, NSTextFieldDelegate {
    private enum Phase { case selecting, editing, passive }
    private enum DragMode { case none, drawing, resizing(Int) }

    private let frozen: NSImage
    private let frozenCG: CGImage
    /// Built lazily (only the active screen's loupe samples it) so multi-monitor
    /// captures don't allocate a full-res bitmap rep per display up-front.
    // (color sampling reads a 1x1 crop of frozenCG on demand — no full-res
    //  NSBitmapImageRep is kept, which would pin ~60 MB for the whole session.)
    private let scale: CGFloat
    private weak var settings: SettingsStore?
    private weak var session: CaptureEditor.Session?

    private var phase: Phase = .selecting
    private var selection: CGRect = .zero
    private var dragStart: CGPoint?
    private var dragMode: DragMode = .none
    private var mouseLoc: CGPoint = .zero
    private var showLoupe = false

    private let windowRects: [CGRect]   // window-snap targets, this screen's local coords
    private var hoverWindow: CGRect?
    private var lastStrokeRect: NSRect = .zero

    private var tool: AnnotationTool = .arrow
    private var color: NSColor = .systemRed
    private var lineWidth: CGFloat = 3
    private var annotations: [AnnotationStroke] = []
    private var redoStack: [AnnotationStroke] = []
    private var current: AnnotationStroke?
    private var stepCounter = 0

    private var toolBar: NSView?
    private var actionBar: NSView?
    private var toolButtons: [NSButton] = []
    private var swatchButtons: [SwatchButton] = []

    private var textField: NSTextField?
    private var pendingTextOrigin: CGPoint = .zero
    private let handleSize: CGFloat = 11
    /// Show a usage hint for the first few captures, then fade out for good.
    private let showHint = UserDefaults.standard.integer(forKey: "editorHintCount") <= 5

    init(frozen cg: CGImage, screen: NSScreen, windowRects globalRects: [CGRect],
         settings: SettingsStore, session: CaptureEditor.Session) {
        self.frozenCG = cg
        self.scale = screen.backingScaleFactor
        self.frozen = NSImage(cgImage: cg, size: screen.frame.size)
        self.settings = settings
        self.session = session
        self.tool = AnnotationTool(rawValue: settings.defaultTool) ?? .arrow
        self.color = NSColor(hex: settings.defaultAnnotationColorHex) ?? .systemRed
        self.lineWidth = CGFloat(settings.defaultLineWidth)

        // Convert global CG (top-left) window rects → this screen's local
        // (bottom-left) coords, keeping only those overlapping this display.
        // CG global coords flip about the PRIMARY display (origin == .zero),
        // which is not necessarily screens.first.
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? screen
        let primaryH = primary.frame.height
        let local = CGRect(origin: .zero, size: screen.frame.size)
        self.windowRects = globalRects.compactMap { cgR in
            let appkitY = primaryH - cgR.minY - cgR.height
            let r = CGRect(x: cgR.minX - screen.frame.minX, y: appkitY - screen.frame.minY,
                           width: cgR.width, height: cgR.height)
            return r.intersects(local) ? r.intersection(local) : nil
        }
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// Read one pixel from a CGImage without unpacking a full-resolution bitmap
    /// rep (that would pin ~60 MB on a 5K capture for the whole editor session).
    private static func pixelColor(_ img: CGImage, x: Int, y: Int) -> NSColor? {
        var px: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                       blue: CGFloat(px[2]) / 255, alpha: 1)
    }
    override var acceptsFirstResponder: Bool { true }
    // First click always lands (starts a drag / snaps a window) even if the
    // overlay isn't the active window yet — no dead "focus" click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    override func resetCursorRects() {
        if phase == .selecting { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    func passiveDismiss(except active: EditorView) {
        if self !== active { phase = .passive; needsDisplay = true }
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        mouseLoc = convert(event.locationInWindow, from: nil)
        // Window-snap outline hint while hovering (before any drag). Full redraw so
        // the dim is always complete — targeted redraws left stale un-dimmed patches.
        guard phase == .selecting, dragStart == nil else { return }
        let newHover = windowAt(mouseLoc)
        if newHover != hoverWindow { hoverWindow = newHover; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) {
        showLoupe = false; hoverWindow = nil; needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseLoc = p
        switch phase {
        case .passive:
            // Another display is mid-annotation → a stray click here must not
            // throw that work away. Only a click with no edits closes.
            if let active = session?.activeView,
               active.annotations.isEmpty == false || active.current != nil { return }
            session?.finish()
        case .selecting:
            session?.claim(self)
            if session?.activeView !== self { phase = .passive; return }
            dragStart = p; selection = .zero; needsDisplay = true
        case .editing:
            commitTextIfEditing()
            if let h = handleAt(p) { dragMode = .resizing(h); dragStart = p }
            else if selection.contains(p) { beginAnnotation(at: p); dragMode = .drawing }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseLoc = p
        switch phase {
        case .selecting:
            guard let s = dragStart else { return }
            hoverWindow = nil; showLoupe = true
            selection = AnnotationRenderer.rect(s, p).intersection(bounds)
            // Full redraw every drag frame → the dim is ALWAYS complete, no stale
            // un-dimmed patches. Single frozen-image blit per frame stays smooth.
            needsDisplay = true
        case .editing:
            switch dragMode {
            case .drawing: updateAnnotation(to: p)
            case .resizing(let h):
                resizeSelection(handle: h, to: p); layoutBars()
                needsDisplay = true
            case .none: break
            }
        case .passive: break
        }
    }


    private func strokeBounds(_ pts: [CGPoint]) -> NSRect {
        guard let f = pts.first else { return .zero }
        var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
        for q in pts { minX = min(minX, q.x); minY = min(minY, q.y); maxX = max(maxX, q.x); maxY = max(maxY, q.y) }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    override func mouseUp(with event: NSEvent) {
        switch phase {
        case .selecting:
            dragStart = nil; showLoupe = false
            if selection.width > 4, selection.height > 4 {
                enterEditing()
            } else if let hw = windowAt(mouseLoc) {   // click / tiny-drag on a window → snap
                selection = hw; enterEditing()
            } else { needsDisplay = true }
        case .editing:
            if case .drawing = dragMode { finishAnnotation() }
            dragMode = .none; needsDisplay = true
        case .passive: break
        }
    }

    private func enterEditing() {
        phase = .editing
        buildBars(); layoutBars()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Smallest on-screen window containing `p` (≈ the topmost one).
    private func windowAt(_ p: CGPoint) -> CGRect? {
        windowRects.filter { $0.contains(p) }.min { $0.width * $0.height < $1.width * $1.height }
    }

    override func keyDown(with event: NSEvent) {
        // Note: while the inline text field is editing it is first responder, so
        // these never fire then — letters type into the field as expected.
        if event.keyCode == 53 { session?.finish(); return }          // Esc
        if event.keyCode == 36 || event.keyCode == 76 { copyAction(); return }  // Return

        let ch = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command) {
            switch ch {
            case "c": copyAction(); return     // ⌘C — copy without clicking
            case "s": saveAction(); return     // ⌘S
            case "z":
                if event.modifierFlags.contains(.shift) { redo() } else { undo() }
                return                         // ⌘Z / ⌘⇧Z
            default: break
            }
        } else if phase == .editing, let t = toolForKey(ch) {
            setTool(t); return                 // A/L/R/O/P/H/B/N/T
        }
        super.keyDown(with: event)
    }

    /// ⌘C/⌘S/⌘Z must work even while the inline text field is first responder
    /// (keyDown above never fires then). Commits the in-progress text first, so
    /// "type caption → ⌘C" copies the annotated screenshot as the user expects.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard textField != nil, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": copyAction(); return true
        case "s": saveAction(); return true
        case "z":
            commitTextIfEditing()
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Annotations

    private func beginAnnotation(at p: CGPoint) {
        if tool == .text { beginText(at: p); dragMode = .none; return }
        if tool == .step {
            stepCounter += 1
            annotations.append(AnnotationStroke(tool: .step, color: color, width: lineWidth,
                                                points: [p], text: nil, image: nil, step: stepCounter))
            redoStack.removeAll()
            needsDisplay = true; dragMode = .none; return
        }
        let hl = tool == .highlighter
        current = AnnotationStroke(tool: tool, color: hl ? color.withAlphaComponent(0.4) : color,
                                   width: hl ? 16 : lineWidth, points: [p, p], text: nil)
    }

    private func updateAnnotation(to p: CGPoint) {
        guard var a = current else { return }
        if a.tool == .pen || a.tool == .highlighter { a.points.append(p) }
        else if a.points.count >= 2 { a.points[1] = p }
        current = a
        // Spotlight repaints the entire selection (it dims everything outside
        // the stroke) — partial invalidation left most of it undimmed mid-drag.
        if a.tool == .spotlight {
            setNeedsDisplay(selection.insetBy(dx: -4, dy: -4))
            return
        }
        // Redraw only the stroke's bounding box (+ last frame's), not the screen.
        let pad = max(70, a.width * 8)
        let bbox = strokeBounds(a.points).insetBy(dx: -pad, dy: -pad)
        setNeedsDisplay(bbox.union(lastStrokeRect))
        lastStrokeRect = bbox
    }

    private func finishAnnotation() {
        guard var a = current else { return }
        if a.tool == .blur, a.points.count > 1 {
            a.image = AnnotationRenderer.pixelate(frozenCG,
                rectInPoints: AnnotationRenderer.rect(a.points[0], a.points[1]), viewSize: bounds.size)
        }
        annotations.append(a); current = nil
        redoStack.removeAll()
        lastStrokeRect = .zero
    }

    // Inline text field (placed on the overlay — never behind it).
    private func beginText(at p: CGPoint) {
        commitTextIfEditing()
        let h = max(20, lineWidth * 6 + 8)
        let tf = NSTextField(frame: NSRect(x: p.x, y: p.y, width: 240, height: h))
        tf.font = .boldSystemFont(ofSize: max(14, lineWidth * 6))
        tf.textColor = color
        tf.drawsBackground = false; tf.isBordered = false; tf.focusRingType = .none
        tf.placeholderString = "Type, ↵ to add"
        tf.delegate = self
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf; pendingTextOrigin = p
    }

    private func commitTextIfEditing() {
        guard let tf = textField else { return }
        let s = tf.stringValue
        tf.removeFromSuperview(); textField = nil
        if !s.isEmpty {
            annotations.append(AnnotationStroke(tool: .text, color: color, width: lineWidth,
                                                points: [pendingTextOrigin], text: s, image: nil, step: nil))
            redoStack.removeAll()
        }
        window?.makeFirstResponder(self); needsDisplay = true
    }

    private func cancelText() {
        textField?.removeFromSuperview(); textField = nil
        window?.makeFirstResponder(self); needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { commitTextIfEditing(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Single image draw (opaque). The old code drew the frozen image TWICE
        // per frame (full + clipped-bright) which made big screens lag.
        frozen.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)

        let dim = NSColor.snapDim
        dim.setFill()
        let bright = brightRect()

        if phase == .passive || bright.width <= 0 || bright.height <= 0 {
            bounds.fill(using: .sourceOver)
            // Snap hint: thin accent outline around the hovered window ONLY — screen
            // stays fully dim (no un-dim), so nothing looks pre-selected on open.
            if phase == .selecting, let h = hoverWindow {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
                let p = NSBezierPath(rect: h.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
            }
        } else {
            // Dim only the 4 regions AROUND the bright rect — no clip, no re-draw
            // of the image. Clipped automatically to dirtyRect by AppKit.
            for r in surrounding(bright) { r.fill(using: .sourceOver) }

            if phase == .editing {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: selection).setClip()
                for a in annotations { AnnotationRenderer.draw(a) }
                if let c = current { AnnotationRenderer.draw(c) }
                NSGraphicsContext.restoreGraphicsState()
            }

            // High-contrast triple border: dark hairline (outside) + accent +
            // white hairline (inside) → visible on light AND dark content.
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let outer = NSBezierPath(rect: bright.insetBy(dx: -1.5, dy: -1.5)); outer.lineWidth = 1; outer.stroke()
            NSColor.controlAccentColor.setStroke()
            let b = NSBezierPath(rect: bright); b.lineWidth = 2; b.stroke()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let inner = NSBezierPath(rect: bright.insetBy(dx: 1.5, dy: 1.5)); inner.lineWidth = 0.75; inner.stroke()

            drawDimLabel(bright)
            if phase == .editing { drawHandles() }
        }
        if showLoupe, phase == .selecting { drawLoupe() }
        if showHint, phase != .passive { drawHint() }
    }

    private func drawHint() {
        let text = phase == .editing
            ? "Tools  A L R O P H B N T   ·   ⌘C copy   ·   ⌘Z undo   ·   Esc"
            : "Drag to select   ·   click a window to snap   ·   Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let sz = text.size(withAttributes: attrs)
        let pad: CGFloat = 12
        let box = NSRect(x: bounds.midX - (sz.width + pad * 2) / 2, y: 38,
                         width: sz.width + pad * 2, height: sz.height + 10)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
        NSColor.white.withAlphaComponent(0.15).setStroke()
        let b = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9); b.lineWidth = 0.5; b.stroke()
        text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + 5), withAttributes: attrs)
    }

    /// The currently "bright" (un-dimmed) rect: only the live/edited selection.
    /// A hovered window is NOT un-dimmed — it just gets a thin outline hint, so the
    /// screen stays fully dim until the user actually drags (no "pre-selected" look).
    private func brightRect() -> CGRect {
        if phase == .editing { return selection }
        return selection.width > 0 ? selection : .zero
    }

    private func surrounding(_ s: CGRect) -> [NSRect] {
        [NSRect(x: bounds.minX, y: s.maxY, width: bounds.width, height: bounds.maxY - s.maxY),
         NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: s.minY - bounds.minY),
         NSRect(x: bounds.minX, y: s.minY, width: s.minX - bounds.minX, height: s.height),
         NSRect(x: s.maxX, y: s.minY, width: bounds.maxX - s.maxX, height: s.height)]
    }

    private func drawDimLabel(_ selection: CGRect) {
        let label = "\(Int(selection.width)) × \(Int(selection.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        let bg = CGRect(x: selection.minX, y: min(bounds.maxY - sz.height - 4, selection.maxY + 6),
                        width: sz.width + 12, height: sz.height + 5)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
        label.draw(at: CGPoint(x: bg.minX + 6, y: bg.minY + 2.5), withAttributes: attrs)
    }

    private func drawHandles() {
        for r in handleRects() {
            // Dark ring for contrast on light content, white fill, accent stroke.
            let outer = NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1))
            NSColor.black.withAlphaComponent(0.4).setStroke(); outer.lineWidth = 1; outer.stroke()
            let p = NSBezierPath(ovalIn: r)
            NSColor.white.setFill(); p.fill()
            NSColor.controlAccentColor.setStroke(); p.lineWidth = 2; p.stroke()
        }
    }

    private func drawLoupe() {
        let boxSize: CGFloat = 132
        var origin = CGPoint(x: mouseLoc.x + 18, y: mouseLoc.y - boxSize - 18)
        if origin.x + boxSize > bounds.maxX { origin.x = mouseLoc.x - boxSize - 18 }
        if origin.y < bounds.minY { origin.y = mouseLoc.y + 18 }
        let box = NSRect(origin: origin, size: NSSize(width: boxSize, height: boxSize))

        let srcPts: CGFloat = 17
        let px = mouseLoc.x * scale, py = (bounds.height - mouseLoc.y) * scale
        let half = srcPts * scale / 2
        let srcRect = CGRect(x: px - half, y: py - half, width: srcPts * scale, height: srcPts * scale).integral

        let cell = boxSize / srcPts
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).setClip()
        if let crop = frozenCG.cropping(to: srcRect) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: crop, size: box.size).draw(in: box)
        }
        // Pixel grid.
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let grid = NSBezierPath(); grid.lineWidth = 0.5
        var gx = box.minX
        while gx <= box.maxX { grid.move(to: NSPoint(x: gx, y: box.minY)); grid.line(to: NSPoint(x: gx, y: box.maxY)); gx += cell }
        var gy = box.minY
        while gy <= box.maxY { grid.move(to: NSPoint(x: box.minX, y: gy)); grid.line(to: NSPoint(x: box.maxX, y: gy)); gy += cell }
        grid.stroke()
        // Center cell crosshair.
        NSColor.controlAccentColor.withAlphaComponent(0.95).setStroke()
        let mid = NSRect(x: box.midX - cell / 2, y: box.midY - cell / 2, width: cell, height: cell)
        let m = NSBezierPath(rect: mid); m.lineWidth = 1.5; m.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let frame = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10); frame.lineWidth = 1; frame.stroke()

        let txt = "\(Int(mouseLoc.x)), \(Int(bounds.height - mouseLoc.y))  \(sampledHex())"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white]
        let sz = txt.size(withAttributes: attrs)
        let bg = CGRect(x: box.minX, y: box.minY - sz.height - 5, width: max(box.width, sz.width + 10), height: sz.height + 5)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
        txt.draw(at: CGPoint(x: bg.minX + 5, y: bg.minY + 2.5), withAttributes: attrs)
    }

    private func sampledHex() -> String {
        let x = Int(min(max(mouseLoc.x * scale, 0), CGFloat(frozenCG.width - 1)))
        let y = Int(min(max((bounds.height - mouseLoc.y) * scale, 0), CGFloat(frozenCG.height - 1)))
        guard let c = Self.pixelColor(frozenCG, x: x, y: y)?.usingColorSpace(.sRGB) else { return "#------" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    // MARK: - Handles / resize

    private func handleRects() -> [CGRect] {
        let s = selection, h = handleSize
        let xs = [s.minX, s.midX, s.maxX], ys = [s.minY, s.midY, s.maxY]
        var rects: [CGRect] = []
        for (i, y) in ys.enumerated() {
            for (j, x) in xs.enumerated() {
                if i == 1 && j == 1 { continue }
                rects.append(CGRect(x: x - h / 2, y: y - h / 2, width: h, height: h))
            }
        }
        return rects   // 0:BL 1:B 2:BR 3:L 4:R 5:TL 6:T 7:TR
    }

    private func handleAt(_ p: CGPoint) -> Int? {
        for (i, r) in handleRects().enumerated() where r.insetBy(dx: -3, dy: -3).contains(p) { return i }
        return nil
    }

    private func resizeSelection(handle: Int, to p: CGPoint) {
        var minX = selection.minX, minY = selection.minY, maxX = selection.maxX, maxY = selection.maxY
        if [0, 3, 5].contains(handle) { minX = p.x }
        if [2, 4, 7].contains(handle) { maxX = p.x }
        if [0, 1, 2].contains(handle) { minY = p.y }
        if [5, 6, 7].contains(handle) { maxY = p.y }
        selection = AnnotationRenderer.rect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)).intersection(bounds)
    }

    // MARK: - Floating glass bars

    private func buildBars() {
        toolBar?.removeFromSuperview(); actionBar?.removeFromSuperview()
        toolButtons.removeAll(); swatchButtons.removeAll()

        let tools: [(String, AnnotationTool, String)] = [
            ("arrow.up.left", .arrow, "Arrow (A)"), ("line.diagonal", .line, "Line (L)"),
            ("rectangle", .rectangle, "Rectangle (R)"), ("circle", .ellipse, "Ellipse (O)"),
            ("pencil.tip", .pen, "Pen (P)"), ("highlighter", .highlighter, "Marker (H)"),
            ("circle.grid.3x3.fill", .blur, "Blur (B)"), ("number.circle", .step, "Step (N)"),
            ("textformat", .text, "Text (T)"), ("flashlight.on.fill", .spotlight, "Spotlight (S)"),
        ]
        let tStack = NSStackView(); tStack.orientation = .vertical; tStack.spacing = 3; tStack.alignment = .centerX
        tStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for (sym, t, help) in tools {
            let b = NSButton(image: symbol(sym, help), target: self, action: #selector(selectTool(_:)))
            b.tag = t.rawValue; b.isBordered = false; b.setButtonType(.momentaryChange)
            b.imageScaling = .scaleProportionallyDown; b.toolTip = help
            b.widthAnchor.constraint(equalToConstant: 34).isActive = true
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            styleTool(b, selected: t == tool)
            toolButtons.append(b); tStack.addArrangedSubview(b)
        }
        tStack.addArrangedSubview(divider())
        tStack.addArrangedSubview(swatchPalette())
        tStack.addArrangedSubview(divider())
        let slider = NSSlider(value: Double(lineWidth), minValue: 1, maxValue: 14, target: self, action: #selector(widthChanged(_:)))
        slider.isVertical = true
        slider.heightAnchor.constraint(equalToConstant: 64).isActive = true
        slider.toolTip = "Stroke width"
        tStack.addArrangedSubview(slider)
        let tBar = wrapBar(tStack); toolBar = tBar; addSubview(tBar)

        let aStack = NSStackView(); aStack.orientation = .horizontal; aStack.spacing = 6
        aStack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let undo = NSButton(image: symbol("arrow.uturn.backward", "Undo"), target: self, action: #selector(undo))
        undo.bezelStyle = .texturedRounded; undo.toolTip = "Undo (⌘Z)"
        let redoB = NSButton(image: symbol("arrow.uturn.forward", "Redo"), target: self, action: #selector(redo))
        redoB.bezelStyle = .texturedRounded; redoB.toolTip = "Redo (⌘⇧Z)"
        let beautify = NSButton(image: symbol("wand.and.stars", "Beautify"), target: self, action: #selector(beautifyAction))
        beautify.bezelStyle = .texturedRounded; beautify.toolTip = "Beautify — gradient background"
        let pin = NSButton(image: symbol("pin", "Pin"), target: self, action: #selector(pinAction))
        pin.bezelStyle = .texturedRounded; pin.toolTip = "Pin to screen"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyAction))
        copy.bezelStyle = .texturedRounded; copy.toolTip = "Copy (⌘C / ↵)"
        let save = NSButton(title: "Save", target: self, action: #selector(saveAction))
        save.bezelStyle = .texturedRounded; save.toolTip = "Save (⌘S)"
        let close = NSButton(image: symbol("xmark", "Close"), target: self, action: #selector(closeAction))
        close.bezelStyle = .texturedRounded; close.toolTip = "Close (Esc)"
        [undo, redoB, beautify, pin, copy, save, close].forEach { aStack.addArrangedSubview($0) }
        let aBar = wrapBar(aStack); actionBar = aBar; addSubview(aBar)
    }

    private func divider() -> NSView {
        let b = NSBox(); b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    private func swatchPalette() -> NSView {
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                 .systemBlue, .systemPurple, .white, .black]
        let grid = NSStackView(); grid.orientation = .vertical; grid.spacing = 4; grid.alignment = .centerX
        for pair in stride(from: 0, to: colors.count, by: 2) {
            let row = NSStackView(); row.orientation = .horizontal; row.spacing = 4
            for i in pair..<min(pair + 2, colors.count) {
                let b = SwatchButton(color: colors[i]); b.target = self; b.action = #selector(selectSwatch(_:))
                b.widthAnchor.constraint(equalToConstant: 20).isActive = true
                b.heightAnchor.constraint(equalToConstant: 20).isActive = true
                // Highlight the swatch matching the current color from the start.
                b.picked = colors[i].hexString() == color.hexString()
                swatchButtons.append(b); row.addArrangedSubview(b)
            }
            grid.addArrangedSubview(row)
        }
        return grid
    }

    private func wrapBar(_ stack: NSStackView) -> NSView {
        let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.blendingMode = .withinWindow
        fx.state = .active; fx.wantsLayer = true
        // Force dark vibrancy so the toolbar keeps high contrast over ANY
        // wallpaper (light desktops washed the glass out before).
        fx.appearance = NSAppearance(named: .vibrantDark)
        fx.layer?.cornerRadius = 14; fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 1; fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        let size = stack.fittingSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.shadow = NSShadow()
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.45
        container.layer?.shadowRadius = 14
        container.layer?.shadowOffset = CGSize(width: 0, height: -3)
        fx.frame = NSRect(origin: .zero, size: size)
        fx.autoresizingMask = [.width, .height]
        container.addSubview(fx)
        return container
    }

    private func layoutBars() {
        guard let t = toolBar, let a = actionBar else { return }
        let gap: CGFloat = 10
        var tx = selection.maxX + gap
        if tx + t.frame.width > bounds.maxX { tx = selection.minX - t.frame.width - gap }
        if tx < bounds.minX { tx = selection.maxX - t.frame.width - gap }
        var ty = selection.midY - t.frame.height / 2
        ty = min(max(ty, bounds.minY + gap), bounds.maxY - t.frame.height - gap)
        t.frame.origin = CGPoint(x: tx, y: ty)

        var ay = selection.minY - a.frame.height - gap
        if ay < bounds.minY { ay = selection.maxY + gap }
        if ay + a.frame.height > bounds.maxY { ay = selection.minY + gap }
        var ax = selection.maxX - a.frame.width
        ax = min(max(ax, bounds.minX + gap), bounds.maxX - a.frame.width - gap)
        a.frame.origin = CGPoint(x: ax, y: ay)
    }

    // MARK: - Toolbar actions

    @objc private func selectTool(_ sender: NSButton) {
        setTool(AnnotationTool(rawValue: sender.tag) ?? .arrow)
    }

    private func setTool(_ t: AnnotationTool) {
        commitTextIfEditing()
        tool = t
        toolButtons.forEach { styleTool($0, selected: $0.tag == t.rawValue) }
    }

    /// Single-key tool shortcut (no modifier).
    private func toolForKey(_ ch: String?) -> AnnotationTool? {
        switch ch {
        case "a": .arrow;  case "l": .line;   case "r": .rectangle
        case "o": .ellipse; case "p": .pen;   case "h": .highlighter
        case "b": .blur;   case "n": .step;   case "t": .text
        case "s": .spotlight
        default: nil
        }
    }

    /// High-contrast tool styling: selected = filled accent chip with white icon,
    /// unselected = bright icon on transparent. Readable on any wallpaper.
    private func styleTool(_ b: NSButton, selected: Bool) {
        b.wantsLayer = true
        b.layer?.cornerRadius = 7
        b.layer?.backgroundColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        b.contentTintColor = selected ? .white : NSColor.white.withAlphaComponent(0.88)
    }
    @objc private func selectSwatch(_ sender: SwatchButton) {
        color = sender.swatch
        swatchButtons.forEach { $0.picked = ($0 === sender) }
        if let tf = textField { tf.textColor = color }
    }
    @objc private func widthChanged(_ sender: NSSlider) { lineWidth = CGFloat(sender.doubleValue) }
    @objc private func undo() {
        guard !annotations.isEmpty else { return }
        let r = annotations.removeLast()
        redoStack.append(r)
        if r.tool == .step { stepCounter = max(0, stepCounter - 1) }
        needsDisplay = true
    }

    @objc private func redo() {
        guard let r = redoStack.popLast() else { return }
        annotations.append(r)
        if r.tool == .step { stepCounter += 1 }
        needsDisplay = true
    }

    @objc private func copyAction() {
        commitTextIfEditing()
        guard let cg = compositeCG() else { return }
        let img = NSImage(cgImage: cg, size: selection.size)
        let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects([img])
        if let s = settings, s.autoSaveEnabled { autoSave(cg, settings: s) }
        Notifier.info("Copied", "Screenshot copied to clipboard.")
        playFeedback()
        session?.finish()
    }

    @objc private func saveAction() {
        commitTextIfEditing()
        guard let cg = compositeCG() else { return }
        let fmt = settings?.saveFormat ?? .png
        let q = settings?.jpegQuality ?? 0.9
        session?.hideOverlays()              // so the panel isn't hidden behind the overlay
        let panel = NSSavePanel()
        panel.allowedContentTypes = fmt == .png ? [.png] : [.jpeg]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "SnapDesk \(f.string(from: Date())).\(fmt == .png ? "png" : "jpg")"
        panel.begin { [weak self] resp in
            if resp == .OK, let url = panel.url, let data = AnnotationRenderer.encode(cg, format: fmt, quality: q) {
                do {
                    try data.write(to: url, options: .atomic)
                    self?.playFeedback()
                    self?.session?.finish()
                } catch {
                    Notifier.error("Save failed", error.localizedDescription)
                    self?.session?.showOverlays()
                }
            } else {
                self?.session?.showOverlays()   // cancelled → bring the editor back
            }
        }
    }

    @objc private func beautifyAction() {
        commitTextIfEditing()
        guard let cg = compositeCG(), let nice = AnnotationRenderer.beautify(cg) else { return }
        let pb = NSPasteboard.general; pb.clearContents()
        pb.writeObjects([NSImage(cgImage: nice, size: NSSize(width: nice.width, height: nice.height))])
        Notifier.info("Beautified", "Padded gradient screenshot copied to clipboard.")
        playFeedback()
        session?.finish()
    }

    @objc private func pinAction() {
        commitTextIfEditing()
        guard let cg = compositeCG() else { return }
        playFeedback()
        let playSound = settings?.playSound ?? false
        let soundName = settings?.soundName ?? "Pop"
        session?.finish()
        PinWindow.pin(cg, scale: scale, playSound: playSound, soundName: soundName)
    }

    @objc private func closeAction() { session?.finish() }

    private func autoSave(_ cg: CGImage, settings s: SettingsStore) {
        let ext = s.saveFormat == .png ? "png" : "jpg"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // stable digits in every locale
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        // Fall back to Desktop if the chosen folder was deleted/unmounted, so a
        // capture is never silently lost.
        var dir = s.autoSaveFolder
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) {
            dir = NSHomeDirectory() + "/Desktop"
        }
        // Same-second captures must not overwrite each other.
        let base = "SnapDesk \(f.string(from: Date()))"
        var url = URL(fileURLWithPath: dir).appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = URL(fileURLWithPath: dir).appendingPathComponent("\(base) \(n).\(ext)"); n += 1
        }
        guard let data = AnnotationRenderer.encode(cg, format: s.saveFormat, quality: s.jpegQuality) else { return }
        do { try data.write(to: url, options: .atomic) }
        catch { Notifier.error("Auto-save failed", error.localizedDescription) }
    }

    private func compositeCG() -> CGImage? {
        AnnotationRenderer.composite(frozen: frozen, fullSize: bounds.size, scale: scale,
                                     selection: selection, strokes: annotations)
    }

    private func playFeedback() {
        if settings?.playSound == true { Sounds.play(settings?.soundName ?? "Pop") }
    }

    // MARK: - Symbol helper

    private func symbol(_ name: String, _ desc: String? = nil) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: desc)
            ?? NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: desc)
            ?? NSImage(size: NSSize(width: 15, height: 15))
        return img.withSymbolConfiguration(cfg) ?? img
    }
}
