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
        // "Restart SnapDesk" dialog). The screen-level overlay would cover the
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
        private var monitors: [Any] = []
        /// The view currently receiving a drag (set on the first mouseDown).
        private weak var activeView: SelectionView?

        init(prompt: CenterPrompt?, dim: DimStyle, completion: @escaping (RegionSelection?) -> Void) {
            self.prompt = prompt
            self.dim = dim
            self.completion = completion
        }

        func begin() {
            // Icons off the desktop BEFORE the overlay appears, so they never
            // blink away underneath the dim (and never reach a shot).
            DesktopCover.raise()
            // From here the clock belongs to the USER: reading the prompt, moving a
            // window out of the way, then dragging carefully. Hold the cover open
            // for as long as the overlay is up, or the app's own 20 s ceiling fires
            // mid-selection and the icons reappear behind a live overlay.
            DesktopCover.holdForSelection()
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
            // Make key the overlay on the screen the mouse is on, NOT the last
            // one ordered (crosshair cursor rects and Esc only work in the key
            // window). Non-activating panel: key without stealing app focus, and
            // immune to macOS's cooperative-activation denial (which used to
            // leave NO key window → dead Esc, no crosshair → "hotkey did nothing").
            let mouse = NSEvent.mouseLocation
            let target = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
            target?.makeKeyAndOrderFront(nil)
            installMonitors()
            // Become the active app: the active app owns the pointer, so this
            // makes the SYSTEM crosshair below take effect immediately and
            // reliably (a background app's cursor request can be ignored).
            NSApp.activate(ignoringOtherApps: true)
            NSCursor.crosshair.set()
        }

        /// The selection is driven by EVENT MONITORS, not per-window mouse
        /// routing. The window server can route a click through/past a freshly
        /// ordered transparent overlay (registration takes a beat; hit-testing
        /// is pixel-alpha based), with monitors the very first click after the
        /// hotkey ALWAYS starts the drag, no matter which window macOS picked.
        private func installMonitors() {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            // Normal path: the event reached one of our overlay windows. Swallow
            // it (return nil). The view no longer handles mouse events itself.
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
                guard let self, let w = e.window as? SelectionWindow else { return e }
                self.route(e, at: w.convertPoint(toScreen: e.locationInWindow))
                return nil
            }) { monitors.append(m) }
            // Rescue path: macOS routed the click to ANOTHER app (pass-through).
            // Can't consume it, but the selection still tracks perfectly.
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
                // With no window attached, locationInWindow IS screen coordinates.
                self?.route(e, at: e.window == nil ? e.locationInWindow : NSEvent.mouseLocation)
            }) { monitors.append(m) }
            // Esc / arrows / Return / F from ANY of our windows, even if the
            // overlay lost key.
            if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
                guard let self else { return e }
                if e.keyCode == OverlayKey.escape { self.finish(screen: nil, rect: nil); return nil }
                // Arrows and Return steer whichever view owns a selection.
                if let view = self.keyView, view.handleKey(e) { return nil }
                if e.isPlainF { self.finishFullScreen(); return nil }
                return e
            }) { monitors.append(m) }
        }

        /// The view a key press should steer: the one being dragged, else the one
        /// holding a selection the arrows have taken over, else the one under the
        /// mouse. Without the middle case the arrow keys would go dead the moment
        /// the mouse button came up, which is exactly when they're wanted.
        private var keyView: SelectionView? {
            if let activeView { return activeView }
            let views = windows.compactMap { $0.contentView as? SelectionView }
            if let waiting = views.first(where: { $0.isAwaitingConfirmation }) { return waiting }
            let mouse = NSEvent.mouseLocation
            return windows.first { NSMouseInRect(mouse, $0.frame, false) }?
                .contentView as? SelectionView
        }

        /// Feed a mouse event (screen coordinates) to the right overlay view.
        private func route(_ e: NSEvent, at screenPoint: NSPoint) {
            switch e.type {
            case .leftMouseDown:
                guard activeView == nil,   // one drag at a time (local+global can't double-fire, but be safe)
                      let win = windows.first(where: { NSMouseInRect(screenPoint, $0.frame, false) }),
                      let view = win.contentView as? SelectionView else { return }
                // Starting a drag abandons a keyboard-latched selection left on
                // another display, so only one selection is ever on screen.
                let views = windows.compactMap { $0.contentView as? SelectionView }
                for other in views where other !== view { other.clearPending() }
                activeView = view
                view.beginDrag(at: viewPoint(screenPoint, in: win))
            case .leftMouseDragged:
                guard let view = activeView, let win = view.window else { return }
                view.updateDrag(to: viewPoint(screenPoint, in: win))
            case .leftMouseUp:
                guard let view = activeView, let win = view.window else { return }
                activeView = nil
                view.endDrag(at: viewPoint(screenPoint, in: win))
            default:
                break
            }
        }

        private func viewPoint(_ screenPoint: NSPoint, in window: NSWindow) -> NSPoint {
            let winPoint = window.convertPoint(fromScreen: screenPoint)
            return window.contentView?.convert(winPoint, from: nil) ?? winPoint
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
            // Tear down the monitors first, then every overlay.
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            activeView = nil
            windows.forEach { $0.orderOut(nil) }
            windows.removeAll()

            // The overlay is gone, so the user-paced part is over and the tight
            // ceiling applies again from here.
            DesktopCover.selectionEnded()
            if let screen, let rect, rect.width > 2, rect.height > 2 {
                // The pixels are grabbed AFTER this returns, so the desktop cover
                // has to outlive the callback: CaptureService drops it the
                // instant it has the frame, and this is only the ceiling.
                DesktopCover.lower(after: 3)
                completion(RegionSelection(screen: screen, rectInScreenPoints: rect))
            } else {
                DesktopCover.lower()
                completion(nil)
            }
        }
    }
}

