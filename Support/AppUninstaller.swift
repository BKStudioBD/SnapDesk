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
        // — "Slack Helper.app.plist" has three dotted parts and is still a
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
        guard range.upperBound < haystack.endIndex else { return true }
        let next = haystack[range.upperBound]
        return !next.isLetter && !next.isNumber
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
    /// Short fragments are dropped — "com", "app" and "for" match everything.
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
        return childToken != vendorToken
    }
}

/// Removes an app and everything it left around the system — support files,
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
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
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
                               url: child, bundleID: bundleID))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Where leftovers hide. The `/Library` entries are admin-owned and a trash
    /// attempt there may simply fail — that is reported honestly rather than
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
                if UninstallMatch.matchesBundleID(name, bundleID: app.bundleID)
                    || UninstallMatch.matchesName(name, appName: app.name) {
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
    /// the person has already said they want this app gone — but the polite
    /// request comes first, so an app with unsaved work gets its own chance to
    /// save.
    @MainActor
    static func quit(_ app: App) async {
        let running = runningInstances(app)
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        try? await Task.sleep(for: .milliseconds(1500))
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        try? await Task.sleep(for: .milliseconds(500))
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
}
