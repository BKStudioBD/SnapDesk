import Foundation

/// One line in the Clean tab: a named pile of disposable files, the folders it
/// covers, and whether it is safe to tick by default.
///
/// A value type with no file access of its own, so the catalog can be built
/// against a temporary directory in a test.
struct CacheCategory: Identifiable, Sendable, Hashable {
    enum Group: String, CaseIterable, Sendable, Identifiable {
        case developer = "Developer"
        case browsers = "Browsers"
        case apps = "Apps"
        case system = "System"
        var id: String { rawValue }
    }

    let id: String
    let group: Group
    let name: String
    let detail: String
    let symbol: String
    /// Directories whose CONTENTS may be removed — never the directory itself.
    let paths: [URL]
    /// Ticked when the window opens. Anything that deletes rather than rebuilds
    /// (the Trash) is false: a permanent delete is never a default.
    let defaultOn: Bool
    /// Child names to leave alone, so a folder owned by another category is not
    /// measured or cleaned twice.
    let excluding: Set<String>

    /// Emptying the Trash is a permanent delete; everything else is a cache the
    /// owning app rebuilds, so the in-use guard does not apply there.
    var isTrash: Bool { id == "trash" }
}

/// Finds and clears disposable files: build caches, browser caches, app caches,
/// temporary files, logs and (opt-in) the Trash.
///
/// Two rules hold everywhere in here. Only the CONTENTS of a known cache
/// directory are removed, never the directory itself — an app that finds its
/// cache folder missing can behave far worse than one that finds it empty. And
/// anything written in the last ten minutes is left alone, because `unlink`
/// succeeds on a file another process still holds open, and a cache database
/// deleted mid-write is a corrupted app, not a cleaned one.
enum CacheCleaner {

    // MARK: - Catalog

