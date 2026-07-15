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
        return cropped
    }

    /// Shareable-content cache: enumerating windows is an IPC round-trip, and
    /// scrolling capture calls captureScreen up to ~8×/sec. 2 s freshness is
    /// plenty (we only need displays + our own windows).
    @MainActor private static var cachedContent: (SCShareableContent, Date)?

    /// Captures one whole display at native pixel resolution. Used to "freeze"
    /// the screen for the Lightshot-style in-place editor.
    @MainActor
    static func captureScreen(_ screen: NSScreen) async throws -> CGImage {
        let scale = screen.backingScaleFactor
        let displayID = screen.displayID

        let content: SCShareableContent
        if let (c, at) = cachedContent, Date().timeIntervalSince(at) < 2 {
            content = c
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            cachedContent = (content, Date())
        }

        // NO first-display fallback — capturing the wrong monitor and cropping
        // it with the right monitor's rect delivers wrong content silently.
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        // Exclude SnapDesk's own windows (recording border/control bar, pins…)
        // so they never appear inside a screenshot taken mid-recording.
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        let filter: SCContentFilter
        if let ourApp = content.applications.first(where: { $0.processID == pid }) {
            filter = SCContentFilter(display: scDisplay, excludingApplications: [ourApp],
                                     exceptingWindows: [])
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
    /// (top-left origin). Used for Lightshot/CleanShot-style window snapping.
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
    /// The CoreGraphics display ID backing this screen.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
    }
}
