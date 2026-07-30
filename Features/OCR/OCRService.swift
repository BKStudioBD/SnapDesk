import AppKit
@preconcurrency import Vision
import VisionKit

/// Which recognizer runs first.
enum OCREngine: String, CaseIterable, Identifiable {
    /// macOS Live Text first — it reads columns, tables and wrapped paragraphs
    /// in the right order, which a plain top-to-bottom word sort cannot. Falls
    /// back to the detailed pipeline whenever it comes up empty.
    case automatic = "Automatic"
    /// Always the word-box pipeline. The only mode that can take custom words
    /// and space paragraphs by their measured gaps.
    case detailed = "Detailed"
    var id: String { rawValue }
}

/// Everything the recognizer needs to know about the user's preferences.
/// Passed as one value so a new option never means a new parameter on five
/// call sites.
struct OCROptions {
    var engine: OCREngine = .automatic
    /// Empty + `autoDetect` lets Vision pick the script.
    var languages: [String] = []
    var autoDetect: Bool = true
    /// Domain words the language model should favour (product names, jargon,
    /// identifiers it would otherwise "correct" into something else).
    var customWords: [String] = []
    /// true = keep the on-screen line layout; false = one line.
    var keepLineBreaks: Bool = true
    /// Blank line between blocks that the layout separates. In `.detailed` this
    /// is measured from the line gaps; with Live Text it keeps (or collapses)
    /// the paragraph breaks macOS already found.
    var paragraphBreaks: Bool = true
    var trim: Bool = true
    /// Turn the language model OFF. Identifiers like `getUserById()` or `--no-cache`
    /// get "corrected" into English words otherwise, which silently breaks pasted
    /// code. Forces the detailed engine (Live Text has no such switch).
    var codeMode: Bool = false
    /// Lay recognized text out as TAB-separated columns when the words fall into
    /// clear vertical bands, so a table pastes into a spreadsheet as cells.
    var tableMode: Bool = false

    /// Live Text takes no custom words, so asking for them picks the pipeline
    /// that honours them — silently dropping them would be worse.
    /// Code mode and table mode both need the word boxes, which only the detailed
    /// pass produces — so they force it, exactly like custom words do.
    var usesLiveText: Bool {
        engine == .automatic && customWords.isEmpty && codeMode == false && tableMode == false
    }
}

/// On-device text recognition (Apple Vision + Live Text). Private, offline, no
/// bundled engine, no third-party dependency.
///
/// Two recognizers, in order:
///
///   A. Live Text (`ImageAnalyzer`) — macOS's own reader. Its transcript comes
///      out in reading order with paragraphs already joined, which is what a
///      multi-column or wrapped block needs. No boxes, no knobs.
///   B. The detailed pipeline — one happy path plus escalating rescues, tried in
///      order and stopped at the first that finds text, so an ordinary capture
///      pays for exactly one pass and only a genuine miss walks further:
///
///        1. `readWhole` on the (small-upscaled) image                — common case
///        2. detected-but-unreadable (boxes found, no glyphs) → 2× pass
///        3. nothing detected → a larger pass, then tiling            — blind spots
///
/// Everything internal to B speaks ONE coordinate space: `Word`s in pixels,
/// top-left origin, relative to the prepared image. Vision's own boxes are
/// normalized and bottom-left — converted once, at the edge, so the ordering
/// logic never has to think about it.
enum OCRService {

    // MARK: - Public

    static func recognizeText(in image: CGImage, options: OCROptions) async throws -> String {
        // Both recognizers see the SAME prepared image — tiny glyphs are the #1
        // miss for either of them.
        let prepared = upscaledIfSmall(image)

        if options.usesLiveText, let transcript = await liveText(prepared, options: options) {
            return finish(shape(transcript, options: options), options: options)
        }
        let words = try await recognizeWords(in: prepared, options: options)
        return finish(compose(words, options: options), options: options)
    }

