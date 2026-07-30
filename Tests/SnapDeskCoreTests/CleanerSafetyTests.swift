import Testing
import Foundation
@testable import SnapDeskCore

/// The rules that decide what a destructive feature is allowed to touch.
///
/// Nothing here deletes: every test works on a scratch directory and checks the
/// DECISION — what the cleaner would remove, and what the scanner would tick —
/// which is where the damage would come from.
struct CleanerSafetyTests {

    /// Symlinks resolved: the temporary directory is `/var/…`, which is itself a
    /// link to `/private/var/…`, and the scanner reports the resolved path — so
    /// an unresolved root here fails a comparison the app gets right.
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapdesk-cleaner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeFile(_ url: URL, _ text: String = "x") throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - What a clean would remove

    @Test("A cache clean offers the CONTENTS, never the directory itself",
          .tags(.regression))
    func removesContentsNotTheDirectory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = root.appending(path: "Caches")
        try makeDirectory(caches.appending(path: "com.example.app"))
        try makeFile(caches.appending(path: "loose.bin"))

        let category = CacheCategory(id: "test", group: .system, name: "Test",
                                     detail: "", symbol: "folder", paths: [caches],
                                     defaultOn: true, excluding: [])
        let items = CacheCleaner.removableItems(in: category)

        // If this ever returned the path itself, cleaning would take
        // ~/Library/Caches and ~/.Trash outright.
        #expect(items.contains(caches) == false)
        #expect(Set(items.map(\.lastPathComponent)) == ["com.example.app", "loose.bin"])
    }

    @Test("An excluded name is left alone even though it sits in the same folder")
    func honoursExclusions() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let caches = root.appending(path: "Caches")
        try makeDirectory(caches.appending(path: "Homebrew"))
        try makeDirectory(caches.appending(path: "com.example.app"))

        let category = CacheCategory(id: "other", group: .system, name: "Other",
                                     detail: "", symbol: "folder", paths: [caches],
                                     defaultOn: true, excluding: ["Homebrew"])
        let names = Set(CacheCleaner.removableItems(in: category).map(\.lastPathComponent))
        #expect(names.contains("Homebrew") == false)
        #expect(names.contains("com.example.app"))
    }

    @Test("A cache belonging to a running app is skipped, whatever its timestamp says")
    func skipsRunningAppsCaches() {
        // Modification time can't see an open file descriptor: a Chromium app
        // holds its cache open for hours without writing to it.
        let running: Set<String> = ["com.tinyspeck.slackmacgap"]
        let slack = URL(fileURLWithPath: "/tmp/Caches/com.tinyspeck.slackmacgap")
        let other = URL(fileURLWithPath: "/tmp/Caches/com.example.notrunning")
        #expect(CacheCleaner.isOwnedByRunningApp(slack, runningIDs: running))
        #expect(CacheCleaner.isOwnedByRunningApp(other, runningIDs: running) == false)
    }

    // MARK: - What the build-folder scan would tick

    @Test("A match stops the descent — the node_modules inside a node_modules is not its own row",
          .tags(.regression))
    func stopsAtTheFirstMatch() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appending(path: "project")
        let outer = project.appending(path: "node_modules")
        try makeDirectory(outer.appending(path: "left-pad/node_modules"))

        let found = ProjectJunkScanner.scan(roots: [root], maxDepth: 6)
        #expect(found.count == 1)
        // Suffix, not the absolute path: /var/folders is a symlink to
        // /private/var/folders and the walk reports the resolved side.
        #expect(found.first?.url.path.hasSuffix("project/node_modules") == true)
    }

    @Test("A symlink is never followed, so a link can't drag a folder outside the tree in",
          .tags(.regression))
    func ignoresSymlinks() throws {
        let root = try scratch()
        let outside = try scratch()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try makeDirectory(outside.appending(path: "node_modules"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"),
                                                   withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "node_modules"),
                                                   withDestinationURL: outside.appending(path: "node_modules"))

        #expect(ProjectJunkScanner.scan(roots: [root], maxDepth: 6).isEmpty)
    }

    @Test("A dot-directory straight under the root is a tool's home — listed, never pre-ticked",
          .tags(.regression))
    func neverPreTicksAGlobalToolHome() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // ~/.gradle holds gradle.properties: signing passwords and registry
        // tokens, kept there precisely because they are not in the repo.
        try makeDirectory(root.appending(path: ".gradle"))
        try makeDirectory(root.appending(path: "project/.gradle"))

        let found = ProjectJunkScanner.scan(roots: [root], maxDepth: 6)
        let home = try #require(found.first { $0.url.path.contains("/project/") == false })
        let inProject = try #require(found.first { $0.url.path.contains("/project/") })

        #expect(home.isGlobalHome)
        #expect(home.safeToPreselect == false)      // found, listed, not ticked
        #expect(inProject.isGlobalHome == false)
        #expect(inProject.safeToPreselect)
    }

    @Test("An ambiguous name is found but never pre-ticked", arguments: ["build", "dist", "target"])
    func neverPreTicksAmbiguousNames(_ name: String) throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeDirectory(root.appending(path: "project/\(name)"))

        let found = try #require(ProjectJunkScanner.scan(roots: [root], maxDepth: 6).first)
        #expect(found.safeToPreselect == false)
    }
}
