import Foundation
import UserNotifications

/// Shows a normal Mac notification for each ring. Ding removes it again after the ring, so nothing piles up
/// in Notification Center, unless the alarm keeps it there ("Keep in Notification Center").
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Runs when the notification is clicked or closed.
    var onClick: (() -> Void)?
    /// Runs when "Snooze 5 min" is clicked, with the alarm to snooze.
    var onSnooze: ((UUID) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let categoryID = "ding.ring"
    private let snoozeID = "ding.snooze"
    private let keepPrefix = "ding.keep."

    private override init() {
        super.init()
    }

    func setUp() {
        center.delegate = self
        let snooze = UNNotificationAction(identifier: snoozeID, title: "Snooze 5 min", options: [])
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [snooze],
                                              intentIdentifiers: [],
                                              options: [.customDismissAction])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Posts the notification for a ring and returns its id.
    @discardableResult
    func post(_ ring: Ring) -> String {
        // A kept notification has one id per alarm, so its next ring replaces it rather than adding another.
        let id = ring.alarm.keepNotification ? keepPrefix + ring.alarm.id.uuidString : "ding." + UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = ring.alarm.displayName
        var lines = [ring.snoozed ? "\(Format.time(ring.time)) (snoozed)" : Format.time(ring.time)]
        if let next = ring.next {
            lines.append(Format.nextLine(next, from: ring.time))
        }
        content.body = lines.joined(separator: "\n")
        content.categoryIdentifier = categoryID
        content.userInfo = ["alarm": ring.alarm.id.uuidString]
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        return id
    }

    func remove(_ id: String, after seconds: TimeInterval) {
        let center = self.center
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    // Show the banner; keep it in Notification Center only for alarms that keep their notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(keepPrefix) ? [.banner, .list] : [.banner]
    }

    // A click anywhere on the notification (or closing it) stops the sound; "Snooze 5 min" also rings it again later.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
        let alarm = (response.notification.request.content.userInfo["alarm"] as? String).flatMap(UUID.init(uuidString:))
        let snooze = response.actionIdentifier == snoozeID
        await MainActor.run {
            if snooze, let alarm {
                Notifier.shared.onSnooze?(alarm)
            } else {
                Notifier.shared.onClick?()
            }
        }
    }
}
