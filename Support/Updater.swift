import AppKit

/// Checks GitHub Releases for a newer SnapDesk and installs it.
///
/// NO third-party framework and no service of our own: one HTTPS GET to the
/// public GitHub API, then the release's ZIP asset. That keeps SnapDesk's "pure
/// Swift on Apple frameworks, no external dependencies" promise intact.
///
/// PRIVACY: this is the ONLY code in the app that touches the network, and it is
/// **off by default**. Nothing is sent — no identifiers, no telemetry, no version
/// ping — it is a plain unauthenticated read of a public URL, and it only happens
/// when the user turns automatic checks on or presses Check Now.
///
/// SECURITY: a downloaded bundle is never trusted on the strength of the URL. It
/// must (a) carry a valid signature and (b) be signed by the SAME authority as the
/// copy already running, or it is deleted and the update refused. Without (b) any
/// validly-signed app could be swapped in. An ad-hoc signature names nobody, so a
/// copy signed that way has no identity to hold a download to and refuses to
/// self-update — saying that, rather than blaming the download.
enum Updater {
    /// `owner/repo` — the only place releases are ever fetched from.
    static let repository = "BKStudioBD/SnapDesk"
    /// The one asset an update is ever installed from. A release can also carry
    /// dSYMs or a symbols archive, so "whichever .zip comes first" is a coin flip
    /// that hands users the wrong file.
    static let assetName = "SnapDesk.zip"

    enum Err: LocalizedError, Equatable {
        case network, noRelease, noAsset, unpackFailed, unsigned, wrongSigner, replaceFailed, noIdentity
        var errorDescription: String? {
            switch self {
            case .network:       "Couldn't reach GitHub."
            case .noRelease:     "No published release found."
            case .noAsset:       "That release has no SnapDesk.zip to download."
            case .unpackFailed:  "The download couldn't be unpacked."
            case .unsigned:      "The download isn't validly signed — refusing to install it."
            case .wrongSigner:   "The download is signed by someone else — refusing to install it."
            case .replaceFailed: "Couldn't replace the installed app."
            case .noIdentity:    "This copy of SnapDesk has no signing identity to check the download against — please install the update manually."
            }
        }
    }

    struct Release {
        let version: String        // "1.2.0" — the tag with any leading "v" removed
        let notes: String          // the release body, shown in What's New
        let zip: URL
    }

    // MARK: - Version

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// True when `candidate` is a later version than `current`. Numeric,
    /// component-wise — so "1.10.0" correctly beats "1.9.0", which a string
    /// comparison gets backwards.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Check

    /// Latest published release, or nil when it isn't newer than what's running.
    static func checkForUpdate() async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw Err.network
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub wants a User-Agent; identify the app and nothing about the user.
        request.setValue("SnapDesk/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Err.network }
        // 404 = no releases published yet, which is not an error worth alarming
        // the user about.
        if http.statusCode == 404 { throw Err.noRelease }
        guard http.statusCode == 200 else { throw Err.network }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { throw Err.noRelease }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version, than: currentVersion) else { return nil }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zip = appZipURL(in: assets) else { throw Err.noAsset }

