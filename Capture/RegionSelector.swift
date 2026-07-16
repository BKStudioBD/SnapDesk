import AppKit

/// The result of a region drag: which screen it happened on and the rectangle
/// in that screen's *local* coordinate space (top-left origin, in points).
/// Keeping everything relative to a single screen avoids global multi-monitor
/// coordinate-flip headaches when we later capture & crop.
struct RegionSelection {
    let screen: NSScreen
    /// Top-left origin, in points, relative to `screen`.
    let rectInScreenPoints: CGRect
}

/// Presents a dimmed full-screen overlay on every display and lets the user drag
/// out a rectangle. Calls back with the selection, or `nil` if cancelled (Esc).
enum RegionSelector {
    /// Big centered overlay text + full-screen button,
    /// shown until the user starts dragging. Nil → small bottom hint pill.
    struct CenterPrompt {
        let title: String
        let subtitle: String
        let buttonTitle: String
    }

    /// How the overlay shades the screen while selecting.
    enum DimStyle {
        /// Whole screen dims, the dragged area punches through bright.
        case full
        /// Screen stays untouched; ONLY the dragged area gets a dark tint (OCR).
        case selectionOnly
    }

    // Holds the overlay windows alive for the duration of the selection.
    private static var session: Session?

    static func selectRegion(prompt: CenterPrompt? = nil,
                             dim: DimStyle = .full,
                             completion: @escaping (RegionSelection?) -> Void) {
        // Re-trigger while an overlay is already up → tear the stale one down
        // and start fresh. Silently swallowing the hotkey here left users with
        // a "sometimes it just doesn't work" dead press when an (invisible,
        // selection-only) overlay was still alive from a previous attempt.
        dispatchPrecondition(condition: .onQueue(.main))
        // Never open a capture overlay above a modal alert (e.g. the permission
        // "Restart SnapDesk" dialog) — the screen-level overlay would cover the
        // alert and eat every click while the modal session ignores them.
        guard NSApp.modalWindow == nil else { completion(nil); return }
        if let stale = session {
            session = nil
            stale.cancel()
        }
        session = Session(prompt: prompt, dim: dim, completion: { result in
            session = nil
            completion(result)
        })
        session?.begin()
    }

    // MARK: - Session

    private final class Session {
        private let completion: (RegionSelection?) -> Void
        private let prompt: CenterPrompt?
        private let dim: DimStyle
        private var windows: [SelectionWindow] = []

        init(prompt: CenterPrompt?, dim: DimStyle, completion: @escaping (RegionSelection?) -> Void) {
            self.prompt = prompt
            self.dim = dim
            self.completion = completion
        }

        func begin() {
            for screen in NSScreen.screens {
                let window = SelectionWindow(screen: screen, prompt: prompt, dim: dim)
                window.onFinish = { [weak self] rect in
                    self?.finish(screen: screen, rect: rect)
                }
                window.onCancel = { [weak self] in self?.finish(screen: nil, rect: nil) }
                window.onFull = { [weak self] in self?.finishFullScreen() }
                window.orderFrontRegardless()
                windows.append(window)
            }
            // Make key the overlay on the screen the mouse is on — NOT the last
            // one ordered (crosshair cursor rects and Esc only work in the key
            // window). Non-activating panel: key without stealing app focus, and
            // immune to macOS's cooperative-activation denial (which used to
            // leave NO key window → dead Esc, no crosshair → "hotkey did nothing").
            let mouse = NSEvent.mouseLocation
            let target = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
            target?.makeKeyAndOrderFront(nil)
        }

        /// Tear down the overlays and report "no selection" (stale-session reset).
        func cancel() { finish(screen: nil, rect: nil) }

        /// F pressed → select the ENTIRE screen the mouse is currently on.
        private func finishFullScreen() {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen else { finish(screen: nil, rect: nil); return }
            finish(screen: screen,
                   rect: CGRect(origin: .zero, size: screen.frame.size))
        }

