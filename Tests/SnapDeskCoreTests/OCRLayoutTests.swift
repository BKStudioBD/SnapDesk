import Testing
import AppKit
@testable import SnapDeskCore

/// Table mode and code mode both reshape what the user pastes, so the risk isn't
/// "it doesn't work" — it's that they fire when they shouldn't and mangle plain
/// text. These render real layouts and run the real recognizer.
///
/// Serialized: each test drives Vision, and running several `.accurate` passes at
/// once just makes them all slower.
@Suite(.serialized)
struct OCRLayoutTests {

    /// Draw text at exact positions, so the recognizer sees a genuine layout
    /// rather than a synthetic word list.
    private func render(_ items: [(text: String, x: CGFloat, y: CGFloat)],
                        size: NSSize = NSSize(width: 460, height: 220)) throws -> CGImage {
        let scale: CGFloat = 2
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
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black]
        for item in items {
            (item.text as NSString).draw(at: NSPoint(x: item.x, y: item.y), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.cgImage)
    }

    private var tableOptions: OCROptions {
        var o = OCROptions(engine: .detailed)
        o.tableMode = true
        return o
    }

    @Test("A 3×3 grid comes back as tab-separated cells")
    func recognizesAGrid() async throws {
        let image = try render([
            ("Name", 24, 170), ("Qty", 200, 170), ("Price", 320, 170),
            ("Widget", 24, 130), ("12", 200, 130), ("4.50", 320, 130),
            ("Gadget", 24, 90), ("7", 200, 90), ("19.00", 320, 90),
        ])
        let tsv = try await OCRService.recognizeText(in: image, options: tableOptions)
        let rows = tsv.split(separator: "\n")
        #expect(rows.count == 3)
        for row in rows {
            #expect(row.split(separator: "\t", omittingEmptySubsequences: false).count == 3,
                    "every row should have three cells, got: \(row)")
        }
        #expect(tsv.contains("Widget\t12"), "cells must land under their own heading")
    }

    @Test("Multi-word cells stay ONE cell", .tags(.regression))
    func keepsMultiWordCellsTogether() async throws {
        // Two gaps per row (one word space, one column). The first implementation
        // took the MEDIAN gap as "normal spacing", and the median of two is the
        // larger — so the threshold inflated and nothing ever split.
        let image = try render([
            ("Region", 24, 170), ("Total revenue", 240, 170),
            ("North America", 24, 130), ("1 240", 240, 130),
            ("Europe", 24, 90), ("980", 240, 90),
        ])
        let tsv = try await OCRService.recognizeText(in: image, options: tableOptions)
        #expect(tsv.contains("North America\t"), "got: \(tsv)")
    }

    @Test("Prose is NEVER turned into tabs, even with table mode on", .tags(.regression))
    func leavesProseAlone() async throws {
        // The first implementation clustered every WORD's left edge, so each word
        // of a sentence became its own column.
        let image = try render([
            ("The quick brown fox jumps", 24, 170),
            ("over the lazy dog and then", 24, 140),
            ("keeps running down the road", 24, 110),
        ])
        let text = try await OCRService.recognizeText(in: image, options: tableOptions)
        #expect(text.contains("\t") == false, "got: \(text)")
    }

    @Test("Code mode leaves identifiers as single unrewritten tokens")
    func codeModeKeepsIdentifiers() async throws {
        let image = try render([("getUserById(42)", 24, 150), ("--no-cache", 24, 110)])
        var options = OCROptions(engine: .detailed)
        options.codeMode = true
        let text = try await OCRService.recognizeText(in: image, options: options)
        #expect(text.contains("--no-cache"), "got: \(text)")
        // What code mode actually guarantees: the language model doesn't SPLIT
        // camelCase into English words. It cannot fix a glyph confusion such as
        // capital-I vs lowercase-l — nothing can, from the shape alone.
        #expect(text.contains("get User") == false, "got: \(text)")
    }

    @Test("Both special modes force the detailed engine, since Live Text has neither switch")
    func specialModesForceDetailedEngine() {
        var code = OCROptions()
        code.codeMode = true
        #expect(code.usesLiveText == false)

        var table = OCROptions()
        table.tableMode = true
        #expect(table.usesLiveText == false)

        #expect(OCROptions().usesLiveText, "the plain default should still use Live Text")
    }
}
