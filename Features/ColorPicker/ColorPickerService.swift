import AppKit

enum ColorFormat: String, CaseIterable, Identifiable {
    case hex = "HEX"
    case rgb = "RGB"

    var id: String { rawValue }
}

/// Magnified eyedropper using Apple's native `NSColorSampler`: pixel-accurate,
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
        // Force-reading RGB components on a pattern/catalog color raises: bail
        // to a safe value rather than crash on an exotic sampled color.
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())

        switch format {
        case .hex:
            let s = String(format: "#%02X%02X%02X", r, g, b)
            return uppercaseHex ? s : s.lowercased()
        case .rgb:
            return "rgb(\(r), \(g), \(b))"
        }
    }
}
