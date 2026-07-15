import AppKit
import SwiftUI

extension NSColor {
    /// "#RRGGBB" in sRGB. Pass uppercase=false for lowercase hex.
    func hexString(uppercase: Bool = true) -> String {
        // Force-reading .redComponent on a pattern/catalog color raises — fall
        // back to a neutral swatch instead of crashing.
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let s = String(format: "#%02X%02X%02X", r, g, b)
        return uppercase ? s : s.lowercased()
    }

    /// Parse "#RRGGBB" / "RRGGBB". Returns nil if malformed.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: String) {
        let ns = NSColor(hex: hex) ?? .gray
        self.init(nsColor: ns)
    }
}
