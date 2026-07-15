import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

/// Burns presenter-style effects into recording frames on the GPU:
/// boosted cursor, click-highlight rings, a keystroke banner, and a circular
/// webcam bubble. Events are collected on the main thread; `decorate` runs on
/// the recorder's queue reading a lock-protected snapshot.
final class FrameDecorator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Config {
        var cursorBoost = false        // draw a 2× cursor (real cursor hidden)
        var clickHighlight = false     // expanding ring on every click
        var keystrokes = false         // last shortcut/keys banner
        var camera = false             // webcam bubble bottom-right
    }

    private let config: Config
    private let displayOriginCG: CGPoint   // recorded display origin, CG global top-left coords
    private let sourceRect: CGRect         // recorded region, display-local points (top-left)
    private let scale: CGFloat

    private let lock = NSLock()
    private var clicks: [(pos: CGPoint, time: CFTimeInterval)] = []   // frame px, top-left
    private var keyTime: CFTimeInterval = 0
    private var keyImage: CIImage?
    private var cameraBuffer: CVPixelBuffer?

    private var monitors: [Any] = []
    private var camSession: AVCaptureSession?
    private let camControlQueue = DispatchQueue(label: "com.snapdesk.camera.control")

    private let cursorImage: CIImage?
    private let cursorHotSpot: CGPoint
    private let ringImage: CIImage
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(config: Config, displayID: CGDirectDisplayID, sourceRect: CGRect, scale: CGFloat) {
        self.config = config
        self.displayOriginCG = CGDisplayBounds(displayID).origin
        self.sourceRect = sourceRect
        self.scale = scale
        // Pre-render the (consistent) arrow cursor and the click ring once.
        let arrow = NSCursor.arrow
        self.cursorImage = Self.ciImage(from: arrow.image)
        self.cursorHotSpot = arrow.hotSpot
        self.ringImage = Self.makeRing()
        super.init()
    }

    // MARK: - Lifecycle (main thread)

    func start() {
        if config.clickHighlight {
            let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                self?.addClick(at: NSEvent.mouseLocation)
            }
            if let m { monitors.append(m) }
            let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                self?.addClick(at: NSEvent.mouseLocation); return e
            }
            if let l { monitors.append(l) }
        }
        if config.keystrokes {
            let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
                self?.setKeystroke(from: e)
            }
            if let m { monitors.append(m) }
        }
        if config.camera { startCamera() }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let cam = camSession {
            camControlQueue.async { cam.stopRunning() }   // off-main, ordered after start
            camSession = nil
        }
    }

    // MARK: - Event capture (main thread)

    /// Global AppKit mouse location (bottom-left origin) → frame px (top-left).
    private func addClick(at global: NSPoint) {
        let primaryH = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        let cgPoint = CGPoint(x: global.x, y: primaryH - global.y)   // → CG top-left global
        let local = CGPoint(x: cgPoint.x - displayOriginCG.x - sourceRect.minX,
                            y: cgPoint.y - displayOriginCG.y - sourceRect.minY)
        let px = CGPoint(x: local.x * scale, y: local.y * scale)
        lock.lock()
        clicks.append((px, CACurrentMediaTime()))
        if clicks.count > 12 { clicks.removeFirst() }
        lock.unlock()
    }

    private func setKeystroke(from e: NSEvent) {
        var s = ""
        let f = e.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += Hotkey.keyName(UInt32(e.keyCode))
        let img = Self.renderBanner(s)
        lock.lock()
        keyTime = CACurrentMediaTime(); keyImage = img
        lock.unlock()
    }

    private func startCamera() {
        guard let device = AVCaptureDevice.default(for: .video) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "com.snapdesk.camera"))
        guard session.canAddOutput(out) else { return }
        session.addOutput(out)
        camControlQueue.async { session.startRunning() }
        camSession = session
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); cameraBuffer = pb; lock.unlock()
    }

    // MARK: - Frame decoration (recorder queue)

    func decorate(_ input: CIImage, bufferSize: CGSize) -> CIImage {
        var img = input
        let now = CACurrentMediaTime()

        lock.lock()
        let clicksSnap = clicks
        let kImg = keyImage
        let kAge = now - keyTime
        let camPB = cameraBuffer
        lock.unlock()

        // Click rings: expand + fade over 0.45s.
        if config.clickHighlight {
            for c in clicksSnap {
                let age = now - c.time
                guard age >= 0, age < 0.45 else { continue }
                let t = CGFloat(age / 0.45)
                let ringScale = (0.35 + t * 0.9)                     // grows
                let alpha = (1 - t) * 0.85                            // fades
                let size = 120 * ringScale
                let x = c.pos.x - size / 2
                let y = bufferSize.height - c.pos.y - size / 2        // → CI bottom-left
                let ring = ringImage
                    .transformed(by: CGAffineTransform(scaleX: ringScale, y: ringScale)
                        .concatenating(CGAffineTransform(translationX: x, y: y)))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                img = ring.composited(over: img)
            }
        }

        // Boosted cursor (2×) at the live pointer position.
        if config.cursorBoost, let cur = cursorImage {
            // CGEvent(source:).location = global top-left coords AND thread-safe
            // (this runs on the recorder queue; NSEvent/NSScreen are AppKit
            // main-thread API).
            let cg = CGEvent(source: nil)?.location ?? .zero
            let local = CGPoint(x: cg.x - displayOriginCG.x - sourceRect.minX,
                                y: cg.y - displayOriginCG.y - sourceRect.minY)
            let boost: CGFloat = 2.0 * scale
            let px = CGPoint(x: local.x * scale - cursorHotSpot.x * boost,
                             y: local.y * scale - cursorHotSpot.y * boost)
            let h = cur.extent.height * boost
            let placed = cur
                .transformed(by: CGAffineTransform(scaleX: boost, y: boost)
                    .concatenating(CGAffineTransform(translationX: px.x,
                                                     y: bufferSize.height - px.y - h)))
            img = placed.composited(over: img)
        }

        // Keystroke banner bottom-center, visible 1.4s with quick fade.
        if config.keystrokes, let banner = kImg, kAge < 1.4 {
            let alpha = kAge < 1.1 ? 1.0 : max(0, 1 - (kAge - 1.1) / 0.3)
            let k = scale
            let w = banner.extent.width * k
            let placed = banner
                .transformed(by: CGAffineTransform(scaleX: k, y: k)
                    .concatenating(CGAffineTransform(translationX: (bufferSize.width - w) / 2,
                                                     y: 28 * k)))
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
            img = placed.composited(over: img)
        }

        // Webcam bubble bottom-right (circle-masked, aspect-fill).
        if config.camera, let pb = camPB {
            let cam = CIImage(cvPixelBuffer: pb)
            let d = min(cam.extent.width, cam.extent.height)
            let squared = cam.cropped(to: CGRect(x: cam.extent.midX - d / 2,
                                                 y: cam.extent.midY - d / 2, width: d, height: d))
            let bubble = bufferSize.height * 0.22
            let s = bubble / d
            let margin = 24 * scale
            let ox = bufferSize.width - bubble - margin
            let oy = margin
            let moved = squared
                .transformed(by: CGAffineTransform(translationX: -squared.extent.minX,
                                                   y: -squared.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: s, y: s)
                    .concatenating(CGAffineTransform(translationX: ox, y: oy)))
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: ox + bubble / 2, y: oy + bubble / 2),
                "inputRadius0": bubble / 2 - 2,
                "inputRadius1": bubble / 2,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            ])!.outputImage!
            let masked = moved.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: mask,
            ])
            img = masked.composited(over: img)
        }

        return img
    }

    // MARK: - Prerendered assets

    private static func ciImage(from ns: NSImage) -> CIImage? {
        guard let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// 120×120 white ring with soft edge (tinted by alpha at composite time).
    private static func makeRing() -> CIImage {
        let size = NSSize(width: 120, height: 120)
        let ns = NSImage(size: size, flipped: false) { rect in
            let p = NSBezierPath(ovalIn: rect.insetBy(dx: 8, dy: 8))
            p.lineWidth = 7
            NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 1).setStroke()
            p.stroke()
            return true
        }
        return ciImage(from: ns) ?? CIImage.empty()
    }

    /// Rounded dark pill with the shortcut text, rendered at 1× points.
    private static func renderBanner(_ text: String) -> CIImage? {
        let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let sz = text.size(withAttributes: attrs)
        let pad: CGFloat = 16
        let size = NSSize(width: sz.width + pad * 2, height: sz.height + 14)
        let ns = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            text.draw(at: NSPoint(x: pad, y: 7), withAttributes: attrs)
            return true
        }
        return ciImage(from: ns)
    }
}
