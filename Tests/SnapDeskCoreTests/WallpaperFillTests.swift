import Testing
import AppKit
@testable import SnapDeskCore

/// The desktop cover has to look like the desktop it replaces. A wallpaper laid
/// in at the wrong aspect ratio, or a fallback colour that comes out black,
/// doesn't hide icons — it puts a visibly wrong background into someone's
/// screenshot. These pin the maths for the display shapes that actually exist.
struct WallpaperFillTests {

    /// A 16:10 laptop panel and a 16:9 external monitor, in points.
    private let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let monitor = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // MARK: - Aspect maths

    @Test("Fill always covers the screen, whichever way the picture is the wrong shape",
          arguments: [
            CGSize(width: 1000, height: 500),    // wider than either display
            CGSize(width: 500, height: 1000),    // taller
            CGSize(width: 3024, height: 1964),   // a real desktop picture
            CGSize(width: 8, height: 8),         // a tile, scaled way up
          ])
    func fillCovers(_ imageSize: CGSize) {
        // Compared with a tolerance, not with contains(_:): the scale factor is a
        // division followed by a multiplication, so an edge that should land
        // exactly on the screen's can miss it by one ulp.
        let slack: CGFloat = 0.001
        for bounds in [laptop, monitor] {
            let rect = WallpaperFill.aspectFillRect(imageSize: imageSize, in: bounds)
            #expect(rect.minX <= bounds.minX + slack, "\(imageSize) left a gap: \(rect)")
            #expect(rect.maxX >= bounds.maxX - slack, "\(imageSize) left a gap: \(rect)")
            #expect(rect.minY <= bounds.minY + slack, "\(imageSize) left a gap: \(rect)")
            #expect(rect.maxY >= bounds.maxY - slack, "\(imageSize) left a gap: \(rect)")
            #expect(abs(rect.width / rect.height - imageSize.width / imageSize.height) < 0.0001,
                    "aspect ratio drifted — the wallpaper would look stretched")
            #expect(abs(rect.midX - bounds.midX) < slack)
            #expect(abs(rect.midY - bounds.midY) < slack)
        }
    }

    @Test("Fit stays inside the screen and leaves the bars the real desktop leaves")
    func fitStaysInside() {
        let rect = WallpaperFill.aspectFitRect(imageSize: CGSize(width: 1000, height: 500),
                                               in: laptop)
        let slack: CGFloat = 0.001
        #expect(rect.minX >= laptop.minX - slack)
        #expect(rect.maxX <= laptop.maxX + slack)
        #expect(abs(rect.width - 1440) < slack, "limited by the width, so it spans it")
        #expect(abs(rect.height - 720) < slack)
        #expect(abs(rect.minY - 90) < slack, "the leftover height splits into two bars")
    }

    @Test("A square picture fills and fits to the same square, centred")
    func squareIsSymmetric() {
        let fill = WallpaperFill.aspectFillRect(imageSize: CGSize(width: 100, height: 100),
                                                in: laptop)
        let fit = WallpaperFill.aspectFitRect(imageSize: CGSize(width: 100, height: 100),
                                              in: laptop)
        #expect(fill.width == fill.height)
        #expect(fit.width == fit.height)
        #expect(abs(fill.width - 1440) < 0.001, "fill matches the LONG side")
        #expect(abs(fit.width - 900) < 0.001, "fit matches the short one")
    }

    @Test("An image with no size falls back to the screen rather than a zero-area rect")
    func degenerateSizesAreSafe() {
        #expect(WallpaperFill.aspectFillRect(imageSize: .zero, in: laptop) == laptop)
        #expect(WallpaperFill.aspectFitRect(imageSize: .zero, in: laptop) == laptop)
        #expect(WallpaperFill.aspectFillRect(imageSize: CGSize(width: 100, height: 0),
                                             in: laptop) == laptop)
    }

    // MARK: - Desktop layout modes

    @Test("Every wallpaper position is either reproduced exactly or declined",
          .tags(.regression))
    func layoutPerWallpaperPosition() {
        // System Settings → Wallpaper offers five positions. Treating everything
        // that wasn't "Fit to Screen" as fill got three of them wrong: a Centre
        // wallpaper was blown up until it covered the screen (a small logo became a
        // huge blurry crop, on screen AND in the shot), one Tile was magnified to
        // full screen, and Stretch came back aspect-correct and cropped.
        let fill = WallpaperFill.layout(scalingRawValue: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                                        allowsClipping: true)
        #expect(fill == .fill, "Fill Screen")
        let fit = WallpaperFill.layout(scalingRawValue: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                                       allowsClipping: false)
        #expect(fit == .fit, "Fit to Screen")
        let stretch = WallpaperFill.layout(scalingRawValue: NSImageScaling.scaleAxesIndependently.rawValue,
                                           allowsClipping: false)
        #expect(stretch == .stretch, "Stretch to Fill Screen")
        // Centre and Tile are both `.scaleNone` and nothing in NSWorkspace separates
        // them, so neither can be drawn without risking pixels that were never on
        // the screen: the screen goes uncovered instead.
        let centred = WallpaperFill.layout(scalingRawValue: NSImageScaling.scaleNone.rawValue,
                                           allowsClipping: false)
        #expect(centred == nil, "Center / Tile")
    }

    @Test("No scaling key means macOS's own default; an unrecognised one means decline")
    func layoutFallbacks() {
        #expect(WallpaperFill.layout(scalingRawValue: nil, allowsClipping: false) == .fill,
                "a desktop that reports no scaling is on Fill Screen")
        #expect(WallpaperFill.layout(scalingRawValue: 9_999, allowsClipping: false) == nil,
                "a value that is not a scaling mode is not an excuse to guess")
    }

    @Test("Stretch hands back the screen itself, so the picture really is distorted")
    func stretchUsesTheWholeScreen() {
        let rect = WallpaperFill.rect(for: .stretch,
                                      imageSize: CGSize(width: 800, height: 600), in: laptop)
        #expect(rect == laptop)
        #expect(WallpaperFill.rect(for: .fit, imageSize: CGSize(width: 800, height: 600),
                                   in: laptop) != laptop,
                "fit of a 4:3 picture onto a 16:10 panel has to leave bars")
    }

    // MARK: - Fallback colour

    @Test("A solid picture averages to exactly itself — the solid-colour desktop case")
    func averageOfASolidImage() throws {
        let image = try filled([(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1),
                                 CGRect(x: 0, y: 0, width: 32, height: 32))])
        let average = try #require(WallpaperFill.averageColor(of: image))
        #expect(abs(average.redComponent - 0.2) < 0.01)
        #expect(abs(average.greenComponent - 0.4) < 0.01)
        #expect(abs(average.blueComponent - 0.8) < 0.01)
    }

    @Test("Half black, half white averages to a mid grey — not to whichever pixel got sampled")
    func averageOfASplitImage() throws {
        let image = try filled([
            (.black, CGRect(x: 0, y: 0, width: 32, height: 32)),
            (.white, CGRect(x: 0, y: 0, width: 32, height: 16)),
        ])
        let average = try #require(WallpaperFill.averageColor(of: image))
        for channel in [average.redComponent, average.greenComponent, average.blueComponent] {
            #expect(channel > 0.35 && channel < 0.65, "got \(channel)")
        }
    }

    @Test("Channels don't swap: the buffer is BGRA, and reading it as RGBA turns red into blue")
    func channelOrderSurvives() throws {
        let image = try filled([(.red, CGRect(x: 0, y: 0, width: 32, height: 32))])
        let average = try #require(WallpaperFill.averageColor(of: image))
        #expect(average.redComponent > 0.9)
        #expect(average.blueComponent < 0.1)
    }

    /// Paints rects into a 32×32 bitmap, later ones on top.
    private func filled(_ layers: [(NSColor, CGRect)]) throws -> CGImage {
        let ctx = try #require(CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                        CGBitmapInfo.byteOrder32Little.rawValue))
        for (color, rect) in layers {
            let c = try #require(color.usingColorSpace(.sRGB))
            ctx.setFillColor(red: c.redComponent, green: c.greenComponent,
                             blue: c.blueComponent, alpha: 1)
            ctx.fill(rect)
        }
        return try #require(ctx.makeImage())
    }
}
