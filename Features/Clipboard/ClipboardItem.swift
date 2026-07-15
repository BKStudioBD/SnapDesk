import AppKit

/// A single clipboard history entry. Text items persist to disk; image items
/// live for the session only (kept lightweight).
struct ClipboardItem: Identifiable, Equatable {
    enum Kind {
        case text(String)
        /// Compressed JPEG bytes (decoded only when copied back) + a small
        /// thumbnail for the list row. Storing decoded NSImages held ~23 MB
        /// per Retina screenshot — hundreds of items meant GBs of RAM.
        case image(data: Data, thumb: NSImage)
    }

    let id: UUID
    let kind: Kind
    let date: Date
    var pinned: Bool
    /// Cached at init — recomputing these per row render (they trim/scan the
    /// full string) caused visible scroll hitches with large history items.
    let preview: String
    let contentType: ContentType

    init(id: UUID = UUID(), kind: Kind, date: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.date = date
        self.pinned = pinned
        self.preview = Self.makePreview(kind)
        self.contentType = Self.makeContentType(kind)
    }

    /// True if `s` has more than `n` characters, walking at most n+1 — a plain
    /// `s.count > n` walks the WHOLE string (up to 1 MB here) just to compare.
    private static func longer(_ s: String, than n: Int) -> Bool {
        return s.index(s.startIndex, offsetBy: n + 1, limitedBy: s.endIndex) != nil
    }

    private static func makePreview(_ kind: Kind) -> String {
        switch kind {
        case .text(let s):
            let trimmed = longer(s, than: 2000)
                ? String(s.prefix(2000)).trimmingCharacters(in: .whitespacesAndNewlines)
                : s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "(whitespace)" }
            // Rows only show 2-3 lines; never hand SwiftUI a multi-MB string.
            return longer(trimmed, than: 500) ? String(trimmed.prefix(500)) + "…" : trimmed
        case .image:
            return "Image"
        }
    }

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool { lhs.id == rhs.id }
}

// MARK: - Smart content classification (drives the card look)

extension ClipboardItem {
    enum ContentType { case text, link, color, email, code, image }

    fileprivate static func makeContentType(_ kind: Kind) -> ContentType {
        switch kind {
        case .image: return .image
        case .text(let s):
            // Cap the scan — classification only needs the head of the string.
            let head = longer(s, than: 4000) ? String(s.prefix(4000)) : s
            let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isHexColor(t) { return .color }
            if Self.isLink(t)     { return .link }
            if Self.isEmail(t)    { return .email }
            if Self.looksLikeCode(t) { return .code }
            return .text
        }
    }

    /// "#RRGGBB" string when this item is a color, else nil.
    var hexString: String? {
        if case .text(let s) = kind {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isHexColor(t) { return t.hasPrefix("#") ? t : "#" + t }
        }
        return nil
    }

    private static func isHexColor(_ s: String) -> Bool {
        // Require a leading '#' so 6-char hex-ish tokens (git short SHAs, ids,
        // words like "facade") aren't misclassified as colors.
        guard s.hasPrefix("#") else { return false }
        let h = String(s.dropFirst())
        return h.count == 6 && h.allSatisfy { $0.isHexDigit }
    }
    private static func isLink(_ s: String) -> Bool {
        guard !s.contains(" "), !s.contains("\n") else { return false }
        return s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("www.")
    }
    private static func isEmail(_ s: String) -> Bool {
        guard !s.contains(" "), !s.contains("\n") else { return false }
        let parts = s.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".")
    }
    private static func looksLikeCode(_ s: String) -> Bool {
        guard s.contains("\n") else { return false }
        let tokens = ["{", "};", "()", "=>", "func ", "def ", "import ", "</", "const ", "var ", "let "]
        return tokens.contains { s.contains($0) }
    }
}