        private func finish(screen: NSScreen?, rect: CGRect?) {
            // Tear down every overlay.
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()

            if let screen, let rect, rect.width > 2, rect.height > 2 {
                completion(RegionSelection(screen: screen, rectInScreenPoints: rect))
            } else {
                completion(nil)
            }
        }
    }
}

// MARK: - Overlay window

// NSPanel + .nonactivatingPanel: becomes key WITHOUT activating SnapDesk —
// an accessory app's NSApp.activate() can be silently denied by macOS 14+
// (no recent user interaction), which left a plain NSWindow overlay with no
// key window at all: no crosshair, dead Esc, "the hotkey did nothing".
private final class SelectionWindow: NSPanel {
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onFull: (() -> Void)?

    private let screenRef: NSScreen

    init(screen: NSScreen, prompt: RegionSelector.CenterPrompt?,
         dim: RegionSelector.DimStyle = .full) {
        self.screenRef = screen
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false        // NSPanel default is true — overlay must survive
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = SelectionView(frame: screen.frame)
        view.prompt = prompt
        view.dimStyle = dim
        view.onFinish = { [weak self] rectInView in
            guard let self else { return }
            // Convert view rect (bottom-left origin) -> screen-local top-left.
            let h = self.screenRef.frame.height
            let local = CGRect(x: rectInView.minX,
                               y: h - rectInView.maxY,
                               width: rectInView.width,
                               height: rectInView.height)
            self.onFinish?(local)
        }
        view.onCancel = { [weak self] in self?.onCancel?() }
        view.onFull = { [weak self] in self?.onFull?() }
        contentView = view
        // Without this the WINDOW is first responder and Esc/F pressed before
        // the first click are silently discarded (the invisible OCR overlay
        // then stays up eating clicks — "sometimes it just doesn't work").
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - Drawing view

private final class SelectionView: NSView {
    var onFinish: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onFull: (() -> Void)?
    var prompt: RegionSelector.CenterPrompt?
    var dimStyle: RegionSelector.DimStyle = .full

    private var startPoint: NSPoint?
    private var currentRect: CGRect = .zero
    /// Hit area of the full-screen button while the center prompt is up.
    private var buttonRect: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }
    // First click starts the drag immediately even if the overlay just appeared
    // and isn't the active window yet — no "click once to focus" dead click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Multi-display: cursor rects (crosshair) and Esc only live in the KEY
    // window. Follow the mouse — whichever screen's overlay it enters grabs
    // key (cheap for a non-activating panel, no app focus change).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        if window?.isKeyWindow == false { window?.makeKey() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        // Over the full-screen button: clickable hand, not the drag crosshair.
        if prompt != nil, startPoint == nil, currentRect.width <= 0, buttonRect != .zero {
            addCursorRect(buttonRect, cursor: .pointingHand)
        }
    }

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        // Reset the dirty area to fully transparent FIRST — without this, moving
        // the selection leaves stale dim/clear pixels behind ("black patches"
        // that break up during the drag).
        NSColor.clear.set()
        dirtyRect.fill(using: .copy)

        // Full-screen dim: the whole screen darkens…
        // (.selectionOnly — OCR — leaves the screen untouched instead.)
        if dimStyle == .full {
            NSColor.snapDim.setFill()
            bounds.fill(using: .sourceOver)
        } else {
            // The window server routes clicks THROUGH fully transparent pixels
            // of a borderless window — an all-clear overlay shows the crosshair
            // but the mouseDown lands in the app underneath and the drag never
            // starts. A ~1% fill is invisible yet makes every pixel hit-testable.
            // FLOOR: must stay ≥ 0.01 — alpha quantizes to an 8-bit byte and
            // anything that rounds to 0/255 silently becomes click-through again
            // (0.001 fails, 0.015 ≈ 4/255 verified working).
            NSColor.black.withAlphaComponent(0.015).setFill()
            bounds.fill(using: .sourceOver)
        }

        guard currentRect.width > 0, currentRect.height > 0 else {
            // Hide the prompt the moment a drag starts.
            if startPoint == nil {
                if prompt != nil { drawCenterPrompt() } else { drawHint() }
            }
            return
        }

