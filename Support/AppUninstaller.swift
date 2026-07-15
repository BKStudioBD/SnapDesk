import AppKit

/// AppCleaner-style uninstall: force-quits the app if it's running, then
/// removes the app AND every leftover it owns (support files, caches, prefs,
/// launch agents, containers, logs …). Everything goes to the Trash — fully
/// reversible. (Direct build only; the sandboxed MAS build can't reach other
/// apps' files.)
enum AppUninstaller {
    struct App: Identifiable {
        let id: String        // bundle id (or path)
        let name: String
        let url: URL
        let icon: NSImage
        let bundleID: String
    }

    /// User-facing apps in /Applications and ~/Applications (not SnapDesk itself).
    static func installedApps() -> [App] {
        let fm = FileManager.default
        let dirs = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        let myBID = Bundle.main.bundleIdentifier ?? "com.snapdesk.app"
        var out: [App] = []
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                let bundle = Bundle(url: url)
                let bid = bundle?.bundleIdentifier ?? ""
                if bid == myBID { continue }
                out.append(App(id: bid.isEmpty ? url.path : bid,
                               // Strip ONLY the trailing ".app" (not every ".app"
                               // substring — "Foo.app.app" must not mangle).
                               name: (item as NSString).deletingPathExtension,
                               url: url,
                               icon: NSWorkspace.shared.icon(forFile: url.path),
                               bundleID: bid))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Every directory that can hold app leftovers. User Library subfolders
    /// plus the system-wide locations (those may fail to trash — skipped).
    private static func leftoverDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library")
        let userSubdirs = [
            "Application Support", "Caches", "Preferences", "Preferences/ByHost",
            "Logs", "Logs/DiagnosticReports", "Containers", "Group Containers",
            "Saved Application State", "HTTPStorages", "WebKit", "Cookies",
            "LaunchAgents", "Application Scripts", "Services", "PreferencePanes",
            "Internet Plug-Ins", "Autosave Information",
            "Application Support/CrashReporter", "Caches/CloudKit",
        ]
        var dirs = userSubdirs.map { lib.appendingPathComponent($0) }
        // System-wide (admin-owned; trash attempt may fail → silently skipped).
        dirs += ["/Library/LaunchAgents", "/Library/LaunchDaemons",
                 "/Library/Application Support", "/Library/Preferences",
                 "/Library/Caches"].map { URL(fileURLWithPath: $0) }
        return dirs
    }

    /// The app bundle + every leftover file it owns (by bundle id / name).
    /// Depth 1: item name contains the bundle id or the full app name.
    /// Depth 2: vendor-nested data (e.g. Application Support/Google/Chrome) —
    /// both the vendor folder AND the child must match a name/bundle-id token,
    /// so "Google Chrome" finds Google/Chrome without grabbing Google/DriveFS.
    static func relatedFiles(for app: App) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = [app.url]
        let bid = app.bundleID
        // Tokens: app-name words + bundle-id components, ≥4 chars ("for"/"com" noise out).
        let tokens = (app.name.components(separatedBy: CharacterSet.alphanumerics.inverted)
                      + bid.components(separatedBy: "."))
            .map { $0.lowercased() }.filter { $0.count >= 4 }
        func matchedToken(_ n: String) -> String? {
            let l = n.lowercased()
            return tokens.first { l.contains($0) }
        }
        // A filename that IS a reverse-DNS bundle id (com.foo.bar[.plist]) — the
        // name-only heuristic must NOT fire on these, or a 3rd-party app named
        // "Notes"/"Music" would grab Apple's com.apple.Notes/Music prefs.
        func looksLikeBundleID(_ n: String) -> Bool {
            let base = (n as NSString).deletingPathExtension
            let parts = base.components(separatedBy: ".")
            return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
        }
        // Bundle-id match as a WHOLE reverse-DNS prefix (delimited by "." or a
        // non-alnum), so removing "com.google.Chrome" does NOT also grab
        // "com.google.Chrome.canary" / helper-of-another-product files.
        func bidMatches(_ n: String) -> Bool {
            guard !bid.isEmpty else { return false }
            let l = n.lowercased(), b = bid.lowercased()
            guard let r = l.range(of: b) else { return false }
            let after = r.upperBound
            if after == l.endIndex { return true }
            let next = l[after]
            return !next.isLetter && !next.isNumber   // "." or "_" or "-" etc. — a boundary
        }
        // Word-boundary name match: "Snap" must NOT grab "SnapDesk" files, and a
        // short app name ("Arc") must not grab every "*arc*" folder. The name
        // must appear delimited by non-alphanumerics (or string edges) — and
        // NEVER against a reverse-DNS filename (that's the bundle-id's job).
        func nameMatches(_ n: String) -> Bool {
            guard app.name.count >= 4, !looksLikeBundleID(n) else { return false }
            let pattern = "(^|[^\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: app.name)
                + "($|[^\\p{L}\\p{N}])"
            return n.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        for dir in leftoverDirs() {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let deep = dir.lastPathComponent == "Application Support" || dir.lastPathComponent == "Caches"
            for item in items {
                let n = item.lastPathComponent
                let matches = bidMatches(n) || nameMatches(n)
                if matches {
                    results.append(item)
                } else if deep, let parentToken = matchedToken(n),
                          let kids = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                    // Vendor dir: the child must match a DIFFERENT token than the
                    // vendor folder itself, else "Google Chrome" would also grab
                    // Google/GoogleUpdater (shared with Drive/Earth).
                    for kid in kids {
                        if let kidToken = matchedToken(kid.lastPathComponent), kidToken != parentToken {
                            results.append(kid)
                        }
                    }
                }
            }
        }
        return results
    }

    static func size(of urls: [URL]) -> UInt64 {
        urls.reduce(0) { $0 + CacheCleaner.dirSizePublic($1) }
    }

    /// True if any instance of the app is currently running.
    static func isRunning(_ app: App) -> Bool {
        !runningInstances(app).isEmpty
    }

    private static func runningInstances(_ app: App) -> [NSRunningApplication] {
        if !app.bundleID.isEmpty {
            return NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        }
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL == app.url }
    }

    /// Force-quit every running instance (polite quit → 1.5s → force-kill; the
    /// app is being uninstalled, so force is what the user asked for), then
    /// call back on the main thread.
    static func forceQuit(_ app: App, completion: @escaping () -> Void) {
        let running = runningInstances(app)
        guard !running.isEmpty else { completion(); return }
        running.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            // Small beat so the process is fully gone before we trash the bundle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: completion)
        }
    }

    /// Move everything to Trash. Returns count trashed.
    @discardableResult
    static func uninstall(_ urls: [URL]) -> Int {
        var n = 0
        for u in urls where (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil { n += 1 }
        return n
    }
}
