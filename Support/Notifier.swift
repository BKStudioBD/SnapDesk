import AppKit
import UserNotifications

/// Thin wrapper over UserNotifications for lightweight feedback toasts.
enum Notifier {
    private static let center = UNUserNotificationCenter.current()

    /// Shows banners even while SnapDesk is the active app (default is to
    /// suppress a foreground app's own notifications — every toast vanished).
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        static let shared = Delegate()
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler:
                                        @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }

    static func requestAuthorization() {
        center.delegate = Delegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func info(_ title: String, _ body: some StringProtocol) {
        post(title: title, body: String(body), isError: false)
    }

    static func error(_ title: String, _ body: some StringProtocol) {
        post(title: title, body: String(body), isError: true)
    }

    private static func post(title: String, body: String, isError: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if isError { content.sound = .defaultCritical }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        // Check authorization at POST time, not a launch-time snapshot — the
        // user can flip notifications off mid-session, and a silently dropped
        // "No text found" / "OCR failed" reads as "the app is broken".
        center.getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                       || settings.authorizationStatus == .provisional
            guard allowed else {
                // Denied → at least an audible cue instead of total silence.
                DispatchQueue.main.async { NSSound.beep() }
                return
            }
            center.add(request) { error in
                if let error {
                    NSLog("SnapDesk: notification failed (\(title)): \(error)")
                    if isError { DispatchQueue.main.async { NSSound.beep() } }
                }
            }
        }
    }
}
