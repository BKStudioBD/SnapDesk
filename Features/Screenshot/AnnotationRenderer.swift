import AppKit
import CoreImage

/// The annotation tools, shared by the capture editor and the render self-test.
enum AnnotationTool: Int, CaseIterable {
    case arrow, rectangle, ellipse, line, pen, highlighter, blur, step, text, spotlight
}

/// One drawn annotation, independent of any view — purely data + geometry.
struct AnnotationStroke {
    var tool: AnnotationTool
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]          // pen/highlighter: many; others: [start, end]; step/text: [origin]
    var text: String?
    var image: NSImage?            // blur: the pixelated crop to draw in its rect
    var step: Int?
}

/// Pure drawing/compositing for annotations. No window, no screen — so it can be
/// exercised headlessly (see test-tools.sh) and reused by the live editor.
enum AnnotationRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Draw one stroke into the *current* NSGraphicsContext (coords already set).
    static func draw(_ a: AnnotationStroke) {
        a.color.setStroke(); a.color.setFill()
        guard let first = a.points.first else { return }
        switch a.tool {
        case .rectangle:
            guard a.points.count > 1 else { return }
            let p = NSBezierPath(rect: rect(first, a.points[1])); p.lineWidth = a.width; p.stroke()
        case .ellipse:
            guard a.points.count > 1 else { return }
            let p = NSBezierPath(ovalIn: rect(first, a.points[1])); p.lineWidth = a.width; p.stroke()
        case .line:
            guard a.points.count > 1 else { return }
            let p = NSBezierPath(); p.lineWidth = a.width; p.lineCapStyle = .round
            p.move(to: first); p.line(to: a.points[1]); p.stroke()
        case .pen, .highlighter:
            let p = NSBezierPath(); p.lineWidth = a.width; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: first); for q in a.points.dropFirst() { p.line(to: q) }; p.stroke()
        case .arrow:
            guard a.points.count > 1 else { return }
            drawArrow(from: first, to: a.points[1], width: a.width)
        case .blur:
            guard a.points.count > 1 else { return }
            let r = rect(first, a.points[1])
            if let img = a.image { img.draw(in: r) }
            else { NSColor.black.withAlphaComponent(0.25).setFill(); r.fill() }
        case .step:
            drawStep(at: first, number: a.step ?? 1, color: a.color, width: a.width)
        case .spotlight:
            // Dim everything EXCEPT the dragged rect (even-odd hole punch).
            guard a.points.count > 1 else { return }
            let hole = rect(first, a.points[1])
            let path = NSBezierPath(rect: NSRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000))
            path.append(NSBezierPath(rect: hole))
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55).setFill()
            path.fill()
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: max(14, a.width * 6)), .foregroundColor: a.color]
            (a.text ?? "").draw(at: first, withAttributes: attrs)
        }
    }

    private static func drawArrow(from s: CGPoint, to e: CGPoint, width: CGFloat) {
        let line = NSBezierPath(); line.lineWidth = width; line.lineCapStyle = .round
        line.move(to: s); line.line(to: e); line.stroke()
        let ang = atan2(e.y - s.y, e.x - s.x); let len = max(12, width * 4); let a = CGFloat.pi / 6
        let p1 = CGPoint(x: e.x - len * cos(ang - a), y: e.y - len * sin(ang - a))
        let p2 = CGPoint(x: e.x - len * cos(ang + a), y: e.y - len * sin(ang + a))
        let h = NSBezierPath(); h.move(to: e); h.line(to: p1); h.line(to: p2); h.line(to: e); h.close(); h.fill()
    }

    private static func drawStep(at c: CGPoint, number: Int, color: NSColor, width: CGFloat) {
        let r = max(11, width * 4)
        let box = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        color.setFill(); NSBezierPath(ovalIn: box).fill()
        let s = "\(number)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: r), .foregroundColor: NSColor.white]
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: attrs)
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// Pixelate a region of `cg`. `r` is in point coords of a view sized `viewSize`
    /// (bottom-left origin); `cg` is the full frozen image (top-left origin).
    static func pixelate(_ cg: CGImage, rectInPoints r: CGRect, viewSize: NSSize) -> NSImage? {
        guard r.width > 2, r.height > 2 else { return nil }
        let sx = CGFloat(cg.width) / viewSize.width, sy = CGFloat(cg.height) / viewSize.height
        let pr = CGRect(x: r.minX * sx, y: (viewSize.height - r.maxY) * sy,
                        width: r.width * sx, height: r.height * sy).integral
        guard let crop = cg.cropping(to: pr) else { return nil }
        let ci = CIImage(cgImage: crop)
        let block = max(8, min(crop.width, crop.height) / 12)
        guard let f = CIFilter(name: "CIPixellate", parameters: [
            kCIInputImageKey: ci, kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: 0, y: 0)]),
              let out = f.outputImage,
              let outCG = ciContext.createCGImage(out, from: ci.extent) else { return nil }
        return NSImage(cgImage: outCG, size: r.size)
    }

    /// Composite the frozen full image + strokes into a CGImage cropped to `selection`
    /// (point coords, bottom-left). `fullSize` = frozen image size in points.
    static func composite(frozen: NSImage, fullSize: NSSize, scale: CGFloat,
                          selection: CGRect, strokes: [AnnotationStroke]) -> CGImage? {
        let sel = selection.integral
        guard sel.width > 2, sel.height > 2 else { return nil }
        let pw = Int(sel.width * scale), ph = Int(sel.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = sel.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let xform = NSAffineTransform(); xform.translateX(by: -sel.minX, yBy: -sel.minY); xform.concat()
        frozen.draw(in: NSRect(origin: .zero, size: fullSize))
        for s in strokes { draw(s) }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// "Beautify" a screenshot for sharing: gradient background + padding +
    /// rounded corners + drop shadow (Xnapper-style). Works in pixel space.
    static func beautify(_ cg: CGImage, padding: CGFloat = 110, radius: CGFloat = 22,
                         from: NSColor = NSColor(srgbRed: 0.40, green: 0.36, blue: 0.90, alpha: 1),
                         to: NSColor = NSColor(srgbRed: 0.20, green: 0.62, blue: 0.92, alpha: 1)) -> CGImage? {
        let pad = Int(padding)
        let outW = cg.width + pad * 2, outH = cg.height + pad * 2
        guard outW > 0, outH > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: outW, pixelsHigh: outH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: outW, height: outH)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let full = NSRect(x: 0, y: 0, width: outW, height: outH)
        NSGradient(starting: from, ending: to)?.draw(in: full, angle: 45)

        let imgRect = NSRect(x: pad, y: pad, width: cg.width, height: cg.height)
        let path = NSBezierPath(roundedRect: imgRect, xRadius: radius, yRadius: radius)
        // Drop shadow.
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
        sh.shadowBlurRadius = 40; sh.shadowOffset = NSSize(width: 0, height: -16); sh.set()
        NSColor.black.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Clipped image.
        path.addClip()
        NSImage(cgImage: cg, size: imgRect.size).draw(in: imgRect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Encode a CGImage to PNG or JPEG data.
    static func encode(_ cg: CGImage, format: ImageFormat, quality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cg)
        switch format {
        case .png:  return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
    }
}
