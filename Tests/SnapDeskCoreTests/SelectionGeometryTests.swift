import Testing
import CoreGraphics
@testable import SnapDeskCore

/// The selection overlay's arithmetic. None of this can be checked by looking at
/// the screen: a chip clipped off the bottom of a secondary display, or a nudge
/// that quietly shrinks a rect at the screen edge, is exactly the kind of thing
/// that ships. Every rect here is one screen's local space, bottom-left origin.
struct SelectionGeometryTests {

    /// A 1440×900 display, and the chip size a Retina readout comes out at.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let chip = CGSize(width: 150, height: 18)

    // MARK: - Readout placement

    @Test("At rest the chip hangs under the selection's left edge — the corner a drag doesn't end on")
    func restingPlace() {
        let selection = CGRect(x: 400, y: 400, width: 300, height: 200)
        let layout = SelectionGeometry.readout(size: chip, selection: selection, container: screen)
        #expect(layout.frame.minX == 400)
        #expect(layout.frame.maxY == 400 - SelectionGeometry.readoutGap)
        #expect(layout.isInsideSelection == false)
    }

    @Test("A selection against the bottom edge flips the chip above it instead of off screen")
    func flipsUpAtTheBottomEdge() {
        let selection = CGRect(x: 400, y: 2, width: 300, height: 200)
        let layout = SelectionGeometry.readout(size: chip, selection: selection, container: screen)
        #expect(layout.frame.minY == selection.maxY + SelectionGeometry.readoutGap)
        #expect(screen.contains(layout.frame))
    }

    @Test("A selection against the top edge keeps the chip below it")
    func staysBelowAtTheTopEdge() {
        let selection = CGRect(x: 400, y: 700, width: 300, height: 200)
        let layout = SelectionGeometry.readout(size: chip, selection: selection, container: screen)
        #expect(layout.frame.maxY == selection.minY - SelectionGeometry.readoutGap)
        #expect(screen.contains(layout.frame))
    }

    @Test("A narrow selection at the right edge slides the chip back inside, never past it")
    func slidesInAtTheRightEdge() {
        let selection = CGRect(x: 1380, y: 400, width: 50, height: 200)
        let layout = SelectionGeometry.readout(size: chip, selection: selection, container: screen)
        #expect(layout.frame.maxX == screen.maxX - SelectionGeometry.readoutMargin)
        #expect(screen.contains(layout.frame))
    }

    @Test("At the left edge the chip never crosses the margin")
    func stopsAtTheLeftMargin() {
        let selection = CGRect(x: 0, y: 400, width: 60, height: 200)
        let layout = SelectionGeometry.readout(size: chip, selection: selection, container: screen)
        #expect(layout.frame.minX == screen.minX + SelectionGeometry.readoutMargin)
    }

    @Test("The bottom-right corner needs BOTH flips at once")
    func bothEdgesAtOnce() {
        let selection = CGRect(x: 1390, y: 1, width: 50, height: 20)
        let layout = SelectionGeometry.readout(size: chip, selection: selection, container: screen)
        #expect(layout.frame.minY == selection.maxY + SelectionGeometry.readoutGap, "flipped up")
        #expect(layout.frame.maxX == screen.maxX - SelectionGeometry.readoutMargin, "pulled left")
        #expect(screen.contains(layout.frame))
    }

    @Test("A full-height selection has no outside left, so the chip moves inside it")
    func flipsInsideWhenThereIsNoOutside() {
        let selection = CGRect(x: 400, y: 0, width: 300, height: 900)
        let layout = SelectionGeometry.readout(size: chip, selection: selection, container: screen)
        #expect(layout.isInsideSelection)
        #expect(selection.contains(layout.frame))
        #expect(screen.contains(layout.frame))
    }

