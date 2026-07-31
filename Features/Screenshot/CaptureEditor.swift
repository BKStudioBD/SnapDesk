import AppKit

/// In-place screenshot annotation editor with a modern "glass" toolbar.
///
/// The screen is frozen up-front, a dimmed overlay shows it, the user drags out a
/// selection (with a live magnifier loupe), then annotates directly on the overlay
/// using a floating glass toolbar docked to the selection. Resize handles adjust
/// the region; Copy / Save / Close finish. All on one overlay, no second window.
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
            // Activate FIRST: this is an accessory (LSUIElement) app launched from
            // a Carbon global hotkey, so it isn't frontmost. A borderless window
            // can only become key once the app is active, so ordering activate
            // before makeKey is what actually delivers keyboard events (Esc, tool
            // shortcuts) instead of leaving them dropped.
            NSApp.activate(ignoringOtherApps: true)
            windows.forEach { $0.orderFront(nil) }
            windows.first?.makeKeyAndOrderFront(nil)
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
    /// What the pointer is doing to the crop box: nothing, dragging handle `n`,
    /// sliding it (from the last mouse point), or rubber-banding a new one (from
    /// where the drag started).
    private enum CropDrag { case none, handle(Int), move(CGPoint), draw(CGPoint) }

    private let frozen: NSImage
    private let frozenCG: CGImage
    /// Built lazily (only the active screen's loupe samples it) so multi-monitor
    /// captures don't allocate a full-res bitmap rep per display up-front.
    // (color sampling reads a 1x1 crop of frozenCG on demand, no full-res
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
    private var current: AnnotationStroke?
    private var stepCounter = 0

    /// ONE stack for strokes and whole-image transforms alike: see EditorEdit.
    private var undoStack: [EditorEdit] = []
    private var redoStack: [EditorEdit] = []

    /// Non-nil once a crop / rotate / flip has been applied: the flat bitmap the
    /// selection now shows *instead of* the frozen screen underneath it.
    ///
    /// Strategy (b) of the two ways to transform an annotated picture: flatten the
    /// strokes into the bitmap first, then transform the bitmap. Strategy (a),
    /// transforming each stroke's geometry alongside the image, keeps them
    /// editable, but every
    /// arrow head, text baseline and stroke width has to be re-derived, and any
    /// error there is invisible until someone looks closely at a shipped screenshot.
    /// The deliberate cost of (b): strokes made BEFORE a transform are pixels
    /// afterwards and can no longer be undone individually: ⌘Z past the transform
    /// restores them as live strokes again, which is where they become editable.
    private var flattened: CGImage?
    private var cropBox: CropBox?
    private var cropDrag: CropDrag = .none

    private var toolBar: NSView?
    private var actionBar: NSView?
    private var toolButtons: [NSButton] = []
    private var swatchButtons: [SwatchButton] = []
    private weak var cropButton: NSButton?

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
        // The context is DRAWN INTO after its initializer has returned, so the
        // buffer pointer has to outlive that call. `&px` guarantees the pointer
        // only for the duration of the call itself: Core Graphics then writes
        // through memory the array may no longer own, and the bytes read back
        // are whatever happened to be there. Same trap `CaptureService.looksBlank`
        // documents; keep the draw inside the scope that owns the pointer.
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y),
                                     width: img.width, height: img.height))
            return true
        }
        guard drawn else { return nil }
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                       blue: CGFloat(px[2]) / 255, alpha: 1)
    }
    override var acceptsFirstResponder: Bool { true }
    // First click always lands (starts a drag / snaps a window) even if the
    // overlay isn't the active window yet, no dead "focus" click.
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

    /// Work that a stray click on another display must not discard.
    private var hasEdits: Bool {
        annotations.isEmpty == false || current != nil || flattened != nil
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        mouseLoc = convert(event.locationInWindow, from: nil)
        // Window-snap outline hint while hovering (before any drag). Full redraw so
        // the dim is always complete: targeted redraws left stale un-dimmed patches.
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
            if let active = session?.activeView, active.hasEdits { return }
            session?.finish()
        case .selecting:
            session?.claim(self)
            if session?.activeView !== self { phase = .passive; return }
            dragStart = p; selection = .zero; needsDisplay = true
        case .editing:
            commitTextIfEditing()
            // Crop mode swallows the mouse: no stroke may start while a crop is
            // pending, or confirming it would flatten a half-drawn annotation.
            if let box = cropBox {
                if let h = box.handle(at: p, size: handleSize) { cropDrag = .handle(h) }
                else if box.rect.contains(p) { cropDrag = .move(p) }
                else { cropDrag = .draw(p) }   // rect only changes once the drag moves
                needsDisplay = true
                return
            }
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
            if var box = cropBox {
                switch cropDrag {
                case .handle(let h): box.drag(handle: h, to: p)
                case .move(let last):
                    box.move(by: CGSize(width: p.x - last.x, height: p.y - last.y))
                    cropDrag = .move(p)
                case .draw(let origin): box.draw(from: origin, to: p)
                case .none: return
                }
                cropBox = box
                needsDisplay = true
                return
            }
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
            if cropBox != nil { cropDrag = .none; needsDisplay = true; return }
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

    /// Topmost on-screen window containing `p`. `windowRects` comes from
    /// CGWindowList in front-to-back order, so the FIRST match is the one the
    /// user actually sees under the cursor: picking the smallest instead used to
    /// snap to a tiny window fully hidden behind a larger one.
    private func windowAt(_ p: CGPoint) -> CGRect? {
        windowRects.first { $0.contains(p) }
    }

    override func keyDown(with event: NSEvent) {
        // Note: while the inline text field is editing it is first responder, so
        // these never fire then: letters type into the field as expected.

        // Crop mode owns Esc and ↵ first: Esc must abandon the crop, not the whole
        // capture. That would take every annotation with it.
        if cropBox != nil {
            if event.keyCode == 53 { cancelCrop(); return }
            if event.keyCode == 36 || event.keyCode == 76 { applyCrop(); return }
        }
        if event.keyCode == 53 { session?.finish(); return }          // Esc
        if event.keyCode == 36 || event.keyCode == 76 { copyAction(); return }  // Return

        let ch = event.charactersIgnoringModifiers?.lowercased()
        if event.modifierFlags.contains(.command) {
            switch ch {
            case "c": copyAction(); return     // ⌘C copies without clicking
            case "s": saveAction(); return     // ⌘S
            case "t" where event.modifierFlags.contains(.shift):
                grabTextAction(); return       // ⌘⇧T reads this shot
            case "r" where event.modifierFlags.contains(.shift):
                repeatLastAnnotation(); return // ⌘⇧R reuses the tool/colour/width
            case "z":
                if event.modifierFlags.contains(.shift) { redo() } else { undo() }
                return                         // ⌘Z / ⌘⇧Z
            // Rotate matches Preview's ⌘L / ⌘R. ⌘⇧R stays "repeat last annotation"
            // because its `where` case above is matched first.
            case "l": applyTransform(.rotateLeft); return
            case "r": applyTransform(.rotateRight); return
            case "h" where event.modifierFlags.contains(.shift):
                applyTransform(.flipHorizontal); return     // ⌘⇧H
            case "v" where event.modifierFlags.contains(.shift):
                applyTransform(.flipVertical); return       // ⌘⇧V
            default: break
            }
        } else if phase == .editing, cropBox == nil, ch == "c" {
            beginCrop(); return                // C is the one letter no tool uses
        } else if phase == .editing, cropBox == nil, let t = toolForKey(ch) {
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
        case "t" where event.modifierFlags.contains(.shift):
            grabTextAction(); return true
        case "z":
            commitTextIfEditing()
            if event.modifierFlags.contains(.shift) { redo() } else { undo() }
            return true
        // ⌘⇧R is not handled here (it isn't today either), so guard the shift bit
        // rather than stealing it for a rotate.
        case "r" where event.modifierFlags.contains(.shift) == false:
            applyTransform(.rotateRight); return true
        case "l" where event.modifierFlags.contains(.shift) == false:
            applyTransform(.rotateLeft); return true
        case "h" where event.modifierFlags.contains(.shift):
            applyTransform(.flipHorizontal); return true
        case "v" where event.modifierFlags.contains(.shift):
            applyTransform(.flipVertical); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Annotations

    /// The only way a stroke reaches `annotations`, so the undo stack can never
    /// disagree with what's on screen.
    private func pushStroke(_ a: AnnotationStroke) {
        annotations.append(a)
        undoStack.append(.stroke(nil))
        redoStack.removeAll()
    }

    private func beginAnnotation(at p: CGPoint) {
        if tool == .text { beginText(at: p); dragMode = .none; return }
        if tool == .step {
            stepCounter += 1
            pushStroke(AnnotationStroke(tool: .step, color: color, width: lineWidth,
                                        points: [p], text: nil, image: nil, step: stepCounter))
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
        // the stroke): partial invalidation left most of it undimmed mid-drag.
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
            let r = AnnotationRenderer.rect(a.points[0], a.points[1])
            // Sample whatever the selection is actually SHOWING. After a crop or
            // rotate the frozen screen no longer lines up with it, and blurring it
            // would paste a slice of the old picture over the new one.
            if let flat = flattened {
                a.image = AnnotationRenderer.pixelate(flat, rectInPoints: r, displayedIn: selection)
            } else {
                a.image = AnnotationRenderer.pixelate(frozenCG, rectInPoints: r, viewSize: bounds.size)
            }
        }
        current = nil
        pushStroke(a)
        lastStrokeRect = .zero
    }

    // Inline text field (placed on the overlay, never behind it).
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
            pushStroke(AnnotationStroke(tool: .text, color: color, width: lineWidth,
                                        points: [pendingTextOrigin], text: s, image: nil, step: nil))
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
            // Snap hint: a thin accent outline around the hovered window only. The screen
            // stays fully dim (no un-dim), so nothing looks pre-selected on open.
            if phase == .selecting, let h = hoverWindow {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
                let p = NSBezierPath(rect: h.insetBy(dx: 1, dy: 1)); p.lineWidth = 2; p.stroke()
            }
        } else {
            // Dim only the 4 regions AROUND the bright rect, no clip, no re-draw
            // of the image. Clipped automatically to dirtyRect by AppKit.
            for r in surrounding(bright) { r.fill(using: .sourceOver) }

            if phase == .editing {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: selection).setClip()
                // A transformed bitmap covers the frozen screen inside the selection:
                // after a rotate the pixels underneath are no longer this picture.
                if let flat = flattened {
                    NSImage(cgImage: flat, size: selection.size)
                        .draw(in: selection, from: .zero, operation: .copy, fraction: 1)
                }
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

            if let box = cropBox {
                drawCropBox(box)
            } else {
                drawDimLabel(bright)
                if phase == .editing, flattened == nil { drawHandles() }
            }
        }
        if showLoupe, phase == .selecting { drawLoupe() }
        if showHint, phase != .passive { drawHint() }
    }

    private func drawHint() {
        let text: String
        if cropBox != nil {
            text = "Drag the crop box   ·   ↵ to crop   ·   Esc to cancel"
        } else if phase == .editing {
            text = "Tools  A L R O P H B N T   ·   C crop   ·   ⌘L / ⌘R rotate   ·   ⌘C copy   ·   Esc"
        } else {
            text = "Drag to select   ·   click a window to snap   ·   Esc to cancel"
        }
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
    /// A hovered window is NOT un-dimmed. It just gets a thin outline hint, so the
    /// screen stays fully dim until the user actually drags (no "pre-selected" look).
    private func brightRect() -> CGRect {
        if phase == .editing { return selection }
        return selection.width > 0 ? selection : .zero
    }

    private func surrounding(_ s: CGRect) -> [NSRect] { surrounding(s, within: bounds) }

    /// The four rects of `outer` left over around `s`: used both for the screen dim
    /// and for dimming the part of the selection a pending crop throws away.
    private func surrounding(_ s: CGRect, within outer: CGRect) -> [NSRect] {
        [NSRect(x: outer.minX, y: s.maxY, width: outer.width, height: max(0, outer.maxY - s.maxY)),
         NSRect(x: outer.minX, y: outer.minY, width: outer.width, height: max(0, s.minY - outer.minY)),
         NSRect(x: outer.minX, y: s.minY, width: max(0, s.minX - outer.minX), height: s.height),
         NSRect(x: s.maxX, y: s.minY, width: max(0, outer.maxX - s.maxX), height: s.height)]
    }

    private func drawDimLabel(_ selection: CGRect) {
        drawBadge("\(Int(selection.width)) × \(Int(selection.height))", above: selection)
    }

    private func drawBadge(_ label: String, above r: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
        let sz = label.size(withAttributes: attrs)
        let bg = CGRect(x: r.minX, y: min(bounds.maxY - sz.height - 4, r.maxY + 6),
                        width: sz.width + 12, height: sz.height + 5)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 5, yRadius: 5).fill()
        label.draw(at: CGPoint(x: bg.minX + 6, y: bg.minY + 2.5), withAttributes: attrs)
    }

    /// The pending crop: the discarded area dimmed a second time, thirds guides, and
    /// a readout of the PIXEL size the crop will produce (points would understate a
    /// 2× capture by half).
    private func drawCropBox(_ box: CropBox) {
        let r = box.rect
        NSColor.snapDim.setFill()
        for part in surrounding(r, within: selection) { part.fill(using: .sourceOver) }

        NSColor.white.withAlphaComponent(0.3).setStroke()
        let guides = NSBezierPath(); guides.lineWidth = 0.5
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            guides.move(to: NSPoint(x: x, y: r.minY)); guides.line(to: NSPoint(x: x, y: r.maxY))
            guides.move(to: NSPoint(x: r.minX, y: y)); guides.line(to: NSPoint(x: r.maxX, y: y))
        }
        guides.stroke()

        NSColor.black.withAlphaComponent(0.55).setStroke()
        let outer = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1)); outer.lineWidth = 1; outer.stroke()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let edge = NSBezierPath(rect: r); edge.lineWidth = 1.5; edge.stroke()

        for hr in CropBox.handleRects(for: r, size: handleSize) {
            let ring = NSBezierPath(ovalIn: hr.insetBy(dx: -1, dy: -1))
            NSColor.black.withAlphaComponent(0.4).setStroke(); ring.lineWidth = 1; ring.stroke()
            let p = NSBezierPath(ovalIn: hr)
            NSColor.white.setFill(); p.fill()
            NSColor.controlAccentColor.setStroke(); p.lineWidth = 2; p.stroke()
        }

        let s = effectiveScale
        drawBadge("\(Int((r.width * s).rounded())) × \(Int((r.height * s).rounded())) px", above: r)
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
        // Once a transform has replaced the pixels, dragging the selection edge can
        // no longer mean "show me more of the screen there": there is no more
        // picture outside the bitmap. Trimming after a transform is the crop tool.
        guard flattened == nil else { return nil }
        for (i, r) in handleRects().enumerated() where r.insetBy(dx: -3, dy: -3).contains(p) { return i }
        return nil
    }

    private func resizeSelection(handle: Int, to p: CGPoint) {
        var minX = selection.minX, minY = selection.minY, maxX = selection.maxX, maxY = selection.maxY
        if [0, 3, 5].contains(handle) { minX = p.x }
        if [2, 4, 7].contains(handle) { maxX = p.x }
        if [0, 1, 2].contains(handle) { minY = p.y }
        if [5, 6, 7].contains(handle) { maxY = p.y }
        let resized = AnnotationRenderer.rect(CGPoint(x: minX, y: minY),
                                              CGPoint(x: maxX, y: maxY)).intersection(bounds)
        // Dragged clean off the display, `intersection` returns CGRect.null,
        // whose maxX/minY are infinite: the toolbars fly off to infinity and
        // disappear, compositing returns nil so Copy/Save/Pin quietly stop
        // working, and the annotations are only recoverable by pressing Esc.
        // Keep the last good rect instead, the way CropBox does.
        guard !resized.isNull, resized.width >= 8, resized.height >= 8 else { return }
        selection = resized
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
        let crop = NSButton(image: symbol("crop", "Crop"), target: self, action: #selector(cropAction))
        crop.bezelStyle = .texturedRounded; crop.toolTip = "Crop (C). ↵ applies, Esc cancels"
        crop.setAccessibilityLabel("Crop")
        cropButton = crop
        let transforms: [(String, EditorImageTransform, String)] = [
            ("rotate.left", .rotateLeft, "Rotate left (⌘L)"),
            ("rotate.right", .rotateRight, "Rotate right (⌘R)"),
            // These spelled-out names are the flip glyphs as they were catalogued in
            // macOS 11–15; there is no "flip.vertical" spelling at all, so both use
            // the long form to stay a matched pair.
            ("arrow.left.and.right.righttriangle.left.righttriangle.right", .flipHorizontal,
             "Flip horizontal (⌘⇧H)"),
            ("arrow.up.and.down.righttriangle.up.righttriangle.down", .flipVertical,
             "Flip vertical (⌘⇧V)"),
        ]
        var transformButtons: [NSButton] = []
        for (sym, t, help) in transforms {
            let b = NSButton(image: symbol(sym, t.label), target: self, action: #selector(transformAction(_:)))
            b.bezelStyle = .texturedRounded
            b.tag = EditorImageTransform.allCases.firstIndex(of: t) ?? 0
            b.toolTip = help
            b.setAccessibilityLabel(t.label)
            transformButtons.append(b)
        }
        let beautify = NSButton(image: symbol("wand.and.stars", "Beautify"), target: self, action: #selector(beautifyAction))
        beautify.bezelStyle = .texturedRounded; beautify.toolTip = "Beautify: adds a gradient background"
        let pin = NSButton(image: symbol("pin", "Pin"), target: self, action: #selector(pinAction))
        pin.bezelStyle = .texturedRounded; pin.toolTip = "Pin to screen"
        let grabText = NSButton(image: symbol("text.viewfinder", "Grab text"),
                                target: self, action: #selector(grabTextAction))
        grabText.bezelStyle = .texturedRounded
        grabText.toolTip = "Grab the text in this shot (⌘⇧T)"
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyAction))
        copy.bezelStyle = .texturedRounded; copy.toolTip = "Copy (⌘C / ↵)"
        let save = NSButton(title: "Save", target: self, action: #selector(saveAction))
        save.bezelStyle = .texturedRounded; save.toolTip = "Save (⌘S)"
        let close = NSButton(image: symbol("xmark", "Close"), target: self, action: #selector(closeAction))
        close.bezelStyle = .texturedRounded; close.toolTip = "Close (Esc)"
        ([undo, redoB, crop] + transformButtons + [beautify, grabText, pin, copy, save, close])
            .forEach { aStack.addArrangedSubview($0) }
        styleCropButton()
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
        guard let edit = undoStack.popLast() else { return }
        switch edit {
        case .stroke:
            guard let r = annotations.popLast() else { return }
            if r.tool == .step { stepCounter = max(0, stepCounter - 1) }
            redoStack.append(.stroke(r))
        case .transform(let before, let after):
            restore(before)
            redoStack.append(.transform(before: before, after: after))
        }
        needsDisplay = true
    }

    @objc private func redo() {
        guard let edit = redoStack.popLast() else { return }
        switch edit {
        case .stroke(let stroke):
            guard let r = stroke else { return }
            annotations.append(r)
            if r.tool == .step { stepCounter += 1 }
            undoStack.append(.stroke(nil))
        case .transform(let before, let after):
            restore(after)
            undoStack.append(.transform(before: before, after: after))
        }
        needsDisplay = true
    }

    // MARK: - Crop / rotate / flip

    /// Put the editor back into a recorded state. The bitmap is the same object the
    /// snapshot was taken from and the strokes are the same values, so undoing a
    /// rotate returns the picture and its annotations bit-identical: nothing is
    /// re-rendered to get there.
    private func restore(_ s: EditorImageState) {
        flattened = s.flattened
        selection = s.selection
        annotations = s.annotations
        stepCounter = s.stepCounter
        current = nil
        cancelCrop()
        dragMode = .none
        lastStrokeRect = .zero
        layoutBars()
        needsDisplay = true
    }

    private var currentState: EditorImageState {
        EditorImageState(flattened: flattened, selection: selection,
                         annotations: annotations, stepCounter: stepCounter)
    }

    /// Apply a whole-image change as ONE undo step.
    private func pushTransform(to state: EditorImageState) {
        let before = currentState
        restore(state)
        undoStack.append(.transform(before: before, after: state))
        redoStack.removeAll()
        trimTransformHistory()
    }

    /// Ceiling on the bitmaps the transform history may pin.
    ///
    /// Every `.transform` entry holds a full-resolution `CGImage` in its `before`
    /// state for the whole editor session, and nothing evicted them. A full-screen
    /// selection on a 5K display is 5120×2880×4 B ≈ 59 MB, so rotating four times to
    /// work out which way round a shot was. And then ten crop/rotate/flip steps
    /// before finally hitting Copy: left hundreds of megabytes resident while a
    /// `.screenSaver`-level overlay covered the screen and could not be moved out of
    /// the way. The rest of this file goes out of its way not to pin even one spare
    /// full-size rep.
    private static let transformHistoryBudget = 192 * 1024 * 1024

    /// Drop the oldest transforms once they pin more than the budget.
    ///
    /// Trimmed from the BOTTOM, so what is left is still a contiguous suffix of the
    /// real edit order and ⌘Z simply stops at the cut. Removing an entry from the
    /// middle would leave older strokes to be undone against a picture whose rotate
    /// can no longer be reversed. The mixed-order bug the single stack in
    /// `EditorEdit` exists to prevent. The newest transform always survives, however
    /// big it is: a rotate you cannot undo at all is worse than the memory.
    private func trimTransformHistory() {
        var bytes = 0
        var kept = 0
        var cut: Int?
        for (i, edit) in undoStack.enumerated().reversed() {
            // Only `before` is counted: the `after` of one step is the `before` of the
            // next (and the newest `after` is the live picture), so adding both would
            // count every bitmap twice.
            guard case .transform(let before, _) = edit else { continue }
            bytes += Self.pinnedBytes(of: before.flattened)
            if kept > 0, bytes > Self.transformHistoryBudget { cut = i; break }
            kept += 1
        }
        if let cut { undoStack.removeFirst(cut + 1) }
    }

    private static func pinnedBytes(of image: CGImage?) -> Int {
        guard let image else { return 0 }
        return image.bytesPerRow * image.height
    }

    /// Pixels per point of what the selection currently shows. Equals the display's
    /// backing scale until a rotate has to shrink the bitmap to fit on screen, which
    /// is why the crop readout can't just multiply by `scale`.
    private var effectiveScale: CGFloat {
        guard let flat = flattened, selection.width > 0 else { return scale }
        return CGFloat(flat.width) / selection.width
    }

    private func applyTransform(_ t: EditorImageTransform) {
        commitTextIfEditing()
        guard phase == .editing, cropBox == nil else { return }
        guard let base = compositeCG(), let out = t.apply(to: base) else {
            Notifier.error("\(t.label) failed", "Couldn't transform that shot. Try again.")
            return
        }
        pushTransform(to: EditorImageState(flattened: out,
                                           selection: t.displayRect(for: selection, in: bounds),
                                           annotations: [],
                                           // Baked-in step numbers must not be handed
                                           // out twice, so the counter carries over.
                                           stepCounter: stepCounter))
    }

    private func beginCrop() {
        commitTextIfEditing()
        guard phase == .editing, cropBox == nil else { return }
        cropBox = CropBox(limit: selection)
        cropDrag = .none
        styleCropButton()
        needsDisplay = true
    }

    private func cancelCrop() {
        guard cropBox != nil else { return }
        cropBox = nil
        cropDrag = .none
        styleCropButton()
        needsDisplay = true
    }

    /// Fold a pending crop into the picture before anything composites it.
    ///
    /// Every finishing action goes through `compositeCG()`, which knows nothing
    /// about `cropBox`. Dragging a tight crop box and then clicking Copy (four
    /// buttons further along the SAME bar), or pressing ⌘C (only Esc and ↵ are
    /// intercepted while cropping), put the FULL selection on the clipboard, closed
    /// the overlay and showed the "Copied" toast as if nothing were wrong. The crop
    /// was unrecoverable, because the editor was already gone. Same shape as
    /// `commitTextIfEditing()`, which those actions already call to flush the other
    /// kind of pending edit.
    private func commitCropIfPending() {
        guard cropBox != nil else { return }
        applyCrop()
    }

    private func applyCrop() {
        guard let box = cropBox, let base = compositeCG() else { cancelCrop(); return }
        // A box nobody touched is the 8%-inset default the constructor draws to show
        // the box IS draggable, not a crop anyone asked for. Confirming it threw
        // away 29% of the pixels, so a second click on the Crop button (or C then ↵)
        // silently cut the edges off the very window being captured.
        guard box.wasDragged else { cancelCrop(); return }
        let px = ImageTransformer.pixelRect(from: box.rect, displayRect: selection,
                                            pixelWidth: base.width, pixelHeight: base.height)
        guard let out = ImageTransformer.cropped(base, toPixelRect: px) else {
            // CropBox already forbids an empty or inverted rect; if the pixel rect
            // still came out unusable, keep the picture and let the user re-drag.
            Notifier.error("Crop failed", "That crop was too small. Drag a larger box.")
            return
        }
        // Show the result at the rect those whole pixels actually cover, not the one
        // dragged: sub-pixel rounding otherwise skews every later stroke slightly.
        let shown = ImageTransformer.pointRect(from: px, displayRect: selection,
                                               pixelWidth: base.width, pixelHeight: base.height)
        cropBox = nil
        styleCropButton()
        pushTransform(to: EditorImageState(flattened: out, selection: shown,
                                           annotations: [], stepCounter: stepCounter))
    }

    @objc private func copyAction() {
        commitTextIfEditing()
        commitCropIfPending()
        guard let cg = compositeCG() else { return }
        let img = NSImage(cgImage: cg, size: selection.size)
        let pb = NSPasteboard.general
        pb.clearContents()
        // `finish()` releases the frozen bitmap and every annotation, so saying
        // "Copied" without checking meant the only copy of the work could be
        // gone while the toast claimed otherwise.
        guard pb.writeObjects([img]) else {
            Notifier.error("Copy failed", "Couldn't write the screenshot to the clipboard. Try the copy again.")
            return
        }
        if let s = settings, s.autoSaveEnabled { autoSave(cg, settings: s) }
        Notifier.info("Copied", "Screenshot copied to clipboard.")
        playFeedback()
        session?.finish()
    }

    /// Grab the TEXT out of the shot instead of the pixels. Everything needed is
    /// already here, the composited image and the user's OCR settings, so the
    /// alternative was: copy the shot, close, press the OCR hotkey, drag the same
    /// region again.
    /// Re-arm the tool, colour and width of the most recent annotation.
    ///
    /// Annotating a screenshot is repetitive: five arrows in the same red at the
    /// same weight. And every one of those meant re-picking the tool and the
    /// swatch after an undo or a tool change.
    private func repeatLastAnnotation() {
        guard let last = annotations.last else {
            Notifier.info("Nothing to repeat", "Draw one annotation first, then ⌘⇧R re-arms it.")
            return
        }
        setTool(last.tool)
        color = last.color
        lineWidth = last.width
        // Reflect it in the bar, or the toolbar would disagree with what draws.
        swatchButtons.forEach { $0.picked = $0.swatch.hexString() == last.color.hexString() }
        needsDisplay = true
    }

    @objc private func grabTextAction() {
        commitTextIfEditing()
        commitCropIfPending()
        guard let cg = compositeCG() else { return }
        let options = settings?.ocrOptions ?? OCROptions()
        let notify = settings?.ocrNotify ?? true
        session?.finish()   // the overlay must not sit over the notification
        Task { @MainActor in
            do {
                let text = try await OCRService.recognizeText(in: cg, options: options)
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    Notifier.info("No text found",
                                  "Nothing readable in that shot. Try a tighter crop around the text.")
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                guard pb.setString(text, forType: .string) else {
                    Notifier.error("Copy failed", "Couldn't write to the clipboard. Try again.")
                    return
                }
                if notify {
                    Notifier.info("Text copied",
                                  "\(text.count) character\(text.count == 1 ? "" : "s") on the clipboard.")
                }
            } catch {
                NSLog("SnapDesk: editor OCR failed. \(error)")
                Notifier.error("OCR failed", "Couldn't read that shot. Try again.")
            }
        }
    }

    @objc private func saveAction() {
        commitTextIfEditing()
        commitCropIfPending()
        guard let cg = compositeCG() else { return }
        let fmt = settings?.saveFormat ?? .png
        let q = settings?.jpegQuality ?? 0.9
        session?.hideOverlays()              // so the panel isn't hidden behind the overlay
        let panel = NSSavePanel()
        panel.allowedContentTypes = fmt == .png ? [.png] : [.jpeg]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "SnapDesk \(f.string(from: Date())).\(fmt == .png ? "png" : "jpg")"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else {
                self?.session?.showOverlays()   // cancelled → bring the editor back
                return
            }
            // Encoding a full-resolution shot and writing it are seconds of work
            // apiece on a 5K selection, and both ran on the main thread, with a
            // `.screenSaver`-level overlay still on every display, so the whole
            // Mac looked hung at the exact moment the app was told to finish.
            // `cg` is immutable, so only the outcome has to come back.
            DispatchQueue.global(qos: .userInitiated).async {
                // A failed encode used to land in the SAME branch as "the user
                // pressed Cancel": no file written, no message, the editor simply
                // reappearing as though nothing had been asked for.
                guard let data = AnnotationRenderer.encode(cg, format: fmt, quality: q) else {
                    DispatchQueue.main.async {
                        Notifier.error("Save failed", "Couldn't encode that image. Try saving as PNG instead.")
                        self?.session?.showOverlays()
                    }
                    return
                }
                do {
                    try data.write(to: url, options: .atomic)
                    DispatchQueue.main.async {
                        self?.playFeedback()
                        self?.session?.finish()
                    }
                } catch {
                    DispatchQueue.main.async {
                        Notifier.error("Save failed", error.localizedDescription)
                        self?.session?.showOverlays()
                    }
                }
            }
        }
    }

    @objc private func beautifyAction() {
        commitTextIfEditing()
        commitCropIfPending()
        guard let cg = compositeCG() else { return }
        // Beautify allocates a bitmap larger than the shot itself (padding on all
        // four sides). When that allocation fails the wand button did nothing at
        // all, no image, no toast, no clue that it had even been pressed.
        guard let nice = AnnotationRenderer.beautify(cg) else {
            Notifier.error("Beautify failed", "Couldn't build the padded image. Try a smaller selection.")
            return
        }
        let pb = NSPasteboard.general; pb.clearContents()
        // Same reason as Copy: `finish()` throws the work away, so the toast
        // must not claim a copy that didn't happen.
        guard pb.writeObjects([NSImage(cgImage: nice,
                                       size: NSSize(width: nice.width, height: nice.height))]) else {
            Notifier.error("Copy failed", "Couldn't write the screenshot to the clipboard. Try the copy again.")
            return
        }
        Notifier.info("Beautified", "Padded gradient screenshot copied to clipboard.")
        playFeedback()
        session?.finish()
    }

    @objc private func pinAction() {
        commitTextIfEditing()
        commitCropIfPending()
        guard let cg = compositeCG() else { return }
        playFeedback()
        let playSound = settings?.playSound ?? false
        // A transform can leave the bitmap at a different pixels-per-point than the
        // display's, and a pin sized by the wrong one comes up half/double size.
        let pinScale = effectiveScale
        session?.finish()
        PinWindow.pin(cg, scale: pinScale, playSound: playSound)
    }

    @objc private func closeAction() { session?.finish() }

    /// One button both starts a crop and confirms it, so there's a pointer-only path
    /// to "apply" for anyone who never presses ↵.
    @objc private func cropAction() {
        if cropBox == nil { beginCrop() } else { applyCrop() }
    }

    @objc private func transformAction(_ sender: NSButton) {
        let all = EditorImageTransform.allCases
        guard all.indices.contains(sender.tag) else { return }
        applyTransform(all[sender.tag])
    }

    private func styleCropButton() {
        guard let b = cropButton else { return }
        let cropping = cropBox != nil
        b.contentTintColor = cropping ? .controlAccentColor : nil
        b.toolTip = cropping ? "Apply crop (↵). Esc cancels" : "Crop (C). ↵ applies, Esc cancels"
        b.setAccessibilityLabel(cropping ? "Apply crop" : "Crop")
    }

    private func autoSave(_ cg: CGImage, settings s: SettingsStore) {
        let format = s.saveFormat
        let quality = s.jpegQuality
        let folder = s.autoSaveFolder
        // Copy runs this INLINE, so a full-resolution encode plus an atomic write
        // froze the main thread in the middle of ⌘C: on a 5K shot, seconds of it,
        // right where the app was about to say "Copied". `cg` is immutable and this
        // closure keeps it alive, so the editor is free to close underneath.
        DispatchQueue.global(qos: .userInitiated).async {
            let ext = format == .png ? "png" : "jpg"
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")   // stable digits in every locale
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            // Fall back to Desktop if the chosen folder was deleted/unmounted, so a
            // capture is never silently lost.
            var dir = folder
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
            // A nil encode returned in silence: the auto-save the user switched on
            // simply never happened, and the only sign of it was a missing file
            // discovered later.
            guard let data = AnnotationRenderer.encode(cg, format: format, quality: quality) else {
                Notifier.error("Auto-save failed", "Couldn't encode that screenshot. It was not written to the auto-save folder.")
                return
            }
            do { try data.write(to: url, options: .atomic) }
            catch { Notifier.error("Auto-save failed", error.localizedDescription) }
        }
    }

    /// The picture as it stands: the frozen screen cropped to the selection with the
    /// strokes drawn in, or, once a crop/rotate/flip has happened, the flattened
    /// bitmap with whatever has been drawn on it since.
    private func compositeCG() -> CGImage? {
        guard let flat = flattened else {
            return AnnotationRenderer.composite(frozen: frozen, fullSize: bounds.size, scale: scale,
                                                selection: selection, strokes: annotations)
        }
        // Nothing drawn since the last transform → hand back the exact same bitmap.
        // A chain of rotates then costs no re-render at all, and can't resample.
        guard annotations.isEmpty == false else { return flat }
        return AnnotationRenderer.compositeFlat(base: flat, displayRect: selection, strokes: annotations)
    }

    private func playFeedback() {
        if settings?.playSound == true { Sounds.playIn() }
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
