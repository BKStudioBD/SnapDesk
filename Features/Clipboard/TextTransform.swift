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
    static func available(for text: String) -> [TextTransform] {
        allCases.filter { transform in
            switch transform {
            case .prettyJSON, .urlDecode, .plain, .trimLines:
                // Only when they'd actually change something.
                return transform.apply(to: text).map { $0 != text } ?? false
            default:
                return true
            }
        }
    }
}
