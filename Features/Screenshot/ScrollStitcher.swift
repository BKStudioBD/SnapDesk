import CoreGraphics

/// The maths behind scrolling capture: turn frames into row signatures, find how
/// much two consecutive frames overlap, and paste the new rows into one tall
/// image.
///
/// Split out of `ScrollCapture` because it is pure — CGImages in, a CGImage out,
/// no window, no permission, no Vision. That is what lets it be tested, and the
/// stitcher is the part most worth testing: a seam bug silently duplicates or
/// drops content, and nobody notices until they read the screenshot later.
enum ScrollStitcher {

    /// Per-row signature: 3 horizontal bands (left/mid/right thirds) of a
    /// 96-wide grayscale downsample → 3 floats per row. Bands keep horizontal
    /// structure a single row-mean loses, so alignment is far less likely to
    /// snap to the wrong offset on repetitive content. Layout: [l,m,r] * rows.
    static let bandsPerRow = 3

    static func rowSignature(_ img: CGImage) -> [Float] {
        let w = 96, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let sig: [Float]? = buf.withUnsafeMutableBytes { raw -> [Float]? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let pixels = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var out = [Float](repeating: 0, count: h * bandsPerRow)
            let third = w / 3
            for y in 0..<h {
                for b in 0..<bandsPerRow {
                    var sum = 0
                    let x0 = b * third, x1 = (b == bandsPerRow - 1) ? w : (b + 1) * third
                    for x in x0..<x1 { sum += Int(pixels[y * w + x]) }
                    out[y * bandsPerRow + b] = Float(sum) / Float(x1 - x0)
                }
            }
            return out
        }
        return sig ?? []   // row 0 = image TOP
    }

    /// Rows in a signature.
    static func rows(_ sig: [Float]) -> Int { sig.count / bandsPerRow }

    /// Mean abs diff between the same row of two signatures.
    @inline(__always)
    static func rowDiff(_ a: [Float], _ ra: Int, _ b: [Float], _ rb: Int) -> Float {
        var s: Float = 0
        for k in 0..<bandsPerRow { s += abs(a[ra * bandsPerRow + k] - b[rb * bandsPerRow + k]) }
        return s / Float(bandsPerRow)
    }

    /// Mean abs diff between two whole signatures — "did the content change at
    /// all", which is what decides whether a frame is worth keeping.
    static func meanDiff(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var s: Float = 0
        for i in 0..<a.count { s += abs(a[i] - b[i]) }
        return s / Float(a.count)
    }

    /// Row contrast (max band spread) — flat rows (whitespace) carry no
    /// alignment information and are down-weighted in matching.
    @inline(__always)
    static func rowContrast(_ a: [Float], _ r: Int) -> Float {
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for k in 0..<bandsPerRow {
            let v = a[r * bandsPerRow + k]
            lo = min(lo, v); hi = max(hi, v)
        }
        return hi - lo
    }

    /// Sticky header height (rows): rows at the top that stayed identical
    /// across EVERY frame (site nav bars, toolbars). They must be ignored when
    /// aligning, or the header stitches into the image over and over.
    static func stickyHeaderRows(_ sigs: [[Float]]) -> Int {
        guard sigs.count >= 3, let first = sigs.first else { return 0 }
        let h = rows(first)
        let maxHeader = h * 2 / 5
        var header = maxHeader
        for sig in sigs.dropFirst() {
            guard rows(sig) == h else { return 0 }
            var match = 0
            while match < header, rowDiff(first, match, sig, match) < 2.0 { match += 1 }
            header = min(header, match)
            if header == 0 { break }
        }
        return header
    }

    /// Find how many rows at the BOTTOM of `prev` match the TOP of `next`,
    /// ignoring `header` sticky rows at the top of both frames. Contrast-
    /// weighted SAD: flat (whitespace) rows contribute little, so alignment
    /// locks onto real content edges instead of blank space.
    static func bestOverlap(_ prev: [Float], _ next: [Float], header: Int) -> Int? {
        let h = min(rows(prev), rows(next)) - header
        guard h > 40 else { return nil }
        var bestO = 0
        var bestScore = Float.infinity
        let minO = max(12, h / 20)
        // Starts at h, not h-1: a frame that did not scroll at all overlaps
        // COMPLETELY, and stopping one row short meant the best it could report
        // was a one-row shift — which scores badly and lands the matcher on some
        // unrelated offset, appending a band of content the image already has.
        var o = h
        while o >= minO {
            var s: Float = 0
            var wsum: Float = 0
            let step = max(1, o / 160)   // sample rows for speed
            var i = 0
            while i < o {
                let rp = header + h - o + i     // row in prev
                let rn = header + i             // row in next
                let w = max(0.15, min(1, rowContrast(prev, rp) / 24))
                s += rowDiff(prev, rp, next, rn) * w
                wsum += w
                i += step
            }
            let score = s / max(0.001, wsum)
            if score < bestScore { bestScore = score; bestO = o }
            o -= 1
        }
        return bestScore < 4.0 ? bestO + header : nil   // weak match → new content
    }

