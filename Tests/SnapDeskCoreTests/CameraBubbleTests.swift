import Testing
import AppKit
import AVFoundation
import CoreImage
import CoreVideo
@testable import SnapDeskCore

/// The webcam bubble is burned into every recorded frame, so a mistake in its
/// placement, its circle mask or its mirroring is only discovered on playback:
/// after the take is spoiled. These render one real decorated frame from a
/// SYNTHETIC camera picture and read the pixels back: no camera, no screen
/// capture, no permission prompt, nothing on screen.
///
/// `@MainActor` because `FrameDecorator` pre-renders AppKit assets (the cursor
/// image, the keystroke pill) at init.
@MainActor
struct WebcamBubbleRendering {

    // MARK: - Fixtures

    /// A camera picture that can be told apart after any transform: left half
    /// RED, right half BLUE, a GREEN band across the top.
    private func cameraPicture(width: Int = 640, height: Int = 480) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] as CFDictionary,
                            &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = try #require(CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        // CGContext draws bottom-left origin, matching CoreImage: high y is the
        // TOP of the upright picture.
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: Int(Double(height) * 0.85), width: width, height: height / 8))
        return pixels
    }

    /// One decorated frame, sampled in CoreImage coordinates (bottom-left origin).
    private struct Frame {
        let bitmap: NSBitmapImageRep
        let height: Int

        func color(_ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double) {
            guard let c = bitmap.colorAt(x: x, y: height - 1 - y)?.usingColorSpace(.deviceRGB) else {
                return (-1, -1, -1)
            }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        func isRed(_ x: Int, _ y: Int) -> Bool { let c = color(x, y); return c.red > 0.5 && c.blue < 0.4 }
        func isBlue(_ x: Int, _ y: Int) -> Bool { let c = color(x, y); return c.blue > 0.5 && c.red < 0.4 }
        func isGreen(_ x: Int, _ y: Int) -> Bool {
            let c = color(x, y); return c.green > 0.5 && c.red < 0.4 && c.blue < 0.4
        }
        /// The flat grey the synthetic screen frame is filled with.
        func isScreen(_ x: Int, _ y: Int) -> Bool {
            let c = color(x, y)
            return abs(c.red - 0.15) < 0.06 && abs(c.green - 0.15) < 0.06 && abs(c.blue - 0.15) < 0.06
        }
    }

    private static let width = 1280
    private static let height = 800
    private static let scale: CGFloat = 2

    private func decoratedFrame(corner: CameraCorner, size: CameraSize, mirrored: Bool,
                                camera: CVPixelBuffer?) throws -> Frame {
        var config = FrameDecorator.Config()
        config.camera = true
        config.cameraCorner = corner
        config.cameraSize = size
        config.cameraMirrored = mirrored
        let decorator = FrameDecorator(
            config: config, displayID: CGMainDisplayID(),
            sourceRect: CGRect(x: 0, y: 0,
                               width: CGFloat(Self.width) / Self.scale,
                               height: CGFloat(Self.height) / Self.scale),
            scale: Self.scale)
        if let camera { decorator.acceptCameraFrame(camera) }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(Self.width), height: CGFloat(Self.height))
        let screen = CIImage(color: CIColor(red: 0.15, green: 0.15, blue: 0.15)).cropped(to: bounds)
        let decorated = decorator.decorate(screen, bufferSize: bounds.size)
        // Software renderer: a test machine may have no GPU context available.
        let rendered = try #require(CIContext(options: [.useSoftwareRenderer: true])
            .createCGImage(decorated, from: bounds))
        return Frame(bitmap: NSBitmapImageRep(cgImage: rendered), height: Self.height)
    }

    /// Where the bubble is supposed to land, derived from the same rule the
    /// on-screen preview window uses: a fraction of the region's height, 24 pt
    /// from the chosen corner.
    private func expectedBubble(corner: CameraCorner, size: CameraSize) -> CGRect {
        let diameter = CGFloat(Self.height) * size.fraction
        let margin = 24 * Self.scale
        return CGRect(x: corner.isLeading ? margin : CGFloat(Self.width) - diameter - margin,
                      y: corner.isTop ? CGFloat(Self.height) - diameter - margin : margin,
                      width: diameter, height: diameter)
    }

    // MARK: - Tests

    @Test("The bubble lands in the chosen corner at the chosen size",
          arguments: CameraCorner.allCases, CameraSize.allCases)
    func bubblePlacement(corner: CameraCorner, size: CameraSize) throws {
        let frame = try decoratedFrame(corner: corner, size: size, mirrored: false,
                                       camera: cameraPicture())
        let bubble = expectedBubble(corner: corner, size: size)
        #expect(!frame.isScreen(Int(bubble.midX), Int(bubble.midY)),
                "nothing was drawn where the bubble belongs")
        // The far corner of the frame must be untouched, or the bubble is in the
        // wrong place entirely.
        #expect(frame.isScreen(corner.isLeading ? Self.width - 10 : 10,
                               corner.isTop ? 10 : Self.height - 10))
    }

    @Test("The bubble is masked to a circle, not a square",
          arguments: CameraCorner.allCases)
    func circleMask(corner: CameraCorner) throws {
        let frame = try decoratedFrame(corner: corner, size: .large, mirrored: false,
                                       camera: cameraPicture())
        let bubble = expectedBubble(corner: corner, size: .large)
        // Inside the bounding box, outside the circle: still the screen.
        #expect(frame.isScreen(Int(bubble.minX + bubble.width * 0.03),
                               Int(bubble.minY + bubble.height * 0.03)))
        // 80% of the way out along the horizontal is still inside the circle.
        #expect(!frame.isScreen(Int(bubble.midX + bubble.width * 0.4), Int(bubble.midY)))
    }

    @Test("Mirroring flips left and right, and nothing else", arguments: [false, true])
    func mirroring(mirrored: Bool) throws {
        let frame = try decoratedFrame(corner: .bottomRight, size: .large, mirrored: mirrored,
                                       camera: cameraPicture())
        let bubble = expectedBubble(corner: .bottomRight, size: .large)
        let left = Int(bubble.minX + bubble.width * 0.25)
        let right = Int(bubble.minX + bubble.width * 0.75)
        let middle = Int(bubble.midY)
        if mirrored {
            #expect(frame.isBlue(left, middle), "the camera's right half should show on the left")
            #expect(frame.isRed(right, middle), "the camera's left half should show on the right")
        } else {
            #expect(frame.isRed(left, middle))
            #expect(frame.isBlue(right, middle))
        }
        // A vertical flip would put the green band at the bottom and hand the
        // user an upside-down face.
        #expect(frame.isGreen(Int(bubble.midX), Int(bubble.minY + bubble.height * 0.88)))
        #expect(!frame.isGreen(Int(bubble.midX), Int(bubble.minY + bubble.height * 0.12)))
    }

    @Test("Nothing is drawn until the first camera frame arrives")
    func noBubbleBeforeFirstFrame() throws {
        let frame = try decoratedFrame(corner: .bottomRight, size: .medium, mirrored: true,
                                       camera: nil)
        let bubble = expectedBubble(corner: .bottomRight, size: .medium)
        #expect(frame.isScreen(Int(bubble.midX), Int(bubble.midY)))
    }

    @Test("Any sensor shape fills the circle. No letterboxing, no squashing",
          arguments: [(1920, 1080), (640, 480), (480, 640)])
    func sensorAspectRatios(sensor: (width: Int, height: Int)) throws {
        let frame = try decoratedFrame(corner: .topLeft, size: .large, mirrored: false,
                                       camera: cameraPicture(width: sensor.width, height: sensor.height))
        let bubble = expectedBubble(corner: .topLeft, size: .large)
        #expect(!frame.isScreen(Int(bubble.midX), Int(bubble.midY)))
        #expect(!frame.isScreen(Int(bubble.midX + bubble.width * 0.4), Int(bubble.midY)))
        #expect(!frame.isScreen(Int(bubble.midX), Int(bubble.midY + bubble.height * 0.4)))
    }
}

/// A camera that can't be used has to SAY so. The whole point of these cases is
/// that the bubble never fails in silence again.
struct CameraProblemMessages {

    @Test("Every problem names itself and says the recording is still running",
          arguments: CameraProblem.allCases)
    func everyProblemIsActionable(problem: CameraProblem) {
        #expect(!problem.title.isEmpty)
        // The user's first fear is that the take is being lost. Answer it in the
        // message itself, whatever went wrong.
        #expect(problem.body.contains("still being recorded"),
                "\(problem.rawValue) doesn't tell the user the screen is still being recorded")
    }

    @Test("A busy camera points at the cause the user can fix")
    func busyMentionsTheOtherApp() {
        #expect(CameraProblem.busy.body.contains("Another app"))
    }

    @Test("Only a camera that dies mid-take gets the loud alert")
    func disruptionsAreTheOnesThatInterrupt() {
        let loud = CameraProblem.allCases.filter(\.isDisruption)
        #expect(Set(loud) == [.disconnected, .runtimeError])
    }
}
