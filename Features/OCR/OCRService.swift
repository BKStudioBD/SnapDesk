import Foundation
@preconcurrency import Vision

/// On-device OCR using Apple's Vision framework. Fast, private, no network,
/// no third-party dependency, no bundled OCR engine. Returns recognized text joined by
/// newlines, ordered top-to-bottom.
enum OCRService {

    /// - Parameters:
    ///   - keepLineBreaks: true = outline mode (preserve layout, newline per line);
    ///     false = inline mode (join everything into one line).
    ///   - trim: trim leading/trailing whitespace from the result.
    static func recognizeText(in image: CGImage,
                              keepLineBreaks: Bool,
                              trim: Bool,
                              languages: [String],
                              autoDetectLanguage: Bool) async throws -> String {
        // Small selections are Vision's #1 miss cause — tiny glyphs recognize
        // far better upscaled. 2-3× for small regions, no-op for big ones.
        let prepared = upscaledIfSmall(image)
        let first = try await recognizePass(in: prepared, keepLineBreaks: keepLineBreaks,
                                            trim: trim, languages: languages,
                                            autoDetectLanguage: autoDetectLanguage)
        // Whitespace-only counts as a miss too — otherwise (with trim off) a
        // recoverable faint-text selection would skip the retry below.
        if !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return first }

        // Nothing found → one more try at double resolution. Cap on the
        // PREPARED image (the one actually being scaled): the original may
        // already be 2-3× upscaled, and 2× on top of that exploded to a
        // ~144 MB transient bitmap before this guard was fixed.
        let preparedMax = max(prepared.width, prepared.height)
        guard preparedMax * 2 <= 4096, let bigger = scaled(prepared, by: 2) else { return first }
        // Cheap .fast probe first — most empty first passes are selections with
        // genuinely no text (mis-drag, blank area); don't pay a second full
        // .accurate pass just to confirm a guaranteed miss.
        guard await containsAnyText(bigger) else { return first }
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
        // Bounds are defensive only — unreachable from current call sites (the
        // retry guard caps at 4096) — but they hard-cap the CGContext
        // allocation for any future caller.
        guard w > 0, h > 0, w <= 8192, h <= 8192,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Fast, correction-free probe: "is there ANY text here at all?" Costs a
    /// fraction of an .accurate pass; used to gate the expensive retry.
    private static func containsAnyText(_ image: CGImage) async -> Bool {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([request])
                continuation.resume(returning: !(request.results ?? []).isEmpty)
            }
        }
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
            request.automaticallyDetectsLanguage = autoDetectLanguage

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let text = assemble(request.results ?? [], keepLineBreaks: keepLineBreaks)
                continuation.resume(returning:
                    trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text)
            }
        }
    }

    /// Orders observations into visual lines. A naive fuzzy-tolerance sort
    /// comparator is not a strict weak ordering (sorted(by:) output becomes
    /// unspecified on dense captures), and keying off the box BOTTOM edge
    /// reorders same-line fragments whose boxes differ in height. Instead:
    /// strict top-to-bottom sort by center-Y, then greedy grouping by vertical
    /// overlap, then left-to-right within each line.
    private static func assemble(_ observations: [VNRecognizedTextObservation],
                                 keepLineBreaks: Bool) -> String {
        // Vision's origin is bottom-left → larger midY = higher on screen.
        let sorted = observations.sorted {
            let a = $0.boundingBox, b = $1.boundingBox
            return a.midY != b.midY ? a.midY > b.midY : a.minX < b.minX
        }

        var lines: [[VNRecognizedTextObservation]] = []
        var bandMinY = 0.0, bandMaxY = 0.0   // current line's vertical span
        for obs in sorted {
            let box = obs.boundingBox
            if !lines.isEmpty {
                // Same line if the box overlaps ≥50% of the smaller of the two
                // heights (box vs. the line's accumulated band).
                let overlap = min(bandMaxY, box.maxY) - max(bandMinY, box.minY)
                let minH = min(box.height, bandMaxY - bandMinY)
                if minH > 0, overlap >= 0.5 * minH {
                    lines[lines.count - 1].append(obs)
                    bandMinY = min(bandMinY, box.minY)
                    bandMaxY = max(bandMaxY, box.maxY)
                    continue
                }
            }
            lines.append([obs])
            bandMinY = box.minY
            bandMaxY = box.maxY
        }

        let textLines = lines.map { line in
            line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
        }
        return textLines.joined(separator: keepLineBreaks ? "\n" : " ")
    }
}
