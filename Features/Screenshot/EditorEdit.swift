/// One entry on the capture editor's single undo stack.
///
/// Strokes and whole-image transforms share one stack on purpose: two stacks meant
/// ⌘Z could undo a rotate that happened *before* three arrows the user drew after
/// it, and the picture would come back with the arrows in the wrong places.
enum EditorEdit {
    /// A stroke appended to the editor's annotation list. While the entry sits on
    /// the undo stack the stroke itself still lives in that list, so the payload is
    /// nil; the popped copy travels with the entry onto the redo stack.
    case stroke(AnnotationStroke?)
    /// A crop / rotate / flip, with the state on both sides of it.
    case transform(before: EditorImageState, after: EditorImageState)
}
