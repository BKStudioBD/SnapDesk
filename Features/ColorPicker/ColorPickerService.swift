import AppKit

/// Magnified eyedropper using Apple's native `NSColorSampler` — pixel-accurate,
/// works anywhere on screen, and needs no extra permission.
///
/// One job: sample a pixel and hand back its color. The hex string it is copied
/// as lives in `ColorHex`, which the recent-colors swatches share.
enum ColorPickerService {
    static func pick(completion: @escaping (NSColor?) -> Void) {
        let sampler = NSColorSampler()
        sampler.show { color in
            completion(color)
        }
    }
}
