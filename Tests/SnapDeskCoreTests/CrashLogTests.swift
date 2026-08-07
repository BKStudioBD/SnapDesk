import Testing
import Foundation
@testable import SnapDeskCore

/// Which crash reports belong to SnapDesk, and which ones get to stay.
///
/// The reports that went unnoticed for three days were sitting in
/// `DiagnosticReports/Retired`, so "newest" has to be decided across both
/// folders and by the timestamp in the name rather than by which folder was
/// read first.
struct CrashLogTests {

    private let mine = [
        "SnapDesk-2026-08-07-071741.ips",
        "SnapDesk-2026-08-05-081822.ips",
        "SnapDesk-2026-08-06-204817.ips",
    ]

    @Test("Only this app's reports, newest first")
    func picksOwnReportsInOrder() {
        let names = mine + [
            "Safari-2026-08-07-090000.ips",          // another app
            "SnapDeskHelper-2026-08-07-090000.ips",  // another process, prefix-adjacent
            "SFA-ckks.json_2026-08-06-131420.diag",  // not a crash report
            "SnapDesk-2026-08-07-071741.ips.tmp",    // half-written
        ]
        let found = CrashLog.ownReports(in: names)
        #expect(found == ["SnapDesk-2026-08-07-071741.ips",
                          "SnapDesk-2026-08-06-204817.ips",
                          "SnapDesk-2026-08-05-081822.ips"])
    }

    @Test("A report for a different process is never adopted")
    func ignoresOtherProcesses() {
        // "SnapDeskHelper" starts with "SnapDesk", which is why the rule matches
        // on "SnapDesk-" and not on the bare name.
        #expect(CrashLog.ownReports(in: ["SnapDeskHelper-2026-08-07-090000.ips"]).isEmpty)
    }

    @Test("Nothing to keep, nothing to delete")
    func emptyIsHandled() {
        #expect(CrashLog.ownReports(in: []).isEmpty)
        #expect(CrashLog.overflow([]).isEmpty)
    }

    @Test("Under the cap, every report stays")
    func keepsEverythingUnderTheCap() {
        #expect(CrashLog.overflow(mine, keeping: 10).isEmpty)
    }

    @Test("Over the cap, the OLDEST go")
    func dropsOldestFirst() {
        let doomed = CrashLog.overflow(mine, keeping: 1)
        // The newest is the one worth keeping: it is the crash the user was
        // just told about.
        #expect(doomed == ["SnapDesk-2026-08-06-204817.ips",
                           "SnapDesk-2026-08-05-081822.ips"])
    }

    @Test("A report older than the run that died is NOT that run's crash")
    func ignoresReportsFromEarlierRuns() {
        let launch = Date(timeIntervalSince1970: 1_000_000)
        // ./build.sh kills the running copy, which leaves the marker behind and
        // writes no report. Adopting a stale one here would announce a crash
        // that did not happen, every single rebuild.
        let stale = [("SnapDesk-2026-08-05-081822.ips", launch.addingTimeInterval(-3600))]
        #expect(CrashLog.report(from: stale, since: launch) == nil)
    }

    @Test("A report written after the run started is the one adopted")
    func adoptsTheReportFromThatRun() {
        let launch = Date(timeIntervalSince1970: 1_000_000)
        let candidates = [
            ("SnapDesk-2026-08-05-081822.ips", launch.addingTimeInterval(-3600)),  // earlier run
            ("SnapDesk-2026-08-07-071741.ips", launch.addingTimeInterval(120)),    // this one
            ("SnapDesk-2026-08-06-204817.ips", launch.addingTimeInterval(-60)),    // earlier run
        ]
        #expect(CrashLog.report(from: candidates, since: launch) == "SnapDesk-2026-08-07-071741.ips")
    }

    @Test("With several from the same run, the newest name wins")
    func newestOfTheRunWins() {
        let launch = Date(timeIntervalSince1970: 1_000_000)
        let candidates = [
            ("SnapDesk-2026-08-07-071741.ips", launch.addingTimeInterval(60)),
            ("SnapDesk-2026-08-07-090000.ips", launch.addingTimeInterval(90)),
        ]
        #expect(CrashLog.report(from: candidates, since: launch) == "SnapDesk-2026-08-07-090000.ips")
    }

    @Test("Both the live and the rotated report folders are searched")
    func looksInRetiredToo() {
        let paths = CrashLog.systemReportDirectories.map(\.path)
        #expect(paths.count == 2)
        #expect(paths.contains { $0.hasSuffix("/Logs/DiagnosticReports") })
        #expect(paths.contains { $0.hasSuffix("/Logs/DiagnosticReports/Retired") })
    }

    @Test("Kept reports live beside the app's other logs, not in /tmp")
    func staysUnderTheUsersLogs() {
        #expect(CrashLog.directory.path.hasSuffix("/Logs/SnapDesk/Crashes"))
        #expect(CrashLog.directory.path.contains("/tmp") == false)
    }
}
