import AppKit

/// WCAG 2.1 contrast between two colors, and the pass/fail bands that go with it.
///
/// The whole point of picking colors off a screen is usually to use them
/// together, and "is this readable" is the question a picker can answer but
/// normally doesn't. Pure math on sRGB values — no network, no dependency.
enum ColorContrast {

    /// Relative luminance per WCAG 2.1 (sRGB, gamma-expanded).
    static func luminance(_ color: NSColor) -> Double {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> Double {
            let s = Double(v)
            // The 0.04045 knee and 2.4 exponent are the sRGB transfer function
            // WCAG specifies — NOT a plain 2.2 gamma.
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
             + 0.7152 * channel(c.greenComponent)
             + 0.0722 * channel(c.blueComponent)
    }

    /// Contrast ratio, 1…21. Order-independent.
    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// The WCAG bands, in the order a designer checks them.
    enum Level: String, CaseIterable {
        case aaNormal = "AA text"          // ≥ 4.5:1
        case aaaNormal = "AAA text"        // ≥ 7:1
        case aaLarge = "AA large"          // ≥ 3:1  (≥18pt, or ≥14pt bold)
        case ui = "UI shapes"              // ≥ 3:1  (icons, borders, focus rings)

        var threshold: Double {
            switch self {
            case .aaNormal: 4.5
            case .aaaNormal: 7
            case .aaLarge, .ui: 3
            }
        }
    }

    /// Which bands a ratio clears.
    static func passing(_ ratio: Double) -> [Level] {
        Level.allCases.filter { ratio >= $0.threshold }
    }

    /// "4.83:1" — two decimals is the convention, and rounding UP would claim a
    /// pass the pair doesn't have, so truncate toward zero.
    static func formatted(_ ratio: Double) -> String {
        String(format: "%.2f:1", (ratio * 100).rounded(.down) / 100)
    }
}

/// Export formats for the recent-colors palette. Each emits text the user can
/// paste straight into the file they were already editing.
enum PaletteFormat: String, CaseIterable, Identifiable {
    case cssVariables = "CSS variables"
    case tailwind = "Tailwind config"
    case swiftUI = "SwiftUI"
    case hexList = "Plain hex list"
    var id: String { rawValue }

    /// `hexes` are "#RRGGBB" strings, newest first — the order they were picked.
    func text(for hexes: [String]) -> String {
        let named = hexes.enumerated().map { (index, hex) in (name: "color-\(index + 1)", hex: hex) }
        switch self {
        case .cssVariables:
            let body = named.map { "  --\($0.name): \($0.hex.lowercased());" }.joined(separator: "\n")
            return ":root {\n\(body)\n}\n"
        case .tailwind:
            let body = named.map { "        '\($0.name)': '\($0.hex.lowercased())'," }.joined(separator: "\n")
            return """
            module.exports = {
              theme: {
                extend: {
                  colors: {
            \(body)
                  },
                },
              },
            }

            """
        case .swiftUI:
            let body = named.map { entry -> String in
                let camel = entry.name.split(separator: "-").enumerated()
                    .map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }
                    .joined()
                return "    static let \(camel) = Color(hex: \"\(entry.hex)\")"
            }.joined(separator: "\n")
            return "extension Color {\n\(body)\n}\n"
        case .hexList:
            return hexes.joined(separator: "\n") + "\n"
        }
    }
}