    /// Every category SnapDesk knows how to clean, for the given home directory.
    /// Pure: no disk access, no filtering — call `present(in:)` for what exists.
    static func catalog(home: URL) -> [CacheCategory] {
        let library = home.appending(path: "Library")
        let caches = library.appending(path: "Caches")
        func inCaches(_ name: String) -> URL { caches.appending(path: name) }

        var out: [CacheCategory] = []

        // Developer — the biggest and safest wins on a working Mac.
        out.append(.init(id: "xcode.derived", group: .developer, name: "Xcode DerivedData",
                         detail: "Build products and indexes — rebuilt on the next build",
                         symbol: "hammer",
                         paths: [library.appending(path: "Developer/Xcode/DerivedData")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "xcode.devicesupport", group: .developer, name: "iOS DeviceSupport",
                         detail: "Symbols for devices you once plugged in",
                         symbol: "iphone",
                         paths: [library.appending(path: "Developer/Xcode/iOS DeviceSupport")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "simulator.caches", group: .developer, name: "Simulator caches",
                         detail: "CoreSimulator's own cache — not your simulators",
                         symbol: "square.stack",
                         paths: [inCaches("com.apple.dt.Xcode"), inCaches("com.apple.CoreSimulator")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "swiftpm", group: .developer, name: "Swift Package Manager",
                         detail: "Cloned dependencies, re-fetched on demand",
                         symbol: "shippingbox",
                         paths: [inCaches("org.swift.swiftpm"),
                                 home.appending(path: ".swiftpm/cache")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "node", group: .developer, name: "npm · yarn · pnpm",
                         detail: "Package manager download caches",
                         symbol: "cube",
                         paths: [home.appending(path: ".npm/_cacache"),
                                 inCaches("Yarn"), home.appending(path: ".cache/yarn"),
                                 library.appending(path: "pnpm/store")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "homebrew", group: .developer, name: "Homebrew",
                         detail: "Downloaded bottles and formula tarballs",
                         symbol: "mug",
                         paths: [inCaches("Homebrew")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "pip", group: .developer, name: "pip",
                         detail: "Python wheel cache",
                         symbol: "chevron.left.forwardslash.chevron.right",
                         paths: [inCaches("pip"), home.appending(path: ".cache/pip")],
                         defaultOn: true, excluding: []))

        // Browsers — cleared every day by the browser itself; safe, and big.
        out.append(.init(id: "chrome", group: .browsers, name: "Chrome",
                         detail: "Page and code caches",
                         symbol: "globe",
                         paths: [inCaches("Google/Chrome")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "safari", group: .browsers, name: "Safari",
                         detail: "Page cache and web data",
                         symbol: "safari",
                         paths: [inCaches("com.apple.Safari"), library.appending(path: "Safari/Favicon Cache")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "firefox", group: .browsers, name: "Firefox",
                         detail: "Page and startup caches",
                         symbol: "globe",
                         paths: [inCaches("Firefox")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "arc", group: .browsers, name: "Arc",
                         detail: "Page and code caches",
                         symbol: "globe",
                         paths: [inCaches("company.thebrowser.Browser")],
                         defaultOn: true, excluding: []))

        // Apps — the Electron trio that quietly grow the most.
        out.append(.init(id: "spotify", group: .apps, name: "Spotify",
                         detail: "Streamed audio cache",
                         symbol: "music.note",
                         paths: [inCaches("com.spotify.client")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "slack", group: .apps, name: "Slack",
                         detail: "Message and image cache",
                         symbol: "message",
                         paths: [inCaches("com.tinyspeck.slackmacgap")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "discord", group: .apps, name: "Discord",
                         detail: "Message and image cache",
                         symbol: "bubble.left.and.bubble.right",
                         paths: [inCaches("com.hnc.Discord")],
                         defaultOn: true, excluding: []))

        // System — what is left, so nothing is counted twice.
        //
        // "Other app caches" lists the CHILDREN of ~/Library/Caches, so the
        // exclusions have to be child names: for a nested path like
        // `Caches/Google/Chrome` that is `Google`, not `Chrome`. Comparing URLs
        // directly does not work here — an appended path carries a trailing
        // slash its parent does not — so this walks the path components instead.
        let cachesComponents = caches.standardizedFileURL.pathComponents
        let named = Set(out.flatMap(\.paths).compactMap { path -> String? in
            let components = path.standardizedFileURL.pathComponents
            guard components.count > cachesComponents.count,
                  Array(components.prefix(cachesComponents.count)) == cachesComponents
            else { return nil }
            return components[cachesComponents.count]
        })
        out.append(.init(id: "other.caches", group: .system, name: "Other app caches",
                         detail: "Everything in ~/Library/Caches not listed above",
                         symbol: "archivebox",
                         paths: [caches], defaultOn: true, excluding: named))
        out.append(.init(id: "temp", group: .system, name: "Temporary files",
                         detail: "Scratch files apps left behind",
                         symbol: "clock.arrow.circlepath",
                         paths: [FileManager.default.temporaryDirectory],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "logs", group: .system, name: "Logs",
                         detail: "App and diagnostic logs",
                         symbol: "doc.text",
                         paths: [library.appending(path: "Logs")],
                         defaultOn: true, excluding: []))
        out.append(.init(id: "trash", group: .system, name: "Empty the Trash",
                         detail: "Deletes for good — this one is not reversible",
                         symbol: "trash",
                         paths: [home.appending(path: ".Trash")],
                         defaultOn: false, excluding: []))
        return out
    }

    /// The catalog filtered to what actually exists on this Mac.
    static func present(in catalog: [CacheCategory]) -> [CacheCategory] {
        let fm = FileManager.default
        return catalog.filter { category in
            category.paths.contains { fm.fileExists(atPath: $0.path) }
        }
    }

    // MARK: - Measuring

    /// Bytes the category would free.
    static func size(of category: CacheCategory) -> UInt64 {
        removableItems(in: category).reduce(0) { $0 + size(ofItemAt: $1) }
    }

    /// Size every category concurrently. A task group rather than one queue hop:
    /// the slow categories (DerivedData, browser caches) then run alongside the
    /// dozen instant ones instead of behind them.
    static func measure(_ categories: [CacheCategory]) async -> [String: UInt64] {
        await withTaskGroup(of: (String, UInt64).self) { group in
            for category in categories {
                group.addTask { (category.id, size(of: category)) }
            }
            var out: [String: UInt64] = [:]
            for await (id, bytes) in group { out[id] = bytes }
            return out
        }
    }

    // MARK: - Cleaning

    /// Remove what the categories cover, newest-touched files spared. Returns
    /// the bytes actually freed — measured per item BEFORE removing it, so a
    /// protected file that fails to delete never inflates the total.
    ///
    /// Categories run one after another on purpose: the whole point is to reduce
    /// disk pressure, and a dozen concurrent recursive deletes fight for the
    /// same disk while making the progress report meaningless.
    static func clean(_ categories: [CacheCategory]) async -> UInt64 {
        var freed: UInt64 = 0
        for category in categories {
            if Task.isCancelled { break }
            freed += clean(category)
        }
        return freed
    }

    @discardableResult
    static func clean(_ category: CacheCategory) -> UInt64 {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-recentWindow)
        var freed: UInt64 = 0
        for item in removableItems(in: category) {
            if !category.isTrash, wasTouched(item, after: cutoff) { continue }
            let bytes = size(ofItemAt: item)
            do {
                try fm.removeItem(at: item)
                freed += bytes
            } catch {
                // Locked, owned by another user, or protected — leave it.
            }
        }
        return freed
    }

    // MARK: - Helpers

    /// A file written this recently is assumed to be in use.
    private static let recentWindow: TimeInterval = 600

    /// The children of a category's directories that may be removed.
    private static func removableItems(in category: CacheCategory) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for directory in category.paths {
            guard let children = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]) else { continue }
            out += children.filter { !category.excluding.contains($0.lastPathComponent) }
        }
        return out
    }

    /// True if the item — or anything nested inside it — was modified after
    /// `cutoff`. A folder's own timestamp does not move when a file deep inside
    /// it is written, so the whole tree has to be asked. Stops at the first hit,
    /// and includes hidden files: the lock and write-ahead-log files that mark a
    /// live cache are exactly the ones that start with a dot.
    static func wasTouched(_ url: URL, after cutoff: Date) -> Bool {
        let fm = FileManager.default
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        if let modified = try? url.resourceValues(forKeys: key).contentModificationDate,
           modified > cutoff { return true }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(key),
                                         options: [], errorHandler: { _, _ in true })
        else { return false }
        for case let file as URL in walker {
            if let modified = try? file.resourceValues(forKeys: key).contentModificationDate,
               modified > cutoff { return true }
        }
        return false
    }

    /// Bytes an item occupies, following its whole tree. Allocated size, not
    /// logical size, so the figure matches what the disk gets back.
    static func size(ofItemAt url: URL) -> UInt64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func allocated(_ url: URL) -> UInt64 {
            let values = try? url.resourceValues(forKeys: keys)
            return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return allocated(url) }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                         options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker { total += allocated(file) }
        return total
    }
}
