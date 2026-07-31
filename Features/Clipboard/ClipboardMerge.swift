import Foundation

/// Joining several selected rows into one new entry.
enum ClipboardMerge {
    /// A newline. Rows are whole lines, cells or paragraphs in practice, so
    /// anything else (", ", " ") would need re-editing after almost every merge.
    static let separator = "\n"

    /// ORDER: oldest first, i.e. the order things were actually copied.
    ///
    /// This is deliberately NOT the visual order. The list is newest-first, so
    /// collecting rows top-down selects newest → oldest; merged by date, three
    /// copies made A then B then C come back as "A\nB\nC", which is what
    /// collecting them was for. Merging in row order would reverse the text of
    /// every list the person builds by copying.
    ///
    /// Trailing newlines are stripped from each piece: a copied line usually
    /// carries one, and left in place each of them becomes a blank line in the
    /// middle of the merged block. A piece that is nothing BUT newlines
    /// contributes nothing.
    ///
    /// Image rows are skipped, they have no text to join, so merging a
    /// selection that happens to include a screenshot still produces the text.
    /// Returns nil when nothing textual is left, so the caller adds no empty row.
    static func merged(_ items: [ClipboardItem]) -> String? {
        let ordered = items.enumerated().sorted { a, b in
            if a.element.date != b.element.date { return a.element.date < b.element.date }
            // Identical timestamps (two copies inside the same tick, or a restored
            // list): fall back to the reverse of the given order, which for a
            // newest-first list is still oldest-first.
            return a.offset > b.offset
        }
        let pieces = ordered.compactMap { row -> String? in
            guard var text = row.element.text else { return nil }
            while let last = text.last, last.isNewline { text.removeLast() }
            return text.isEmpty ? nil : text
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: separator)
    }
}