    /// SAD score of a specific overlap (rows) between prev-bottom and next-top.
    static func overlapScore(_ prev: [Float], _ next: [Float], overlap: Int, header: Int) -> Float {
        let h = min(rows(prev), rows(next)) - header
        let o = overlap - header
        guard h > 0, o > 4, o < h else { return .infinity }
        var s: Float = 0, wsum: Float = 0
        let step = max(1, o / 160)
        var i = 0
        while i < o {
            let rp = header + h - o + i, rn = header + i
            let w = max(0.15, min(1, rowContrast(prev, rp) / 24))
            s += rowDiff(prev, rp, next, rn) * w
            wsum += w
            i += step
        }
        return s / max(0.001, wsum)
    }

    /// Paste the frames into one tall image.
    ///
    /// `offsets` are scroll amounts measured during capture (Vision
    /// registration); `visionOffset` is the fallback for a pair that has none.
    /// It is a closure rather than a direct call so this file stays free of
    /// Vision — and so a test can drive the stitcher with no offsets at all.
    static func stitch(frames: [CGImage], signatures: [[Float]], offsets: [Int?] = [],
                       visionOffset: ((CGImage, CGImage) -> Int?)? = nil) -> CGImage? {
        guard let first = frames.first else { return nil }
        guard frames.count > 1 else { return first }
        let w = first.width
        // Sticky site header (nav bar etc.) present in every frame → ignore it
        // while aligning and never re-append it mid-image.
        let sigHeader = stickyHeaderRows(signatures)
        // `rowSignature` hands back an EMPTY array when its downsample context
        // can't be allocated, and the frame is stored anyway (an empty signature
        // reads as "changed", so it is never deduped away). Dividing by its row
        // count then makes the scale infinite, and `Int(nan)` traps a line later:
        // one failed allocation mid-capture turned pressing Done into a crash
        // that took the whole scroll capture with it.
        let sigRows = rows(signatures[0])
        let scaleY = (first.height > 0 && sigRows > 0) ? Float(first.height) / Float(sigRows) : 1
        let headerPx = Int(Float(sigHeader) * scaleY)
        // Row ranges of each frame to append (frame, fromRow).
        var pieces: [(CGImage, Int)] = [(first, 0)]
        var total = first.height
        var ref = 0   // last appended frame — skipped frames must not shift the chain
        for i in 1..<frames.count {
            let h = min(rows(signatures[ref]), rows(signatures[i]))
            // 1) Registration candidate (precomputed during capture), verified
            //    ±2 rows against the signature score…
            var overlap: Int? = nil
            if ref == i - 1, let scroll = (i - 1) < offsets.count
                ? offsets[i - 1] : visionOffset?(frames[i - 1], frames[i]) {
                var bestO: Int? = nil
                var bestS = Float(4.0)
                for d in -2...2 {
                    let o = h - scroll + d
                    let sc = overlapScore(signatures[ref], signatures[i], overlap: o, header: sigHeader)
                    if sc < bestS { bestS = sc; bestO = o }
                }
                overlap = bestO
            }
            // 2) …else the full contrast-weighted SAD search.
            if overlap == nil {
                overlap = bestOverlap(signatures[ref], signatures[i], header: sigHeader)
            }
            // No alignment (scrolled back up / jumped, or the auto engine's
            // ~55%-of-a-screen step outran the overlap) → keep the frame anyway,
            // minus any sticky header, and re-anchor the chain on it. Dropping it
            // and leaving `ref` on the last APPENDED frame orphaned the chain: the
            // next frame is one more step further away, so it missed too, and
            // EVERY frame after the first miss was silently dropped — "ready" over
            // an image that stops partway down the page. One visible seam is worth
            // far less than everything below it.
            let from = overlap.map { max(Int(Float($0) * scaleY), headerPx) } ?? headerPx
            let add = frames[i].height - from
            guard add > 0 else { ref = i; continue }   // fully-overlapping frame
            pieces.append((frames[i], from))
            total += add
            ref = i
            // Cap by BYTES too (w×total×4) — 60k rows of a wide capture would
            // be a ~gigabyte single allocation.
            if total > 60_000 || total * w * 4 > 700_000_000 { break }
        }
        guard total > 0,
              let ctx = CGContext(data: nil, width: w, height: total, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // CG origin bottom-left; lay pieces top-down. Draw ONLY each frame's
        // new rows [from..h) — drawing the full frame would stamp its top rows
        // (incl. any sticky header) over the previous piece at every seam.
        var yTop = 0
        for (img, from) in pieces {
            let visible = img.height - from
            guard visible > 0 else { continue }
            let slice: CGImage? = from == 0 ? img
                : img.cropping(to: CGRect(x: 0, y: from, width: img.width, height: visible))
            guard let slice else { continue }
            let y = total - yTop - visible
            ctx.draw(slice, in: CGRect(x: 0, y: y, width: img.width, height: visible))
            yTop += visible
        }
        return ctx.makeImage()
    }
}
