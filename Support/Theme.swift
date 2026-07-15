import AppKit

/// SnapDesk's shared overlay tint. A pure-black dim reads flat/harsh; this is
/// a deep charcoal with a cool blue cast (a calm, premium look for
/// overlays) — dark enough to focus the selection, soft enough to feel calm.
extension NSColor {
    /// Base dim for full-screen overlays (selection, editor, scroll spotlight).
    static let snapDim = NSColor(srgbRed: 0.043, green: 0.055, blue: 0.106, alpha: 0.52)
    /// Lighter tint for marking a selected region on an otherwise live screen.
    static let snapTint = NSColor(srgbRed: 0.043, green: 0.055, blue: 0.106, alpha: 0.34)
}

/// Reusable "spotlight" overlay: dims the ENTIRE screen with `snapDim` except a
/// punched-out live hole, with a colored border around the hole. Click-through,
/// and (like every SnapDesk window) excluded from captures/recordings.
enum SpotlightOverlay {
    static func window(around globalRect: NSRect, on screen: NSScreen,
                       border: NSColor) -> NSWindow {
        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.level = .statusBar
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = SpotlightView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.hole = NSRect(x: globalRect.minX - screen.frame.minX,
                        y: globalRect.minY - screen.frame.minY,
                        width: globalRect.width, height: globalRect.height)
        v.borderColor = border
        win.contentView = v
        return win
    }

    private final class SpotlightView: NSView {
        var hole: NSRect = .zero
        var borderColor: NSColor = .controlAccentColor
        override func draw(_ dirtyRect: NSRect) {
            NSColor.snapDim.setFill()
            NSRect(x: 0, y: hole.maxY, width: bounds.width,
                   height: max(0, bounds.maxY - hole.maxY)).fill()
            NSRect(x: 0, y: 0, width: bounds.width, height: max(0, hole.minY)).fill()
            NSRect(x: 0, y: hole.minY, width: max(0, hole.minX), height: hole.height).fill()
            NSRect(x: hole.maxX, y: hole.minY, width: max(0, bounds.maxX - hole.maxX),
                   height: hole.height).fill()
            borderColor.setStroke()
            let p = NSBezierPath(roundedRect: hole.insetBy(dx: -1, dy: -1), xRadius: 4, yRadius: 4)
            p.lineWidth = 2
            p.stroke()
        }
    }
}
