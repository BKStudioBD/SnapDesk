import AppKit

// SnapDesk: app icon generator.
//
// Draws Resources/AppIcon.png and the .iconset that becomes AppIcon.icns, from
// the SAME bracket geometry the menu-bar mark uses (App/MenuBarIcon.swift is
// compiled in alongside this file), so the two can't drift apart. Run it with
// ./make-icon.sh after changing the mark.
//
// Everything is vector and every measurement is a fraction of the canvas, so
// each size in the iconset is drawn fresh rather than downsampled, so 16pt stays
// legible instead of turning to mush.

// MARK: - Palette (sampled from the icon this replaces, so the brand holds)

enum Palette {
    static let backgroundTop = NSColor(srgbRed: 0x77 / 255, green: 0x74 / 255, blue: 0xEA / 255, alpha: 1)
    static let backgroundBottom = NSColor(srgbRed: 0xA6 / 255, green: 0x6B / 255, blue: 0xE5 / 255, alpha: 1)
    /// The centre wheel, clockwise from the top-right quadrant.
    static let wheel: [NSColor] = [
        NSColor(srgbRed: 0x00 / 255, green: 0x91 / 255, blue: 0xFF / 255, alpha: 1),  // upper right
        NSColor(srgbRed: 0xFF / 255, green: 0x54 / 255, blue: 0x3E / 255, alpha: 1),  // lower right
        NSColor(srgbRed: 0xFF / 255, green: 0xD3 / 255, blue: 0x00 / 255, alpha: 1),  // lower left
        NSColor(srgbRed: 0x3A / 255, green: 0xCD / 255, blue: 0x6C / 255, alpha: 1),  // upper left
    ]
}

// MARK: - Apple's macOS icon grid

/// The shape every macOS app icon is expected to be, as fractions of the canvas.
///
/// Apple templates it at 1024 pt: an 824 pt rounded square, corner radius
/// 185.4 pt, centred, with the rest transparent. Those three numbers are what
/// make an icon sit at the same visual size as its neighbours in the Dock,
/// Launchpad and Finder, and a hand-picked margin is exactly how an icon ends up
/// looking slightly too big beside every system app.
enum Grid {
    /// 1024 pt canvas, 824 pt of artwork, so 100 pt of margin on each side.
    static let margin: CGFloat = 100.0 / 1024.0
    /// 185.4 pt of the 824 pt plate.
    static let cornerRadius: CGFloat = 185.4 / 824.0
}

// MARK: - Drawing

/// Draws the icon into the current graphics context at `side` × `side` points.
///
/// - Parameter side: Edge length of the square canvas.
func drawIcon(side: CGFloat) {
    let canvas = NSRect(x: 0, y: 0, width: side, height: side)

    // Rounded-square plate, on Apple's macOS icon grid: an 824 pt square inside
    // a 1024 pt canvas, corner radius 185.4 pt. An icon drawn edge to edge sits
    // visibly larger than its neighbours in the Dock, and one drawn to its own
    // invented margin sits at its own size next to every system app.
    let plate = canvas.insetBy(dx: side * Grid.margin, dy: side * Grid.margin)
    let platePath = NSBezierPath(roundedRect: plate,
                                 xRadius: plate.width * Grid.cornerRadius,
                                 yRadius: plate.width * Grid.cornerRadius)
    NSGradient(starting: Palette.backgroundTop, ending: Palette.backgroundBottom)?
        .draw(in: platePath, angle: -90)   // top → bottom

    // Everything inside is measured against the PLATE, not the canvas, so the
    // mark keeps its proportions whatever the grid says the margin should be.
    // Measured against the canvas, a change of margin silently resizes the mark.
    let lineWidth = plate.width * 0.0306
    // A heptagon's corners sit closer to its centre than a square's do, so
    // matching the ring's apparent size means pushing the vertices out.
    let half = plate.width * 0.2952 + lineWidth / 2
    let ring = NSRect(x: canvas.midX - half, y: canvas.midY - half,
                      width: half * 2, height: half * 2)
    NSColor.white.setStroke()
    MenuBarIcon.bracketsPath(in: ring, lineWidth: lineWidth, armRatio: 0.34).stroke()

    drawWheel(in: canvas, radius: plate.width * 0.1024)
}

/// The four-quadrant colour wheel at the centre: the one part of the mark that
/// is the same as it ever was.
///
/// - Parameters:
///   - canvas: The full icon square; the wheel is centred in it.
///   - radius: Outer radius, white ring included.
func drawWheel(in canvas: NSRect, radius: CGFloat) {
    let centre = NSPoint(x: canvas.midX, y: canvas.midY)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius,
                                width: radius * 2, height: radius * 2)).fill()

    let inner = radius * 0.87
    for (index, colour) in Palette.wheel.enumerated() {
        let start = CGFloat(90 - 90 * (index + 1))   // 0…-360, clockwise from 90°
        let wedge = NSBezierPath()
        wedge.move(to: centre)
        wedge.appendArc(withCenter: centre, radius: inner,
                        startAngle: start, endAngle: start + 90)
        wedge.close()
        colour.setFill()
        wedge.fill()
    }
}

/// Renders the icon to a PNG.
///
/// - Parameter pixels: Width and height of the output, in pixels.
/// - Returns: PNG data, or nil if the bitmap could not be created.
func pngData(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(side: CGFloat(pixels))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

/// A monochrome sheet of the menu-bar mark at the sizes it is actually shown at,
/// so a change can be judged where it has to survive rather than at 1024.
///
/// - Parameter path: Where to write the PNG.
func writeMenuBarProof(to path: String) {
    let sizes: [CGFloat] = [18, 36, 72]         // 1×, 2× (what Retina shows), 4×
    let gap: CGFloat = 12
    let width = sizes.reduce(0, +) + gap * CGFloat(sizes.count + 1)
    let height = sizes.max()! + gap * 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(width), pixelsHigh: Int(height),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    var x = gap
    for size in sizes {
        let image = MenuBarIcon.image(pointSize: size)
        image.draw(in: NSRect(x: x, y: (height - size) / 2, width: size, height: size))
        x += size + gap
    }
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// MARK: - Output

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: icon <resources-dir> <iconset-dir>\n".utf8))
    exit(2)
}
let resources = URL(fileURLWithPath: arguments[1], isDirectory: true)
let iconset = URL(fileURLWithPath: arguments[2], isDirectory: true)

guard let master = pngData(pixels: 1024) else {
    FileHandle.standardError.write(Data("could not render the icon\n".utf8))
    exit(1)
}
try master.write(to: resources.appendingPathComponent("AppIcon.png"))

// The names iconutil expects. Each is drawn at its own size, not scaled.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    guard let data = pngData(pixels: variant.pixels) else { continue }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

writeMenuBarProof(to: "/tmp/snapdesk-menubar-mark.png")
print("✅ Icon rendered: \(variants.count) iconset sizes + AppIcon.png")
print("   Menu-bar mark proof sheet: /tmp/snapdesk-menubar-mark.png")
