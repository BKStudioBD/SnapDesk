import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: LocalizedError {
    case displayNotFound
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "Couldn't find the display to capture."
        case .cropFailed:      return "Couldn't crop the captured image."
        }
    }
}

/// Captures a region using ScreenCaptureKit. Strategy: grab the full display at
/// native pixel resolution (very reliable), then crop the CGImage to the
/// selection in pixel space. This sidesteps the coordinate ambiguity of
/// `SCStreamConfiguration.sourceRect` across multiple monitors.
enum CaptureService {

    @MainActor
    static func capture(_ selection: RegionSelection) async throws -> CGImage {
        let scale = selection.screen.backingScaleFactor
        let fullImage = try await captureScreen(selection.screen)

        // Selection rect is top-left origin in points -> scale to pixels.
        // Clamp to the captured image bounds so an edge selection (whose .integral
        // rounding can spill 1px past the image) doesn't make cropping(to:) fail.
        let r = selection.rectInScreenPoints
        let bounds = CGRect(x: 0, y: 0, width: fullImage.width, height: fullImage.height)
        let pixelRect = CGRect(x: r.minX * scale,
                               y: r.minY * scale,
                               width: r.width * scale,
                               height: r.height * scale).integral.intersection(bounds)

        guard !pixelRect.isEmpty, let cropped = fullImage.cropping(to: pixelRect) else {
            throw CaptureError.cropFailed
        }
        // cropping() SHARES the entire full-display backing store — a small crop
        // would pin ~59 MB on a 5K screen for as long as any caller holds it
        // (blur overlay for minutes, OCR through multi-second Vision passes).
        // Redraw into a right-sized buffer so only the crop's bytes survive.
        // Near-full-frame crops (F-key full screen) share no meaningful excess —
        // skip the copy entirely. Real crops redraw OFF the main actor so a big
        // region never blocks the UI.
        if pixelRect.width * pixelRect.height >= 0.95 * bounds.width * bounds.height {
            return cropped
        }
        let copy = await Task.detached(priority: .userInitiated) { detached(cropped) }.value
        return copy ?? cropped
    }

