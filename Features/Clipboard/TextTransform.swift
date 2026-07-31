import Foundation

/// One-shot text cleanups applied on the way OUT of the clipboard history.
///
/// The history is a log of what you copied, so a transform never rewrites the
/// stored item — it only changes what lands on the pasteboard this once. That's
/// why these are actions in the row's context menu rather than a mode you leave
/// switched on.
enum TextTransform: String, CaseIterable, Identifiable {
    case plain = "Strip line breaks"
    case trimLines = "Trim each line"
    case lowercase = "lowercase"
    case uppercase = "UPPERCASE"
    case titleCase = "Title Case"
    case slug = "slug-case"
    case urlDecode = "URL-decode"
    case prettyJSON = "Pretty-print JSON"

    var id: String { rawValue }

    /// Applied to a whole clipboard item. Returns nil when the transform can't
    /// apply (bad JSON, nothing to decode) — the caller then leaves the text alone
    /// rather than pasting something mangled.
    func apply(to text: String) -> String? {
        switch self {
        case .plain:
            // Every run of whitespace/newlines becomes one space. What you want
            // when pasting a wrapped paragraph into a single-line field.
            let parts = text.split(whereSeparator: \.isWhitespace)
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        case .trimLines:
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
        case .lowercase:
            return text.lowercased()
        case .uppercase:
            return text.uppercased()
        case .titleCase:
            return text.lowercased()
                .split(separator: " ", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        case .slug:
            let lowered = text.lowercased()
            // Keep letters and digits, everything else becomes a separator.
            let pieces = lowered.split { ch in
                (ch.isLetter || ch.isNumber) == false
            }
            let slug = pieces.joined(separator: "-")
            return slug.isEmpty ? nil : slug
        case .urlDecode:
            guard let decoded = text.removingPercentEncoding, decoded != text else { return nil }
            return decoded
        case .prettyJSON:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let string = String(data: pretty, encoding: .utf8) else { return nil }
            return string
        }
    }

    /// Transforms worth offering for this item — a JSON pretty-print on a plain
    /// sentence is noise, and an image has no text at all.
    ///
    /// This runs while ROWS RENDER — SwiftUI builds a row's context menu as part
    /// of `body`, not on right-click — so it has to stay cheap. It used to run
    /// four whole transforms, `JSONSerialization` among them, across the full
    /// item for every visible row on every keystroke in the search field, and a
    /// history row holds up to 1 MB. These answer the same question by LOOKING at
    /// the text instead of rewriting it.
    static func available(for text: String) -> [TextTransform] {
        allCases.filter { transform in
            switch transform {
            case .plain:
                // Something for a collapse to actually do.
                return text.contains(where: \.isNewline) || text.contains("  ")
                    || text.first?.isWhitespace == true || text.last?.isWhitespace == true
            case .trimLines:
                return hasLineEdgeWhitespace(text)
            case .urlDecode:
                return text.contains("%")
            case .prettyJSON:
                return looksLikeJSON(text)
            default:
                return true
            }
        }
    }

    /// Whitespace that `trimLines` would strip: at the start or end of any line,
    /// newlines themselves excluded.
    private static func hasLineEdgeWhitespace(_ text: String) -> Bool {
        func isEdge(_ c: Character) -> Bool { c.isWhitespace && !c.isNewline }
        var atLineStart = true
        var previous: Character?
        for character in text {
            if character.isNewline {
                if let previous, isEdge(previous) { return true }
                atLineStart = true
            } else {
                if atLineStart, isEdge(character) { return true }
                atLineStart = false
            }
            previous = character
        }
        if let previous, isEdge(previous) { return true }
        return false
    }

    /// Parsing is the expensive half, so it only happens for text that starts
    /// like JSON and is small enough to be worth confirming. A huge blob is
    /// offered optimistically and `apply` makes the real decision when picked.
    private static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }),
              first == "{" || first == "[" else { return false }
        guard text.utf8.count <= 32_768 else { return true }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