    /// Recognition languages this OS actually has, newest model first — the list
    /// Settings offers. Empty only if Vision refuses to answer.
    static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.revision = revision
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    private static func finish(_ text: String, options: OCROptions) -> String {
        options.trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    // MARK: - Live Text

    /// Creating an analyzer is the expensive part, not analyzing — one for the
    /// process, reused.
    private static let analyzer = ImageAnalyzer()

    /// macOS's Live Text transcript, or nil when it's unsupported, errors, or
    /// finds nothing (all three mean "let the detailed pipeline try").
    private static func liveText(_ image: CGImage, options: OCROptions) async -> String? {
        guard ImageAnalyzer.isSupported else { return nil }
        var configuration = ImageAnalyzer.Configuration([.text])
        // Empty = let macOS choose, same contract as Vision's auto-detect.
        configuration.locales = options.autoDetect ? [] : options.languages
        let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        do {
            let analysis = try await analyzer.analyze(ns, orientation: .up,
                                                     configuration: configuration)
            let transcript = analysis.transcript
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : transcript
        } catch {
            NSLog("SnapDesk: Live Text pass failed, falling back — \(error)")
            return nil
        }
    }

    /// Live Text hands back ONE line per block, in reading order, with the lines
    /// a paragraph wrapped onto already joined. So the block boundaries are the
    /// paragraph boundaries — nothing to measure, just the user's choices to
    /// apply. (Blank lines it emits are normalized away first, so the spacing
    /// comes out the same whether macOS added them or we did.)
    private static func shape(_ transcript: String, options: OCROptions) -> String {
        let blocks = transcript.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard options.keepLineBreaks else { return blocks.joined(separator: " ") }
        guard options.paragraphBreaks, blocks.count > 1 else {
            return blocks.joined(separator: "\n")
        }
        var out = blocks[0]
        for i in 1..<blocks.count {
            // Blank line only BETWEEN TWO PROSE blocks. A list, a table column
            // or a row of labels arrives as many short blocks, and double-spacing
            // those reads worse than leaving them alone — the detailed engine is
            // the one that can tell them apart by measuring the gaps.
            let prose = isProse(blocks[i - 1]) && isProse(blocks[i])
            out += prose ? "\n\n" : "\n"
            out += blocks[i]
        }
        return out
    }

    /// Long enough to be a sentence rather than a label or a cell.
    private static func isProse(_ line: String) -> Bool {
        line.split(whereSeparator: \.isWhitespace).count > 4
    }

    // MARK: - Pipeline

    /// A recognized word placed in a shared pixel space (top-left origin).
    private struct Word {
        let rect: CGRect
        let text: String
    }

    /// Runs the full escalation and returns the words in the PREPARED image's
    /// pixel space. Empty means genuinely nothing readable.
    private static func recognizeWords(in prepared: CGImage, options: OCROptions) async throws -> [Word] {
        // 1. The one pass an ordinary selection ever needs.
        let first = try await readWhole(prepared, options: options)
        if !first.words.isEmpty { return first.words }

        // 2. Boxes were detected but not read — faint or sub-pixel glyphs that
        //    more resolution recovers. (Zero boxes means the DETECTOR came up
        //    empty; scaling the same framing won't change that — a different
        //    framing, below, will.)
        if first.observations > 0,
           let bigger = scaledToMinSide(prepared, target: minSideForRetry),
           bigger !== prepared {
            let retry = try await readWhole(bigger, options: options)
            let scale = CGFloat(prepared.width) / CGFloat(bigger.width)
            if !retry.words.isEmpty { return retry.words.map { rescale($0, by: scale) } }
        }

        // 3a. Detector found nothing. First try simply handing Vision more
        //     pixels: a small or awkwardly-proportioned region is often under a
        //     detection threshold that a larger frame clears.
        if let bigger = scaledToMinSide(prepared, target: minSideForRescue),
           bigger !== prepared {
            let up = try await readWhole(bigger, options: options)
            let scale = CGFloat(prepared.width) / CGFloat(bigger.width)
            if !up.words.isEmpty { return up.words.map { rescale($0, by: scale) } }
        }

        // 3b. Still nothing. Vision's detector normalizes by the long side, so a
        //     wide strip (one line dragged tightly) or a large busy region can
        //     hide text that a well-proportioned sub-tile reads cleanly. Cut it
        //     into overlapping tiles and keep each word once (see `tileWords`).
        return try await tileWords(prepared, options: options)
    }

    // MARK: - Vision

    /// Newest recognition model this OS actually ships. Vision adds a revision
    /// with most macOS releases; asking for one that isn't installed throws, and
    /// pinning an old number leaves accuracy on the table for everyone on a
    /// newer system. Resolved once — the set can't change mid-process.
    private static let revision: Int = {
        Array(VNRecognizeTextRequest.supportedRevisions).max() ?? VNRecognizeTextRequestRevision3
    }()

    private static func configure(_ request: VNRecognizeTextRequest, options: OCROptions) {
        request.revision = revision
        request.recognitionLevel = .accurate
        // Code mode: no language model. It's what turns `getUserById()` into
        // "get User By Id" and `--no-cache` into "-no cache".
        request.usesLanguageCorrection = options.codeMode == false
        // Empty + automaticallyDetectsLanguage lets Vision pick the script;
        // otherwise the passed languages constrain it. It falls back gracefully
        // when a language pack is absent.
        request.recognitionLanguages = options.languages
        request.automaticallyDetectsLanguage = options.autoDetect
        // Words the language model would otherwise "correct" away. Only read
        // when usesLanguageCorrection is on, which it is.
        request.customWords = options.customWords
    }

    /// Recognize an entire image. Returns word boxes in the image's own pixel
    /// space (top-left) plus the raw observation count — the caller needs the
    /// latter to distinguish "no text detected" from "detected, unreadable".
    private static func readWhole(_ image: CGImage, options: OCROptions) async throws -> (words: [Word], observations: Int) {
        try await withCheckedThrowingContinuation { continuation in
            // No completion handler: on failure Vision would BOTH call the
            // handler and throw, double-resuming the continuation. Reading
            // `results` after `perform` gives exactly one resume path.
            let request = VNRecognizeTextRequest()
            configure(request, options: options)
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            // Off the main thread — an .accurate pass on a big region is heavy.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error); return
                }
                let observations = request.results ?? []
                let size = CGSize(width: image.width, height: image.height)
                let words = observations.flatMap { wordBoxes(from: $0, imageSize: size) }
                continuation.resume(returning: (words, observations.count))
            }
        }
    }

    /// One observation → its word boxes in pixel space (top-left origin).
    /// Vision boxes are normalized (0…1) and bottom-left; convert here so
    /// nothing downstream deals in Vision's coordinate system.
    private static func wordBoxes(from observation: VNRecognizedTextObservation,
                              imageSize: CGSize) -> [Word] {
        guard let candidate = observation.topCandidates(1).first else { return [] }
        func toPixels(_ norm: CGRect) -> CGRect {
            CGRect(x: norm.minX * imageSize.width,
                   y: (1 - norm.maxY) * imageSize.height,   // flip to top-left
                   width: norm.width * imageSize.width,
                   height: norm.height * imageSize.height)
        }
        var out: [Word] = []
        for (range, text) in candidate.string.wordRanges {
            // Prefer the word's own box; fall back to the whole observation's
            // when Vision can't map the substring (rare) — a slightly misplaced
            // word beats a dropped one.
            let norm = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
            out.append(Word(rect: toPixels(norm), text: text))
        }
        return out
    }

    // MARK: - Tiling rescue

    /// Recognize by cutting the image into overlapping tiles Vision handles
    /// well, then keeping each word exactly once. A word is owned by the single
    /// tile whose CORE (the half-overlap inset) contains its centre; the cores
    /// partition the image with no gaps, and the overlap guarantees any word
    /// clipped by one tile's edge sits whole inside its owner. Generalizes to
    /// both wide strips (many columns) and large regions (a full grid).
    private static func tileWords(_ image: CGImage, options: OCROptions) async throws -> [Word] {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cols = tileStarts(full.width)
        let rows = tileStarts(full.height)
        // Single tile that IS the whole image → identical to the pass that
        // already failed; nothing to gain, skip the work.
        if cols.count == 1 && rows.count == 1 { return [] }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var words: [Word] = []
                for cx in cols {
                    for ry in rows {
                        let tile = CGRect(x: cx.start, y: ry.start,
                                          width: cx.length, height: ry.length)
                        guard let cropped = image.cropping(to: tile) else { continue }
                        let request = VNRecognizeTextRequest()
                        configure(request, options: options)
                        try? VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
                        let tileSize = CGSize(width: tile.width, height: tile.height)
                        for observation in request.results ?? [] {
                            for w in self.wordBoxes(from: observation, imageSize: tileSize) {
                                let centre = CGPoint(x: tile.minX + w.rect.midX,
                                                     y: tile.minY + w.rect.midY)
                                guard cx.core.contains(centre.x), ry.core.contains(centre.y) else { continue }
                                // Re-home the box into the full image's space.
                                words.append(Word(rect: w.rect.offsetBy(dx: tile.minX, dy: tile.minY),
                                                  text: w.text))
                            }
                        }
                    }
                }
                continuation.resume(returning: words)
            }
        }
    }

    private struct Tile { let start: CGFloat; let length: CGFloat; let core: ClosedRange<CGFloat> }

    /// Tile offsets along one axis: ≤`tileMax` each, 45% overlap, with the core
    /// (owning) range for each tile. The first/last tiles own right up to the
    /// image edge; interior tiles own only inside their half-overlap inset.
    private static func tileStarts(_ total: CGFloat) -> [Tile] {
        guard total > tileMax else { return [Tile(start: 0, length: total, core: 0...total)] }
        let overlap = tileMax * 0.45, step = tileMax - overlap
        var tiles: [Tile] = []
        var start: CGFloat = 0
        while true {
            let length = min(tileMax, total - start)
            let isFirst = start == 0, isLast = start + length >= total
            let lo = start + (isFirst ? 0 : overlap / 2)
            let hi = start + length - (isLast ? 0 : overlap / 2)
            tiles.append(Tile(start: start, length: length, core: lo...max(lo, hi)))
            if isLast { break }
            start += step
        }
        return tiles
    }

    private static func rescale(_ w: Word, by scale: CGFloat) -> Word {
        Word(rect: CGRect(x: w.rect.minX * scale, y: w.rect.minY * scale,
                          width: w.rect.width * scale, height: w.rect.height * scale),
             text: w.text)
    }

    // MARK: - Line assembly

    /// Words → text. Group into visual lines by vertical overlap against each
    /// line's ANCHOR (its first, topmost word) — never a running band, which
    /// would inflate around a tall word (a heading beside body text) and swallow
    /// adjacent lines. Then left-to-right within each line, top-to-bottom overall.
    private static func compose(_ words: [Word], options: OCROptions) -> String {
        guard !words.isEmpty else { return "" }
        // Top-to-bottom (pixel space: smaller y = higher), left tiebreak.
        let sorted = words.sorted {
            $0.rect.midY != $1.rect.midY ? $0.rect.midY < $1.rect.midY : $0.rect.minX < $1.rect.minX
        }
        var lines: [[Word]] = []
        var anchor = CGRect.zero
        for w in sorted {
            if !lines.isEmpty {
                let overlap = min(anchor.maxY, w.rect.maxY) - max(anchor.minY, w.rect.minY)
                let minH = min(w.rect.height, anchor.height)
                if minH > 0, overlap >= 0.5 * minH {
                    lines[lines.count - 1].append(w)
                    continue
                }
            }
            lines.append([w])
            anchor = w.rect
        }
        let texts = lines.map { line in
            line.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ")
        }
        if options.tableMode, let table = asTable(lines) { return table }
        guard options.keepLineBreaks else { return texts.joined(separator: " ") }
        guard options.paragraphBreaks else { return texts.joined(separator: "\n") }
        return joinWithParagraphs(texts, lines: lines)
    }

    /// Tab-separated rows when the layout genuinely forms COLUMNS.
    ///
    /// Two stages, and the FIRST is what keeps prose safe:
    ///
    ///  1. Split each line into CELLS on unusually wide horizontal gaps. A
    ///     sentence has near-uniform word spacing, so it yields exactly one cell
    ///     and can never become tabs. A table row has one huge gap per column
    ///     boundary. (Clustering word left-edges directly — without this step —
    ///     turns every word of a sentence into its own column.)
    ///  2. Cluster those cell left-edges across lines into column anchors, and
    ///     require the anchors to REPEAT down the page.
    ///
    /// Returns nil whenever the evidence is weak, so ordinary text is never
    /// mangled.
    private static func asTable(_ lines: [[Word]]) -> String? {
        guard lines.count >= 2 else { return nil }
        let heights = lines.flatMap { $0 }.map(\.rect.height).sorted()
        guard heights.isEmpty == false else { return nil }
        // Tolerance proportional to text size, so it holds at any zoom or DPI.
        let tolerance = max(heights[heights.count / 2] * 1.2, 6)

        let rowCells = lines.map { cells(in: $0) }
        // A table needs at least two rows that actually have multiple cells.
        guard rowCells.filter({ $0.count >= 2 }).count >= 2 else { return nil }

        // Candidate anchors from every cell's left edge.
        var anchors: [CGFloat] = []
        for x in rowCells.flatMap({ $0 }).map(\.x).sorted() {
            if let last = anchors.last, x - last <= tolerance { continue }
            anchors.append(x)
        }
        // Keep only anchors that RECUR — a one-off indent isn't a column.
        let recurring = anchors.filter { anchor in
            rowCells.filter { row in row.contains { abs($0.x - anchor) <= tolerance } }.count >= 2
        }
        guard recurring.count >= 2 else { return nil }

        var out: [[String]] = []
        for row in rowCells {
            var cells = [String](repeating: "", count: recurring.count)
            for cell in row {
                // Nearest recurring anchor at or before this cell's left edge.
                let column = recurring.lastIndex { cell.x + tolerance >= $0 } ?? 0
                cells[column] = cells[column].isEmpty ? cell.text : cells[column] + " " + cell.text
            }
            out.append(cells)
        }
        // Trailing empty columns would paste as stray tabs.
        let width = out.map { row in (row.lastIndex { $0.isEmpty == false } ?? 0) + 1 }.max() ?? 1
        return out.map { $0.prefix(width).joined(separator: "\t") }.joined(separator: "\n")
    }

    /// One line → its cells, split where the horizontal gap is far wider than the
    /// line's own typical word spacing. Uniformly-spaced prose gives one cell.
    private static func cells(in line: [Word]) -> [(x: CGFloat, text: String)] {
        let sorted = line.sorted { $0.rect.minX < $1.rect.minX }
        guard let first = sorted.first else { return [] }
        guard sorted.count > 1 else { return [(first.rect.minX, first.text)] }
        var gaps: [CGFloat] = []
        for i in 1..<sorted.count { gaps.append(max(0, sorted[i].rect.minX - sorted[i - 1].rect.maxX)) }
        // Threshold from LINE HEIGHT, not from the gaps themselves. A word space
        // is roughly a third of the line height in any font at any zoom, while a
        // column boundary is at least a whole line height and usually several — so
        // 0.9× separates them cleanly.
        //
        // Deliberately NOT the median gap: a two-column row has exactly two gaps
        // (one space, one column), and the median of two picks the LARGER, which
        // inflated the threshold so nothing ever split. Line height has no such
        // dependence on how many gaps a line happens to have.
        let lineHeight = sorted.map(\.rect.height).max() ?? 0
        let threshold = max(lineHeight * 0.9, 8)

        var out: [(x: CGFloat, text: String)] = [(first.rect.minX, first.text)]
        for i in 1..<sorted.count {
            if gaps[i - 1] > threshold {
                out.append((sorted[i].rect.minX, sorted[i].text))
            } else {
                out[out.count - 1].text += " " + sorted[i].text
            }
        }
        return out
    }

    /// Line breaks, plus a BLANK line wherever the vertical gap says the layout
    /// itself broke. Within one paragraph the gap between wrapped lines is
    /// near-constant, so the median gap is the paragraph's own leading and
    /// anything clearly above it is a real break — no font size or DPI assumed.
    ///
    /// Needs enough lines for a median to mean anything; two lines have exactly
    /// one gap, which is its own median and would never look unusual.
    private static func joinWithParagraphs(_ texts: [String], lines: [[Word]]) -> String {
        guard texts.count >= 3 else { return texts.joined(separator: "\n") }
        let rects = lines.map { line in
            line.dropFirst().reduce(line[0].rect) { $0.union($1.rect) }
        }
        var gaps: [CGFloat] = []
        for i in 1..<rects.count { gaps.append(max(0, rects[i].minY - rects[i - 1].maxY)) }
        let median = gaps.sorted()[gaps.count / 2]

        var out = texts[0]
        for i in 1..<texts.count {
            // Two guards, and the break needs BOTH to be cleared:
            //  · 1.8× the median — unusual for this block's own leading;
            //  · 0.7× the smaller line's height — an absolute floor, so tightly
            //    set text (median 0) can't turn every line into a paragraph.
            let lineHeight = min(rects[i].height, rects[i - 1].height)
            let isBreak = gaps[i - 1] > max(median * 1.8, lineHeight * 0.7)
            out += isBreak ? "\n\n" : "\n"
            out += texts[i]
        }
        return out
    }

    // MARK: - Scaling

    /// Ceiling for any bitmap this file allocates: 8 MP ≈ 32 MB at 4 bytes/px.
    private static let maxPixels = 8_000_000
    /// Longest tile edge Vision reads comfortably.
    private static let tileMax: CGFloat = 1400
    /// Retry (detected-unreadable) target for the shorter side.
    private static let minSideForRetry = 900
    /// Rescue (nothing-detected) target for the shorter side — push harder.
    private static let minSideForRescue = 1200

    /// Upscale small selections up front — tiny glyphs are Vision's #1 miss and
    /// recognize far better enlarged. Keyed off the SHORT side (glyph height
    /// tracks the short side, not a wide strip's long edge) and off the long
    /// side for whole blocks; whichever asks for more wins, capped by budget.
    private static func upscaledIfSmall(_ img: CGImage) -> CGImage {
        let longSide = max(img.width, img.height), shortSide = min(img.width, img.height)
        var factor: CGFloat = longSide <= 700 ? 3 : (longSide <= 1400 ? 2 : 1)
        if factor == 1 { factor = shortSide <= 120 ? 3 : (shortSide <= 240 ? 2 : 1) }
        guard factor > 1 else { return img }
        return scaled(img, by: factor) ?? img
    }

    /// Scale so the SHORTER side reaches `target` px (never downscales). Returns
    /// the same image untouched when it's already at/above target or won't fit
    /// the pixel budget.
    private static func scaledToMinSide(_ img: CGImage, target: Int) -> CGImage? {
        let shortSide = min(img.width, img.height)
        guard shortSide < target else { return img }
        let factor = CGFloat(target) / CGFloat(shortSide)
        return scaled(img, by: factor) ?? img
    }

    private static func scaled(_ img: CGImage, by factor: CGFloat) -> CGImage? {
        var w = Int(CGFloat(img.width) * factor), h = Int(CGFloat(img.height) * factor)
        // Respect the pixel budget: shrink the factor until it fits, rather than
        // refusing to scale at all.
        if w * h > maxPixels {
            let fit = (Double(maxPixels) / Double(img.width * img.height)).squareRoot()
            w = Int(Double(img.width) * fit); h = Int(Double(img.height) * fit)
        }
        guard w > img.width || h > img.height, w > 0, h > 0, w <= 8192, h <= 8192,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Prewarm

    private static let prewarmLock = NSLock()
    private static var prewarmed = false

    /// Claims the one-time prewarm; false when another caller already has it.
    /// Kept synchronous so the lock is never held across a suspension point.
    private static func claimPrewarm() -> Bool {
        prewarmLock.lock()
        defer { prewarmLock.unlock() }
        if prewarmed { return false }
        prewarmed = true
        return true
    }

    /// Load the recognizer's model BEFORE the user finishes dragging. The first
    /// `.accurate` pass in a process pays the full model load; nothing about a
    /// capture depends on it, so it overlaps the drag instead of the wait.
    /// Idempotent and cheap; safe to call on every OCR. MUST mirror the real
    /// request config, and the probe image MUST contain glyphs (a blank image
    /// short-circuits before the recognizer loads).
    static func prewarm(options: OCROptions) async {
        guard claimPrewarm() else { return }
        guard let image = prewarmImage() else { return }
        // Warm whichever recognizer will actually run first, then Vision, which
        // is the fallback for every mode.
        if options.usesLiveText { _ = await liveText(image, options: options) }
        let request = VNRecognizeTextRequest()
        configure(request, options: options)
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }

    /// Build Vision's on-device model cache ONCE per installed build, in the
    /// background. The very first recognition by a new binary costs ~32 s (macOS
    /// compiles the model bundle for this executable, then caches it keyed to
    /// the binary); later launches warm in ~0.1 s. So this is per-update, not
    /// per-launch — and doing it right after a self-relaunch spends that 32 s
    /// where nobody waits. Skipping it otherwise keeps a menu-bar app that may
    /// never OCR from holding the ~54 MB the models occupy.
    static func warmModelCacheAfterUpdate(options: OCROptions) {
        let key = "ocr.warmedBuild", defaults = UserDefaults.standard
        let stamp = buildStamp()
        guard defaults.string(forKey: key) != stamp else { return }
        Task.detached(priority: .background) {
            await prewarm(options: options)
            defaults.set(stamp, forKey: key)
        }
    }

    /// The model cache is keyed to the executable; its mtime is what actually
    /// changes between dev builds (the version string doesn't).
    private static func buildStamp() -> String {
        guard let path = Bundle.main.executablePath,
              let date = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        else { return "unknown" }
        return String(Int(date.timeIntervalSince1970))
    }

    private static func prewarmImage() -> CGImage? {
        let size = NSSize(width: 240, height: 80)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("Ag 123" as NSString).draw(at: NSPoint(x: 10, y: 24),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 34),
                                                     .foregroundColor: NSColor.black])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

private extension String {
    /// Whitespace-separated words with the ranges Vision needs to locate each
    /// inside its recognized line.
    var wordRanges: [(Range<String.Index>, String)] {
        var out: [(Range<String.Index>, String)] = []
        var i = startIndex
        while i < endIndex {
            guard let wordStart = self[i...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let wordEnd = self[wordStart...].firstIndex(where: { $0.isWhitespace }) ?? endIndex
            out.append((wordStart..<wordEnd, String(self[wordStart..<wordEnd])))
            i = wordEnd
        }
        return out
    }
}
