import Foundation

/// Which rows a multi-row action (today: merge) will act on.
///
/// Ids, not indexes. The list re-sorts under the person constantly: a copy
/// arrives, a star floats a row to the top, the search text changes. And an
/// index-based selection would then point at whatever moved into that slot.
struct ClipboardSelection: Equatable {
    /// What a click or a Shift-arrow is asking for.
    enum Change {
        /// Command-click: add or remove exactly this row.
        case toggle
        /// Shift-click: everything between the anchor and this row.
        case extend
    }

    private(set) var ids: Set<UUID> = []
    /// The row an `extend` reaches FROM. An id, for the same reason as `ids`.
    private(set) var anchor: UUID?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    mutating func clear() {
        ids.removeAll()
        anchor = nil
    }

    mutating func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        // The anchor follows the last row touched either way, so a Command-click
        // followed by a Shift-click reads as one continuous gesture.
        anchor = id
    }

    /// Adds every row between the anchor and `id`, inclusive.
    ///
    /// Adds rather than replaces, so Command-clicking three scattered rows and
    /// then Shift-clicking a run keeps both. With no anchor yet. The very first
    /// gesture is a Shift-click: `id` becomes the anchor and the gesture selects
    /// that one row, instead of silently doing nothing.
    mutating func extend(to id: UUID, in rows: [UUID]) {
        guard let target = rows.firstIndex(of: id) else { return }
        let start = anchor.flatMap { rows.firstIndex(of: $0) } ?? target
        if anchor == nil { anchor = id }
        let range = start <= target ? start...target : target...start
        ids.formUnion(rows[range])
    }

    /// Applies a click gesture. `rows` is the visible order, needed only by
    /// `.extend`.
    mutating func apply(_ change: Change, to id: UUID, in rows: [UUID]) {
        switch change {
        case .toggle: toggle(id)
        case .extend: extend(to: id, in: rows)
        }
    }

    /// Drops ids that are no longer on screen: a merge must never act on a row
    /// that was deleted or filtered away while it sat in the selection.
    mutating func prune(to rows: [UUID]) {
        let visible = Set(rows)
        ids.formIntersection(visible)
        if let anchor, visible.contains(anchor) == false { self.anchor = nil }
    }
}
