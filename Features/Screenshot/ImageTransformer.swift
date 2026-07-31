import CoreGraphics

/// Pixel-level crop / rotate / flip for a captured bitmap, plus the point↔pixel
/// mapping the editor needs to turn a dragged rect into a crop.
///
/// No view, no window: the editor draws in POINTS (bottom-left origin) while a
/// CGImage is PIXELS (top-left rows), and getting that conversion wrong is how a
/// crop ends up mirrored or off by a backing-scale factor. All of it lives here so
/// it can be exercised headlessly.
enum ImageTransformer {

    // MARK: - Point ↔ pixel

    /// Pixel rect of `pointRect`, given that `image` of `pixelWidth`×`pixelHeight`
    /// currently occupies `displayRect` on screen.
    ///
    /// Scale falls out of the ratio rather than being passed in: a 2× capture shown
    /// at its natural point size yields a pixel rect twice the point rect, so a crop
    /// of a 2× shot stays 2×.
    static func pixelRect(from pointRect: CGRect, displayRect: CGRect,
                          pixelWidth: Int, pixelHeight: Int) -> CGRect {
        guard displayRect.width > 0, displayRect.height > 0 else { return .zero }
        let sx = CGFloat(pixelWidth) / displayRect.width
        let sy = CGFloat(pixelHeight) / displayRect.height
        let r = pointRect.standardized
        // Measure the crop's TOP edge down from the display rect's top: the view's
        // y grows upward and a CGImage's rows run downward, so using minY here
        // mirrors every crop vertically.
        return CGRect(x: (r.minX - displayRect.minX) * sx,
                      y: (displayRect.maxY - r.maxY) * sy,
                      width: r.width * sx, height: r.height * sy).integral
    }

    /// The inverse of `pixelRect`. `pixelRect` rounds outward to whole pixels, so
    /// the crop the user *gets* is a hair larger than the one they dragged; the
    /// editor displays the result at this rect so the bitmap and its on-screen box
    /// keep exactly the same aspect ratio (otherwise later strokes skew).
    static func pointRect(from pixelRect: CGRect, displayRect: CGRect,
                          pixelWidth: Int, pixelHeight: Int) -> CGRect {
        guard displayRect.width > 0, displayRect.height > 0,
              pixelWidth > 0, pixelHeight > 0 else { return .zero }
        let sx = CGFloat(pixelWidth) / displayRect.width
        let sy = CGFloat(pixelHeight) / displayRect.height
        let r = pixelRect.standardized
        return CGRect(x: displayRect.minX + r.minX / sx,
                      y: displayRect.maxY - r.maxY / sy,
                      width: r.width / sx, height: r.height / sy)
    }

    // MARK: - Transforms

    /// Crop to a pixel rect. Returns nil rather than the untouched image when the
    /// rect is empty, inverted or outside the bitmap: a silently ignored crop
    /// reads as a broken button.
    static func cropped(_ image: CGImage, toPixelRect rect: CGRect) -> CGImage? {
        guard rect.isNull == false, rect.isInfinite == false else { return nil }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = rect.standardized.integral.intersection(full)
        guard clamped.isNull == false, clamped.width >= 1, clamped.height >= 1 else { return nil }
        // `cropping` shares the source's pixels: bit depth, alpha layout and colour
        // space survive untouched, which redrawing through a context can't promise.
        return image.cropping(to: clamped)
    }

    /// Quarter turn. `clockwise` is what the user sees, i.e. the left edge becomes
    /// the top edge.
    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = context(width: h, height: w, like: image) else { return nil }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Mirror about the vertical axis (`horizontally`) or the horizontal one.
    static func flipped(_ image: CGImage, horizontally: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = context(width: w, height: h, like: image) else { return nil }
        if horizontally {
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Backing bitmap

    private static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        // Match the source's bit depth, alpha layout and colour space first: a
        // quarter turn or a mirror only moves whole pixels, so keeping the layout
        // keeps a Display-P3 capture in P3 instead of quietly landing in sRGB.
        // CGImage.bitmapInfo doesn't always carry the alpha bits, so splice them in.
        let info = (image.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue)
            | image.alphaInfo.rawValue
        if let space = image.colorSpace,
           let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: image.bitsPerComponent, bytesPerRow: 0,
                              space: space, bitmapInfo: info) {
            ctx.interpolationQuality = .none   // exact pixel move; resampling only softens it
            return ctx
        }
        // Layouts CGContext refuses to back (indexed, alpha-less 24-bit, float HDR):
        // land in 8-bit premultiplied sRGB rather than dropping the edit entirely.
        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: fallback,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.interpolationQuality = .none
        return ctx
    }
}
