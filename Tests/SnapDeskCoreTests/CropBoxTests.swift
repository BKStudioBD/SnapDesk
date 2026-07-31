import Testing
import CoreGraphics
@testable import SnapDeskCore

/// The crop box's whole job is to be impossible to aim badly. Everything here is a
/// rule that, when it broke, cost the user pixels they could not get back: the shot
/// is already taken, and a crop is destructive.
struct CropBoxTests {

    private let image = CGRect(x: 0, y: 0, width: 800, height: 600)

    // MARK: - "I never touched it"

    /// The default box is inset 8% a side, so confirming an UNTOUCHED one silently
    /// discards 29% of the picture. The Crop button both starts and confirms, so a
    /// double-click, which is what people give toolbar buttons, used to cut the
    /// edges off the very window being captured with nothing on screen to show it.
    @Test("A box nobody aimed reports itself untouched", .tags(.regression))
    func freshBoxIsNotDragged() {
        let box = CropBox(limit: image)
        #expect(box.wasDragged == false)
        // And it really is inset, i.e. confirming it would NOT have been a no-op,
        // which is exactly why the untouched flag has to exist.
        #expect(box.rect != image)
        #expect(box.rect.width < image.width && box.rect.height < image.height)
    }

    /// Typed, not stringly: with a `default:` arm a typo in an argument silently
    /// re-ran the `draw` case and the test stayed green while one of the three
    /// gestures went unexercised.
    enum AimGesture: CaseIterable { case handle, move, draw }

    @Test("Each way of aiming the box marks it touched", arguments: AimGesture.allCases)
    func aimingMarksItDragged(_ gesture: AimGesture) {
        var box = CropBox(limit: image)
        switch gesture {
        case .handle: box.drag(handle: 0, to: CGPoint(x: 10, y: 10))
        case .move:   box.move(by: CGSize(width: 5, height: 0))
        case .draw:   box.draw(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        }
        #expect(box.wasDragged, "gesture: \(gesture)")
    }

    /// A rect handed in came from somewhere that already aimed it, so it must not be
    /// mistaken for the untouched default and thrown away.
    @Test("A box built from an explicit rect counts as aimed")
    func explicitRectCountsAsDragged() {
        let box = CropBox(limit: image, rect: CGRect(x: 100, y: 100, width: 200, height: 150))
        #expect(box.wasDragged)
        #expect(box.rect == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    // MARK: - It cannot leave the image

    @Test("Dragging a handle far outside clamps to the image, not past it")
    func handleDragClampsToImage() {
        var box = CropBox(limit: image)
        box.drag(handle: 5, to: CGPoint(x: -500, y: 9000))   // top-left, way out
        #expect(image.contains(box.rect), "got \(box.rect)")
    }

    @Test("Sliding the box off the edge stops it flush, and keeps its size")
    func moveStopsAtTheEdge() {
        var box = CropBox(limit: image, rect: CGRect(x: 700, y: 500, width: 80, height: 80))
        let size = box.rect.size
        box.move(by: CGSize(width: 400, height: 400))
        #expect(box.rect.size == size, "sliding must not resize")
        #expect(box.rect.maxX == image.maxX)
        #expect(box.rect.maxY == image.maxY)
    }

    @Test("Rubber-banding outside the image is clamped into it")
    func drawClampsToImage() {
        var box = CropBox(limit: image)
        box.draw(from: CGPoint(x: -200, y: -200), to: CGPoint(x: 2000, y: 2000))
        #expect(box.rect == image)
    }

    // MARK: - It cannot invert or collapse

    /// An inverted rect reaches the compositor as a negative-size crop, which returns
    /// no image at all: to the user the shot simply vanished.
    @Test("An edge dragged past its opposite stops instead of flipping",
          .tags(.regression), arguments: [0, 2, 5, 7, 3, 4, 1, 6])
    func edgesNeverInvert(_ handle: Int) {
        var box = CropBox(limit: image, rect: CGRect(x: 300, y: 200, width: 200, height: 200))
        // Aim every handle at the far opposite corner: whichever edge it owns, it is
        // being asked to cross the one facing it.
        box.drag(handle: handle, to: CGPoint(x: 300 + (handle % 2 == 0 ? 400 : -400),
                                            y: 200 + (handle < 4 ? 400 : -400)))
        #expect(box.rect.width > 0 && box.rect.height > 0, "handle \(handle) → \(box.rect)")
        #expect(box.rect == box.rect.standardized, "handle \(handle) inverted: \(box.rect)")
        #expect(box.rect.width >= CropBox.minimumSide, "handle \(handle) → \(box.rect)")
        #expect(box.rect.height >= CropBox.minimumSide, "handle \(handle) → \(box.rect)")
    }

    @Test("A zero-length rubber-band still leaves an aimable box")
    func zeroDrawStillLeavesAGrabbableBox() {
        var box = CropBox(limit: image)
        let point = CGPoint(x: 400, y: 300)
        box.draw(from: point, to: point)
        #expect(box.rect.width >= CropBox.minimumSide)
        #expect(box.rect.height >= CropBox.minimumSide)
        #expect(image.contains(box.rect), "got \(box.rect)")
    }

    /// The floor must never exceed the image, or a thin capture (a one-line strip
    /// of a terminal, say) could not be cropped at all.
    @Test("An image thinner than the minimum is still croppable")
    func aThinImageIsStillCroppable() {
        let strip = CGRect(x: 0, y: 0, width: 400, height: 6)
        var box = CropBox(limit: strip)
        box.draw(from: CGPoint(x: 10, y: 0), to: CGPoint(x: 20, y: 6))
        #expect(box.rect.height <= strip.height, "got \(box.rect)")
        #expect(box.rect.height > 0)
        #expect(strip.contains(box.rect), "got \(box.rect)")
    }

    // MARK: - Handles

    @Test("There are eight handles and no centre one")
    func eightHandlesNoCentre() {
        let rects = CropBox.handleRects(for: CGRect(x: 0, y: 0, width: 100, height: 100), size: 10)
        #expect(rects.count == 8)
        #expect(rects.contains { $0.midX == 50 && $0.midY == 50 } == false,
                "a centre handle would sit under the drag-to-move area")
    }

    /// An 11pt dot is hard to hit exactly, so hit-testing is deliberately slack,
    /// without the slop a handle reads as unresponsive rather than as small.
    @Test("Hit-testing a handle allows for slop just outside it")
    func handleHitTestHasSlop() {
        let box = CropBox(limit: image, rect: CGRect(x: 100, y: 100, width: 200, height: 200))
        #expect(box.handle(at: CGPoint(x: 100, y: 100), size: 11) != nil, "dead centre")
        #expect(box.handle(at: CGPoint(x: 93, y: 93), size: 11) != nil, "just outside")
        #expect(box.handle(at: CGPoint(x: 200, y: 200), size: 11) == nil, "the middle is not a handle")
    }
}
