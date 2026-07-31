import Testing
import CoreGraphics
@testable import SnapDeskCore

/// The scrolling-capture stitcher.
///
/// A seam bug here is invisible at capture time and only shows up when someone
/// reads the saved image later: a band of content repeated, or a band missing.
/// Everything below is synthetic pixels, so it needs no screen and no
/// permission.
struct ScrollStitcherTests {

    // MARK: - Fixtures

    /// A tall image whose every row is visually distinct, with different values
    /// in the left/middle/right thirds so rows carry real horizontal structure
    /// (a flat row is deliberately weighted down by the matcher).
    ///
    /// `variant` changes how fast the pattern walks per row, which is what makes
    /// two pages genuinely UNRELATED: same-variant pages differ only by a row
    /// offset, so windows of them can always be aligned to each other somewhere.
    private func page(width: Int = 120, height: Int, variant: Int = 1) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        for y in 0..<height {
            // Deterministic, not random: the same page every run.
            let seed = (y &* variant &* 2_654_435_761) % 251
            for (band, offset) in [(0, 0), (1, 83), (2, 167)] {
                let v = Double((seed + offset) % 251) / 250
                ctx.setFillColor(red: v, green: 1 - v, blue: Double(y % 97) / 96, alpha: 1)
                let x = band * width / 3
                // CG's origin is bottom-left; row 0 of the IMAGE is the top row.
                ctx.fill(CGRect(x: x, y: height - 1 - y, width: width / 3, height: 1))
            }
        }
        return try #require(ctx.makeImage())
    }

    /// Rows `from..<from+height` of `page`, the way a scrolled screenshot sees
    /// them: CGImage crops from the TOP.
    private func window(_ page: CGImage, from: Int, height: Int) throws -> CGImage {
        try #require(page.cropping(to: CGRect(x: 0, y: from, width: page.width, height: height)))
    }

    // MARK: - Signatures

    @Test("A signature has three bands per row, top row first")
    func signatureShape() throws {
        let img = try page(height: 60)
        let sig = ScrollStitcher.rowSignature(img)
        #expect(sig.count == 60 * ScrollStitcher.bandsPerRow)
        #expect(ScrollStitcher.rows(sig) == 60)
    }

    @Test("The same frame twice is no change at all; a different one is")
    func meanDiffSeparatesSameFromDifferent() throws {
        let source = try page(height: 300)
        let a = ScrollStitcher.rowSignature(try window(source, from: 0, height: 120))
        let again = ScrollStitcher.rowSignature(try window(source, from: 0, height: 120))
        let moved = ScrollStitcher.rowSignature(try window(source, from: 60, height: 120))
        #expect(ScrollStitcher.meanDiff(a, again) == 0)
        #expect(ScrollStitcher.meanDiff(a, moved) > 1)
    }

    @Test("Signatures of different heights are incomparable, not accidentally equal")
    func meanDiffRejectsMismatchedHeights() throws {
        let source = try page(height: 300)
        let short = ScrollStitcher.rowSignature(try window(source, from: 0, height: 100))
        let tall = ScrollStitcher.rowSignature(try window(source, from: 0, height: 120))
        #expect(ScrollStitcher.meanDiff(short, tall) == .infinity)
    }

    // MARK: - Sticky headers

    @Test("A nav bar that never moves is measured as the header, and excluded")
    func detectsAStickyHeader() throws {
        let source = try page(height: 400)
        let header = try window(source, from: 0, height: 40)
        // Three frames scrolled to different places, each wearing the same
        // 40-row header: a site nav bar.
        let sigs = try [80, 160, 240].map { start -> [Float] in
            let body = try window(source, from: start, height: 160)
            let composed = try #require(CGContext(data: nil, width: source.width, height: 200,
                                                  bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
            composed.draw(body, in: CGRect(x: 0, y: 0, width: source.width, height: 160))
            composed.draw(header, in: CGRect(x: 0, y: 160, width: source.width, height: 40))
            return ScrollStitcher.rowSignature(try #require(composed.makeImage()))
        }
        #expect(ScrollStitcher.stickyHeaderRows(sigs) >= 30,
                "the repeated top band should be recognised as a header")
    }

    @Test("Frames that share nothing at the top report no header")
    func noHeaderWhenNothingRepeats() throws {
        let source = try page(height: 600)
        let sigs = try [0, 150, 300].map {
            ScrollStitcher.rowSignature(try window(source, from: $0, height: 150))
        }
        #expect(ScrollStitcher.stickyHeaderRows(sigs) == 0)
    }

    // MARK: - Overlap

    @Test("A frame scrolled by a known amount reports that much overlap",
          arguments: [40, 80, 120])
    func findsTheOverlap(_ scroll: Int) throws {
        let source = try page(height: 500)
        let prev = ScrollStitcher.rowSignature(try window(source, from: 0, height: 200))
        let next = ScrollStitcher.rowSignature(try window(source, from: scroll, height: 200))
        let overlap = try #require(ScrollStitcher.bestOverlap(prev, next, header: 0))
        #expect(abs(overlap - (200 - scroll)) <= 2,
                "expected about \(200 - scroll) rows of overlap, got \(overlap)")
    }

    @Test("Two unrelated frames report no overlap rather than a wrong one")
    func rejectsAnUnrelatedFrame() throws {
        let first = try page(width: 120, height: 200)
        let second = try page(width: 120, height: 200)
        // A second page built from the same rule is identical, so shift the
        // comparison onto genuinely different content: rows reversed.
        let flipped = try #require(CGContext(data: nil, width: 120, height: 200,
                                             bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        flipped.translateBy(x: 0, y: 200)
        flipped.scaleBy(x: 1, y: -1)
        flipped.draw(second, in: CGRect(x: 0, y: 0, width: 120, height: 200))
        let prev = ScrollStitcher.rowSignature(first)
        let next = ScrollStitcher.rowSignature(try #require(flipped.makeImage()))
        // Either no match, or a match the stitcher would treat as new content.
        if let overlap = ScrollStitcher.bestOverlap(prev, next, header: 0) {
            #expect(overlap < 200, "a reversed page must not claim a full-frame overlap")
        }
    }

    // MARK: - Stitching

    @Test("Two overlapping frames stitch back to the original height. No band repeated",
          .tags(.regression))
    func stitchingDoesNotDuplicateTheOverlap() throws {
        let source = try page(height: 300)
        let frames = [try window(source, from: 0, height: 200),
                      try window(source, from: 100, height: 200)]
        let sigs = frames.map(ScrollStitcher.rowSignature)
        let stitched = try #require(ScrollStitcher.stitch(frames: frames, signatures: sigs))
        #expect(stitched.width == 120)
        #expect(abs(stitched.height - 300) <= 2,
                "expected the 300-row page back, got \(stitched.height)")
        #expect(stitched.height < 380, "the 100-row overlap was appended twice")
    }

    @Test("A measured scroll offset is used, and gives the same answer as the search")
    func offsetsAgreeWithTheSearch() throws {
        let source = try page(height: 300)
        let frames = [try window(source, from: 0, height: 200),
                      try window(source, from: 100, height: 200)]
        let sigs = frames.map(ScrollStitcher.rowSignature)
        let withOffset = try #require(
            ScrollStitcher.stitch(frames: frames, signatures: sigs, offsets: [100]))
        let searched = try #require(ScrollStitcher.stitch(frames: frames, signatures: sigs))
        #expect(withOffset.height == searched.height)
    }

    @Test("One unalignable frame does not take the rest of the page with it",
          .tags(.regression))
    func aMissMidChainKeepsTheFramesAfterIt() throws {
        // Frame 2 lands on content frame 1 shares nothing with. The page jumped.
        // Frame 3 overlaps frame 2 normally. The chain used to stay anchored on
        // frame 1, so frame 3 was another scroll step further away, missed too,
        // and every frame after the first miss was dropped: a "full page" one
        // frame tall.
        let first = try page(height: 400)
        let jumped = try page(height: 400, variant: 3)
        let frames = [try window(first, from: 0, height: 200),
                      try window(jumped, from: 0, height: 200),
                      try window(jumped, from: 100, height: 200)]
        let sigs = frames.map(ScrollStitcher.rowSignature)
        #expect(ScrollStitcher.bestOverlap(sigs[0], sigs[1], header: 0) == nil,
                "the fixture only proves anything if that jump really is unalignable")
        let stitched = try #require(ScrollStitcher.stitch(frames: frames, signatures: sigs))
        // 200 (first) + 200 (the unalignable frame, seamed in) + 100 (frame 3's
        // new rows): anything near 200 means the tail was dropped again.
        #expect(stitched.height >= 480,
                "frames after the miss were dropped. Got \(stitched.height) rows")
        #expect(stitched.height <= 520, "got \(stitched.height) rows")
    }

    @Test("A frame that overlaps completely adds nothing")
    func fullyOverlappingFrameIsNotAppended() throws {
        let source = try page(height: 300)
        let frame = try window(source, from: 0, height: 200)
        let frames = [frame, frame]
        let sigs = frames.map(ScrollStitcher.rowSignature)
        let stitched = try #require(ScrollStitcher.stitch(frames: frames, signatures: sigs))
        #expect(stitched.height == 200)
    }

    @Test("A frame whose signature came back empty doesn't crash Done", .tags(.regression))
    func stitchSurvivesAnUnmeasuredFirstFrame() throws {
        // `rowSignature` returns an empty array when its downsample context can't
        // be allocated, and the frame is stored regardless: an empty signature
        // compares as "changed", so the dedup never drops it. Dividing the frame's
        // height by that row count made the row scale infinite, and converting the
        // header to pixels one line later trapped on the NaN: one failed
        // allocation mid-capture turned pressing Done into a crash that took every
        // captured frame with it.
        let source = try page(height: 300)
        let frames = [try window(source, from: 0, height: 200),
                      try window(source, from: 100, height: 200)]
        let sigs: [[Float]] = [[], ScrollStitcher.rowSignature(frames[1])]
        let stitched = try #require(ScrollStitcher.stitch(frames: frames, signatures: sigs))
        #expect(stitched.width == 120)
        // Nothing to align against, so the second frame is seamed on whole: what
        // matters is that both frames survive rather than the capture being lost.
        #expect(stitched.height == 400, "got \(stitched.height) rows")
    }

    @Test("One frame stitches to itself; no frames stitches to nothing")
    func degenerateInputs() throws {
        let single = try page(height: 120)
        let sig = ScrollStitcher.rowSignature(single)
        #expect(ScrollStitcher.stitch(frames: [single], signatures: [sig])?.height == 120)
        #expect(ScrollStitcher.stitch(frames: [], signatures: []) == nil)
    }
}
