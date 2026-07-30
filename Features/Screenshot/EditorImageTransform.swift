import CoreGraphics

/// A whole-image edit in the capture editor: the operations that change the
/// picture's geometry instead of drawing on top of it.
enum EditorImageTransform: CaseIterable {
    case rotateLeft, rotateRight, flipHorizontal, flipVertical

    /// Spoken/VoiceOver name — also what a failure notification says.
    var label: String {
        switch self {
        case .rotateLeft: "Rotate left"
        case .rotateRight: "Rotate right"
        case .flipHorizontal: "Flip horizontal"
        case .flipVertical: "Flip vertical"
        }
    }

    /// True when the result's width and height trade places.
    var swapsAxes: Bool {
        switch self {
        case .rotateLeft, .rotateRight: true
        case .flipHorizontal, .flipVertical: false
        }
    }

    func apply(to image: CGImage) -> CGImage? {
        switch self {
        case .rotateLeft: ImageTransformer.rotated(image, clockwise: false)
        case .rotateRight: ImageTransformer.rotated(image, clockwise: true)
        case .flipHorizontal: ImageTransformer.flipped(image, horizontally: true)
        case .flipVertical: ImageTransformer.flipped(image, horizontally: false)
        }
    }

    /// Where the transformed image should sit on screen, given the rect it occupies
    /// now. A quarter turn swaps the box's sides about its own centre, so the
    /// pixels-per-point ratio survives — a rotated 2× capture is still 2×.
    ///
    /// A box that would then hang off the display is shrunk to fit, keeping its
    /// aspect: everything the editor draws (the dim, the handles, the toolbars) is
    /// positioned from this rect, and an off-screen selection puts the toolbar out
    /// of reach. The exported bitmap keeps its full pixel count either way.
    func displayRect(for rect: CGRect, in bounds: CGRect) -> CGRect {
        guard swapsAxes, rect.width > 0, rect.height > 0,
              bounds.width > 0, bounds.height > 0 else { return rect }
        var w = rect.height, h = rect.width
        let fit = min(1, min(bounds.width / w, bounds.height / h))
        w = max(1, (w * fit).rounded(.down))
        h = max(1, (h * fit).rounded(.down))
        var x = (rect.midX - w / 2).rounded()
        var y = (rect.midY - h / 2).rounded()
        x = min(max(x, bounds.minX), bounds.maxX - w)
        y = min(max(y, bounds.minY), bounds.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
