import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FIRST: if we're running from a temporary/translocated path (downloaded
        // app not yet in /Applications), TCC permissions will never stick and the
        // user gets an endless "allow again" loop. Offer to move + relaunch
        // before anything requests a permission. false → a fresh /Applications
        // instance is taking over, so this (temporary) one must stop now.
        guard InstallHelper.ensureProperLocation() else { return }

        // Record whether Screen Recording was granted BEFORE anything can
        // change it — a grant that arrives later needs a relaunch to work,
        // and ensureScreenRecording() uses this snapshot to know that.
        Permissions.primeLaunchState()

        // Only one SnapDesk at a time: a freshly launched copy wins and quits any
        // older instances (e.g. one left running from a mounted DMG or a previous
        // build). Prevents duplicate menu-bar icons.
        enforceSingleInstance()

        // Menu-bar only.
        NSApp.setActivationPolicy(.accessory)
        coordinator.start()
    }

    /// Terminate every other running copy that shares our bundle identifier so
    /// this instance is the sole survivor.
    private func enforceSingleInstance() {
        let me = NSRunningApplication.current
        let bundleID = Bundle.main.bundleIdentifier ?? "com.snapdesk.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
        guard !others.isEmpty else { return }
        // The NEWEST copy must win — that's how build-updates replace the
        // running app. ("Lowest pid wins" was backwards: every fresh build
        // killed ITSELF and the stale binary lived forever.) Deterministic
        // tie-break for simultaneous launches: later launchDate wins, then
        // higher pid.
        let myDate = me.launchDate ?? .distantPast
        let newerExists = others.contains { other in
            let d = other.launchDate ?? .distantPast
            return d > myDate || (d == myDate && other.processIdentifier > me.processIdentifier)
        }
        if newerExists {
            NSApp.terminate(nil)
            return
        }
        others.forEach { $0.terminate() }
        // A stuck old instance can ignore the polite quit — force it after 3s
        // so the user never sees two menu-bar icons.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
    }

    /// If a recording is in progress, delay termination until the writer has
    /// finalized the .mov — otherwise the file loses its moov atom and becomes
    /// unplayable. A 6s watchdog guarantees we never hang the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.finishActiveRecording(then: {
            NSApp.reply(toApplicationShouldTerminate: true)
        }) else { return .terminateNow }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            NSApp.reply(toApplicationShouldTerminate: true)   // watchdog
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }
}
