import Foundation
import UserNotifications

/// Sends a local macOS notification whenever a document is auto-saved.
/// Authorization is requested once at app launch; if the user declines,
/// `notify(...)` simply becomes a no-op.
enum AutoSaveNotifier {

    /// Ask the system for permission to post notifications. Safe to call at launch.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    print("[AutoSaveNotifier] Authorization failed: \(error.localizedDescription)")
                } else {
                    print("[AutoSaveNotifier] Notification authorization granted: \(granted)")
                }
            }
    }

    /// Post a notification announcing that `documentName` was auto-saved.
    static func notify(documentName: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = "Auto-saved"
            content.body = documentName
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil   // deliver immediately
            )
            center.add(request) { error in
                if let error {
                    print("[AutoSaveNotifier] Failed to post notification: \(error.localizedDescription)")
                }
            }
        }
    }
}
