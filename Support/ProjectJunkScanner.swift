import Foundation

/// A kind of build leftover the Developer tab knows by name.
struct JunkKind: Sendable, Hashable {
    let directoryName: String
    let label: String
    let symbol: String
    /// Ticked on sight. False for the ambiguous names — a folder called `build`
    /// or `dist` is a build product most of the time and somebody's source the
    /// rest of the time, and the cleaner never gambles with that difference.
    let safeToPreselect: Bool
}

/// One found folder.
struct JunkItem: Identifiable, Sendable, Hashable {
    let url: URL
    let kind: JunkKind
    let size: UInt64
    var id: String { url.path }
    /// "~/Dev/app" — the project the folder belongs to, which is what makes a
    /// row recognisable; the folder's own name is the same for hundreds of rows.
    var project: String {
        url.deletingLastPathComponent().path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

/// Which directory names count as build junk, and where the walk may go.
/// Pure rules, kept apart from the file system so they can be tested directly.
enum JunkRules {
    static let known: [JunkKind] = [
        .init(directoryName: "node_modules", label: "Node modules",
              symbol: "cube.box", safeToPreselect: true),
        .init(directoryName: "DerivedData", label: "Xcode DerivedData",
              symbol: "hammer", safeToPreselect: true),
        .init(directoryName: ".build", label: "SwiftPM build",
              symbol: "swift", safeToPreselect: true),
        .init(directoryName: "Pods", label: "CocoaPods",
              symbol: "shippingbox", safeToPreselect: true),
        .init(directoryName: "__pycache__", label: "Python bytecode",
              symbol: "chevron.left.forwardslash.chevron.right", safeToPreselect: true),
        .init(directoryName: ".venv", label: "Python virtualenv",
              symbol: "chevron.left.forwardslash.chevron.right", safeToPreselect: true),
        .init(directoryName: ".next", label: "Next.js build",
              symbol: "arrow.triangle.2.circlepath", safeToPreselect: true),
        .init(directoryName: ".nuxt", label: "Nuxt build",
              symbol: "arrow.triangle.2.circlepath", safeToPreselect: true),
        .init(directoryName: ".gradle", label: "Gradle cache",
              symbol: "shippingbox", safeToPreselect: true),
        // Ambiguous on purpose — found and listed, never pre-ticked.
        .init(directoryName: "build", label: "build folder",
              symbol: "questionmark.folder", safeToPreselect: false),
        .init(directoryName: "dist", label: "dist folder",
              symbol: "questionmark.folder", safeToPreselect: false),
        .init(directoryName: "target", label: "target folder",
              symbol: "questionmark.folder", safeToPreselect: false),
    ]

    private static let byName = Dictionary(uniqueKeysWithValues: known.map { ($0.directoryName, $0) })

    /// The junk kind a directory name is, if any. Case-sensitive: `Build` in an
    /// Xcode project is not the `build` a bundler writes.
    static func kind(for directoryName: String) -> JunkKind? { byName[directoryName] }

    /// Directories the walk refuses to enter.
    ///
    /// Every dotfile directory is skipped, which is what keeps a global cache
    /// like `~/.nvm` or `~/.npm` out of a scan that is supposed to be about
    /// projects — the dot-named junk kinds are matched BEFORE this is asked, so
    /// `.build` and `.venv` are still found. `Library` and `Applications` belong
    /// to the Clean and Uninstall tabs, and following symlinks turns a walk into
    /// a loop.
    static func shouldDescend(into name: String) -> Bool {
        if name.hasPrefix(".") { return false }
        return name != "Library" && name != "Applications"
    }
}

/// Walks the home directory for build folders that can be rebuilt from source.
///
/// An explicit stack rather than `FileManager.enumerator`: a match must stop the
/// descent right there. Walking INTO a `node_modules` to find the hundreds
/// nested inside it is how a scan turns into a minute of disk churn for rows
/// that are all the same answer.
enum ProjectJunkScanner {

    /// Depth measured from each root. Seven is deep enough for
    /// `~/Dev/company/app/packages/web/node_modules` and shallow enough that a
    /// stray deep tree cannot run away with the scan.
    static let maxDepth = 7

    static func scan(roots: [URL] = defaultRoots(), maxDepth: Int = maxDepth) -> [JunkItem] {
        let fm = FileManager.default
        var found: [JunkItem] = []
        var seen: Set<String> = []
        var stack: [(url: URL, depth: Int)] = roots.map { ($0, 0) }

        while let (directory, depth) = stack.popLast() {
            guard depth <= maxDepth else { continue }
            guard let children = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsPackageDescendants]) else { continue }

            for child in children {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let name = child.lastPathComponent

                if let kind = JunkRules.kind(for: name) {
                    guard seen.insert(child.path).inserted else { continue }
                    found.append(JunkItem(url: child, kind: kind,
                                          size: CacheCleaner.size(ofItemAt: child)))
                    continue                      // matched — do not descend into it
                }
                if JunkRules.shouldDescend(into: name) {
                    stack.append((child, depth + 1))
                }
            }
        }
        return found.sorted { $0.size > $1.size }
    }

    /// Off the main actor, so a scan of a big home directory never holds up the
    /// window it is drawing into. It runs on a dispatch queue rather than a
    /// detached task because the walk BLOCKS — see `BackgroundWork`.
    static func scanInBackground() async -> [JunkItem] {
        await BackgroundWork.run { scan() }
    }

    /// Where a project usually lives. The home directory itself is included, so
    /// a project sitting loose in `~` is still found.
    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home]
    }

    /// Move the given folders to the Trash — reversible, like every other
    /// destructive action in SnapDesk. Returns the bytes recovered.
    @discardableResult
    static func trash(_ items: [JunkItem]) -> UInt64 {
        var freed: UInt64 = 0
        for item in items {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                freed += item.size
            } catch {
                // Already gone, or in use — skip it.
            }
        }
        return freed
    }

    /// Same work, off the main actor: a `node_modules` tree is tens of thousands
    /// of files, and moving it froze the window until it finished.
    static func trashInBackground(_ items: [JunkItem]) async -> UInt64 {
        await BackgroundWork.run { trash(items) }
    }
}
