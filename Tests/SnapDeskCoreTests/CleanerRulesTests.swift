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

    @Test("Every other category is ticked. They are all caches something rebuilds")
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

    @Test("Developer tooling is not offered, and not swept up instead")
    func developerCachesAreLeftAlone() throws {
        let catalog = CacheCleaner.catalog(home: home)
        // Dropping the rows is only half of it. "Other app caches" lists every
        // child of ~/Library/Caches, so a folder that loses its own row lands
        // there by default: still deleted, now without its name on screen.
        let other = try #require(catalog.first { $0.id == "other.caches" })
        for folder in CacheCleaner.developerCaches {
            #expect(other.excluding.contains(folder), "\(folder) would be swept by the catch-all")
        }
        let developerIDs = ["xcode.derived", "xcode.devicesupport", "simulator.caches",
                            "swiftpm", "node", "homebrew", "pip"]
        #expect(catalog.contains { developerIDs.contains($0.id) } == false)
        // Nothing points at Xcode's build products or a package manager's store.
        let paths = catalog.flatMap(\.paths).map(\.path)
        #expect(paths.contains { $0.contains("DerivedData") || $0.contains(".npm") } == false)
    }

    @Test("Nothing outside the home directory it was given")
    func staysInsideTheGivenHome() {
        let paths = CacheCleaner.catalog(home: home).flatMap(\.paths).map(\.path)
        let outside = paths.filter { !$0.hasPrefix(home.path) }
        // The only exception is the system temporary directory, which is not
        // under home by definition.
        #expect(outside.allSatisfy { $0.contains("/T/") || $0.hasPrefix("/var") || $0.hasPrefix("/private") })
    }

    @Test("Every per-app row names the app it belongs to",
          arguments: ["chrome", "safari", "firefox", "arc", "spotify", "slack", "discord"])
    func perAppRowsNameTheirOwner(_ id: String) throws {
        // Without it the running-app guard has nothing to compare: the row's
        // items are that app's `Cache` and `GPUCache` folders, and no name there
        // says whose they are.
        let row = try #require(CacheCleaner.catalog(home: home).first { $0.id == id })
        #expect(row.owners.isEmpty == false)
    }

    @Test("The owner is matched however the catalog spelled it")
    func ownerMatchIsCaseInsensitive() throws {
        // Running bundle ids arrive lowercased; the catalog writes them the way
        // the app does: `com.google.Chrome`.
        let chrome = try #require(CacheCleaner.catalog(home: home).first { $0.id == "chrome" })
        #expect(CacheCleaner.isOwnedByRunningApp(chrome, runningIDs: ["com.google.chrome"]))
        #expect(CacheCleaner.isOwnedByRunningApp(chrome, runningIDs: ["com.apple.safari"]) == false)
    }

    @Test("A row that isn't about one app has no owner to check")
    func catchAllRowsHaveNoOwner() throws {
        let catalog = CacheCleaner.catalog(home: home)
        for id in ["other.caches", "temp", "logs", "trash"] {
            let row = try #require(catalog.first { $0.id == id })
            #expect(row.owners.isEmpty)
        }
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

