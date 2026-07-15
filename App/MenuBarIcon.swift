import AppKit

/// Selectable menu-bar icon look. Stored in settings; all drawn as vector
/// template images so they adapt to light/dark menu bars with zero asset files.
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case snap = "Snap"            // viewfinder + scissor notch (default, distinctive)
    case viewfinder = "Viewfinder"
    case camera = "Camera"
    case crosshair = "Crosshair"

    var id: String { rawValue }
}

/// Crisp, vector-drawn menu-bar icons. Template images → adapt to light/dark
/// automatically. Cheap to draw, no asset files needed.
enum MenuBarIcon {
    static func image(style: MenuBarIconStyle = .snap, pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            switch style {
            case .snap:       drawSnap(in: rect)
            case .viewfinder: drawViewfinder(in: rect)
            case .camera:     drawCamera(in: rect)
            case .crosshair:  drawCrosshair(in: rect)
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Solid red dot shown in the menu bar while a recording is in progress.
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

    // MARK: - Variants

    /// Viewfinder brackets with a small diagonal "snip" mark — SnapDesk's mark.
    private static func drawSnap(in rect: NSRect) {
        let inset = rect.insetBy(dx: 2, dy: 2)
        drawBrackets(in: inset, lineWidth: 1.6)
        // Center "snip": two short diagonal strokes forming an open scissor tip.
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let r = inset.width * 0.16
        let p = NSBezierPath()
        p.lineWidth = 1.6
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: c.x - r, y: c.y - r)); p.line(to: NSPoint(x: c.x + r, y: c.y + r))
        p.move(to: NSPoint(x: c.x - r, y: c.y + r)); p.line(to: NSPoint(x: c.x + r, y: c.y - r))
        p.stroke()
    }

    private static func drawViewfinder(in rect: NSRect) {
        let inset = rect.insetBy(dx: 2, dy: 2)
        drawBrackets(in: inset, lineWidth: 1.6)
        let dotR = inset.width * 0.13
        let d = NSRect(x: rect.midX - dotR, y: rect.midY - dotR, width: dotR * 2, height: dotR * 2)
        NSBezierPath(ovalIn: d).fill()
    }

    private static func drawCamera(in rect: NSRect) {
        let body = rect.insetBy(dx: 2, dy: 3.5)
        let path = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        path.stroke()
        // Little viewfinder bump on top.
        let bump = NSRect(x: rect.midX - 3, y: body.maxY - 1, width: 6, height: 2.5)
        NSBezierPath(roundedRect: bump, xRadius: 1, yRadius: 1).fill()
        // Lens.
        let lr = body.width * 0.20
        let lens = NSRect(x: rect.midX - lr, y: rect.midY - lr, width: lr * 2, height: lr * 2)
        let lp = NSBezierPath(ovalIn: lens); lp.lineWidth = 1.5; lp.stroke()
    }

    private static func drawCrosshair(in rect: NSRect) {
        let inset = rect.insetBy(dx: 2.5, dy: 2.5)
        let ring = NSBezierPath(ovalIn: inset); ring.lineWidth = 1.5; ring.stroke()
        let p = NSBezierPath(); p.lineWidth = 1.5; p.lineCapStyle = .round
        p.move(to: NSPoint(x: rect.midX, y: inset.minY - 1.5)); p.line(to: NSPoint(x: rect.midX, y: inset.maxY + 1.5))
        p.move(to: NSPoint(x: inset.minX - 1.5, y: rect.midY)); p.line(to: NSPoint(x: inset.maxX + 1.5, y: rect.midY))
        p.stroke()
    }

    /// Four rounded corner brackets inside `inset`.
    private static func drawBrackets(in inset: NSRect, lineWidth: CGFloat) {
        let corner = inset.width * 0.28
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        // top-left
        path.move(to: NSPoint(x: inset.minX, y: inset.maxY - corner))
        path.line(to: NSPoint(x: inset.minX, y: inset.maxY))
        path.line(to: NSPoint(x: inset.minX + corner, y: inset.maxY))
        // top-right
        path.move(to: NSPoint(x: inset.maxX - corner, y: inset.maxY))
        path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        path.line(to: NSPoint(x: inset.maxX, y: inset.maxY - corner))
        // bottom-right
        path.move(to: NSPoint(x: inset.maxX, y: inset.minY + corner))
        path.line(to: NSPoint(x: inset.maxX, y: inset.minY))
        path.line(to: NSPoint(x: inset.maxX - corner, y: inset.minY))
        // bottom-left
        path.move(to: NSPoint(x: inset.minX + corner, y: inset.minY))
        path.line(to: NSPoint(x: inset.minX, y: inset.minY))
        path.line(to: NSPoint(x: inset.minX, y: inset.minY + corner))
        path.stroke()
    }
}
