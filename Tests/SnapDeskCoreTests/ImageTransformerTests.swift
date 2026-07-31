import Testing
import CoreGraphics
@testable import SnapDeskCore

/// Crop / rotate / flip act on a picture the user is about to paste into a bug
/// report, so a mirrored or resampled result is shipped before anyone notices.
/// These build real CGImages with a different colour in every pixel: a transform
/// that transposes the wrong way round cannot coincidentally match.
struct ImageTransformerTests {

    // MARK: - Fixtures

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                        bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<height {
            for x in 0..<width {
                // Opaque, so nothing is lost to premultiplication rounding and the
                // comparisons below can demand exact equality.
                ctx.setFillColor(red: CGFloat(20 + x * 40) / 255,
                                 green: CGFloat(20 + y * 40) / 255, blue: 0.5, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try #require(ctx.makeImage())
    }

    /// RGBA bytes, row 0 first. The row order CGImage itself uses (top row first).
    private func read(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        try buf.withUnsafeMutableBytes { raw in
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let ctx = try #require(CGContext(data: raw.baseAddress, width: w, height: h,
                                             bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    private func pixel(_ buf: [UInt8], x: Int, y: Int, width: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(buf[i..<i + 4])
    }

    // MARK: - Rotation

    @Test("A quarter turn swaps the pixel dimensions")
    func rotationSwapsDimensions() throws {
        let src = try makeImage(width: 3, height: 2)
        for clockwise in [true, false] {
            let out = try #require(ImageTransformer.rotated(src, clockwise: clockwise))
            #expect(out.width == 2 && out.height == 3, "clockwise: \(clockwise)")
        }
    }

    @Test("Rotating right moves the top-left pixel to the top-right, i.e. clockwise")
    func rotationGoesTheRightWay() throws {
        // The direction is the one thing a symmetry test can't catch, and a rotate
        // button that turns the wrong way is the whole feature being backwards.
        let src = try makeImage(width: 3, height: 2)
        let s = try read(src)
        let out = try #require(ImageTransformer.rotated(src, clockwise: true))
        let d = try read(out)
        for y in 0..<2 {
            for x in 0..<3 {
                #expect(pixel(d, x: 2 - 1 - y, y: x, width: out.width) == pixel(s, x: x, y: y, width: 3),
                        "pixel (\(x), \(y)) landed wrong")
            }
        }
    }

    @Test("Rotating right twice is a 180° turn")
    func twiceRightIsHalfATurn() throws {
        let src = try makeImage(width: 3, height: 2)
        let s = try read(src)
        let once = try #require(ImageTransformer.rotated(src, clockwise: true))
        let twice = try #require(ImageTransformer.rotated(once, clockwise: true))
        #expect(twice.width == 3 && twice.height == 2, "180° must restore the original shape")
        for y in 0..<2 {
            for x in 0..<3 {
                #expect(pixel(try read(twice), x: x, y: y, width: 3)
                        == pixel(s, x: 3 - 1 - x, y: 2 - 1 - y, width: 3))
            }
        }
    }

    @Test("Rotate left undoes rotate right, pixel for pixel")
    func rotationsAreInverses() throws {
        let src = try makeImage(width: 4, height: 3)
        let right = try #require(ImageTransformer.rotated(src, clockwise: true))
        let back = try #require(ImageTransformer.rotated(right, clockwise: false))
        #expect(back.width == 4 && back.height == 3)
        let roundTripped = try read(back), original = try read(src)
        #expect(roundTripped == original)
    }

    // MARK: - Flips

    @Test("Flipping twice is the identity", arguments: [true, false])
    func flipTwiceIsIdentity(_ horizontally: Bool) throws {
        let src = try makeImage(width: 4, height: 3)
        let once = try #require(ImageTransformer.flipped(src, horizontally: horizontally))
        let twice = try #require(ImageTransformer.flipped(once, horizontally: horizontally))
        #expect(twice.width == 4 && twice.height == 3)
        let flippedBack = try read(twice), original = try read(src)
        #expect(flippedBack == original)
    }

    @Test("Horizontal flips mirror columns and vertical ones mirror rows. Not both")
    func flipsMirrorOneAxisEach() throws {
        // Mirroring the wrong axis still round-trips, so the identity test above
        // can't tell the two apart on its own.
        let src = try makeImage(width: 3, height: 2)
        let s = try read(src)
        let h = try read(try #require(ImageTransformer.flipped(src, horizontally: true)))
        let v = try read(try #require(ImageTransformer.flipped(src, horizontally: false)))
        for y in 0..<2 {
            for x in 0..<3 {
                #expect(pixel(h, x: x, y: y, width: 3) == pixel(s, x: 3 - 1 - x, y: y, width: 3))
                #expect(pixel(v, x: x, y: y, width: 3) == pixel(s, x: x, y: 2 - 1 - y, width: 3))
            }
        }
    }

    @Test("A transform keeps the bitmap's colour space and depth")
    func transformsPreserveColourSpace() throws {
        let src = try makeImage(width: 3, height: 2)
        for out in [try #require(ImageTransformer.rotated(src, clockwise: true)),
                    try #require(ImageTransformer.flipped(src, horizontally: true))] {
            #expect(out.colorSpace?.name == src.colorSpace?.name)
            #expect(out.bitsPerComponent == src.bitsPerComponent)
            #expect(out.alphaInfo == src.alphaInfo)
        }
    }

    // MARK: - Crop

    @Test("A 2× capture stays 2× through a crop")
    func cropKeepsBackingScale() throws {
        // 8×4 pixels shown in a 4×2 point box is a 2× shot. Cropping half of it must
        // yield half the PIXELS, not half the points at 1×.
        let src = try makeImage(width: 8, height: 4)
        let display = CGRect(x: 100, y: 100, width: 4, height: 2)
        let px = ImageTransformer.pixelRect(from: CGRect(x: 101, y: 100.5, width: 2, height: 1),
                                            displayRect: display, pixelWidth: 8, pixelHeight: 4)
        #expect(px == CGRect(x: 2, y: 1, width: 4, height: 2))
        let out = try #require(ImageTransformer.cropped(src, toPixelRect: px))
        #expect(out.width == 4 && out.height == 2, "2 × 1 points at 2× is 4 × 2 pixels")
    }

    @Test("The crop rect is measured from the TOP of the image, not the bottom")
    func pixelRectFlipsTheYAxis() throws {
        // The view's y grows upward and a CGImage's rows run downward; getting this
        // wrong mirrors every crop vertically, which looks almost right on a
        // symmetric screenshot.
        let display = CGRect(x: 0, y: 0, width: 10, height: 10)
        let topStrip = ImageTransformer.pixelRect(from: CGRect(x: 0, y: 8, width: 10, height: 2),
                                                  displayRect: display, pixelWidth: 10, pixelHeight: 10)
        #expect(topStrip.minY == 0, "a strip at the top of the view is row 0 of the image")
        let bottomStrip = ImageTransformer.pixelRect(from: CGRect(x: 0, y: 0, width: 10, height: 2),
                                                     displayRect: display, pixelWidth: 10, pixelHeight: 10)
        #expect(bottomStrip.minY == 8)
    }

    @Test("Point and pixel rects round-trip, so the crop is shown where its pixels are")
    func pointRectIsTheInverse() {
        let display = CGRect(x: 100, y: 100, width: 4, height: 2)
        let px = CGRect(x: 2, y: 1, width: 4, height: 2)
        #expect(ImageTransformer.pointRect(from: px, displayRect: display,
                                           pixelWidth: 8, pixelHeight: 4)
                == CGRect(x: 101, y: 100.5, width: 2, height: 1))
    }

    @Test("An empty, inverted or off-image crop returns nothing instead of the whole shot")
    func cropRejectsDegenerateRects() throws {
        let src = try makeImage(width: 8, height: 4)
        #expect(ImageTransformer.cropped(src, toPixelRect: CGRect(x: 0, y: 0, width: 0, height: 4)) == nil)
        #expect(ImageTransformer.cropped(src, toPixelRect: CGRect(x: 0, y: 0, width: 4, height: 0)) == nil)
        #expect(ImageTransformer.cropped(src, toPixelRect: .null) == nil)
        #expect(ImageTransformer.cropped(src, toPixelRect: CGRect(x: 40, y: 40, width: 4, height: 4)) == nil,
                "a rect entirely off the bitmap is not a crop of it")
        // A negative-size rect is what a handle dragged past its opposite edge used
        // to produce; standardizing it is fine, silently returning the full image is not.
        let inverted = try #require(ImageTransformer.cropped(src, toPixelRect: CGRect(x: 4, y: 2, width: -2, height: -1)))
        #expect(inverted.width == 2 && inverted.height == 1)
    }

    @Test("A crop clamped to the bitmap never grows past it")
    func cropClampsToTheBitmap() throws {
        let src = try makeImage(width: 8, height: 4)
        let out = try #require(ImageTransformer.cropped(src, toPixelRect: CGRect(x: 6, y: 2, width: 20, height: 20)))
        #expect(out.width == 2 && out.height == 2)
    }

    // MARK: - Where the transformed image is shown

    @Test("A rotate swaps the on-screen box about its centre, so the scale survives")
    func displayRectSwapsSidesAndKeepsScale() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let shown = CGRect(x: 100, y: 100, width: 400, height: 200)   // an 800×400 2× bitmap
        let rotated = EditorImageTransform.rotateRight.displayRect(for: shown, in: bounds)
        #expect(rotated.width == 200 && rotated.height == 400)
        #expect(rotated.midX == shown.midX && rotated.midY == shown.midY)
        // 400 rotated pixels across 200 points is still 2 pixels per point.
        #expect(400 / rotated.width == 2)
    }

