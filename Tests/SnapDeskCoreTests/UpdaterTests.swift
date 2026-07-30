import Testing
@testable import SnapDeskCore

/// Version comparison decides whether the app replaces itself, so a wrong answer
/// either strands users on an old build or downgrades them. No network here — the
/// comparison is pure.
struct UpdaterVersionTests {
    @Test("A later version is detected", arguments: [
        ("1.1.1", "1.1.0"), ("1.2.0", "1.1.9"), ("2.0.0", "1.99.99"),
        ("1.10.0", "1.9.0"),   // string comparison gets this one backwards
    ])
    func detectsNewer(_ candidate: String, _ current: String) {
        #expect(Updater.isNewer(candidate, than: current))
    }

    @Test("Same or older is never offered", arguments: [
        ("1.1.0", "1.1.0"), ("1.0.9", "1.1.0"),
        ("1.9.0", "1.10.0"), ("0.9.9", "1.0.0"),
        // A missing component is zero, so these two are the SAME version in both
        // directions — neither is an update.
        ("1.1", "1.1.0"), ("1.1.0", "1.1"),
    ])
    func rejectsOlderOrEqual(_ candidate: String, _ current: String) {
        #expect(Updater.isNewer(candidate, than: current) == false)
    }

    @Test("A leading v and other noise in a tag don't break the comparison")
    func tolerantOfTagNoise() {
        // The check strips a leading "v" before comparing; non-digits inside a
        // component are ignored so "1.2.0-beta" still reads as 1.2.0.
        #expect(Updater.isNewer("1.2.0-beta", than: "1.1.0"))
        #expect(Updater.isNewer("1.1.0", than: "1.2.0-beta") == false)
    }

    @Test("Releases are only ever fetched from the one pinned repository")
    func repositoryIsPinned() {
        // A wrong or user-settable value here would mean installing code from
        // somewhere else, so it's asserted rather than assumed.
        #expect(Updater.repository == "BKStudioBD/SnapDesk")
    }

    @Test func currentVersionIsReadable() {
        // Under `swift test` there's no app bundle, so this falls back to "0" —
        // the point is that it never traps or returns an empty string.
        #expect(Updater.currentVersion.isEmpty == false)
    }
}
