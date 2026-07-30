import CoreGraphics

/// Everything a crop / rotate / flip replaces, captured so one ⌘Z puts it back.
///
/// `flattened` is held as a reference, not a copy: undoing a rotate restores the
/// exact same bitmap object the editor was showing before it, so the image and its
/// annotations come back bit-identical rather than re-derived.
struct EditorImageState {
    /// nil while the editor is still showing the frozen screen itself.
    var flattened: CGImage?
    /// The rect the picture occupies on the overlay, in view points.
    var selection: CGRect
    /// Strokes still live and editable on top of `flattened`.
    var annotations: [AnnotationStroke]
    /// Where the numbered-step tool continues from — baked-in steps must not be
    /// re-used, so the counter survives a flatten.
    var stepCounter: Int
}
