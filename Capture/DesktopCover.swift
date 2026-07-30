import AppKit
import CoreGraphics

/// Hides everything living on the desktop — icons, a folder of old screenshots,
/// whatever was dragged there this morning — for the length of a capture.
///
/// Mechanism: a window per screen that draws that screen's CURRENT wallpaper,
/// parked one level above the desktop-icon window. The icons go; the background
/// of the shot is the same wallpaper it always was, so the capture looks
/// untouched. Sitting that low means real windows are unaffected — only the
/// desktop is covered.
///
/// Every path out of a capture MUST reach `lower()`. A cover that outlives its
/// capture hides the user's own desktop until they log out, which is far worse
/// than the feature is worth: hence `lower()` being safe to call any number of
/// times from anywhere, a ceiling on how long a cover may wait for the pixel
/// grab, and an unconditional failsafe timer under both.
enum DesktopCover {

    /// UserDefaults key behind the Settings switch. OFF unless the user asks for
    /// it: this changes what a screenshot LOOKS like, which is not a decision to
    /// make on someone's behalf.
    static let settingKey = "shot.hideDesktop"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: settingKey) }

    /// Hard ceiling on a cover's life once the only thing left to wait for is the
    /// app's own pixel grab. Reached only if a caller loses its way out of a
    /// capture — the desktop then comes back by itself.
    private static let failsafeSeconds: TimeInterval = 20

    /// Ceiling while a region-selection overlay is still on screen.
    ///
    /// That part of a capture is USER-paced: reading the centre prompt, moving a
    /// window out of the way, then dragging carefully takes longer than 20 s often
    /// enough. A flat 20 s from the moment the cover appeared fired mid-selection,
    /// popped the icons back in behind the live overlay, and left the rest of the
    /// flow uncovered — `lower(after:)` then found no windows and the frame carried
    /// the icons. The person who took the most care got exactly the shot the switch
    /// promised to prevent. A leaked overlay is still bounded, just on the scale of
    /// a person deciding rather than of a screenshot completing.
    private static let selectionCeilingSeconds: TimeInterval = 300

    private static var windows: [NSWindow] = []
    private static var failsafe: Timer?
    private static var grace: Timer?
    private static var screenChangeObserver: NSObjectProtocol?
    /// True while a selection overlay owns the cover — see `selectionCeilingSeconds`.
    private static var selecting = false
    /// Captures that still need the cover in their own frame.
    ///
    /// `CaptureService.captureScreen` drops the cover the instant it has pixels,
    /// which is right for a one-screen grab and wrong for the screenshot flow: that
    /// freezes EVERY display in a loop, so the first screen's lower uncovered
    /// screens 2..n before they were grabbed and baked the icons into every display
    /// but the first. A flow that grabs more than one frame brackets the whole loop
    /// with `hold()` / `release()`, and the per-grab lower defers to it.
    private static var holds = 0

    /// Window IDs of the live covers.
    ///
    /// ScreenCaptureKit is told to exclude every SnapDesk window from a capture
    /// so the selection overlay can't land in a shot — the cover is one of ours
    /// too, so it has to be handed back in as an exception or the frame would
    /// still contain the icons it hides on screen. See `CaptureService`.
    static var windowIDs: [CGWindowID] {
        windows.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil }
    }

    // MARK: - Raise

    /// Covers every screen whose wallpaper can be reproduced convincingly.
    ///
    /// A screen whose picture is unreadable AND whose average colour can't be
    /// sampled is left alone, and so is one whose wallpaper POSITION can't be
    /// reproduced (see `WallpaperFill.layout`): visible icons are a cosmetic
    /// annoyance, a screen painted the wrong thing is a corrupted screenshot.
    static func raise() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isEnabled else { return }

        // Already covered, because a previous capture's grace or failsafe timer is
        // still pending. The covers themselves are fine to adopt — but the pending
        // teardown belongs to a flow that is OVER and would otherwise fire in the
        // middle of this one, after which this flow's own `lower(after:)` would find
        // no windows to schedule against and the frame would carry the icons. So
        // take ownership: drop the old grace, restart the ceiling.
        if !windows.isEmpty {
            grace?.invalidate(); grace = nil
            armFailsafe()
            return
        }

        for screen in NSScreen.screens {
            guard let window = cover(for: screen) else { continue }
            window.orderFrontRegardless()
            windows.append(window)
        }
        guard !windows.isEmpty else { return }

        armFailsafe()
        // A display plugged in or resolution changed mid-selection leaves the
        // covers the wrong size on the wrong screens. Uncovering is the only
        // safe answer — a mis-sized cover is visible in the shot.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in DesktopCover.lower() }
    }

    /// True while covers are on screen. A caller that needs the window server to
    /// have composited them before it grabs pixels checks this first — there is
    /// nothing to wait for when the setting is off or every screen was declined.
    static var isRaised: Bool { !windows.isEmpty }

    /// Hold the cover open across several grabs. Balanced by `release()`; see `holds`.
    static func hold() {
        dispatchPrecondition(condition: .onQueue(.main))
        holds += 1
    }

    /// Give up a `hold()`. The last one out lowers the cover.
    static func release() {
        dispatchPrecondition(condition: .onQueue(.main))
        holds = max(0, holds - 1)
        if holds == 0 { tearDown() }
    }

    /// The overlay is up and the drag is the user's to pace: extend the ceiling
    /// until `selectionEnded()`.
    static func holdForSelection() {
        dispatchPrecondition(condition: .onQueue(.main))
        selecting = true
        guard !windows.isEmpty else { return }
        armFailsafe()
    }

    /// The overlay has come down. From here the only thing left to wait for is the
    /// app's own pixel grab, so the tight ceiling applies again.
    static func selectionEnded() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard selecting else { return }
        selecting = false
        guard !windows.isEmpty else { return }
        armFailsafe()
    }

    private static func armFailsafe() {
        failsafe?.invalidate()
        let ceiling = selecting ? selectionCeilingSeconds : failsafeSeconds
        failsafe = Timer.scheduledTimer(withTimeInterval: ceiling, repeats: false) { _ in
            DesktopCover.lower()
        }
    }

    // MARK: - Lower

    /// Unconditional teardown. Safe to call repeatedly, and from any thread.
    static func lower() {
        if Thread.isMainThread {
            tearDown()
        } else {
            DispatchQueue.main.async { tearDown() }
        }
    }

    /// Keeps the cover up a moment longer.
    ///
    /// The pixels are grabbed AFTER the selection overlay comes down, so
    /// lowering the cover at that point would put the icons straight back into
    /// the shot it exists to clean up. Whoever grabs the frame calls
    /// `lowerAfterGrab()` the instant it has it; this is only the ceiling on that
    /// wait.
    static func lower(after seconds: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !windows.isEmpty else { return }
        grace?.invalidate()
        grace = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            DesktopCover.lower()
        }
    }

    /// What a single grab calls once it has its pixels: lower, UNLESS a flow that
    /// needs more than one frame is still holding the cover open (see `holds`).
    static func lowerAfterGrab() {
        if Thread.isMainThread {
            if holds == 0 { tearDown() }
        } else {
            DispatchQueue.main.async { if holds == 0 { tearDown() } }
        }
    }

    private static func tearDown() {
        selecting = false
        failsafe?.invalidate(); failsafe = nil
        grace?.invalidate(); grace = nil
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: - One screen

    private static func cover(for screen: NSScreen) -> NSWindow? {
        let workspace = NSWorkspace.shared
        let options = workspace.desktopImageOptions(for: screen)
        let image = workspace.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }

        // A solid-colour desktop has no image to read and carries its colour in
        // the options — that IS the wallpaper, not a fallback.
        var fill = options?[.fillColor] as? NSColor
        if fill == nil, let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            fill = WallpaperFill.averageColor(of: cg)
        }
        guard image != nil || fill != nil else { return nil }

        // A picture whose desktop layout can't be reproduced is worse than no cover
        // at all: the shot would carry a background that was never on the screen.
        // A solid-colour desktop has no picture to lay out, so it is unaffected.
        var layout: WallpaperFill.Layout?
        if image != nil {
            layout = WallpaperFill.layout(
                scalingRawValue: (options?[.imageScaling] as? NSNumber)?.uintValue,
                allowsClipping: (options?[.allowClipping] as? NSNumber)?.boolValue ?? false)
            guard layout != nil else { return nil }
        }

        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = fill ?? .black
        // One level ABOVE the desktop-icon window: over the icons, still far
        // below every ordinary window (both levels are deeply negative).
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let view = WallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.image = image
        view.fill = fill
        view.layout = layout
        window.contentView = view
        return window
    }

}

// MARK: - Wallpaper drawing

/// Draws one screen's wallpaper. Everything is in POINTS — the window is sized
/// in points per screen, so a 1× display and a 2× display both come out right
/// without the view knowing which it is on.
private final class WallpaperView: NSView {
    var image: NSImage?
    var fill: NSColor?
    /// How the real desktop lays this picture in. Nil only when there is no picture
    /// — a solid-colour desktop, where the fill below IS the wallpaper.
    var layout: WallpaperFill.Layout?

    override func draw(_ dirtyRect: NSRect) {
        (fill ?? .black).setFill()
        dirtyRect.fill()
        guard let image, let layout else { return }
        // Aspect-fill overflows the view on purpose; clip so the overflow can't
        // paint outside this screen's window.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        let rect = WallpaperFill.rect(for: layout, imageSize: image.size, in: bounds)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }
}