// MARK: - Overlay window

// NSPanel + .nonactivatingPanel becomes key WITHOUT activating SnapDesk, and
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
        hidesOnDeactivate = false        // NSPanel default is true; the overlay must survive
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = SelectionView(frame: screen.frame)
        view.prompt = prompt
        view.dimStyle = dim
        view.onFinish = { [weak self] rectInView in
            guard let self else { return }
            // View rect (bottom-left origin) -> screen-local top-left.
            self.onFinish?(SelectionGeometry.flipped(rectInView,
                                                    inHeight: self.screenRef.frame.height))
        }
        view.onCancel = { [weak self] in self?.onCancel?() }
        view.onFull = { [weak self] in self?.onFull?() }
        contentView = view
        // Without this the WINDOW is first responder and Esc/F pressed before
        // the first click are silently discarded (the invisible OCR overlay
        // then stays up eating clicks: "sometimes it just doesn't work").
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
    /// Last pointer position in view coords; the readout keeps clear of it.
    private var pointer: NSPoint?
    /// Set by the first arrow key: the selection belongs to the keyboard now, so
    /// the mouse stops moving it and only Return captures it. A drag cannot land
    /// on a chosen pixel, so this is the only route to an exact rectangle.
    private var keyboardDriven = false
    /// Where the readout was drawn last, so a shrinking selection also
    /// invalidates the pixels the chip has just left behind. `.null` rather than
    /// `.zero`: a union with `.zero` would drag the origin into every dirty rect.
    private var lastReadout: CGRect = .null

    /// A selection the arrow keys have taken over, waiting for Return.
    var isAwaitingConfirmation: Bool {
        keyboardDriven && currentRect.width > 0 && currentRect.height > 0
    }

    override var acceptsFirstResponder: Bool { true }
    // First click starts the drag immediately even if the overlay just appeared
    // and isn't the active window yet, no "click once to focus" dead click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Multi-display: cursor rects (crosshair) and Esc only live in the KEY
    // window. Follow the mouse: whichever screen's overlay it enters grabs
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



    // Renders via draw(_:). The .copy clear there is load-bearing; do not
    // switch this view to updateLayer.

    override func draw(_ dirtyRect: NSRect) {
        // Reset the dirty area to fully transparent FIRST, without this, moving
        // the selection leaves stale dim/clear pixels behind ("black patches"
        // that break up during the drag).
        NSColor.clear.set()
        dirtyRect.fill(using: .copy)

        // Full-screen dim: the whole screen darkens…
        // (.selectionOnly, OCR, leaves the screen untouched instead.)
        if dimStyle == .full {
            NSColor.snapDim.setFill()
            bounds.fill(using: .sourceOver)
        } else {
            // The window server routes clicks THROUGH fully transparent pixels
            // of a borderless window: an all-clear overlay shows the crosshair
            // but the mouseDown lands in the app underneath and the drag never
            // starts. A ~1% fill is invisible yet makes every pixel hit-testable.
            // FLOOR: must stay ≥ 0.01: alpha quantizes to an 8-bit byte and
            // anything that rounds to 0/255 silently becomes click-through again
            // (0.001 fails, 0.015 ≈ 4/255 verified working).
            NSColor.black.withAlphaComponent(0.015).setFill()
            bounds.fill(using: .sourceOver)
        }

        guard currentRect.width > 0, currentRect.height > 0 else {
            // Hide the prompt the moment a drag starts.
            if startPoint == nil {
                if prompt != nil { drawCenterPrompt() } else { drawHint(Self.dragHint) }
            }
            return
        }

        if dimStyle == .full {
            // …and the dragged selection is punched fully clear (bright desktop).
            NSColor.clear.set()
            currentRect.fill(using: .copy)
        } else {
            // selectionOnly darkens ONLY the dragged area; the screen stays live.
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

        drawReadout(for: currentRect)
        // Only once the keyboard is in charge: before that the hint is noise on
        // top of a live drag.
        if keyboardDriven { drawHint(Self.adjustHint) }
    }

    /// Live size readout pinned to the selection: points always, plus pixels on a
    /// Retina display, because someone filing a bug about a 2× asset needs the
    /// pixel figure.
    private func drawReadout(for rect: CGRect) {
        let scale = window?.screen?.backingScaleFactor ?? 1
        let (points, pixels) = SelectionGeometry.readoutText(for: rect, scale: scale)
        // Monospaced digits: with proportional ones the chip breathed wider and
        // narrower as the numbers changed, and the whole point of a live readout
        // is that it sits still while you aim.
        let text = NSMutableAttributedString(
            string: points,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                         .foregroundColor: NSColor.white])
        if let pixels {
            text.append(NSAttributedString(
                string: "  " + pixels,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                             // 7.9:1 on the chip: quieter than the point figure,
                             // still well clear of the 4.5:1 floor.
                             .foregroundColor: NSColor(white: 0.72, alpha: 1)]))
        }
        let textSize = text.size()
        let chipSize = CGSize(width: ceil(textSize.width) + 14, height: ceil(textSize.height) + 6)
        // Box around the pointer the chip must dodge: the crosshair's own hot
        // zone with room for a loupe drawn beside it.
        let pointerZone = pointer.map { CGRect(x: $0.x - 64, y: $0.y - 64, width: 128, height: 128) }
        let layout = SelectionGeometry.readout(size: chipSize, selection: rect,
                                               container: bounds,
                                               avoiding: pointerZone ?? .null)
        lastReadout = layout.frame

        let chip = NSBezierPath(roundedRect: layout.frame, xRadius: 5, yRadius: 5)
        // Near-opaque charcoal: 15.8:1 for the point figure over a WHITE
        // wallpaper, and the hairline keeps the chip's own edge visible over a
        // black one. Both are real desktops.
        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 0.92).setFill()
        chip.fill()
        NSColor(white: 1, alpha: 0.18).setStroke()
        chip.lineWidth = 1
        chip.stroke()
        text.draw(at: CGPoint(x: layout.frame.minX + 7, y: layout.frame.minY + 3))
    }

    /// "before you let go" is load-bearing, not padding: mouse-up on a real drag
    /// captures immediately, so the arrows are reachable only while the button is
    /// still down (the first arrow press latches the selection, and Return then
    /// captures it). The old wording promised drag-then-fine-tune, which cannot be
    /// done: people released the button to reach the arrow keys and the capture had
    /// already fired with the imprecise rect, every time.
    private static let dragHint =
        "Drag to select   ·   Arrows fine-tune before you let go   ·   F = full screen   ·   Esc to cancel"
    private static let adjustHint =
        "Arrows move   ·   ⌥ arrows resize   ·   Shift = 10 pt   ·   ⏎ capture   ·   Esc cancel"

    private func drawHint(_ text: String) {
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

    // Mouse input arrives from the Session's event monitors (NOT AppKit window
    // routing: see installMonitors) so the first click always registers, even
    // when the window server hasn't hit-tested the fresh overlay yet.

    func beginDrag(at p: NSPoint) {
        // Center prompt up + click on the button → record the whole screen.
        if prompt != nil, startPoint == nil, currentRect.width <= 0, buttonRect.contains(p) {
            onFull?()
            return
        }
        startPoint = p
        pointer = p
        currentRect = .zero
        // A fresh drag hands the selection back to the mouse.
        keyboardDriven = false
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func updateDrag(to p: NSPoint) {
        // A latched selection belongs to the arrow keys: a mouse still moving
        // (or still held) must not drag it back out from under them.
        guard !keyboardDriven, let start = startPoint else { return }
        pointer = p
        let old = currentRect
        currentRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y))
            .intersection(bounds)   // clamp to this screen
        // Invalidate only around old ∪ new (covers grow AND shrink re-dim) plus
        // the readout's last frame and margin for the border overhang and a chip
        // that flipped or slid along an edge: full-screen invalidation redrew
        // the entire display every mouse move.
        setNeedsDisplay(old.union(currentRect).union(lastReadout).insetBy(dx: -220, dy: -44))
    }

    func endDrag(at p: NSPoint) {
        // Arrows have taken over: releasing must not snap the rect back to the
        // mouse, and must not capture: Return does that now.
        guard !keyboardDriven else { startPoint = nil; return }
        updateDrag(to: p)
        let rect = currentRect
        // A stray click (no real drag) must NOT cancel the whole flow. The
        // session stays alive; Esc is the explicit cancel.
        guard rect.width > 2, rect.height > 2 else {
            reset()
            window?.invalidateCursorRects(for: self)
            return
        }
        confirm(rect)
    }

    /// Hand the selection over and clear the view, whether the mouse or Return
    /// finished it.
    private func confirm(_ rect: CGRect) {
        reset()
        onFinish?(rect)
    }

    /// Drop a selection this view is still holding, because a drag on another
    /// display owns the flow now. Without this a keyboard-latched selection stays
    /// drawn on the first screen while a second one is being dragged, two
    /// selections on screen, one of them a lie.
    func clearPending() {
        guard startPoint != nil || currentRect.width > 0 else { return }
        reset()
    }

    private func reset() {
        startPoint = nil
        currentRect = .zero
        keyboardDriven = false
        lastReadout = .null
        needsDisplay = true
    }

    /// Arrow keys and Return. Returns true when the key was consumed.
    ///
    /// Arrows move by 1 pt, 10 pt with Shift; with Option they resize from the
    /// bottom-right corner instead, so the corner travels the way the arrow
    /// points. The first arrow press latches the selection (`keyboardDriven`),
    /// which is how the keyboard and an in-flight drag stay out of each other's
    /// way: from that press on the mouse no longer touches the rect, and the
    /// button coming up neither moves nor captures it.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case OverlayKey.left, OverlayKey.right, OverlayKey.down, OverlayKey.up:
            guard currentRect.width > 0, currentRect.height > 0 else { return false }
            // Anything beyond Shift+Option is somebody else's shortcut.
            guard flags.subtracting([.shift, .option]).isEmpty else { return false }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch event.keyCode {
            case OverlayKey.left:  dx = -step
            case OverlayKey.right: dx = step
            case OverlayKey.down:  dy = -step
            default:               dy = step
            }
            keyboardDriven = true
            currentRect = flags.contains(.option)
                ? SelectionGeometry.resized(currentRect, dx: dx, dy: dy, in: bounds)
                : SelectionGeometry.nudged(currentRect, dx: dx, dy: dy, in: bounds)
            // Whole-view redraw on purpose: this is a key press, not a 60 Hz
            // drag, and the hint pill appearing is a change nowhere near the
            // selection.
            needsDisplay = true
            return true
        case OverlayKey.enter, OverlayKey.keypadEnter:
            guard flags.isEmpty, currentRect.width > 2, currentRect.height > 2 else { return false }
            confirm(currentRect)
            return true
        default:
            return false
        }
    }

    // Fallback + beep suppression: the Session's local keyDown monitor
    // normally consumes Esc/F before dispatch, so this fires only if that
    // monitor failed to install. It must also stay to swallow every OTHER
    // key, without the override, stray keypresses while the overlay is up
    // reach noResponderFor(_:) and trigger the system beep.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == OverlayKey.escape {
            onCancel?()
        } else if handleKey(event) {
            return
        } else if event.isPlainF {
            onFull?()   // select the whole screen the mouse is on
        }
    }
}

// MARK: - Keys

/// Virtual key codes the overlay reads. Raw values rather than importing Carbon
/// for five constants.
private enum OverlayKey {
    static let enter: UInt16 = 36
    static let escape: UInt16 = 53
    static let keypadEnter: UInt16 = 76
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

private extension NSEvent {
    /// F with NO modifiers. Bare `charactersIgnoringModifiers == "f"` also
    /// matched ⌘F / ⌃F / ⌥F, so a reflex "find" shortcut over the overlay
    /// silently captured the entire screen.
    var isPlainF: Bool {
        charactersIgnoringModifiers?.lowercased() == "f"
            && modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    }
}
