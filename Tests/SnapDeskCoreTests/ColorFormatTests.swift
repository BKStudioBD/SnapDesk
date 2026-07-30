import Testing
import AppKit
@testable import SnapDeskCore

/// What the eyedropper actually puts on the clipboard.
///
/// `ColorHexTests` covers `hexString(uppercase:)`, which is a SEPARATE
/// implementation — `formatted(as:)` re-derives the same rounding on its own,
/// and the rgb() branch had nothing checking it at all. A slip here pastes a
/// wrong colour into someone's stylesheet, silently.
struct ColorFormatTests {

    private func color(_ hex: String) throws -> NSColor {
        try #require(NSColor(hex: hex))
    }

    @Test("HEX comes back exactly as it went in",
          arguments: ["#000000", "#FFFFFF", "#FF8800", "#123456", "#7F7F7F"])
    func hexRoundTrips(_ hex: String) throws {
        #expect(try color(hex).formatted(as: .hex) == hex)
    }

    @Test("Lowercase is honoured, and only for hex")
    func lowercaseFlag() throws {
        let c = try color("#AABBCC")
        #expect(c.formatted(as: .hex, uppercaseHex: false) == "#aabbcc")
        // rgb() has no letters to case, so the flag must not change it.
        #expect(c.formatted(as: .rgb, uppercaseHex: false) == c.formatted(as: .rgb))
    }

    @Test("RGB and HEX describe the SAME colour", .tags(.regression),
          arguments: ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#123456"])
    func rgbAgreesWithHex(_ hex: String) throws {
        let c = try color(hex)
        let rgb = c.formatted(as: .rgb)
        let numbers = rgb.dropFirst(4).dropLast()
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        #expect(numbers.count == 3, "unexpected shape: \(rgb)")
        let rebuilt = String(format: "#%02X%02X%02X", numbers[0], numbers[1], numbers[2])
        #expect(rebuilt == hex)
    }

    @Test("The rgb() form is the shape CSS expects")
    func rgbShape() throws {
        #expect(try color("#FF8800").formatted(as: .rgb) == "rgb(255, 136, 0)")
    }

    @Test("A pattern colour falls back instead of trapping")
    func patternColorIsSafe() {
        // Reading .redComponent on a pattern colour raises; the formatter is
        // handed whatever the sampler returns.
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 4, height: 4)))
        #expect(pattern.formatted(as: .hex) == "#000000")
        #expect(pattern.formatted(as: .rgb) == "#000000")
    }

    @Test("Only the two formats people paste are offered")
    func offersHexAndRgbOnly() {
        #expect(ColorFormat.allCases.map(\.rawValue) == ["HEX", "RGB"])
    }
}
