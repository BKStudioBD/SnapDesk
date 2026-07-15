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

    /// True if the bundle already lives in /Applications. Anywhere else — a
    /// translocated `…/AppTranslocation/…` path, the mounted DMG (`/Volumes/…`),
    /// or Downloads — is a spot where TCC grants can't persist.
    static var isInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix(appsDir + "/")
    }

    /// Call once at launch, BEFORE anything requests a permission.
    /// - Returns: `true` to continue normal startup, `false` when we've begun
    ///   relocating + relaunching (the caller must stop — a fresh instance from
    ///   /Applications is taking over).
    @MainActor
    static func ensureProperLocation() -> Bool {
        // Already installed correctly → clear any leftover quarantine ONCE (only
        // spawns xattr if the flag is actually present; a locally-built dev copy
        // isn't quarantined, so this is a no-op there).
        if isInApplications {
            if hasQuarantine(at: Bundle.main.bundlePath) {
                stripQuarantine(at: Bundle.main.bundlePath)
            }
            return true
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
        guard alert.runModal() == .alertFirstButtonReturn else { return true }
        return !moveToApplicationsAndRelaunch()   // moved → stop this instance
    }

    // MARK: - Move + relaunch

    /// - Returns: `true` if the move started (caller should quit this instance).
    @MainActor
    private static func moveToApplicationsAndRelaunch() -> Bool {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: Bundle.main.bundlePath)
        let dest = URL(fileURLWithPath: appsDir).appendingPathComponent(src.lastPathComponent)

        do {
            // Replace any older copy (e.g. a previous version already installed).
            // Removing a running bundle is fine — the process keeps its open
            // files; enforceSingleInstance in the new copy quits the old one.
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
            stripQuarantine(at: dest.path)
            relaunch(at: dest)
            return true
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't move SnapDesk"
            a.informativeText = "Please drag SnapDesk into your Applications folder manually, then open it from there.\n\n\(error.localizedDescription)"
            a.runModal()
            // Fall back to just opening the Applications folder.
            NSWorkspace.shared.open(URL(fileURLWithPath: appsDir))
            return false
        }
    }

    /// Is the quarantine attribute present? (Avoids spawning xattr every launch.)
    private static func hasQuarantine(at path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
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

    /// Relaunch THIS bundle (from wherever it currently runs) — used after a
    /// permission grant, which macOS only honors on a fresh process.
    @MainActor
    static func relaunchSelf() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
