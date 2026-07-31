import Foundation

/// Builds the visible row list out of the two sources the window shows: the
/// snippets the person wrote, and the history SnapDesk captured.
///
/// Pure, so the ordering and filtering rules are testable without a window,
/// including the one that matters most, that a snippet is present no matter what
/// the history cap did.
enum ClipboardRows {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", snippets = "Snippets", text = "Text"
        case link = "Links", image = "Images", pinned = "Pinned"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .all: "square.grid.2x2"
            case .snippets: "bookmark.fill"
            case .text: "text.alignleft"
            case .link: "link"
            case .image: "photo"
            case .pinned: "pin.fill"
            }
        }

        /// Snippets belong in the unfiltered list and in Text. Links / Images /
        /// Pinned are questions about CAPTURED content, and answering them with
        /// authored entries would make those filters mean two things at once.
        var showsSnippets: Bool { self == .all || self == .snippets || self == .text }
        var showsHistory: Bool { self != .snippets }
    }

    /// Snippet rows first (in the person's own order), then starred history, then
    /// the rest by recency.
    static func compose(history: [ClipboardItem], snippets: [Snippet],
                        filter: Filter, search: String) -> [ClipboardItem] {
        var out: [ClipboardItem] = []
        if filter.showsSnippets {
            out += snippets.map(ClipboardItem.init(snippet:)).filter { matches($0, search) }
        }
        guard filter.showsHistory else { return out }
        let base = history.filter { item in
            switch filter {
            case .all, .snippets: break
            case .text:   if item.isImage { return false }
            case .link:   if item.contentType != .link { return false }
            case .image:  if !item.isImage { return false }
            case .pinned: if !item.pinned { return false }
            }
            return matches(item, search)
        }
        // Pinned float to the top, recency preserved within each group.
        out += base.filter { $0.pinned } + base.filter { !$0.pinned }
        return out
    }

    /// Searches the (≤500-char, cached) preview, never the raw multi-KB string:
    /// keeps every keystroke off the slow path. A snippet also matches on the name
    /// the person gave it, which is usually the only thing they remember.
    private static func matches(_ item: ClipboardItem, _ search: String) -> Bool {
        guard search.isEmpty == false else { return true }
        if item.preview.localizedCaseInsensitiveContains(search) { return true }
        return item.title?.localizedCaseInsensitiveContains(search) == true
    }
}
