import Foundation

/// Sandbox folder access. Under the App Sandbox a saved folder *path* is not
/// enough — access must be re-earned via a security-scoped bookmark captured
/// when the user picked the folder in an NSOpenPanel. Harmless (extra bookmark)
/// in non-sandboxed builds, so the same code ships in both variants.
enum FolderAccess {
    /// Persist a security-scoped bookmark for a user-picked folder.
    static func remember(_ url: URL, key: String) {
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "bookmark." + key)
        }
    }

    /// Resolve the bookmark and start security-scoped access (held for the app's
    /// lifetime — we only ever hold two: recordings + screenshots folders).
    @discardableResult
    static func restore(key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "bookmark." + key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        // Refresh AFTER access starts — creating a security-scoped bookmark
        // without active access fails silently (stale bookmarks never healed).
        if stale { remember(url, key: key) }
        return url
    }
}
