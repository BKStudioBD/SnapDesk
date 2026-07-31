import AppKit

/// SnapDesk's menu-bar mark. ONE icon, drawn in code as a vector template image
/// so it adapts to light and dark menu bars, stays crisp at any scale, and needs
/// no asset files.
///
/// It is the app icon reduced to monochrome: a ring of short, heavy, round-capped
/// corner brackets (capture) around a solid centre mark (the target you drag
/// over). The brackets sit on the vertices of a regular heptagon — seven corners,
/// not the four of a rectangle — which is what separates the mark from every
/// other viewfinder in a menu bar. The centre is a DIAMOND, not a dot: a dot plus
/// brackets is Apple's own `viewfinder` symbol, and at 2× (what every Retina Mac
/// actually shows) the rotated square is what makes the mark read as ours.
///
/// Every measurement is a fraction of the requested point size, so the mark is
/// resolution-independent. The detail level is deliberately low: anything finer
/// (the app icon's four-quadrant colour wheel, for instance) collapses into a
/// blob at a real 18pt menu-bar size — verified by rasterising it.
enum MenuBarIcon {

    /// How many brackets the mark is built from. Shared with the app icon
    /// generator (`tools/icon`) so the two marks can never drift apart.
    static let cornerCount = 7

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
        // The status item is an icon and nothing else, so this string IS the
        // control's name to VoiceOver — without it the menu bar holds an
        // unnamed button.
        img.accessibilityDescription = "SnapDesk"
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
        // "Recording" is carried by the colour alone otherwise, which no
        // screen reader and no colour-blind user can read.
        img.accessibilityDescription = "SnapDesk — recording"
        return img
    }

    // MARK: - The mark

    /// The bracket ring: one bracket per polygon vertex, each with a short arm
    /// running toward either neighbour and an open span between them, so the mark
    /// reads as a viewfinder rather than a filled outline.
    ///
    /// - Parameters:
    ///   - rect: The square the ring is inscribed in; the stroke stays inside it.
    ///   - corners: How many brackets to place. Defaults to the mark's seven.
    ///   - lineWidth: Stroke width, already in the rect's units.
    ///   - armRatio: Arm length as a fraction of one polygon edge. Above ~0.45 the
    ///     arms meet and the ring closes into a plain polygon.
    /// - Returns: A stroked-not-filled path, round-capped and round-joined.
    static func bracketsPath(in rect: NSRect,
                             corners: Int = cornerCount,
                             lineWidth: CGFloat,
                             armRatio: CGFloat = 0.34) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard corners >= 3 else { return path }

        // Half the stroke hangs outside the centre line, so pull the vertices in
        // by that much — otherwise the caps clip against the icon's edge.
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        // Start at the top so one bracket points straight up: a rotated ring
        // reads as a mistake, not as a design.
        let start = CGFloat.pi / 2
        let step = 2 * CGFloat.pi / CGFloat(corners)
        let vertex = { (index: Int) -> NSPoint in
            let angle = start + step * CGFloat(index)
            return NSPoint(x: centre.x + radius * cos(angle),
                           y: centre.y + radius * sin(angle))
        }
        let towards = { (from: NSPoint, to: NSPoint) -> NSPoint in
            NSPoint(x: from.x + (to.x - from.x) * armRatio,
                    y: from.y + (to.y - from.y) * armRatio)
        }

        for index in 0..<corners {
            let corner = vertex(index)
            let previous = vertex((index - 1 + corners) % corners)
            let next = vertex((index + 1) % corners)
            path.move(to: towards(corner, previous))
            path.line(to: corner)
            path.line(to: towards(corner, next))
        }
        return path
    }

    /// The centre diamond — a square on its point, so it survives as a distinct
    /// shape at 2× instead of rounding off into a dot.
    ///
    /// - Parameters:
    ///   - rect: The square the mark is drawn in.
    ///   - radius: Distance from the centre to each point of the diamond.
    /// - Returns: A closed path meant to be filled.
    static func centrePath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x, y: c.y + radius))
        path.line(to: NSPoint(x: c.x + radius, y: c.y))
        path.line(to: NSPoint(x: c.x, y: c.y - radius))
        path.line(to: NSPoint(x: c.x - radius, y: c.y))
        path.close()
        return path
    }

    private static func drawBrackets(in rect: NSRect) {
        let unit = rect.width
        // Seven brackets divide the ring into much shorter edges than four did,
        // so both the stroke and the arms have to come DOWN: at the old weights
        // the round caps met in the middle of every edge and the mark rasterised
        // as a solid ring at a real 18pt menu-bar size — checked on the proof
        // sheet ./make-icon.sh writes.
        bracketsPath(in: rect.insetBy(dx: unit * 0.05, dy: unit * 0.05),
                     lineWidth: unit * 0.066,
                     armRatio: 0.30).stroke()
    }

    private static func drawCentre(in rect: NSRect) {
        centrePath(in: rect, radius: rect.width * 0.11).fill()
    }
}
