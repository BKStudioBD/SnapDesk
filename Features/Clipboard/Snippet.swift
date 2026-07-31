import Foundation

/// A named entry the person wrote themselves: a postal address, a support
/// reply, a shell one-liner.
///
/// Snippets sit in the same list as history but they are NOT history: the
/// history cap never evicts one, and "clear history when SnapDesk quits" never
/// touches them, because that setting is about traces of copying and a snippet
/// is content the person authored.
struct Snippet: Identifiable, Equatable, Codable {
    let id: UUID
    /// The row's label. Never empty: `init` falls back to the first line of the
    /// body, since a nameless row is unfindable in a list of names.
    var title: String
    /// What actually gets pasted.
    var body: String
    /// Creation time. The list order is the person's own (see `SnippetStore`);
    /// this is only the tie-breaker if that order is ever lost.
    let date: Date

    static let untitled = "Untitled snippet"

    init(id: UUID = UUID(), title: String, body: String, date: Date = Date()) {
        self.id = id
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = name.isEmpty ? Self.derivedTitle(from: body) : name
        self.body = body
        self.date = date
    }

    /// A name taken from the first non-blank line of the body.
    ///
    /// Bounded on purpose: a body can be a 256 KB paste, and `prefix(61)` before
    /// any `count` keeps this off the slow path. The same reason
    /// `ClipboardItem.preview` never walks a whole string.
    static func derivedTitle(from body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline)
            .first { $0.trimmingCharacters(in: .whitespaces).isEmpty == false }
        guard let line else { return untitled }
        let head = String(line.trimmingCharacters(in: .whitespaces).prefix(61))
        return head.count > 60 ? String(head.prefix(60)) + "…" : head
    }
}
