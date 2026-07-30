import AppKit
import AVFoundation

/// Live circular webcam preview shown WHILE recording — the on-screen twin of
/// the bubble FrameDecorator burns into the video. Same corner, same size, fed
/// by the same AVCaptureSession, so what the user sees is exactly what the
/// video gets. Without it the camera was invisible until playback and read as
/// "camera doesn't work".
///
/// Click-through (never blocks what's being presented) and automatically absent
/// from the video itself: recordings exclude the whole SnapDesk app.
final class CameraBubbleWindow: NSPanel {

    init(session: AVCaptureSession, selection: RegionSelection,
         corner: CameraCorner, size: CameraSize, mirrored: Bool) {
        let sel = selection.rectInScreenPoints
        let sf = selection.screen.frame
        // Mirror FrameDecorator's layout math, in points. Same corner, same
        // fraction, same margin — if these drift the preview starts lying about
        // where the bubble will be in the video.
        let d = sel.height * size.fraction
        let margin: CGFloat = 24
        // AppKit origin is bottom-left; the selection rect is top-left.
        let x = corner.isLeading ? sf.minX + sel.minX + margin
                                 : sf.minX + sel.maxX - margin - d
        let y = corner.isTop ? sf.maxY - sel.minY - margin - d
                             : sf.maxY - sel.maxY + margin
        let frame = NSRect(x: x, y: y, width: d, height: d)
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        preview.cornerRadius = d / 2
        preview.masksToBounds = true
        preview.borderWidth = 2
        preview.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        // Match whatever the decorator burns in, so the on-screen bubble never
        // lies about the video.
        if let conn = preview.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = mirrored
        }
        view.layer?.addSublayer(preview)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
}
