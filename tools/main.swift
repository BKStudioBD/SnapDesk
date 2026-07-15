import AppKit

// Minimal stand-in so AnnotationRenderer.encode compiles outside the app target.
enum ImageFormat { case png, jpeg }

// Headless render test: draws every annotation tool onto a synthetic screenshot
// and writes one PNG per tool, plus a combined image. Lets us verify each tool
// actually renders without launching the GUI.

_ = NSApplication.shared   // initialise the AppKit environment for offscreen drawing

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/snapdesk-tools"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let pts = NSSize(width: 360, height: 240)
let scale: CGFloat = 2

func makeBase() -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(pts.width * scale), pixelsHigh: Int(pts.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = pts
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    NSGradient(starting: NSColor(white: 0.96, alpha: 1), ending: NSColor(white: 0.76, alpha: 1))?
        .draw(in: NSRect(origin: .zero, size: pts), angle: 90)
    "Sensitive 12345".draw(at: NSPoint(x: 120, y: 108),
        withAttributes: [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.black])
    NSColor.systemBlue.withAlphaComponent(0.5).setFill()
    NSBezierPath(ovalIn: NSRect(x: 36, y: 36, width: 46, height: 46)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

let baseCG = makeBase()
let frozen = NSImage(cgImage: baseCG, size: pts)
let sel = NSRect(origin: .zero, size: pts)

func save(_ cg: CGImage?, _ name: String) {
    guard let cg, let data = AnnotationRenderer.encode(cg, format: .png, quality: 1) else {
        print("FAIL  \(name)"); return
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    try? data.write(to: url)
    print("OK    \(name)  (\(cg.width)x\(cg.height))")
}

let red = NSColor.systemRed, blue = NSColor.systemBlue

func strokes(for tool: AnnotationTool) -> [AnnotationStroke] {
    switch tool {
    case .arrow:     return [AnnotationStroke(tool: .arrow, color: red, width: 4, points: [CGPoint(x: 60, y: 60), CGPoint(x: 300, y: 180)], text: nil, image: nil, step: nil)]
    case .line:      return [AnnotationStroke(tool: .line, color: red, width: 4, points: [CGPoint(x: 60, y: 60), CGPoint(x: 300, y: 180)], text: nil, image: nil, step: nil)]
    case .rectangle: return [AnnotationStroke(tool: .rectangle, color: red, width: 4, points: [CGPoint(x: 60, y: 60), CGPoint(x: 300, y: 180)], text: nil, image: nil, step: nil)]
    case .ellipse:   return [AnnotationStroke(tool: .ellipse, color: red, width: 4, points: [CGPoint(x: 60, y: 60), CGPoint(x: 300, y: 180)], text: nil, image: nil, step: nil)]
    case .pen:       return [AnnotationStroke(tool: .pen, color: red, width: 4, points: (0...40).map { CGPoint(x: 60 + Double($0) * 6, y: 120 + sin(Double($0) / 3) * 40) }, text: nil, image: nil, step: nil)]
    case .highlighter: return [AnnotationStroke(tool: .highlighter, color: NSColor.systemYellow.withAlphaComponent(0.4), width: 18, points: [CGPoint(x: 60, y: 120), CGPoint(x: 300, y: 120)], text: nil, image: nil, step: nil)]
    case .blur:
        let r = CGRect(x: 110, y: 96, width: 150, height: 36)
        let img = AnnotationRenderer.pixelate(baseCG, rectInPoints: r, viewSize: pts)
        return [AnnotationStroke(tool: .blur, color: red, width: 4, points: [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)], text: nil, image: img, step: nil)]
    case .step:      return [
        AnnotationStroke(tool: .step, color: red, width: 4, points: [CGPoint(x: 100, y: 120)], text: nil, image: nil, step: 1),
        AnnotationStroke(tool: .step, color: blue, width: 4, points: [CGPoint(x: 180, y: 120)], text: nil, image: nil, step: 2),
        AnnotationStroke(tool: .step, color: NSColor.systemGreen, width: 4, points: [CGPoint(x: 260, y: 120)], text: nil, image: nil, step: 3)]
    case .text:      return [AnnotationStroke(tool: .text, color: red, width: 5, points: [CGPoint(x: 60, y: 130)], text: "Snap!", image: nil, step: nil)]
    case .spotlight: return [AnnotationStroke(tool: .spotlight, color: red, width: 4, points: [CGPoint(x: 110, y: 90), CGPoint(x: 260, y: 150)], text: nil, image: nil, step: nil)]
    }
}

var all: [AnnotationStroke] = []
for tool in AnnotationTool.allCases {
    let s = strokes(for: tool)
    all.append(contentsOf: s)
    save(AnnotationRenderer.composite(frozen: frozen, fullSize: pts, scale: scale, selection: sel, strokes: s), "\(tool)")
}
let allCG = AnnotationRenderer.composite(frozen: frozen, fullSize: pts, scale: scale, selection: sel, strokes: all)
save(allCG, "ALL")
if let allCG { save(AnnotationRenderer.beautify(allCG), "BEAUTIFY") }
print("\nWrote PNGs to \(outDir)")
