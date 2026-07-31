import Combine
import Foundation

/// Owns the snippet list and its own on-disk copy.
///
/// Deliberately NOT part of `ClipboardManager.items`: keeping snippets out of the
/// history array is what makes "the cap never evicts one" and "clear on quit
/// leaves them alone" structural, instead of a rule someone has to remember at
/// every call site that trims or wipes history.
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    /// Own key, own blob. Nothing here shares storage with history text, which is
    /// what lets one be wiped while the other survives.
    static let persistKey = "SnapDesk.clipboard.snippets"
    /// A snippet is hand-written, so these ceilings are about a runaway paste into
    /// the editor rather than about volume.
    static let bodyByteCap = 262_144     // 256 KB each
    static let byteBudget = 4_194_304    // 4 MB in total

    private let save: (Data) -> Void

    /// Storage is injected so tests can exercise the store without writing to the
    /// real defaults domain: a test must not leave anything in the plist of the
    /// person running the suite.
    init(load: () -> Data? = { UserDefaults.standard.data(forKey: SnippetStore.persistKey) },
         save: @escaping (Data) -> Void = { UserDefaults.standard.set($0, forKey: SnippetStore.persistKey) }) {
        self.save = save
        snippets = Self.decode(load())
    }

    // MARK: - Actions

    @discardableResult
    func add(title: String, body: String) -> Snippet {
        let snippet = Snippet(title: title, body: body)
        snippets = Self.adding(snippet, to: snippets)
        persist()
        return snippet
    }

    func update(id: UUID, title: String, body: String) {
        snippets = Self.updating(id: id, title: title, body: body, in: snippets)
        persist()
    }

    func delete(id: UUID) {
        snippets = Self.removing(id: id, from: snippets)
        persist()
    }

    /// Keyboard reorder: `offset` is -1 for up, +1 for down.
    func move(id: UUID, by offset: Int) {
        snippets = Self.moving(id: id, by: offset, in: snippets)
        persist()
    }

    func snippet(id: UUID) -> Snippet? { snippets.first { $0.id == id } }

    /// Written synchronously, unlike history: a snippet edit is a rare, small,
    /// deliberate act, so there is nothing to debounce. And losing one to a crash
    /// 0.8 s later would be losing something the person typed by hand.
    private func persist() {
        guard let data = Self.encode(snippets) else { return }
        save(data)
    }

    // MARK: - List algebra (pure)

    /// Newest first: the snippet just written is the one about to be used.
    /// Everything below it keeps the person's own order (see `moving`).
    static func adding(_ snippet: Snippet, to list: [Snippet]) -> [Snippet] {
        withinBudget([snippet] + list.filter { $0.id != snippet.id })
    }

    /// Same id AND same date: an edit is not a new snippet, and re-sorting the
    /// list under the person because they fixed a typo would be its own bug.
    static func updating(id: UUID, title: String, body: String, in list: [Snippet]) -> [Snippet] {
        withinBudget(list.map { s in
            guard s.id == id else { return s }
            return Snippet(id: s.id, title: title, body: body, date: s.date)
        })
    }

    static func removing(id: UUID, from list: [Snippet]) -> [Snippet] {
        list.filter { $0.id != id }
    }

    /// Moves one entry by `offset` places, CLAMPED to the ends: a "move up" on the
    /// first row must do nothing, not wrap it to the bottom.
    static func moving(id: UUID, by offset: Int, in list: [Snippet]) -> [Snippet] {
        guard let from = list.firstIndex(where: { $0.id == id }) else { return list }
        let to = min(max(from + offset, 0), list.count - 1)
        guard to != from else { return list }
        var out = list
        out.insert(out.remove(at: from), at: to)
        return out
    }

    /// Per-body and aggregate caps, so one giant paste into the editor can't make
    /// the stored blob unbounded. Entries past the budget are dropped from the
    /// END. The newest are what the person is working with.
    static func withinBudget(_ list: [Snippet]) -> [Snippet] {
        var out: [Snippet] = []
        var bytes = 0
        for s in list {
            let body = s.body.utf8.count > bodyByteCap
                ? ClipboardManager.cappedByBytes(s.body, bodyByteCap)
                : s.body
            bytes += body.utf8.count
            guard bytes <= byteBudget else { break }
            out.append(body == s.body ? s : Snippet(id: s.id, title: s.title, body: body, date: s.date))
        }
        return out
    }

    // MARK: - Coding

    static func encode(_ list: [Snippet]) -> Data? {
        do {
            return try JSONEncoder().encode(list)
        } catch {
            NSLog("SnapDesk: failed to encode snippets: \(error)")
            return nil
        }
    }

    static func decode(_ data: Data?) -> [Snippet] {
        guard let data, let list = try? JSONDecoder().decode([Snippet].self, from: data) else { return [] }
        return list
    }
}
