import AppKit

/// Notices that the last run ended in a crash, keeps the report, and says so.
///
/// SnapDesk crashed for three days without anyone knowing. macOS wrote a report
/// every time, but it went to `~/Library/Logs/DiagnosticReports`, where it is
/// rotated into a `Retired` subfolder and never looked at, and a menu-bar app
/// that vanishes leaves nothing else behind. The only symptom reaching the user
/// was "it quits sometimes" and "the shortcuts stopped working", which is the
/// same thing seen from two sides.
///
/// The mechanism is deliberately dull: a marker file written at launch and
/// deleted on a clean quit. A marker that survives means the last process did
/// not get to quit. Signal handlers were rejected on purpose. Catching a crash
/// from inside the crashing process means running code in a context where
/// almost nothing is safe to call, and the failure mode is a second crash on
/// top of the first.
///
/// Nothing is uploaded. The report is copied next to the app's own logs so it
/// can be found later, and the copy gets the same treatment `MissLog` gives its
/// frames: a crash report carries process memory addresses, loaded paths and
/// the names of everything running, so it is written 0600 inside a 0700
/// directory rather than left somewhere world-readable.
enum CrashLog {

    /// Where kept reports live, beside the OCR miss log.
    static var directory: URL { MissLog.directory.appendingPathComponent("Crashes", isDirectory: true) }

    /// Written at launch, removed on a clean quit.
    private static var markerURL: URL { MissLog.directory.appendingPathComponent("running.marker") }

    /// macOS's own crash reports. The rotated folder is included because a
    /// report is moved there within hours, which is exactly how the first seven
    /// went unnoticed.
    static var systemReportDirectories: [URL] {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let reports = base.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }

    /// How many kept reports to hold. Enough to see a pattern, few enough that
    /// the folder can't grow without bound.
    static let keepCount = 10

    // MARK: - Rules (pure, so they can be checked without crashing anything)

    /// Reports belonging to this app, newest first.
    ///
    /// Matched on the `<process>-<timestamp>.ips` shape macOS uses, so a report
    /// for some other app that merely mentions SnapDesk is never picked up. The
    /// timestamp sorts lexically because it is zero-padded and big-endian.
    static func ownReports(in names: [String], processName: String = "SnapDesk") -> [String] {
        names
            .filter { $0.hasPrefix(processName + "-") && $0.hasSuffix(".ips") }
            .sorted(by: >)
    }

    /// The names to delete so that only `keeping` newest remain.
    static func overflow(_ names: [String], keeping: Int = keepCount) -> [String] {
        Array(names.sorted(by: >).dropFirst(max(0, keeping)))
    }

    /// The report written by the run that just died, or nil when that run left
    /// none behind.
    ///
    /// The date test is what stops a false alarm. `./build.sh` kills the running
    /// copy outright, so the marker survives without a crash report ever being
    /// written; without this, the newest report still on disk (possibly days
    /// old, possibly already reported) would be adopted and announced as a
    /// fresh crash. A report belongs to that run only if it was written after
    /// the run started, which is when the marker was made.
    static func report(from candidates: [(name: String, modified: Date)],
                       since launch: Date) -> String? {
        candidates
            .filter { $0.modified >= launch }
            .max { $0.name < $1.name }?
            .name
    }

    // MARK: - Lifecycle

    /// Call once at launch, BEFORE the marker for this run is written, so the
    /// answer describes the previous process rather than this one.
    ///
    /// - Returns: the kept copy of the report, when the last run crashed.
    @discardableResult
    static func adoptPreviousCrash() -> URL? {
        let fm = FileManager.default
        // The marker's own timestamp IS the dead run's launch time.
        let launched = (try? fm.attributesOfItem(atPath: markerURL.path))?[.modificationDate] as? Date
        markRunning()
        guard let launched else { return nil }

        // Gathered across both folders first, because macOS may have rotated
        // the newest report into Retired/ before this launch got here.
        var candidates: [(name: String, modified: Date)] = []
        var locations: [String: URL] = [:]
        for dir in systemReportDirectories {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in ownReports(in: names) {
                let url = dir.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                candidates.append((name, modified ?? .distantPast))
                locations[name] = url
            }
        }
        guard let name = report(from: candidates, since: launched),
              let url = locations[name] else { return nil }
        let found = (name: name, url: url)

        ensureDirectory()
        let destination = directory.appendingPathComponent(found.name)
        if !fm.fileExists(atPath: destination.path) {
            guard let data = try? Data(contentsOf: found.url) else { return nil }
            guard (try? data.write(to: destination, options: .atomic)) != nil else { return nil }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        prune()
        return destination
    }

    /// Tell the user, once, on the launch after a crash. Not an alert: they are
    /// already back at work, and the report is not going anywhere.
    static func reportPreviousCrash() {
        guard adoptPreviousCrash() != nil else { return }
        Notifier.error("SnapDesk quit unexpectedly last time",
                       "The crash report is saved in ~/Library/Logs/SnapDesk/Crashes. Nothing was sent anywhere.")
    }

    static func markRunning() {
        ensureLogDirectory()
        try? Data().write(to: markerURL, options: .atomic)
        // Owner-only like everything else here. It carries no content, but a
        // directory where one file is 0644 and the rest are 0600 invites the
        // question of which rule is the real one.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: markerURL.path)
    }

    /// Call on a deliberate quit. A missing marker next launch is what says the
    /// last run ended properly.
    static func markCleanExit() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Kept reports, newest first.
    static func saved() -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return ownReports(in: names).map { directory.appendingPathComponent($0) }
    }

    static func revealInFinder() {
        ensureDirectory()
        NSWorkspace.shared.selectFile(saved().first?.path,
                                      inFileViewerRootedAtPath: directory.path)
    }

    // MARK: - Disk

    private static func prune() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in overflow(ownReports(in: names)) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func ensureLogDirectory() {
        try? FileManager.default.createDirectory(
            at: MissLog.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private static func ensureDirectory() {
        ensureLogDirectory()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
