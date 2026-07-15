import Foundation

/// Clears disposable junk (CleanMyMac-style, per category) to reclaim disk.
/// Only touches data that's designed to be disposable — caches, temp, logs —
/// plus (opt-in) the user's Trash. In the sandboxed (Mac App Store) build this
/// is limited to SnapDesk's own container; the direct build cleans user-wide.
enum CacheCleaner {
    /// One cleanable junk category.
    enum Kind: String, CaseIterable, Identifiable {
        case caches = "User caches"
        case temp   = "Temp files"
        case logs   = "Logs"
        case trash  = "Trash"
        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .caches: "App caches — rebuilt automatically"
            case .temp:   "Temporary working files"
            case .logs:   "App & diagnostic logs"
            case .trash:  "Empties the Trash — permanent"
            }
        }
        var symbol: String {
            switch self {
            case .caches: "archivebox"
            case .temp:   "clock.arrow.circlepath"
            case .logs:   "doc.text"
            case .trash:  "trash"
            }
        }
        /// Trash emptying is a permanent delete → never pre-checked.
        var defaultOn: Bool { self != .trash }
    }

    /// Directories whose CONTENTS we're willing to remove for a category.
    private static func targets(_ kind: Kind) -> [URL] {
        let fm = FileManager.default
        switch kind {
        case .caches:
            return fm.urls(for: .cachesDirectory, in: .userDomainMask)
        case .temp:
            return [fm.temporaryDirectory]
        case .logs:
            return [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")]
        case .trash:
            return fm.urls(for: .trashDirectory, in: .userDomainMask)
        }
    }

    /// Total size (bytes) of everything the category could clear. Off-main.
    static func size(_ kind: Kind) -> UInt64 {
        targets(kind).reduce(0) { $0 + dirSize($1) }
    }

    /// Delete the CONTENTS of each target (not the dirs themselves). Skips
    /// entries in use / not removable. Returns freed bytes. Off-main.
    @discardableResult
    static func clean(_ kind: Kind) -> UInt64 {
        let fm = FileManager.default
        var freed: UInt64 = 0
        // Caches/temp: unlink SUCCEEDS on files other apps hold open — deleting
        // a cache DB mid-write can corrupt/crash the app. Skip anything whose
        // DEEP-newest mtime is within 10 min (a folder's own mtime doesn't
        // change when a nested file is written, so top-level mtime isn't enough).
        // Trash is user-intent — always emptied fully.
        let recentCutoff = Date().addingTimeInterval(-600)
        for dir in targets(kind) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for item in items {
                if kind != .trash, Self.newestMTime(item) > recentCutoff { continue }
                let sz = dirSize(item)
                do { try fm.removeItem(at: item); freed += sz }
                catch { /* protected — skip */ }
            }
        }
        return freed
    }

    /// Most-recent modification time anywhere inside `url` (the item itself if a
    /// file). Bounded walk so a huge cache dir can't stall the pass.
    private static func newestMTime(_ url: URL) -> Date {
        let fm = FileManager.default
        var newest = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return newest }
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return newest }
        var seen = 0
        for case let f as URL in en {
            if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               m > newest { newest = m }
            seen += 1
            if seen > 5000 { break }   // safety cap on very large trees
        }
        return newest
    }

    /// Size every category on a background queue → main-thread callback.
    static func measureAll(_ completion: @escaping ([Kind: UInt64]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var out: [Kind: UInt64] = [:]
            for k in Kind.allCases { out[k] = size(k) }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// Clean the given categories in order → main-thread callback (freed bytes).
    static func cleanAsync(_ kinds: [Kind], _ completion: @escaping (UInt64) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let freed = kinds.reduce(0) { $0 + clean($1) }
            DispatchQueue.main.async { completion(freed) }
        }
    }

    // MARK: - Helpers

    /// Public wrapper so other cleaners (uninstall) can size arbitrary paths.
    static func dirSizePublic(_ url: URL) -> UInt64 { dirSize(url) }

    private static func dirSize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey],
                                     errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += UInt64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
