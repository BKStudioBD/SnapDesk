import AppKit

enum ColorFormat: String, CaseIterable, Identifiable {
    case hex = "HEX"
    case rgb = "RGB"
    case rgba = "RGBA"
    case hsl = "HSL"
    case cssVar = "CSS var"
    case swiftUI = "SwiftUI"
    case nsColor = "NSColor"

    var id: String { rawValue }
}

/// Magnified eyedropper using Apple's native `NSColorSampler` — pixel-accurate,
/// works anywhere on screen, and needs no extra permission.
enum ColorPickerService {
    static func pick(completion: @escaping (NSColor?) -> Void) {
        let sampler = NSColorSampler()
        sampler.show { color in
            completion(color)
        }
    }
}

extension NSColor {
    /// Formats the color in the requested representation, converted to sRGB.
    func formatted(as format: ColorFormat, uppercaseHex: Bool = true) -> String {
        // Force-reading RGB components on a pattern/catalog color raises — bail
        // to a safe value rather than crash on an exotic sampled color.
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = c.alphaComponent

        switch format {
        case .hex:
            let s = String(format: "#%02X%02X%02X", r, g, b)
            return uppercaseHex ? s : s.lowercased()
        case .rgb:
            return "rgb(\(r), \(g), \(b))"
        case .rgba:
            return String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, a)
        case .hsl:
            let (h, s, l) = Self.rgbToHSL(c.redComponent, c.greenComponent, c.blueComponent)
            return String(format: "hsl(%d, %d%%, %d%%)",
                          Int(h.rounded()), Int((s * 100).rounded()), Int((l * 100).rounded()))
        case .cssVar:
            let hex = String(format: uppercaseHex ? "#%02X%02X%02X" : "#%02x%02x%02x", r, g, b)
            return "--color: \(hex);"
        case .swiftUI:
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)",
                          c.redComponent, c.greenComponent, c.blueComponent)
        case .nsColor:
            return String(format: "NSColor(red: %.3f, green: %.3f, blue: %.3f, alpha: %.2f)",
                          c.redComponent, c.greenComponent, c.blueComponent, a)
        }
    }

    /// RGB (0…1) → HSL with hue in degrees (0…360), s/l in 0…1.
    static func rgbToHSL(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }   // grey
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: CGFloat
        switch mx {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        return (h * 60, s, l)
    }
}