        return Release(version: version, notes: (json["body"] as? String) ?? "", zip: zip)
    }

    /// The app archive among a release's assets, matched by NAME rather than by
    /// a `.zip` extension — a release that also ships dSYMs or a symbols archive
    /// would otherwise install whichever one GitHub happened to list first.
    static func appZipURL(in assets: [[String: Any]]) -> URL? {
        for asset in assets {
            guard let name = asset["name"] as? String,
                  name.caseInsensitiveCompare(assetName) == .orderedSame,
                  let link = asset["browser_download_url"] as? String else { continue }
            return URL(string: link)
        }
        return nil
    }

    // MARK: - Install

    /// Download, verify and swap in the new build, then relaunch.
    @MainActor
    static func install(_ release: Release) async throws {
        let (downloaded, response) = try await URLSession.shared.download(from: release.zip)
        // A 404, a 500 or a captive portal's login page is still written to disk
        // as a perfectly good file. Handing that to ditto blames the release for
        // an archive that was never an archive, so check the status first.
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: downloaded)
            throw Err.network
        }
        // `download(from:)` hands back a temp file that is deleted when we return
        // — move it somewhere we control first.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapDesk-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent("SnapDesk.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)

        // ditto, not NSFileManager: it preserves the bundle's symlinks and
        // extended attributes, which an unzip that flattens them would break.
        //
        // Every Process below runs on the background queue. They are
        // `waitUntilExit()` calls — an unzip and a `codesign --deep` over a
        // whole bundle — and this function is @MainActor, so on the main thread
        // they beachball the menu bar, the hotkeys and any live recording's
        // control bar for as long as they take.
        guard await BackgroundWork.run({ run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) })
        else { throw Err.unpackFailed }
        guard let newApp = (try? FileManager.default.contentsOfDirectory(at: work,
                                                                        includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { throw Err.unpackFailed }

        // (a) valid signature at all…
        guard await BackgroundWork.run({
            run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        }) else { throw Err.unsigned }
        // (b) …and the SAME signer as the running copy. Skipping this would accept
        // any validly-signed app someone managed to serve us.
        let running = Bundle.main.bundleURL
        let signers = await BackgroundWork.run {
            (mine: signer(of: running), theirs: signer(of: newApp))
        }
        if let refusal = signatureRefusal(running: signers.mine, download: signers.theirs) {
            throw refusal
        }

        // Replace the bundle we're running from. The live process keeps its own
        // inode, so this is safe; the new code takes effect on relaunch.
        guard await BackgroundWork.run({
            (try? FileManager.default.replaceItemAt(running, withItemAt: newApp)) != nil
        }) else { throw Err.replaceFailed }
        // Remember where we came from so What's New can be shown once, after the
        // new version starts.
        UserDefaults.standard.set(release.version, forKey: "update.installedVersion")
        UserDefaults.standard.set(release.notes, forKey: "update.notes")
        InstallHelper.relaunchSelf()
    }

    // MARK: - Shell helpers

    /// Run a tool, true on exit status 0. These are fixed absolute paths with
    /// argument arrays — no shell, so nothing here can be injected into.
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// How a bundle is signed, as `codesign -dv` reports it.
    enum Signer: Equatable {
        /// A named signing identity — "Developer ID Application: …" or a local
        /// certificate. This is the only thing worth comparing.
        case authority(String)
        /// Signed with no identity at all. Anyone can produce one, so it proves
        /// the bundle is intact and nothing whatsoever about who made it.
        case adhoc
    }

    /// The signer of a bundle, or nil when codesign says nothing usable.
    private static func signer(of app: URL) -> Signer? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", app.path]
        let pipe = Pipe()
        // codesign writes this to stderr.
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseSigner(text)
    }

    /// Read the signer out of `codesign -dv` output. An ad-hoc bundle prints
    /// `Signature=adhoc` and NO `Authority=` line at all, so looking only for an
    /// Authority reads a perfectly signed local build as unsigned.
    static func parseSigner(_ codesignOutput: String) -> Signer? {
        var adhoc = false
        for line in codesignOutput.components(separatedBy: .newlines) {
            if line.hasPrefix("Authority=") {
                return .authority(String(line.dropFirst("Authority=".count)))
            }
            if line.hasPrefix("Signature=adhoc") { adhoc = true }
        }
        return adhoc ? .adhoc : nil
    }

    /// Why a download may NOT replace the running copy — nil when it may.
    ///
    /// The test is identity, not mere validity: only the same authority that
    /// signed us gets to replace us. When we have no identity of our own there is
    /// nothing to compare against, and the honest answer is to say so instead of
    /// calling the download unsigned.
    static func signatureRefusal(running: Signer?, download: Signer?) -> Err? {
        switch (running, download) {
        case let (.authority(mine)?, .authority(theirs)?):
            return mine == theirs ? nil : .wrongSigner
        // An identified copy is never replaced by a bundle signed by nobody.
        case (.authority?, .adhoc?): return .wrongSigner
        case (.authority?, nil):     return .unsigned
        default:                     return .noIdentity
        }
    }
}
