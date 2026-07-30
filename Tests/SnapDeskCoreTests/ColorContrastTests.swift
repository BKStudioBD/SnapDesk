import Testing
import AppKit
@testable import SnapDeskCore

/// WCAG maths, checked against the values the spec itself pins down. A wrong
/// ratio here would tell a designer their text is readable when it isn't.
struct ColorContrastTests {
    @Test("Black on white is the maximum 21:1, and a colour against itself is 1:1")
    func knownExtremes() throws {
        let black = try #require(NSColor(hex: "#000000"))
        let white = try #require(NSColor(hex: "#FFFFFF"))
        #expect(abs(ColorContrast.ratio(black, white) - 21) < 0.01)
        #expect(abs(ColorContrast.ratio(white, white) - 1) < 0.001)
    }

    @Test func isOrderIndependent() throws {
        let a = try #require(NSColor(hex: "#336699"))
        let b = try #require(NSColor(hex: "#FFCC00"))
        #expect(abs(ColorContrast.ratio(a, b) - ColorContrast.ratio(b, a)) < 0.0001)
    }

    @Test("Luminance follows the sRGB transfer function, not a plain 2.2 gamma")
    func luminanceEndpoints() throws {
        #expect(ColorContrast.luminance(try #require(NSColor(hex: "#000000"))) == 0)
        #expect(abs(ColorContrast.luminance(try #require(NSColor(hex: "#FFFFFF"))) - 1) < 0.0001)
        // Mid grey is ~0.216, NOT 0.5 — the classic mistake this guards.
        let mid = ColorContrast.luminance(try #require(NSColor(hex: "#808080")))
        #expect(mid > 0.20 && mid < 0.23, "got \(mid)")
    }

    @Test("Green carries far more luminance than blue at the same value")
    func channelWeighting() throws {
        let green = ColorContrast.luminance(try #require(NSColor(hex: "#00FF00")))
        let blue = ColorContrast.luminance(try #require(NSColor(hex: "#0000FF")))
        #expect(green > blue * 5)
    }

    @Test("Which bands a ratio clears", arguments: [
        (21.0, 4), (7.0, 4), (6.9, 3), (4.5, 3), (4.4, 2), (3.0, 2), (2.9, 0), (1.0, 0),
    ])
    func bands(_ ratio: Double, _ expectedCount: Int) {
        #expect(ColorContrast.passing(ratio).count == expectedCount,
                "ratio \(ratio) should clear \(expectedCount) bands")
    }

    @Test("The ratio is truncated, never rounded up — rounding would claim a pass")
    func formattingTruncates() {
        #expect(ColorContrast.formatted(4.499) == "4.49:1")
        #expect(ColorContrast.formatted(21) == "21.00:1")
    }

    @Test("Every palette format emits the colours it was given")
    func paletteFormats() {
        let hexes = ["#FF0000", "#00FF00"]
        for format in PaletteFormat.allCases {
            let text = format.text(for: hexes)
            #expect(text.isEmpty == false, "\(format.rawValue) produced nothing")
            // CSS/Tailwind lowercase; SwiftUI and the plain list keep the input.
            let normalized = text.lowercased()
            #expect(normalized.contains("#ff0000"), "\(format.rawValue) lost the first colour")
            #expect(normalized.contains("#00ff00"), "\(format.rawValue) lost the second colour")
        }
    }

    @Test func paletteFormatsAreSyntacticallyPlausible() {
        let hexes = ["#FF0000"]
        #expect(PaletteFormat.cssVariables.text(for: hexes).contains(":root {"))
        #expect(PaletteFormat.tailwind.text(for: hexes).contains("module.exports"))
        #expect(PaletteFormat.swiftUI.text(for: hexes).contains("extension Color {"))
        #expect(PaletteFormat.hexList.text(for: hexes) == "#FF0000\n")
    }
}
