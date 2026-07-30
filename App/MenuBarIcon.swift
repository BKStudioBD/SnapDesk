import AppKit

/// SnapDesk's menu-bar mark. ONE icon, drawn in code as a vector template image
/// so it adapts to light and dark menu bars, stays crisp at any scale, and needs
/// no asset files.
///
/// It is the app icon reduced to monochrome: four short, heavy, round-capped
/// corner brackets (capture) around a solid centre mark (the target you drag
/// over). The centre is a DIAMOND, not a dot — a dot plus brackets is Apple's own
/// `viewfinder` symbol, and at 2× (what every Retina Mac actually shows) the
/// rotated square is what makes the mark read as ours.
///
/// Every measurement is a fraction of the requested point size, so the mark is
/// resolution-independent. The detail level is deliberately low: anything finer
/// (the app icon's four-quadrant colour wheel, for instance) collapses into a
/// blob at a real 18pt menu-bar size — verified by rasterising it.
enum MenuBarIcon {
    static func image(pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            drawBrackets(in: rect)
            drawCentre(in: rect)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Solid red dot shown in the menu bar while a recording is in progress.
    /// Not a style — a state, which is why it lives alongside the one mark.
    static func recordingImage(pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28)).fill()
            return true
        }
        img.isTemplate = false   // keep it red, not a template tint
        return img
    }

    // MARK: - The mark

    /// Four corner brackets. Short arms and an open middle so the mark reads as a
    /// viewfinder rather than a filled box; round caps to match the app icon.
    private static func drawBrackets(in rect: NSRect) {
        let unit = rect.width
        let frame = rect.insetBy(dx: unit * 0.11, dy: unit * 0.11)
        let arm = frame.width * 0.33
        let path = NSBezierPath()
        path.lineWidth = unit * 0.085          // ≈1.5pt at 18pt
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // top-left
        path.move(to: NSPoint(x: frame.minX, y: frame.maxY - arm))
        path.line(to: NSPoint(x: frame.minX, y: frame.maxY))
        path.line(to: NSPoint(x: frame.minX + arm, y: frame.maxY))
        // top-right
        path.move(to: NSPoint(x: frame.maxX - arm, y: frame.maxY))
        path.line(to: NSPoint(x: frame.maxX, y: frame.maxY))
        path.line(to: NSPoint(x: frame.maxX, y: frame.maxY - arm))
        // bottom-right
        path.move(to: NSPoint(x: frame.maxX, y: frame.minY + arm))
        path.line(to: NSPoint(x: frame.maxX, y: frame.minY))
        path.line(to: NSPoint(x: frame.maxX - arm, y: frame.minY))
        // bottom-left
        path.move(to: NSPoint(x: frame.minX + arm, y: frame.minY))
        path.line(to: NSPoint(x: frame.minX, y: frame.minY))
        path.line(to: NSPoint(x: frame.minX, y: frame.minY + arm))
        path.stroke()
    }

    /// The centre diamond — a square on its point, so it survives as a distinct
    /// shape at 2× instead of rounding off into a dot.
    private static func drawCentre(in rect: NSRect) {
        let r = rect.width * 0.11
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x, y: c.y + r))
        path.line(to: NSPoint(x: c.x + r, y: c.y))
        path.line(to: NSPoint(x: c.x, y: c.y - r))
        path.line(to: NSPoint(x: c.x - r, y: c.y))
        path.close()
        path.fill()
    }
}
