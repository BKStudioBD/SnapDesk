import CoreGraphics

/// The arithmetic behind the selection overlay: where the size readout chip
/// sits, how the arrow keys move and resize a pending selection, and the
/// vertical flip between a screen's view space and the top-left space
/// `RegionSelection` carries.
///
/// Deliberately AppKit-free and screen-free so every case can be pinned by a
/// test, including the ones nobody can reproduce on demand (a drag into the
/// bottom-right corner of a secondary display). Unless a function says
/// otherwise, every rect is in ONE screen's local space, bottom-left origin,
/// points.
enum SelectionGeometry {

    /// The smallest drag that counts as a selection, in points.
    ///
    /// The old floor was 2pt, which is "any movement at all". A 10 × 3pt slip
    /// therefore ran a real capture: the OCR miss log has one, a 21 × 8 pixel
    /// region that of course held no text, reported back to the user as "No
    /// text found" as though the reading had failed. Nothing legible fits below
    /// this, so a smaller drag is treated the way a plain click already is: the
    /// overlay stays up and waits for a real one.
    static let minimumDragPoints: CGFloat = 8

    /// Whether a dragged rect is big enough to act on.
    static func isSelectable(_ rect: CGRect) -> Bool {
        rect.width >= minimumDragPoints && rect.height >= minimumDragPoints
    }

    // MARK: - Readout chip

    /// Gap between the chip and the selection edge it hangs off.
    static let readoutGap: CGFloat = 8
    /// Closest the chip may come to a screen edge.
    static let readoutMargin: CGFloat = 6

    /// Where the readout chip goes.
    struct Readout: Equatable {
        let frame: CGRect
        /// True when there was no room outside the selection on either side, so
        /// the chip had to move inside it: a full-height drag, where "above"
        /// and "below" are both off screen.
        let isInsideSelection: Bool
    }

    /// Places a `size`-sized chip against `selection`, never letting it leave
    /// `container` and never letting it land on `keepClear` (the pointer's own
    /// zone: crosshair plus loupe).
    ///
    /// Order of preference: under the selection then over it, left-aligned
    /// before right-aligned, outside before inside. Under-and-left is the
    /// resting place because a drag runs top-left → bottom-right, which parks
    /// the pointer at the opposite corner.
    static func readout(size: CGSize,
                        selection: CGRect,
                        container: CGRect,
                        avoiding keepClear: CGRect = .null) -> Readout {
        let gap = readoutGap, margin = readoutMargin

        var verticals: [(y: CGFloat, inside: Bool)] = [
            (selection.minY - gap - size.height, false),   // under, outside
            (selection.maxY + gap, false),                 // over, outside
        ]
        // Inside only when the selection can actually hold the chip; otherwise
        // "inside" would just be another way of overhanging the edge.
        if selection.height >= size.height + gap * 2 {
            verticals += [(selection.minY + gap, true), (selection.maxY - gap - size.height, true)]
        }
        // Both alignments are pulled back inside the screen first, so the only
        // thing left to decide between them is whether they clear the pointer.
        let horizontals = [clampedX(selection.minX, width: size.width, in: container),
                           clampedX(selection.maxX - size.width, width: size.width, in: container)]

        var fallback: Readout?
        for (y, inside) in verticals {
            guard y >= container.minY + margin,
                  y + size.height <= container.maxY - margin else { continue }
            for x in horizontals {
                let candidate = Readout(frame: CGRect(x: x, y: y,
                                                      width: size.width, height: size.height),
                                        isInsideSelection: inside)
                if fallback == nil { fallback = candidate }
                if !candidate.frame.intersects(keepClear) { return candidate }
            }
        }
        // Everything overlaps the pointer: showing the number matters more than
        // dodging the cursor, so take the first spot that at least fits.
        if let fallback { return fallback }
        // A chip taller than the screen minus its margins. Clamp and draw.
        let y = clamp(selection.minY - gap - size.height,
                      container.minY + margin, container.maxY - margin - size.height)
        return Readout(frame: CGRect(x: horizontals[0], y: y,
                                     width: size.width, height: size.height),
                       isInsideSelection: false)
    }

    /// Points always; pixels too on a Retina display, because someone filing a
    /// bug about a 2× asset needs the pixel figure and someone sizing a window
    /// needs the point figure.
    static func readoutText(for rect: CGRect, scale: CGFloat) -> (points: String, pixels: String?) {
        let points = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        guard scale > 1 else { return (points, nil) }
        let w = Int((rect.width * scale).rounded()), h = Int((rect.height * scale).rounded())
        return (points, "\(w) × \(h) px")
    }

    // MARK: - Keyboard precision

    /// Moves the whole selection, kept fully inside `container`.
    ///
    /// Clamped, never shrunk: a nudge that quietly trimmed the selection at the
    /// screen edge would throw away the size the user just dialled in, which is
    /// the entire reason they reached for the arrow keys.
    static func nudged(_ rect: CGRect, dx: CGFloat, dy: CGFloat, in container: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: dx, dy: dy)
        moved.origin.x = clamp(moved.minX, container.minX, container.maxX - rect.width)
        moved.origin.y = clamp(moved.minY, container.minY, container.maxY - rect.height)
        return moved
    }

    /// Moves the selection's bottom-right corner. The corner the arrow keys
    /// resize from: by (dx, dy), so the corner travels the way the arrow points.
    ///
    /// Clamped so the selection can neither leave the screen nor cross itself:
    /// an inverted rect has a negative width, which downstream turns into a
    /// mirrored crop rather than an error.
    static func resized(_ rect: CGRect, dx: CGFloat, dy: CGFloat,
                        in container: CGRect, minimumSide: CGFloat = 1) -> CGRect {
        let maxX = clamp(rect.maxX + dx, rect.minX + minimumSide, container.maxX)
        let minY = clamp(rect.minY + dy, container.minY, rect.maxY - minimumSide)
        return CGRect(x: rect.minX, y: minY,
                      width: maxX - rect.minX, height: rect.maxY - minY)
    }

    // MARK: - Screen spaces

    /// Flips a rect between one screen's bottom-left-origin view space and the
    /// top-left-origin, screen-local space `RegionSelection` carries.
    ///
    /// Its own inverse, so one function covers both directions. `height` is that
    /// screen's own height: keeping the rect screen-local is what stops a
    /// second display's offset from leaking into the flip.
    static func flipped(_ rect: CGRect, inHeight height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Helpers

    private static func clampedX(_ x: CGFloat, width: CGFloat, in container: CGRect) -> CGFloat {
        clamp(x, container.minX + readoutMargin, container.maxX - readoutMargin - width)
    }

    /// A clamp that survives an empty range: when `hi < lo` (a rect wider than
    /// the space it must fit) the low bound wins, so the result is predictable
    /// instead of an inverted min/max.
    private static func clamp(_ value: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        hi <= lo ? lo : min(max(value, lo), hi)
    }
}