        if dimStyle == .full {
            // …and the dragged selection is punched fully clear (bright desktop).
            NSColor.clear.set()
            currentRect.fill(using: .copy)
        } else {
            // selectionOnly: ONLY the dragged area darkens — screen stays live.
            NSColor.snapTint.setFill()
            currentRect.fill(using: .sourceOver)
        }

        // High-contrast border: white hairline outside + accent line.
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let outer = NSBezierPath(rect: currentRect.insetBy(dx: -1, dy: -1))
        outer.lineWidth = 1; outer.stroke()
        let border = NSBezierPath(rect: currentRect)
        border.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        // Size label.
        let label = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let bg = CGRect(x: currentRect.minX,
                        y: max(0, currentRect.minY - size.height - 6),
                        width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
        label.draw(at: CGPoint(x: bg.minX + 5, y: bg.minY + 2), withAttributes: attrs)
    }

    private func drawHint() {
        let text = "Drag to select   ·   F = full screen   ·   Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white]
        let sz = text.size(withAttributes: attrs)
        let pad: CGFloat = 12
        let box = NSRect(x: bounds.midX - (sz.width + pad * 2) / 2, y: 38,
                         width: sz.width + pad * 2, height: sz.height + 10)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
        text.draw(at: CGPoint(x: box.minX + pad, y: box.minY + 5), withAttributes: attrs)
    }

    /// Centered overlay: big title, subtitle, a full-screen
    /// button and the Esc hint. Drawn only before the first drag.
    private func drawCenterPrompt() {
        guard let prompt else { return }
        let cx = bounds.midX, cy = bounds.midY

        func draw(_ text: String, _ font: NSFont, _ color: NSColor, y: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let sz = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: cx - sz.width / 2, y: y), withAttributes: attrs)
        }

        draw(prompt.title, .systemFont(ofSize: 52, weight: .heavy), .white, y: cy + 92)
        draw(prompt.subtitle, .systemFont(ofSize: 24, weight: .semibold),
             NSColor(white: 0.72, alpha: 1), y: cy + 52)
        draw("or", .systemFont(ofSize: 14, weight: .bold),
             NSColor(white: 0.6, alpha: 1), y: cy + 16)

        // Full-screen button.
        let bFont = NSFont.systemFont(ofSize: 17, weight: .bold)
        let bAttrs: [NSAttributedString.Key: Any] = [.font: bFont, .foregroundColor: NSColor.white]
        let bSize = prompt.buttonTitle.size(withAttributes: bAttrs)
        let bw = bSize.width + 64, bh: CGFloat = 52
        let newRect = CGRect(x: cx - bw / 2, y: cy - 48 - bh / 2, width: bw, height: bh)
        if newRect != buttonRect {
            buttonRect = newRect
            window?.invalidateCursorRects(for: self)   // hand cursor over the button
        }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: buttonRect, xRadius: 12, yRadius: 12).fill()
        prompt.buttonTitle.draw(at: CGPoint(x: buttonRect.midX - bSize.width / 2,
                                            y: buttonRect.midY - bSize.height / 2),
                                withAttributes: bAttrs)

        draw("Press ESC to cancel", .systemFont(ofSize: 14, weight: .semibold),
             NSColor(white: 0.6, alpha: 1), y: buttonRect.minY - 42)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Center prompt up + click on the button → record the whole screen.
        if prompt != nil, startPoint == nil, currentRect.width <= 0, buttonRect.contains(p) {
            onFull?()
            return
        }
        startPoint = p
        currentRect = .zero
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = currentRect
        startPoint = nil
        currentRect = .zero
        needsDisplay = true
        // A stray click (no real drag) must NOT cancel the whole flow — the
        // session stays alive; Esc is the explicit cancel.
        guard rect.width > 2, rect.height > 2 else {
            window?.invalidateCursorRects(for: self)
            return
        }
        onFinish?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            onCancel?()
        } else if event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFull?()   // select the whole screen the mouse is on
        }
    }
}
