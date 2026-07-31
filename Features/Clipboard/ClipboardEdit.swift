import Foundation

/// Edit-before-paste.
///
/// The history is a log of what was copied and is never rewritten. The same rule
/// `TextTransform` follows. So an edited paste travels on a THROWAWAY item that is
/// routed to the pasteboard and then dropped on the floor.
enum ClipboardEdit {
    /// Only text can be edited; there is nothing to type at an image.
    static func isEditable(_ item: ClipboardItem) -> Bool { item.text != nil }

    /// The item an edited paste travels on.
    ///
    /// `original` is only read. The id is deliberately NOT reused:
    /// `copyToPasteboard(movingToTop:)`, `togglePin` and `delete` all match rows
    /// by id, so an edited copy carrying
    /// the stored row's id could be promoted, starred or deleted in its place,
    /// and a `movingToTop` match would reorder history around a row that was never
    /// stored. Returns nil when there is nothing to paste, or when the row is an
    /// image.
    static func transientItem(editing original: ClipboardItem, to text: String) -> ClipboardItem? {
        guard isEditable(original), text.isEmpty == false else { return nil }
        // Same in-memory ceiling a real copy gets: the editor is a text view and
        // will happily hold whatever was pasted into it.
        return ClipboardItem(kind: .text(ClipboardManager.cappedByBytes(text, 1_048_576)))
    }
}
