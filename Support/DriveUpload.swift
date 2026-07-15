import Foundation

/// "Auto-upload to Google Drive" — SnapDesk itself never touches the network:
/// finished recordings are copied into the Google Drive desktop app's sync
/// folder (~/Library/CloudStorage/GoogleDrive-*/My Drive/SnapDesk Recordings)
/// and Google's own app uploads them. Zero OAuth, zero network code.
enum DriveUpload {
    /// The user's Drive sync root, if the Google Drive desktop app is set up.
    static func driveRoot() -> URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: cloud, includingPropertiesForKeys: nil) else { return nil }
        guard let drive = entries.first(where: { $0.lastPathComponent.hasPrefix("GoogleDrive-") })
        else { return nil }
        let myDrive = drive.appendingPathComponent("My Drive")
        return FileManager.default.fileExists(atPath: myDrive.path) ? myDrive : drive
    }

    static var isAvailable: Bool { driveRoot() != nil }

    /// Copy `url` into "My Drive/SnapDesk Recordings" in the background, then
    /// call back on the main thread (success flag + destination name).
    static func upload(_ url: URL, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let root = driveRoot() else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let dir = root.appendingPathComponent("SnapDesk Recordings", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                var dest = dir.appendingPathComponent(url.lastPathComponent)
                // Never overwrite an earlier upload with the same name.
                if FileManager.default.fileExists(atPath: dest.path) {
                    let stamp = Int(Date().timeIntervalSince1970)
                    let base = url.deletingPathExtension().lastPathComponent
                    dest = dir.appendingPathComponent("\(base)-\(stamp).\(url.pathExtension)")
                }
                try FileManager.default.copyItem(at: url, to: dest)
                DispatchQueue.main.async { completion(true) }
            } catch {
                NSLog("SnapDesk: Drive upload copy failed: \(error)")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }
}
