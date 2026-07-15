import AppKit

/// Fixes the #1 support nightmare for a downloaded, non-notarized macOS app:
/// the "allow permission → asked again → never sticks" loop.
///
/// Root cause = **App Translocation** (Gatekeeper Path Randomization). A
/// quarantined app run from Downloads / a DMG is executed from a random
/// read-only `…/AppTranslocation/…` path. macOS ties every TCC grant (Screen
/// Recording, Accessibility) to that path + code signature, so the next launch
/// — a DIFFERENT random path — has no grant → the app re-prompts forever.
///
/// The only cure is to run from a STABLE path with the quarantine flag cleared.
/// This helper detects the bad state on launch and offers a one-click
/// "Move to Applications & reopen" that copies the bundle to /Applications,
/// strips the quarantine attribute, and relaunches from there.
enum InstallHelper {
    private static let appsDir = "/Applications"

    /// True if the running bundle is in a translocated / temporary location
    /// where TCC permissions can never persist.
    static var isTranslocated: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/")
            || path.hasPrefix("/private/var/folders/")
            || path.contains("/Volumes/")            // running straight from the DMG
    }

    /// True if the bundle already lives in /Applications.
    static var isInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix(appsDir + "/")
    }

    /// Call once at launch. If the app is in a spot where permissions won't
    /// stick, guide the user (or auto-move) BEFORE anything asks for a grant.
    @MainActor
    static func ensureProperLocation() {
        // Already installed correctly → just make sure it isn't quarantined
        // (a quarantined /Applications copy can still translocate on first run).
        if isInApplications {
            stripQuarantine(at: Bundle.main.bundlePath)
            return
        }
        // Not in /Applications (translocated, on the DMG, or in Downloads) →
        // permissions will loop. Offer the fix.
        let alert = NSAlert()
        alert.messageText = "Move SnapDesk to Applications"
        alert.informativeText = """
        SnapDesk is running from a temporary location, so macOS won't remember \
        the Screen Recording / Accessibility permissions you grant — you'd be \
        asked again every time.

        Move it to your Applications folder once and this is fixed for good.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        moveToApplicationsAndRelaunch()
    }

    // MARK: - Move + relaunch

    @MainActor
    private static func moveToApplicationsAndRelaunch() {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: Bundle.main.bundlePath)
        let dest = URL(fileURLWithPath: appsDir).appendingPathComponent(src.lastPathComponent)

        do {
            // Replace any older copy (e.g. a previous version already installed).
            if fm.fileExists(atPath: dest.path) {
                // Quit any copy running from there first, then remove it.
                try? fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
            stripQuarantine(at: dest.path)
            relaunch(at: dest)
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't move SnapDesk"
            a.informativeText = "Please drag SnapDesk into your Applications folder manually, then open it from there.\n\n\(error.localizedDescription)"
            a.runModal()
            // Fall back to just opening the Applications folder.
            NSWorkspace.shared.open(URL(fileURLWithPath: appsDir))
        }
    }

    /// Remove com.apple.quarantine so macOS stops translocating the bundle and
    /// TCC grants bind to the stable /Applications path.
    private static func stripQuarantine(at path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", path]
        p.standardOutput = nil; p.standardError = nil
        try? p.run()
        p.waitUntilExit()
    }

    /// Launch the freshly-installed copy and quit this (temporary) one.
    private static func relaunch(at dest: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
