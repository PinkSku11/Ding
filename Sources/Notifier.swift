import Foundation
import UserNotifications

/// Shows a normal Mac notification for each ring and removes it again afterwards,
/// so nothing piles up in Notification Center.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Runs when the notification is clicked or closed.
    var onClick: (() -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let categoryID = "ding.ring"

    private override init() {
        super.init()
    }

    func setUp() {
        center.delegate = self
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: [],
                                              intentIdentifiers: [],
                                              options: [.customDismissAction])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Posts the notification for a ring and returns its id.
    @discardableResult
    func post(_ ring: Ring) -> String {
        let id = "ding." + UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = ring.alarm.displayName
        var lines = [Format.time(ring.time)]
        if let next = ring.next {
            lines.append(Format.nextLine(next, from: ring.time))
        }
        content.body = lines.joined(separator: "\n")
        content.categoryIdentifier = categoryID
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        return id
    }

    func remove(_ id: String, after seconds: TimeInterval) {
        let center = self.center
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
    }

    // Show the banner, but don't keep it in Notification Center.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    // A click anywhere on the notification (or closing it) stops the sound.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        center.removeDeliveredNotifications(withIdentifiers: [response.notification.request.identifier])
        await MainActor.run {
            Notifier.shared.onClick?()
        }
    }
}