    @Test("The chip is never clipped, wherever the selection lands")
    func neverClipped() {
        for x in stride(from: CGFloat(0), through: 1440, by: 180) {
            for y in stride(from: CGFloat(0), through: 900, by: 180) {
                for size in [CGSize(width: 3, height: 3), CGSize(width: 90, height: 40),
                             CGSize(width: 700, height: 500), CGSize(width: 1440, height: 900)] {
                    let selection = CGRect(origin: CGPoint(x: x, y: y), size: size)
                        .intersection(screen)
                    guard !selection.isEmpty else { continue }
                    let layout = SelectionGeometry.readout(size: chip, selection: selection,
                                                          container: screen)
                    #expect(screen.contains(layout.frame),
                            "clipped at \(selection): chip landed at \(layout.frame)")
                }
            }
        }
    }

    @Test("The chip steps out of the pointer's zone rather than sitting under the crosshair")
    func dodgesThePointer() {
        // Small selection: both alignments under it overlap a pointer parked at
        // the bottom-right corner, so the only clear spot is above.
        let selection = CGRect(x: 600, y: 400, width: 100, height: 60)
        let pointerZone = CGRect(x: 700 - 64, y: 400 - 64, width: 128, height: 128)
        let layout = SelectionGeometry.readout(size: chip, selection: selection,
                                               container: screen, avoiding: pointerZone)
        #expect(layout.frame.intersects(pointerZone) == false)
        #expect(layout.frame.minY == selection.maxY + SelectionGeometry.readoutGap)
    }

    @Test("When every spot is blocked the number still gets drawn, on screen")
    func showsTheNumberEvenWithNowhereClear() {
        let selection = CGRect(x: 400, y: 400, width: 300, height: 200)
        let layout = SelectionGeometry.readout(size: chip, selection: selection,
                                               container: screen, avoiding: screen)
        #expect(screen.contains(layout.frame))
    }

    // MARK: - Readout text

    @Test("A 1× display gets points only; a 2× one also gets the pixel figure a bug report needs")
    func readoutTextByScale() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(SelectionGeometry.readoutText(for: rect, scale: 1).points == "300 × 200")
        #expect(SelectionGeometry.readoutText(for: rect, scale: 1).pixels == nil)
        #expect(SelectionGeometry.readoutText(for: rect, scale: 2).pixels == "600 × 400 px")
    }

    @Test("Sub-point drag positions round, they don't truncate a pixel away")
    func readoutTextRounds() {
        let rect = CGRect(x: 0, y: 0, width: 300.4, height: 199.6)
        let text = SelectionGeometry.readoutText(for: rect, scale: 2)
        #expect(text.points == "300 × 200")
        #expect(text.pixels == "601 × 399 px")
    }

    // MARK: - Nudge

    @Test("An arrow moves the selection by the step and nothing else")
    func nudgeMoves() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let moved = SelectionGeometry.nudged(rect, dx: 10, dy: -1, in: screen)
        #expect(moved == CGRect(x: 110, y: 99, width: 200, height: 100))
    }

    @Test("A nudge into a screen edge stops — it never trims the size the user just dialled in",
          arguments: [
            (CGRect(x: 1240, y: 100, width: 200, height: 100), CGFloat(10), CGFloat(0)),   // right
            (CGRect(x: 0, y: 100, width: 200, height: 100), CGFloat(-10), CGFloat(0)),     // left
            (CGRect(x: 100, y: 0, width: 200, height: 100), CGFloat(0), CGFloat(-10)),     // bottom
            (CGRect(x: 100, y: 800, width: 200, height: 100), CGFloat(0), CGFloat(10)),    // top
          ])
    func nudgeClampsWithoutResizing(_ rect: CGRect, _ dx: CGFloat, _ dy: CGFloat) {
        let moved = SelectionGeometry.nudged(rect, dx: dx, dy: dy, in: screen)
        #expect(moved == rect, "already flush against the edge, so it should not budge")
        #expect(moved.size == rect.size)
        #expect(screen.contains(moved))
    }

    @Test("A selection larger than the screen pins to the origin instead of inverting its clamp")
    func nudgeSurvivesAnOversizeRect() {
        let rect = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let moved = SelectionGeometry.nudged(rect, dx: 10, dy: 10, in: screen)
        #expect(moved.origin == .zero)
        #expect(moved.size == rect.size)
    }

    // MARK: - Resize

    @Test("Option+arrow drives the bottom-right corner the way the arrow points")
    func resizeFollowsTheArrow() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)   // maxY 200
        let wider = SelectionGeometry.resized(rect, dx: 1, dy: 0, in: screen)
        #expect(wider == CGRect(x: 100, y: 100, width: 201, height: 100))
        let taller = SelectionGeometry.resized(rect, dx: 0, dy: -10, in: screen)
        #expect(taller == CGRect(x: 100, y: 90, width: 200, height: 110), "grows downward")
        let shorter = SelectionGeometry.resized(rect, dx: 0, dy: 10, in: screen)
        #expect(shorter == CGRect(x: 100, y: 110, width: 200, height: 90))
        #expect(shorter.maxY == rect.maxY, "the opposite corner is the anchor and must not move")
    }

    @Test("Resizing can't turn the selection inside out — a negative side becomes a mirrored crop",
          arguments: [
            (CGFloat(-50), CGFloat(0)), (CGFloat(0), CGFloat(50)), (CGFloat(-50), CGFloat(50)),
          ])
    func resizeCannotInvert(_ dx: CGFloat, _ dy: CGFloat) {
        let rect = CGRect(x: 100, y: 100, width: 2, height: 2)
        let resized = SelectionGeometry.resized(rect, dx: dx, dy: dy, in: screen)
        #expect(resized.width >= 1)
        #expect(resized.height >= 1)
        #expect(resized.minX == rect.minX)
        #expect(resized.maxY == rect.maxY)
    }

    @Test("Resizing can't push the selection off the screen either")
    func resizeStaysOnScreen() {
        let atRight = SelectionGeometry.resized(CGRect(x: 1400, y: 100, width: 40, height: 100),
                                                dx: 50, dy: 0, in: screen)
        #expect(atRight.maxX == screen.maxX)
        let atBottom = SelectionGeometry.resized(CGRect(x: 100, y: 0, width: 200, height: 100),
                                                 dx: 0, dy: -50, in: screen)
        #expect(atBottom.minY == screen.minY)
        #expect(screen.contains(atRight))
        #expect(screen.contains(atBottom))
    }

    // MARK: - Screen spaces

    @Test("The view→selection flip is its own inverse, so a round trip changes nothing")
    func flipIsItsOwnInverse() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        let local = SelectionGeometry.flipped(rect, inHeight: 900)
        #expect(local == CGRect(x: 10, y: 840, width: 30, height: 40))
        #expect(SelectionGeometry.flipped(local, inHeight: 900) == rect)
    }

    @Test("The flip uses the rect's OWN screen height — the multi-display trap")
    func flipUsesEachScreensHeight() {
        // Same view rect on a 900-point laptop panel and a 1080-point monitor.
        let rect = CGRect(x: 0, y: 20, width: 100, height: 40)
        #expect(SelectionGeometry.flipped(rect, inHeight: 900).minY == 840)
        #expect(SelectionGeometry.flipped(rect, inHeight: 1080).minY == 1020)
    }

    @Test("A selection touching the top of the view lands at y = 0 in top-left space")
    func flipPutsTheTopEdgeAtZero() {
        let rect = CGRect(x: 5, y: 860, width: 100, height: 40)   // maxY == 900
        #expect(SelectionGeometry.flipped(rect, inHeight: 900).minY == 0)
    }
}
