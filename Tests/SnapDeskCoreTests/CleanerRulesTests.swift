import Testing
import Foundation
@testable import SnapDeskCore

/// What the Clean tab offers, and what it refuses to offer.
struct CacheCatalogTests {
    private let home = URL(fileURLWithPath: "/Users/tester")

    @Test("Emptying the Trash is never ticked for you")
    func trashIsNeverDefault() throws {
        let trash = try #require(CacheCleaner.catalog(home: home).first { $0.id == "trash" })
        #expect(trash.defaultOn == false)
        #expect(trash.isTrash)
    }

    @Test("Every other category is ticked — they are all caches something rebuilds")
    func othersAreDefault() {
        let rest = CacheCleaner.catalog(home: home).filter { !$0.isTrash }
        let allTicked = rest.allSatisfy { $0.defaultOn }
        #expect(allTicked)
        #expect(rest.count > 5)
    }

    @Test("“Other app caches” skips the folders the named categories own")
    func otherCachesExcludesNamedBuckets() throws {
        let catalog = CacheCleaner.catalog(home: home)
        let other = try #require(catalog.first { $0.id == "other.caches" })
        // Chrome and Spotify have their own rows, so counting them again inside
        // the catch-all would double the total the header reports.
        #expect(other.excluding.contains("Google"))
        #expect(other.excluding.contains("com.spotify.client"))
        #expect(other.excluding.contains("Homebrew"))
        #expect(other.excluding.isEmpty == false)
    }

    @Test("Nothing outside the home directory it was given")
    func staysInsideTheGivenHome() {
        let paths = CacheCleaner.catalog(home: home).flatMap(\.paths).map(\.path)
        let outside = paths.filter { !$0.hasPrefix(home.path) }
        // The only exception is the system temporary directory, which is not
        // under home by definition.
        #expect(outside.allSatisfy { $0.contains("/T/") || $0.hasPrefix("/var") || $0.hasPrefix("/private") })
    }

    @Test("Ids are unique, or a size lands on the wrong row")
    func idsAreUnique() {
        let ids = CacheCleaner.catalog(home: home).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Only what exists on disk is offered")
    func presenceFiltering() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "snapdesk-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let real = CacheCategory(id: "real", group: .system, name: "Real", detail: "",
                                 symbol: "folder", paths: [temporary], defaultOn: true, excluding: [])
        let missing = CacheCategory(id: "missing", group: .system, name: "Missing", detail: "",
                                    symbol: "folder",
                                    paths: [temporary.appending(path: "nope")],
                                    defaultOn: true, excluding: [])
        let present = CacheCleaner.present(in: [real, missing])
        #expect(present.map(\.id) == ["real"])
    }
}

/// The in-use guard, which is the difference between clearing a cache and
/// corrupting the app that owns it.
struct CacheInUseTests {

    @Test("A file written moments ago counts as in use")
    func recentFileIsInUse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "snapdesk-inuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("live".utf8).write(to: directory.appending(path: "cache.db"))

        #expect(CacheCleaner.wasTouched(directory, after: Date().addingTimeInterval(-600)))
    }

    @Test("A file nested deep still marks the whole folder as in use")
    func nestedFileIsFound() throws {
        // A folder's own timestamp does not move when something inside it is
        // written, so only walking the tree catches this.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "snapdesk-nested-\(UUID().uuidString)")
        let deep = directory.appending(path: "a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("live".utf8).write(to: deep.appending(path: "wal.log"))

        #expect(CacheCleaner.wasTouched(directory, after: Date().addingTimeInterval(-600)))
    }

    @Test("Nothing recent means the folder is fair game")
    func oldFolderIsNotInUse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "snapdesk-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("stale".utf8).write(to: directory.appending(path: "old.bin"))

        // Cutoff in the future: everything on disk is older than it.
        #expect(CacheCleaner.wasTouched(directory, after: Date().addingTimeInterval(3600)) == false)
    }
}

/// Which folders the Developer tab claims, and where it will not walk.
struct JunkRulesTests {

    @Test("The build folders everybody has", arguments: [
        "node_modules", "DerivedData", ".build", "Pods", "__pycache__", ".venv", ".next",
    ])
    func knownNames(_ name: String) throws {
        let kind = try #require(JunkRules.kind(for: name))
        #expect(kind.safeToPreselect, "\(name) is unambiguous and should be pre-ticked")
    }

    @Test("Ambiguous names are found but never pre-ticked", arguments: ["build", "dist", "target"])
    func ambiguousNames(_ name: String) throws {
        let kind = try #require(JunkRules.kind(for: name))
        #expect(kind.safeToPreselect == false)
    }

    @Test("Matching is case-sensitive — Xcode's Build is not a bundler's build")
    func caseSensitivity() {
        #expect(JunkRules.kind(for: "Build") == nil)
        #expect(JunkRules.kind(for: "Node_Modules") == nil)
        #expect(JunkRules.kind(for: "build") != nil)
    }

    @Test("Source folders are not junk", arguments: ["src", "app", "Sources", "node_modules_backup"])
    func leavesSourceAlone(_ name: String) {
        #expect(JunkRules.kind(for: name) == nil)
    }

    @Test("The walk skips dotfile folders, so global caches are not mistaken for projects")
    func skipsDotDirectories() {
        // ~/.nvm and ~/.npm hold gigabytes that belong to the Clean tab, not
        // here — and descending into them would attribute them to "a project".
        #expect(JunkRules.shouldDescend(into: ".nvm") == false)
        #expect(JunkRules.shouldDescend(into: ".npm") == false)
        #expect(JunkRules.shouldDescend(into: ".git") == false)
    }

    @Test("A dot-named junk folder is still FOUND — the name rule is asked first")
    func dotNamedJunkStillMatches() {
        // `.build` and `.venv` would be unreachable if the dot rule ran first,
        // which is exactly the bug this pins.
        #expect(JunkRules.kind(for: ".build") != nil)
        #expect(JunkRules.kind(for: ".venv") != nil)
        #expect(JunkRules.shouldDescend(into: ".build") == false)
    }

    @Test("Library and Applications belong to the other tabs")
    func skipsSystemFolders() {
        #expect(JunkRules.shouldDescend(into: "Library") == false)
        #expect(JunkRules.shouldDescend(into: "Applications") == false)
        #expect(JunkRules.shouldDescend(into: "Dev"))
        #expect(JunkRules.shouldDescend(into: "Documents"))
    }
}