    @Test("Flips leave the on-screen box exactly where it was")
    func flipsDoNotMoveTheBox() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let shown = CGRect(x: 100, y: 100, width: 400, height: 200)
        #expect(EditorImageTransform.flipHorizontal.displayRect(for: shown, in: bounds) == shown)
        #expect(EditorImageTransform.flipVertical.displayRect(for: shown, in: bounds) == shown)
    }

    @Test("A rotate too tall for the display shrinks to fit, keeping its aspect")
    func displayRectShrinksToFit() {
        // A wide strip rotated upright would be 1800pt tall on a 1080pt screen, and
        // an off-screen box puts the toolbar and the crop handles out of reach.
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let shown = CGRect(x: 0, y: 400, width: 1800, height: 300)
        let rotated = EditorImageTransform.rotateLeft.displayRect(for: shown, in: bounds)
        #expect(bounds.contains(rotated))
        #expect(abs(rotated.width / rotated.height - 300.0 / 1800.0) < 0.001)
    }

    @Test("Only the rotations claim to swap the axes")
    func swapsAxesMatchesTheOperation() {
        #expect(EditorImageTransform.rotateLeft.swapsAxes)
        #expect(EditorImageTransform.rotateRight.swapsAxes)
        #expect(EditorImageTransform.flipHorizontal.swapsAxes == false)
        #expect(EditorImageTransform.flipVertical.swapsAxes == false)
    }
}
