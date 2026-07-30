import AppKit

/// Records ONLY the failures: every OCR that recognized nothing, with the facts
/// needed to tell the four causes apart afterwards — bad selection, an empty
/// frame handed over by a lapsed Screen Recording grant, a Vision blind spot, or
/// a wrong-region crop.
///
/// `log show` returns nothing for this app (ad-hoc-signed accessory, no logging
/// subsystem), so a plain file is the only thing readable after the fact.
/// Writes nothing on success — a working install never touches the disk here.
///
/// PRIVACY: a missed frame can contain whatever was on screen — a password
/// manager, a banking page. So the artifacts live under the user's own
/// `~/Library/Logs/SnapDesk` (home is 0700; no other local user can read it),
/// each file is created 0600, and only the few most recent shots are kept.
/// World-readable `/tmp` — the old home — is never touched.
enum MissLog {
    /// Per-user, not world-readable. Created 0700 on first use.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/SnapDesk", isDirectory: true)
    }()
    static var logURL: URL { directory.appendingPathComponent("ocr-misses.log") }

    private static let queue = DispatchQueue(label: "com.snapdesk.misslog")
    /// Keep only this many recent miss screenshots; older ones are pruned.
    private static let maxShots = 5

    /// - Parameters:
    ///   - facts: short `key=value` pairs; keep them cheap to compute.
    ///   - image: the exact frame OCR gave up on. Saved as a PNG beside the log
    ///     so a miss can be inspected after the fact — the only way to tell a
    ///     genuine Vision miss from a mis-drag onto something with no text.
    static func record(_ facts: [String: String], image: CGImage? = nil) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        // CGImage is safe to hand to another thread; encode there, not here —
        // an .accurate-pass frame is multi-megapixel and PNG encoding is heavy.
        queue.async {
            ensureDirectory()
            var body = facts
            if let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                // A UUID, not a 1-second timestamp: two misses in the same
                // second used to overwrite each other's shot.
                let name = "ocr-miss-\(UUID().uuidString).png"
                write(png, to: directory.appendingPathComponent(name))
                body["shot"] = name
                pruneShots()
            }
            let text = body.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            guard let data = "[\(stamp)] front=\(front) \(text)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                write(data, to: logURL)
            }
        }
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Write and immediately clamp to owner-only (0600). `Data.write` creates
    /// with the process umask, so tighten explicitly rather than trust it.
    private static func write(_ data: Data, to url: URL) {
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Delete all but the `maxShots` newest PNGs so screen captures don't pile
    /// up on disk indefinitely.
    private static func pruneShots() {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "png" }) else { return }
        let sorted = all.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for url in sorted.dropFirst(maxShots) { try? fm.removeItem(at: url) }
    }
}
