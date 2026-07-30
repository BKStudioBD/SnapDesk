import AppKit

/// On-disk home for clipboard image bytes, so a restart no longer loses every
/// screenshot in history.
///
/// PRIVACY: a clipboard image is whatever was on screen — a password manager, a
/// banking page, a private message. So the directory is created 0700 and every
/// file 0600, the same treatment `MissLog` gives its captured frames, and it lives
/// under Application Support rather than world-readable `/tmp`.
///
/// And with "clear history when SnapDesk quits" on, only STARRED images are ever
/// written. Deleting unpinned files at quit would not be enough: a crash or a
/// force-quit never runs the quit path, so the only honest version of that promise
/// is that the bytes were never on disk in the first place.
final class ClipboardImageStore {
    /// One image's bytes, ready to be written.
    struct Entry: Equatable {
        let id: UUID
        let data: Data
    }

    /// Per-item ceiling. The compressor already lands ~100-300 KB per item, so
    /// anything past this is pathological and would eat the whole directory
    /// budget on its own.
    static let perItemByteCap = 4_194_304    // 4 MB
    /// Aggregate ceiling for the directory.
    static let byteBudget = 33_554_432       // 32 MB

    let directory: URL

    /// `directory` is injectable so tests write into a temporary directory they
    /// then remove — a test must never leave clipboard images on the disk of the
    /// person running the suite.
    init(directory: URL = ClipboardImageStore.defaultDirectory()) {
        self.directory = directory
    }

    /// ~/Library/Application Support/SnapDesk/ClipboardImages.
    ///
    /// NOT `/tmp`: it is world-readable, and the system sweeps it whenever it
    /// likes, so history would come back with holes in it.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SnapDesk/ClipboardImages", isDirectory: true)
    }

    // MARK: - Policy (pure)

    /// Which image bytes are ALLOWED to exist on disk, in write order.
    ///
    /// - Parameter pinnedOnly: true when "clear history when SnapDesk quits" is
    ///   on, and then nothing unpinned is returned at all — see the type comment.
    static func plan(_ items: [ClipboardItem], pinnedOnly: Bool) -> [Entry] {
        // Pinned first so the budget never sacrifices a starred image for a recent
        // one — the same rule `ClipboardManager.persistSnapshot` follows for text.
        let pinned = items.filter { $0.pinned }
        let unpinned = pinnedOnly ? [] : items.filter { !$0.pinned }
        var out: [Entry] = []
        var seen = Set<UUID>()
        var bytes = 0
        for item in pinned + unpinned {
            guard case .image(let data, _) = item.kind, seen.contains(item.id) == false else { continue }
            guard data.count <= perItemByteCap else { continue }
            // `continue`, not `break`: one oversized item must not shut the door on
            // the smaller ones behind it.
            guard bytes + data.count <= byteBudget else { continue }
            bytes += data.count
            seen.insert(item.id)
            out.append(Entry(id: item.id, data: data))
        }
        return out
    }

    static func fileName(for id: UUID) -> String { id.uuidString + ".jpg" }

    func url(for id: UUID) -> URL { directory.appendingPathComponent(Self.fileName(for: id)) }

    // MARK: - Disk

    /// Bytes for one row, or nil when the file is gone (pruned, or the directory
    /// was cleaned out from under us).
    func data(for id: UUID) -> Data? { try? Data(contentsOf: url(for: id)) }

    /// Makes the directory hold EXACTLY the planned entries: writes what is
    /// missing, and — when `prune` is set — deletes every other image file.
    ///
    /// That second half is half the point. A file whose item is gone — deleted,
    /// evicted by the cap, cleared, or unstarred while clear-on-quit is on — is a
    /// leak of exactly the content this store is careful about, and it would
    /// otherwise survive every restart.
    ///
    /// `prune` has NO default on purpose. An empty plan used to be routed to
    /// `removeAll()`, so "I have nothing to write" silently meant "delete every
    /// image the person has" — which is what a plan built before an asynchronous
    /// restore had merged its rows actually said. Deleting everything is now
    /// something a caller has to ask for in as many words.
    ///
    /// Synchronous on purpose: the caller owns the queue. `ClipboardManager` runs
    /// this on the one serial queue that also writes the history plist, so a
    /// debounced write, the quit-time flush and a prune can never interleave.
    func synchronize(_ entries: [Entry], prune: Bool) {
        if entries.isEmpty == false { ensureDirectory() }
        var keep = Set<String>()
        for entry in entries {
            let name = Self.fileName(for: entry.id)
            keep.insert(name)
            let target = directory.appendingPathComponent(name)
            // An id's bytes never change, so a file that exists is already right.
            guard FileManager.default.fileExists(atPath: target.path) == false else { continue }
            write(entry.data, to: target)
        }
        if prune { pruneOrphans(keeping: keep) }
    }

    /// Deletes every stored image. Only the `.jpg` files this store writes are
    /// touched — never the directory itself, never anything else inside it.
    func removeAll() { pruneOrphans(keeping: []) }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Write, then clamp to owner-only. `Data.write` creates with the process
    /// umask, so tighten explicitly rather than trust it. The `.atomic` temp file
    /// it writes first lives inside the 0700 directory, so it is unreachable by
    /// another local user even for the moment before the rename.
    private func write(_ data: Data, to url: URL) {
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func pruneOrphans(keeping keep: Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".jpg") && keep.contains(name) == false {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
