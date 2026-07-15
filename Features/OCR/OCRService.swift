import Foundation
@preconcurrency import Vision

/// On-device OCR using Apple's Vision framework. Fast, private, no network,
/// no third-party dependency (no Tesseract). Returns recognized text joined by
/// newlines, ordered top-to-bottom.
enum OCRService {

    /// - Parameters:
    ///   - keepLineBreaks: true = outline mode (preserve layout, newline per line);
    ///     false = inline mode (join everything into one line, TextSniper-style).
    ///   - trim: trim leading/trailing whitespace from the result.
    static func recognizeText(in image: CGImage,
                              keepLineBreaks: Bool = true,
                              trim: Bool = true,
                              languages: [String] = ["en-US"],
                              autoDetectLanguage: Bool = true) async throws -> String {
        // Small selections are Vision's #1 miss cause — tiny glyphs recognize
        // far better upscaled. 2-3× for small regions, no-op for big ones.
        let prepared = upscaledIfSmall(image)
        let first = try await recognizePass(in: prepared, keepLineBreaks: keepLineBreaks,
                                            trim: trim, languages: languages,
                                            autoDetectLanguage: autoDetectLanguage)
        if !first.isEmpty { return first }
        // Nothing found → one more try at double resolution (unless the image
        // is already huge). Catches faint/small text the first pass missed.
        guard image.width < 3000, image.height < 3000,
              let bigger = scaled(prepared, by: 2) else { return first }
        return try await recognizePass(in: bigger, keepLineBreaks: keepLineBreaks,
                                       trim: trim, languages: languages,
                                       autoDetectLanguage: autoDetectLanguage)
    }

    /// ≤700 px → 3×, ≤1400 px → 2×, else untouched.
    private static func upscaledIfSmall(_ img: CGImage) -> CGImage {
        let maxDim = max(img.width, img.height)
        let factor: CGFloat = maxDim <= 700 ? 3 : (maxDim <= 1400 ? 2 : 1)
        guard factor > 1, let up = scaled(img, by: factor) else { return img }
        return up
    }

    private static func scaled(_ img: CGImage, by factor: CGFloat) -> CGImage? {
        let w = Int(CGFloat(img.width) * factor), h = Int(CGFloat(img.height) * factor)
        guard w > 0, h > 0, w <= 8192, h <= 8192,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func recognizePass(in image: CGImage,
                                      keepLineBreaks: Bool,
                                      trim: Bool,
                                      languages: [String],
                                      autoDetectLanguage: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Run the (potentially heavy, .accurate) recognition off the main
            // thread so the UI never beachballs during OCR of a large region.
            // NOTE: no completion handler on the request — when perform() fails
            // Vision would call BOTH the handler (with the error) and throw,
            // double-resuming the continuation (crash). Reading request.results
            // after perform() returns gives exactly one resume path.
            let request = VNRecognizeTextRequest()
            request.revision = VNRecognizeTextRequestRevision3   // newest model
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Best-effort multi-language. Vision falls back gracefully if a
            // language pack isn't present.
            request.recognitionLanguages = languages
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = autoDetectLanguage
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results ?? []
                // Sort top-to-bottom (Vision's origin is bottom-left, so larger
                // y = higher on screen); same-height fragments left-to-right.
                let sorted = observations.sorted {
                    if abs($0.boundingBox.origin.y - $1.boundingBox.origin.y) > 0.01 {
                        return $0.boundingBox.origin.y > $1.boundingBox.origin.y
                    }
                    return $0.boundingBox.origin.x < $1.boundingBox.origin.x
                }
                let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
                var result = lines.joined(separator: keepLineBreaks ? "\n" : " ")
                if trim { result = result.trimmingCharacters(in: .whitespacesAndNewlines) }
                continuation.resume(returning: result)
            }
        }
    }
}
