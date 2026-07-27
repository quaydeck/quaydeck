import Foundation
import UserNotifications

/// Local notifications for new dev servers and unrecognised listeners.
///
/// Off by default and only ever asks for permission once the user has switched it on.
public enum Notifier {
    public static func requestAuthorisation() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
