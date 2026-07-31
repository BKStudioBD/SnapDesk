import AppKit

/// Whether a leftover file belongs to the app being removed.
///
/// Every rule here exists because a looser version of it once matched something
/// it shouldn't, so they are pure functions with no file system behind them and
/// each one is pinned by a test.
enum UninstallMatch {

    /// A filename that IS a reverse-DNS identifier, like `com.apple.Notes.plist`.
    /// The name rule must never fire on these: a third-party app called "Notes"
    /// would otherwise claim Apple's preferences.
    static func looksLikeBundleID(_ name: String) -> Bool {
        // The whole name, extension included: stripping it first would turn
        // `org.mozilla.firefox` into a two-part `org.mozilla` and stop treating
        // it as an identifier at all. A space is the giveaway that it isn't one
        //: "Slack Helper.app.plist" has three dotted parts and is still a
        // plain filename.
        guard !name.contains(" ") else { return false }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
    }

    /// The bundle id as a WHOLE reverse-DNS prefix. Removing `com.google.Chrome`
    /// must not also take `com.google.Chrome.canary`, so the match has to end at
    /// a boundary rather than anywhere inside a longer identifier.
    static func matchesBundleID(_ name: String, bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        let haystack = name.lowercased(), needle = bundleID.lowercased()
        guard let range = haystack.range(of: needle) else { return false }
        let rest = haystack[range.upperBound...]
        guard let next = rest.first else { return true }
        // A DOT is not a boundary. `com.google.Chrome.canary` is Chrome Canary's
        // own identifier: a separate product, still installed, whose prefs,
        // cookies and saved state were arriving here pre-ticked. Past the id only
        // a file-type suffix may follow; a word that isn't one is more identifier.
        guard next == "." else { return !next.isLetter && !next.isNumber }
        return rest.dropFirst()
            .split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy(isFileSuffix)
    }

    /// What macOS appends to a bundle id when it names a file after it. Kept
    /// short on purpose: a missed leftover costs kilobytes, and claiming another
    /// product's folder costs the logins inside it.
    private static let fileSuffixes: Set<String> = [
        "plist", "lockfile", "savedstate", "binarycookies", "sfl2", "sfl3", "log",
    ]

