import Testing
import AppKit
@testable import SnapDeskCore

/// The escalation ladder — upscale → bigger retry → overlapping tiles — exists
/// because of measured Vision blind spots, and it is the part of SnapDesk that
/// regressed most often. Nothing here is synthetic: each case renders the exact
/// shape that used to come back empty and asserts the real recognizer reads it.
///
/// Serialized: every case drives an `.accurate` Vision pass, and running them
/// concurrently only makes them all slower.
@Suite(.serialized)
struct OCREscalationTests {

    /// Text on white at an exact size. `scale` mimics a Retina capture.
    private func image(_ text: String, size: NSSize, fontSize: CGFloat,
                       at origin: NSPoint, scale: CGFloat = 2) throws -> CGImage {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        let ctx = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: origin, withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.cgImage)
    }

    /// Compare ignoring case and whitespace runs: the assertion is "did it read
    /// the words", not "did it match byte-for-byte".
    private func reads(_ output: String, _ expected: String) -> Bool {
        func normal(_ s: String) -> String {
            s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return normal(output).contains(normal(expected))
    }

    private let detailed = OCROptions(engine: .detailed)

    @Test("A WIDE THIN STRIP is read — the blind spot the tiling rescue exists for",
          .tags(.regression))
    func readsAWideStrip() async throws {
        // Vision normalizes detection by the LONG side, so a one-line strip
        // dragged tightly used to return ZERO observations. Uniform upscaling did
        // not help; overlapping tiles did.
        let phrase = "the quick brown fox jumps over the lazy dog"
        let strip = try image(phrase, size: NSSize(width: 900, height: 26),
                             fontSize: 13, at: NSPoint(x: 6, y: 6))
        let text = try await OCRService.recognizeText(in: strip, options: detailed)
        #expect(reads(text, "quick brown fox"), "got: \(text)")
    }

    @Test("An extremely wide strip (over 40:1) still reads", .tags(.regression))
    func readsAnExtremeStrip() async throws {
        let phrase = "build 4127 succeeded in 12.4 seconds with no warnings"
        let strip = try image(phrase, size: NSSize(width: 1400, height: 30),
                             fontSize: 14, at: NSPoint(x: 8, y: 7))
        let text = try await OCRService.recognizeText(in: strip, options: detailed)
        #expect(reads(text, "build 4127"), "got: \(text)")
    }

    @Test("TINY text is read, because a small selection is upscaled up front",
          .tags(.regression))
    func readsTinyText() async throws {
        // Small glyphs are Vision's single most common miss; `upscaledIfSmall`
        // enlarges anything short-sided before the first pass.
        let tiny = try image("Total 1284", size: NSSize(width: 120, height: 22),
                            fontSize: 9, at: NSPoint(x: 4, y: 6))
        let text = try await OCRService.recognizeText(in: tiny, options: detailed)
        #expect(reads(text, "1284"), "got: \(text)")
    }

    @Test("A 1× (non-Retina) capture reads too")
    func readsNonRetina() async throws {
        let image = try image("Session expired", size: NSSize(width: 260, height: 40),
                             fontSize: 15, at: NSPoint(x: 8, y: 12), scale: 1)
        let text = try await OCRService.recognizeText(in: image, options: detailed)
        #expect(reads(text, "session expired"), "got: \(text)")
    }

    @Test("A blank frame returns EMPTY, not invented text")
    func blankFrameReadsEmpty() async throws {
        // The whole miss-reporting path depends on this: a lapsed Screen Recording
        // grant hands over a contentless frame, and inventing text there would be
        // far worse than reporting nothing.
        let blank = try image("", size: NSSize(width: 400, height: 200),
                             fontSize: 14, at: .zero)
        let text = try await OCRService.recognizeText(in: blank, options: detailed)
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "got: \(text)")
    }

    @Test("Line order is top-to-bottom, and Outline keeps the breaks")
    func preservesReadingOrder() async throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 300, height: 150)
        let ctx = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 300, height: 150).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black]
        // Drawn bottom-up in AppKit coords, so this puts FIRST at the top.
        ("THIRD" as NSString).draw(at: NSPoint(x: 12, y: 20), withAttributes: attrs)
        ("SECOND" as NSString).draw(at: NSPoint(x: 12, y: 60), withAttributes: attrs)
        ("FIRST" as NSString).draw(at: NSPoint(x: 12, y: 100), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        let cg = try #require(rep.cgImage)

        let text = try await OCRService.recognizeText(in: cg, options: detailed)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.count == 3, "got: \(text)")
        #expect(lines.first?.uppercased().contains("FIRST") == true, "got: \(text)")
        #expect(lines.last?.uppercased().contains("THIRD") == true, "got: \(text)")

        // Inline mode collapses the same content onto one line.
        var inline = detailed
        inline.keepLineBreaks = false
        let flat = try await OCRService.recognizeText(in: cg, options: inline)
        #expect(flat.contains("\n") == false, "got: \(flat)")
    }

    @Test("Trim is honoured in both directions")
    func honoursTrim() async throws {
        let cg = try image("Padded", size: NSSize(width: 300, height: 120),
                           fontSize: 15, at: NSPoint(x: 20, y: 50))
        var trimming = detailed
        trimming.trim = true
        let trimmed = try await OCRService.recognizeText(in: cg, options: trimming)
        #expect(trimmed == trimmed.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(trimmed.isEmpty == false)
    }

    @Test("The warm-up completes off the main thread, and says so honestly",
          .tags(.regression))
    func prewarmRunsOffTheMainThread() async throws {
        // Every caller prewarms from a detached task, so that is where this runs
        // it. What it pins down is the REPORTING: the warm-up used to be recorded
        // as done whether or not it happened, and a warm-up that only appeared to
        // run left the user paying the full model load on their first real grab.
        let options = detailed
        let warmed = await Task.detached { await OCRService.prewarm(options: options) }.value
        #expect(warmed, "a prewarm off the main thread must actually complete")
        // One-shot: a second caller must report that it did no work, so nothing
        // stamps the warm-up twice.
        let again = await OCRService.prewarm(options: options)
        #expect(again == false)
    }

    @Test("The recognizer reports the languages this Mac can actually read")
    func offersInstalledLanguages() {
        // Named for what it checks. It used to claim to prove the newest Vision
        // revision was selected — which it never asserted, so a hard-pinned
        // Revision3 (exactly the regression it was guarding) kept it green.
        let languages = OCRService.supportedLanguages()
        #expect(languages.isEmpty == false, "the recognizer should offer languages")
        #expect(languages.contains { $0.hasPrefix("en") }, "got: \(languages)")
    }
}
