import CoreGraphics

/// The interactive crop rectangle: pure geometry, no view.
///
/// Every rule that keeps a crop sane — it never leaves the image, an edge dragged
/// past its opposite stops instead of flipping, and it can't collapse to nothing —
/// lives here so it can be tested without an overlay window on screen. An inverted
/// or zero-area rect reaches the compositor as a negative-size crop, which returns
/// no image at all and looks to the user like the shot was lost.
struct CropBox {
    /// Smallest crop the handles can produce. Below roughly this the eight grab
    /// targets overlap each other and the box can no longer be aimed at.
    static let minimumSide: CGFloat = 12

    /// Handle order matches the editor's selection handles so the two feel the same:
    /// 0:BL 1:B 2:BR 3:L 4:R 5:TL 6:T 7:TR.
    private static let leftHandles: Set<Int> = [0, 3, 5]
    private static let rightHandles: Set<Int> = [2, 4, 7]
    private static let bottomHandles: Set<Int> = [0, 1, 2]
    private static let topHandles: Set<Int> = [5, 6, 7]

    /// The area the crop may not leave — the image's rect on screen, in points.
    let limit: CGRect
    private(set) var rect: CGRect

    /// True once the box has actually been aimed — rubber-banded, resized by a
    /// handle, or slid.
    ///
    /// The default box is inset 8% on every side so it reads as a box rather than as
    /// the image's own border, which means confirming an UNTOUCHED one is not a
    /// no-op: it keeps 84% × 84% and throws away 29% of the pixels. The Crop button
    /// both starts and confirms, so a second click — or the double-click people give
    /// toolbar buttons, or C then ↵ — silently cut the edges off the very window
    /// being captured, with nothing to show it had happened. The confirm path checks
    /// this and treats an untouched box as "never mind".
    private(set) var wasDragged = false

    /// `rect` nil starts slightly inset from the image, which is what tells the user
    /// the box is draggable at all: a crop box exactly on the image edge looks like
    /// the border that was already there. An explicit `rect` is a box somebody
    /// already aimed, so it counts as dragged.
    init(limit: CGRect, rect: CGRect? = nil) {
        self.wasDragged = rect != nil
        let area = limit.standardized
        self.limit = area
        let side = Self.side(in: area)
        var r = (rect ?? area.insetBy(dx: area.width * 0.08, dy: area.height * 0.08)).standardized
        r = r.intersection(area)
        if r.isNull || r.width < side || r.height < side { r = area }
        self.rect = r
    }

    /// The effective minimum: an image narrower than `minimumSide` must still be
    /// croppable, so the floor never exceeds the image itself.
    private static func side(in area: CGRect) -> CGFloat {
        max(1, min(minimumSide, min(area.width, area.height)))
    }

    static func handleRects(for rect: CGRect, size: CGFloat) -> [CGRect] {
        let xs = [rect.minX, rect.midX, rect.maxX]
        let ys = [rect.minY, rect.midY, rect.maxY]
        var rects: [CGRect] = []
        for (i, y) in ys.enumerated() {
            for (j, x) in xs.enumerated() {
                if i == 1 && j == 1 { continue }   // no centre handle
                rects.append(CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
            }
        }
        return rects
    }

    /// Index of the handle under `point`, with the same 3pt slop as the editor's
    /// selection handles (an 11pt dot is hard to hit exactly).
    func handle(at point: CGPoint, size: CGFloat) -> Int? {
        for (i, r) in Self.handleRects(for: rect, size: size).enumerated()
        where r.insetBy(dx: -3, dy: -3).contains(point) { return i }
        return nil
    }

    mutating func drag(handle: Int, to point: CGPoint) {
        wasDragged = true
        let p = clamped(point)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if Self.leftHandles.contains(handle) { minX = p.x }
        if Self.rightHandles.contains(handle) { maxX = p.x }
        if Self.bottomHandles.contains(handle) { minY = p.y }
        if Self.topHandles.contains(handle) { maxY = p.y }

        // Past the opposite edge the dragged edge STOPS. Letting it through would
        // invert the rect, and the user would be dragging a box whose handles have
        // silently swapped sides under the cursor.
        let side = Self.side(in: limit)
        if maxX - minX < side {
            if Self.leftHandles.contains(handle) { minX = maxX - side } else { maxX = minX + side }
        }
        if maxY - minY < side {
            if Self.bottomHandles.contains(handle) { minY = maxY - side } else { maxY = minY + side }
        }
        rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Slide the whole box without resizing it — it stops at the image edge.
    mutating func move(by delta: CGSize) {
        wasDragged = true
        var r = rect.offsetBy(dx: delta.width, dy: delta.height)
        r.origin.x = min(max(r.minX, limit.minX), limit.maxX - r.width)
        r.origin.y = min(max(r.minY, limit.minY), limit.maxY - r.height)
        rect = r
    }

    /// Rubber-band a fresh box between two dragged points.
    mutating func draw(from a: CGPoint, to b: CGPoint) {
        wasDragged = true
        let p = clamped(a), q = clamped(b)
        var r = CGRect(x: min(p.x, q.x), y: min(p.y, q.y),
                       width: abs(q.x - p.x), height: abs(q.y - p.y))
        let side = Self.side(in: limit)
        if r.width < side {
            r.size.width = side
            r.origin.x = min(r.minX, limit.maxX - side)
        }
        if r.height < side {
            r.size.height = side
            r.origin.y = min(r.minY, limit.maxY - side)
        }
        rect = r
    }

    private func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, limit.minX), limit.maxX),
                y: min(max(p.y, limit.minY), limit.maxY))
    }
}
