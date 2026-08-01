import Testing
import Foundation
@testable import SnapDeskCore

/// The rules that decide what a destructive feature is allowed to touch.
///
/// Nothing here deletes: every test works on a scratch directory and checks the
/// DECISION of what the cleaner would remove, which is where the damage would
/// come from.
struct CleanerSafetyTests {

    /// Symlinks resolved: the temporary directory is `/var/…`, which is itself a
    /// link to `/private/var/…`, and the scanner reports the resolved path. So
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

    @Test("A per-app row is skipped whole while its app runs", .tags(.regression))
    func skipsARunningAppsWholeRow() {
        // The bug this pins: the row lists what is INSIDE Slack's cache folder,
        // so the per-item guard is asked about `Cache` and `GPUCache`: names
        // that match no bundle id ever. And a running Slack lost the cache it
        // was holding open.
        let running: Set<String> = ["com.tinyspeck.slackmacgap"]
        let folder = URL(fileURLWithPath: "/tmp/Caches/com.tinyspeck.slackmacgap")
        let slack = CacheCategory(id: "slack", group: .apps, name: "Slack", detail: "",
                                  symbol: "message", paths: [folder], defaultOn: true,
                                  excluding: [], owners: ["com.tinyspeck.slackmacgap"])
        #expect(CacheCleaner.isOwnedByRunningApp(folder.appending(path: "GPUCache"),
                                                 runningIDs: running) == false)
        #expect(CacheCleaner.isOwnedByRunningApp(slack, runningIDs: running))
        #expect(CacheCleaner.isOwnedByRunningApp(slack, runningIDs: []) == false)
    }
}