    /// True when the image carries no visible detail — every sampled pixel is
    /// the same shade.
    ///
    /// This is how a capture FAILS SILENTLY on macOS: a process without Screen
    /// Recording rights is handed a frame with the windows stripped out (just
    /// the desktop picture) and NO error — measured. So "Vision found no text"
    /// and "the OS gave us an empty frame" are indistinguishable downstream,
    /// and the user gets "No text found" for text plainly on their screen.
    /// Cheap: one 16×16 downsample, no full-size scan.
    static func looksBlank(_ img: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = pixels.withUnsafeMutableBytes({ buf -> CGContext? in
            CGContext(data: buf.baseAddress, width: side, height: side,
                      bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                  CGBitmapInfo.byteOrder32Little.rawValue)
        }) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
        var lo = 255, hi = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            // Buffer is BGRA (byteOrder32Little + premultipliedFirst): the three
            // COLOUR bytes are at i, i+1, i+2; i+3 is alpha. The old code summed
            // i+1…i+3, averaging in the constant alpha and dropping blue — so a
            // solid blue frame read as "not blank". Sum the real B+G+R.
            let l = Int(pixels[i]) &+ Int(pixels[i + 1]) &+ Int(pixels[i + 2])
            let v = l / 3
            lo = min(lo, v); hi = max(hi, v)
        }
        return hi - lo < 6
    }

    /// Copy a CGImage into its own tightly-sized backing (drops the shared
    /// full-frame buffer that `cropping(to:)` retains).
    private static func detached(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }

    /// Shareable-content cache: enumerating windows is an IPC round-trip, and
    /// scrolling capture calls captureScreen up to ~8×/sec. 2 s freshness is
    /// plenty (we only need displays + our own windows).
    @MainActor private static var cachedContent: (SCShareableContent, Date)?

    /// Refresh the cache ahead of a capture the user hasn't finished asking for
    /// yet (they're still dragging). Without this every OCR pays the full
    /// enumerate-every-window IPC *after* mouse-up, where it's dead wait.
    /// Fire-and-forget: a failure here just means the real capture refetches.
    static func warmShareableContent() {
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false) else { return }
            cachedContent = (content, Date())
        }
    }

    /// Captures one whole display at native pixel resolution. Used to "freeze"
    /// the screen for the in-place annotation editor.
    @MainActor
    static func captureScreen(_ screen: NSScreen) async throws -> CGImage {
        // The desktop cover only exists to be in THIS frame — the instant the
        // pixels are in hand the user's icons come back, on every path out of
        // here including a throw. `lowerAfterGrab` rather than `lower`: the
        // screenshot flow freezes EVERY display in a loop, and lowering after the
        // first one put the icons back into screens 2..n. A caller that grabs more
        // than one frame holds the cover across the whole loop.
        defer { DesktopCover.lowerAfterGrab() }

        let scale = screen.backingScaleFactor
        // Stale NSScreen (display just reconfigured) → fail, never guess.
        guard let displayID = screen.displayID else { throw CaptureError.displayNotFound }

        // Windows of ours that must survive the app-wide exclusion below.
        let coverIDs = Set(DesktopCover.windowIDs)

        var content: SCShareableContent
        // A snapshot taken before the cover went up doesn't list it, and
        // filtering against one that doesn't know about it hands back a frame
        // with the very icons the cover hides. Refetch in that case only — the
        // warm-up during the drag normally already includes it.
        if let (c, at) = cachedContent, Date().timeIntervalSince(at) < 2,
           coverIDs.isSubset(of: Set(c.windows.map { $0.windowID })) {
            content = c
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            cachedContent = (content, Date())
        }

        // NO first-display fallback — capturing the wrong monitor and cropping
        // it with the right monitor's rect delivers wrong content silently.
        // Display missing from a ≤2s-old cache right after plugging/unplugging a
        // monitor? Refetch once before failing — the cache is stale, not the display.
        var scDisplay = content.displays.first(where: { $0.displayID == displayID })
        if scDisplay == nil {
            let fresh = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            cachedContent = (fresh, Date())
            // Adopt the fresh snapshot wholesale — reading the display from one
            // snapshot and our own app from another risks missing ourselves in
            // the stale list, which silently drops the self-exclusion below and
            // captures SnapDesk's own overlay into the image.
            content = fresh
            scDisplay = fresh.displays.first(where: { $0.displayID == displayID })
        }
        guard let scDisplay else {
            throw CaptureError.displayNotFound
        }

        // Exclude SnapDesk's own windows (recording border/control bar, pins…)
        // so they never appear inside a screenshot taken mid-recording.
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        // …except the desktop cover, which is one of our windows too: excluded
        // along with the rest, it would hide the icons on screen and leave them
        // in the file.
        let covers = coverIDs.isEmpty ? []
            : content.windows.filter { coverIDs.contains($0.windowID) }
        let filter: SCContentFilter
        if let ourApp = content.applications.first(where: { $0.processID == pid }) {
            filter = SCContentFilter(display: scDisplay, excludingApplications: [ourApp],
                                     exceptingWindows: covers)
        } else {
            filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.width  = Int(CGFloat(scDisplay.width) * scale)
        config.height = Int(CGFloat(scDisplay.height) * scale)
        config.showsCursor = false
        config.captureResolution = .best

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
    }

    /// On-screen normal-window rectangles in CoreGraphics global coords
    /// (top-left origin). Used for click-to-snap window selection.
    static func onScreenWindowRects() -> [CGRect] {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var rects: [CGRect] = []
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,  // normal windows only
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"],
                  w > 40, h > 40 else { continue }
            rects.append(CGRect(x: x, y: y, width: w, height: h))
        }
        return rects
    }
}

extension NSScreen {
    /// The CoreGraphics display ID backing this screen, or nil when
    /// deviceDescription no longer carries NSScreenNumber (stale NSScreen
    /// across a display reconfiguration). Deliberately NO CGMainDisplayID()
    /// fallback — capturing the wrong monitor and cropping it with another
    /// screen's rect delivers wrong content silently.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }
}
