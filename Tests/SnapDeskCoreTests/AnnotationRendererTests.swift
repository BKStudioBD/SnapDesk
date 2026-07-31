import Testing
import AppKit
@testable import SnapDeskCore

/// The annotation renderer's pure parts: how a drag becomes a rectangle, where
/// the blur actually lands, and what a save writes.
///
/// The blur mapping is the one that matters. Blur exists to hide a password or a
/// balance before a screenshot is shared, and it does its point→pixel maths in
/// its own copy of the arithmetic `ImageTransformer` uses for crops. So if the
/// two ever drift, the redaction covers the wrong strip and nothing says so.
struct AnnotationRendererTests {

    private func image(width: Int, height: Int) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(ctx.makeImage())
    }

    // MARK: - rect

    @Test("A drag makes the same rectangle whichever corner it started from",
          arguments: [(CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40)),
                      (CGPoint(x: 50, y: 40), CGPoint(x: 10, y: 10)),
                      (CGPoint(x: 10, y: 40), CGPoint(x: 50, y: 10)),
                      (CGPoint(x: 50, y: 10), CGPoint(x: 10, y: 40))])
    func rectIsDirectionIndependent(_ points: (CGPoint, CGPoint)) {
        let r = AnnotationRenderer.rect(points.0, points.1)
        #expect(r == CGRect(x: 10, y: 10, width: 40, height: 30))
    }

    @Test("A rectangle never has a negative side, however the drag ran")
    func rectIsNeverInverted() {
        let r = AnnotationRenderer.rect(CGPoint(x: 80, y: 90), CGPoint(x: 20, y: 15))
        #expect(r.width > 0)
        #expect(r.height > 0)
    }

    // MARK: - Blur mapping

    @Test("The blur maps to exactly the pixels a crop of the same rect would take",
          .tags(.regression),
          arguments: [CGRect(x: 10, y: 10, width: 40, height: 20),
                      CGRect(x: 0, y: 0, width: 30, height: 30),
                      CGRect(x: 55, y: 18, width: 44, height: 31)])
    func blurAgreesWithTheCropMapping(_ pointRect: CGRect) throws {
        // A 2× backing store shown in a 100×50 point view. The Retina case,
        // where a y-flip mistake is a whole-image mirror rather than a nudge.
        let cg = try image(width: 200, height: 100)
        let display = CGRect(x: 0, y: 0, width: 100, height: 50)

        let expected = ImageTransformer.pixelRect(from: pointRect, displayRect: display,
                                                  pixelWidth: cg.width, pixelHeight: cg.height)
        let blurred = try #require(AnnotationRenderer.pixelate(cg, rectInPoints: pointRect,
                                                              displayedIn: display))
        let rep = try #require(blurred.representations.first)
        #expect(rep.pixelsWide == Int(expected.width))
        #expect(rep.pixelsHigh == Int(expected.height))
        // …and it is handed back sized in POINTS, so it draws over the region the
        // person dragged rather than at twice the size.
        #expect(blurred.size == pointRect.size)
    }

    @Test("An offset display rect shifts the blur by the same amount as a crop")
    func blurHonoursAnOffsetDisplayRect() throws {
        let cg = try image(width: 200, height: 200)
        // The image no longer fills the view: what happens after a crop.
        let display = CGRect(x: 20, y: 30, width: 100, height: 100)
        let pointRect = CGRect(x: 40, y: 60, width: 30, height: 25)

        let expected = ImageTransformer.pixelRect(from: pointRect, displayRect: display,
                                                  pixelWidth: cg.width, pixelHeight: cg.height)
        let blurred = try #require(AnnotationRenderer.pixelate(cg, rectInPoints: pointRect,
                                                              displayedIn: display))
        let rep = try #require(blurred.representations.first)
        #expect(rep.pixelsWide == Int(expected.width))
        #expect(rep.pixelsHigh == Int(expected.height))
    }

    @Test("A degenerate drag blurs nothing rather than returning a stray pixel")
    func blurRefusesADegenerateRect() throws {
        let cg = try image(width: 200, height: 100)
        let display = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(AnnotationRenderer.pixelate(cg, rectInPoints: CGRect(x: 5, y: 5, width: 1, height: 20),
                                            displayedIn: display) == nil)
        #expect(AnnotationRenderer.pixelate(cg, rectInPoints: CGRect(x: 5, y: 5, width: 20, height: 20),
                                            displayedIn: .zero) == nil)
    }

    // MARK: - Encoding

    @Test("PNG comes back as a PNG, JPEG as a JPEG. The extension is not the format")
    func encodesTheRequestedFormat() throws {
        let cg = try image(width: 64, height: 64)
        let png = try #require(AnnotationRenderer.encode(cg, format: .png, quality: 1))
        let jpeg = try #require(AnnotationRenderer.encode(cg, format: .jpeg, quality: 0.8))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))       // \x89PNG
        #expect(jpeg.prefix(2) == Data([0xFF, 0xD8]))                   // JPEG SOI
    }

    @Test("The JPEG quality slider actually reaches the encoder")
    func jpegQualityChangesTheSize() throws {
        // Noise, not a flat fill: a solid colour compresses to about the same
        // size at every quality and would hide a slider that does nothing.
        let side = 128
        let ctx = try #require(CGContext(data: nil, width: side, height: side,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        for y in 0..<side {
            for x in 0..<side {
                let seed = ((x &* 73_856_093) ^ (y &* 19_349_663)) % 255
                ctx.setFillColor(red: Double(abs(seed)) / 255,
                                 green: Double(abs(seed &* 7 % 255)) / 255,
                                 blue: Double(abs(seed &* 13 % 255)) / 255, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let noisy = try #require(ctx.makeImage())
        let low = try #require(AnnotationRenderer.encode(noisy, format: .jpeg, quality: 0.1))
        let high = try #require(AnnotationRenderer.encode(noisy, format: .jpeg, quality: 1))
        #expect(low.count < high.count)
    }
}
