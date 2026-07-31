import AppKit
import CoreGraphics

/// How a desktop picture is laid into a screen, and what colour to fall back to
/// when the picture itself can't be read.
///
/// Split out of `DesktopCover` because it is pure: no windows, no permissions,
/// so the aspect maths (which decides whether a covered desktop looks identical
/// or subtly stretched) can be tested.
enum WallpaperFill {

    /// How the real desktop lays a picture into a screen. Only the modes a cover
    /// can reproduce EXACTLY are here; see `layout(scalingRawValue:allowsClipping:)`
    /// for the ones that have to be declined instead.
    enum Layout: Equatable {
        /// System Settings → Wallpaper → "Fill Screen": cover the screen at the
        /// picture's own aspect ratio and clip the overflow.
        case fill
        /// "Fit to Screen": largest rect that fits, bars of the fill colour around it.
        case fit
        /// "Stretch to Fill Screen": the screen's aspect ratio wins, the picture's
        /// is discarded.
        case stretch
    }

    /// Which layout a screen's `NSWorkspace.desktopImageOptions` describe, or nil
    /// when the desktop's mode cannot be reproduced and the caller must leave that
    /// screen uncovered.
    ///
    /// `scalingRawValue` is `.imageScaling` as stored; nil means the desktop
    /// reported no scaling at all, where macOS's own default of Fill Screen
    /// applies. Answering "fill" for every mode that wasn't Fit was wrong for three
    /// of the five wallpaper positions: Center and Tile blew a small picture up to
    /// full screen, and Stretch came back aspect-correct and cropped. The magnified
    /// blow-up is the visible one: a Centre wallpaper turned the covered desktop
    /// into a huge blurry crop of itself, in the shot as well as on screen.
    static func layout(scalingRawValue: UInt?, allowsClipping: Bool) -> Layout? {
        guard let scalingRawValue else { return .fill }
        // A value that isn't a scaling mode at all is not the same as no value:
        // don't fall back to a default the desktop never claimed.
        guard let scaling = NSImageScaling(rawValue: scalingRawValue) else { return nil }
        switch scaling {
        case .scaleProportionallyUpOrDown: return allowsClipping ? .fill : .fit
        case .scaleAxesIndependently:      return .stretch
        // "Center" and "Tile" are BOTH `.scaleNone`, and NSWorkspace exposes no key
        // that tells them apart. Centring a tiled desktop, or tiling a centred one,
        // puts pixels in the file that were never on the screen, so this screen
        // goes uncovered, the same answer this file already gives for a wallpaper it
        // cannot read at all.
        case .scaleNone: return nil
        // Never seen from a desktop picture; a guess here would be a guess in
        // somebody's screenshot.
        default: return nil
        }
    }

    /// The rect to draw the picture in for a given layout.
    static func rect(for layout: Layout, imageSize: CGSize, in bounds: CGRect) -> CGRect {
        switch layout {
        case .fill:    return aspectFillRect(imageSize: imageSize, in: bounds)
        case .fit:     return aspectFitRect(imageSize: imageSize, in: bounds)
        // Straight into the bounds: NSImage.draw stretches to the rect it is given,
        // which is what "Stretch to Fill Screen" does to the real desktop.
        case .stretch: return bounds
        }
    }

    /// Smallest rect that COVERS `bounds` at the image's aspect ratio, centred:
    /// what "Fill Screen" does. The overflow is the caller's to clip.
    static func aspectFillRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        scaled(imageSize, in: bounds, by: max)
    }

    /// Largest rect that FITS inside `bounds` at the image's aspect ratio,
    /// centred: "Fit to Screen". What's left over shows the desktop's own fill
    /// colour, exactly as the real desktop does.
    static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        scaled(imageSize, in: bounds, by: min)
    }

    /// Average colour of an image.
    ///
    /// The fallback when the wallpaper file is unreadable: a screen painted the
    /// desktop's own average reads as an out-of-focus desktop, where a black one
    /// reads as a broken screenshot.
    ///
    /// Averages a 16×16 downsample rather than a 1×1: Core Graphics does not
    /// promise to area-average all the way down to a single pixel, and a
    /// single-sample "average" of a photo is just whichever pixel it picked.
    static func averageColor(of image: CGImage) -> NSColor? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                                  CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        // Buffer is BGRA (byteOrder32Little + premultipliedFirst). The same
        // layout, and the same easy-to-get-wrong channel order, as
        // CaptureService.looksBlank.
        var b = 0, g = 0, r = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            b += Int(pixels[i]); g += Int(pixels[i + 1]); r += Int(pixels[i + 2])
        }
        let count = CGFloat(side * side) * 255
        return NSColor(srgbRed: CGFloat(r) / count, green: CGFloat(g) / count,
                       blue: CGFloat(b) / count, alpha: 1)
    }

    private static func scaled(_ imageSize: CGSize, in bounds: CGRect,
                               by pick: (CGFloat, CGFloat) -> CGFloat) -> CGRect {
        // A zero dimension means "we don't know how big it is": hand back the
        // bounds so the caller still paints something the right shape.
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let factor = pick(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