    /// A dotted piece that ends a filename rather than continuing an identifier.
    /// The long hex-and-dash form is a ByHost preference's host id
    /// (`com.foo.App.<UUID>.plist`), which is still the app's own file.
    private static func isFileSuffix(_ part: Substring) -> Bool {
        if fileSuffixes.contains(String(part)) { return true }
        return part.count >= 32 && part.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// The app's name, delimited by non-alphanumerics. "Snap" must not claim
    /// "SnapDesk", and a three-letter name is too weak a signal to use at all.
    static func matchesName(_ name: String, appName: String) -> Bool {
        guard appName.count >= 4, !looksLikeBundleID(name) else { return false }
        let pattern = "(^|[^\\p{L}\\p{N}])"
            + NSRegularExpression.escapedPattern(for: appName)
            + "($|[^\\p{L}\\p{N}])"
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Words worth searching for: the app's name and the parts of its bundle id.
    /// Short fragments are dropped: "com", "app" and "for" match everything.
    static func tokens(appName: String, bundleID: String) -> [String] {
        let fromName = appName.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let fromID = bundleID.components(separatedBy: ".")
        return (fromName + fromID).map { $0.lowercased() }.filter { $0.count >= 4 }
    }

    static func matchedToken(_ name: String, tokens: [String]) -> String? {
        let lowered = name.lowercased()
        return tokens.first { lowered.contains($0) }
    }

    /// Inside a vendor folder (`Application Support/Google/…`), a child counts
    /// only if it matches a DIFFERENT token than the vendor folder did.
    /// Otherwise removing Chrome would also take `Google/GoogleUpdater`, which
    /// Drive and Earth share.
    static func vendorChildMatches(vendor: String, child: String, tokens: [String]) -> Bool {
        guard let vendorToken = matchedToken(vendor, tokens: tokens) else { return false }
        guard let childToken = matchedToken(child, tokens: tokens) else { return false }
        guard childToken != vendorToken else { return false }
        // A different token is not enough: "Chrome Canary" and "Chrome Beta"
        // both match on `chrome` while being SEPARATE products, still installed,
        // whose profiles hold their own bookmarks and logins. Every word of the
        // folder has to belong to the app being removed: an extra word means
        // an extra product. This under-removes the odd genuine leftover
        // ("Slack Helper"), which is the side to err on.
        let words = child.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
        return words.allSatisfy { word in tokens.contains { word.contains($0) } }
    }
}

/// Removes an app and everything it left around the system: support files,
/// caches, preferences, launch agents, containers, logs.
///
/// Everything is moved to the Trash, so an uninstall stays reversible until the
/// person empties it themselves. The sandboxed App Store build cannot reach
/// another app's files, which is why this is a direct-build feature.
enum AppUninstaller {

    struct App: Identifiable, Hashable {
        let id: String
        let name: String
        let url: URL
        let bundleID: String
        /// Fetched ONCE during the scan. As a computed property this asked
        /// NSWorkspace for the icon on every row redraw: a disk-backed lookup
        /// inside a list that redraws on every keystroke in the search field.
        let icon: NSImage

        // Identity is the bundle id (or path). Synthesised conformance would
        // drag NSImage's object identity into ==, so two reads of the same app
        // could compare unequal.
        static func == (lhs: App, rhs: App) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// A single removable thing: the bundle, or one leftover.
    struct Leftover: Identifiable, Hashable {
        let url: URL
        let size: UInt64
        /// The bundle itself is always removed; leftovers under `/Library` are
        /// system-wide and are listed unticked, since they may belong to another
        /// user account on the same Mac.
        let preselected: Bool
        var id: String { url.path }
        var name: String { url.lastPathComponent }
        var location: String {
            url.deletingLastPathComponent().path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        }
    }

    // MARK: - Listing

    static func installedApps() -> [App] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let directories = [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications")]
        let ownID = Bundle.main.bundleIdentifier ?? "com.snapdesk.app"
        var out: [App] = []
        for directory in directories {
            guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            else { continue }
            for child in children where child.pathExtension == "app" {
                let bundleID = Bundle(url: child)?.bundleIdentifier ?? ""
                guard bundleID != ownID else { continue }
                out.append(App(id: bundleID.isEmpty ? child.path : bundleID,
                               name: child.deletingPathExtension().lastPathComponent,
                               url: child, bundleID: bundleID,
                               icon: NSWorkspace.shared.icon(forFile: child.path)))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Off the main actor: reading every bundle's Info.plist and icon is disk
    /// work, and it used to run while the window was drawing its first frame.
    /// On a queue, not a detached task. The reads block, and blocking a
    /// cooperative-pool thread is what `BackgroundWork` exists to avoid.
    static func installedAppsInBackground() async -> [App] {
        await BackgroundWork.run { installedApps() }
    }

    /// Where leftovers hide. The `/Library` entries are admin-owned and a trash
    /// attempt there may simply fail. That is reported honestly rather than
    /// hidden.
    private static func leftoverDirectories() -> (user: [URL], system: [URL]) {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        let user = [
            "Application Support", "Application Support/CrashReporter", "Caches",
            "Caches/CloudKit", "Preferences", "Preferences/ByHost", "Logs",
            "Logs/DiagnosticReports", "Containers", "Group Containers",
            "Saved Application State", "HTTPStorages", "WebKit", "Cookies",
            "LaunchAgents", "Application Scripts", "Services", "PreferencePanes",
            "Internet Plug-Ins", "Autosave Information",
        ].map { library.appending(path: $0) }
        let system = ["/Library/LaunchAgents", "/Library/LaunchDaemons",
                      "/Library/Application Support", "/Library/Preferences",
                      "/Library/Caches"].map { URL(fileURLWithPath: $0) }
        return (user, system)
    }

    /// The bundle plus every leftover it owns.
    static func leftovers(for app: App) -> [Leftover] {
        let fm = FileManager.default
        let tokens = UninstallMatch.tokens(appName: app.name, bundleID: app.bundleID)
        let (userDirectories, systemDirectories) = leftoverDirectories()
        var out = [Leftover(url: app.url, size: CacheCleaner.size(ofItemAt: app.url), preselected: true)]
        var seen: Set<String> = [app.url.path]

        func scan(_ directory: URL, preselected: Bool) {
            guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            else { return }
            // Vendor folders only nest under these two; elsewhere a one-level
            // match is the whole story.
            let last = directory.lastPathComponent
            let nested = last == "Application Support" || last == "Caches"
            for child in children {
                let name = child.lastPathComponent
                // The word-boundary name rule is right for FILES: "Slack
                // Helper.plist" belongs to Slack. It is wrong for DIRECTORIES:
                // "Notion Calendar" is a separate app that is still installed,
                // and its folder is that app's whole account state. A directory
                // has to BE the app's own folder.
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                let nameMatches = isDirectory
                    ? name.caseInsensitiveCompare(app.name) == .orderedSame
                    : UninstallMatch.matchesName(name, appName: app.name)
                if UninstallMatch.matchesBundleID(name, bundleID: app.bundleID) || nameMatches {
                    guard seen.insert(child.path).inserted else { continue }
                    out.append(Leftover(url: child, size: CacheCleaner.size(ofItemAt: child),
                                        preselected: preselected))
                } else if nested, let grandchildren = try? fm.contentsOfDirectory(
                    at: child, includingPropertiesForKeys: nil) {
                    for grandchild in grandchildren
                    where UninstallMatch.vendorChildMatches(vendor: name,
                                                            child: grandchild.lastPathComponent,
                                                            tokens: tokens) {
                        guard seen.insert(grandchild.path).inserted else { continue }
                        out.append(Leftover(url: grandchild,
                                            size: CacheCleaner.size(ofItemAt: grandchild),
                                            preselected: preselected))
                    }
                }
            }
        }

        for directory in userDirectories { scan(directory, preselected: true) }
        for directory in systemDirectories { scan(directory, preselected: false) }
        return out
    }

    /// Sizing two dozen Library folders blocks for long enough to matter, so it
    /// happens on a dispatch queue rather than the cooperative pool.
    static func leftoversInBackground(for app: App) async -> [Leftover] {
        await BackgroundWork.run { leftovers(for: app) }
    }

    // MARK: - Removing

    static func isRunning(_ app: App) -> Bool { !runningInstances(app).isEmpty }

    private static func runningInstances(_ app: App) -> [NSRunningApplication] {
        guard app.bundleID.isEmpty else {
            return NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        }
        return NSWorkspace.shared.runningApplications.filter { $0.bundleURL == app.url }
    }

    /// Ask the app to quit, then insist. A running bundle cannot be trashed, and
    /// the person has already said they want this app gone. But the polite
    /// request comes first, so an app with unsaved work gets its own chance to
    /// save.
    /// Returns whether the app is now gone. It is never killed: `terminate()`
    /// is what puts the app's own "Save changes?" sheet on screen, and a
    /// `forceTerminate()` a second and a half later lands ON that sheet and
    /// destroys the work it was asking about. If the person doesn't finish
    /// quitting it, the caller says so instead of removing anything.
    @MainActor
    static func quit(_ app: App) async -> Bool {
        let running = runningInstances(app)
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        for _ in 0..<40 {                                  // up to 20 seconds
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return running.allSatisfy(\.isTerminated)
    }

    /// Move everything to the Trash. Returns what went and what refused, so the
    /// window can say "moved 12 · 2 couldn't be removed" instead of claiming a
    /// clean sweep it didn't make.
    @discardableResult
    static func trash(_ leftovers: [Leftover]) -> (moved: Int, failed: Int, freed: UInt64) {
        var moved = 0, failed = 0, freed: UInt64 = 0
        for leftover in leftovers {
            do {
                try FileManager.default.trashItem(at: leftover.url, resultingItemURL: nil)
                moved += 1
                freed += leftover.size
            } catch {
                failed += 1
            }
        }
        return (moved, failed, freed)
    }

    /// Off the main actor: trashing an app bundle plus its containers is a lot
    /// of file moves, and the window froze for the whole sweep.
    static func trashInBackground(_ leftovers: [Leftover]) async -> (moved: Int, failed: Int, freed: UInt64) {
        await BackgroundWork.run { trash(leftovers) }
    }
}
