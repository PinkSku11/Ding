import Foundation
import UserNotifications

/// Shows a normal Mac notification for each ring. Ding removes it again after the ring, so nothing piles up
/// in Notification Center, unless the alarm keeps it there ("Keep in Notification Center").
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Runs when a notification is clicked or closed, with its id.
    var onClick: ((String) -> Void)?
    /// Runs when a snooze button is clicked, with the alarm to snooze and for how many minutes.
    var onSnooze: ((UUID, Int) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let categoryID = "ding.ring"
    private let keepPrefix = "ding.keep."
    private let missedPrefix = "ding.missed."

    private override init() {
        super.init()
    }

    func setUp() {
        center.delegate = self
        let snoozes = Snooze.lengths.map {
            UNNotificationAction(identifier: Snooze.action($0), title: Snooze.title($0), options: [])
        }
        let category = UNNotificationCategory(identifier: categoryID,
                                              actions: snoozes,
                                              intentIdentifiers: [],
                                              options: [.customDismissAction])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert]) { _, _ in }
        clearLeftovers()
    }

    /// The notifications of rings that were already over when Ding last quit, before it could clear them.
    private func clearLeftovers() {
        let launched = Date()
        let kept = [keepPrefix, missedPrefix]
        center.getDeliveredNotifications { [center] notes in
            let old = notes
                .filter { note in note.date < launched && !kept.contains { note.request.identifier.hasPrefix($0) } }
                .map(\.request.identifier)
            if !old.isEmpty { center.removeDeliveredNotifications(withIdentifiers: old) }
        }
    }

    /// Posts the notification for a ring and returns its id. `silentBecause` says why there's no sound,
    /// such as "No sound: the Mac is muted"; it shows under the alarm's name.
    @discardableResult
    func post(_ ring: Ring, silentBecause reason: String? = nil) -> String {
        // A kept notification has one id per alarm, so its next ring replaces it rather than adding another.
        let id = ring.alarm.keepNotification ? keepPrefix + ring.alarm.id.uuidString : "ding." + UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = ring.alarm.displayName
        if let reason { content.subtitle = reason }
        var lines = [ring.snoozed ? "\(Format.time(ring.time)) (snoozed)" : Format.time(ring.time)]
        if let next = ring.next {
            lines.append(Format.nextLine(next, from: ring.time))
        }
        content.body = lines.joined(separator: "\n")
        content.categoryIdentifier = categoryID
        content.userInfo = ["alarm": ring.alarm.id.uuidString]
        add(id, content)
        return id
    }

    private func add(_ id: String, _ content: UNMutableNotificationContent) {
        RingLog.write("notification \(id) | \(content.title) | \(content.subtitle) | "
                      + content.body.replacingOccurrences(of: "\n", with: " / "))
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { RingLog.write("notification \(id) not shown: \(error.localizedDescription)") }
        }
    }

    /// An alarm the Mac slept through. It stays in Notification Center until you clear it, and a later miss
    /// of the same alarm replaces it.
    func postMissed(_ ring: Ring, now: Date = Date()) {
        let content = UNMutableNotificationContent()
        content.title = ring.alarm.displayName
        let when = Format.past(ring.time, from: now)
        content.body = ring.snoozed
            ? "Missed its snooze \(when) while your Mac was asleep"
            : "Missed \(when) while your Mac was asleep"
        content.userInfo = ["alarm": ring.alarm.id.uuidString]
        add(missedPrefix + ring.alarm.id.uuidString, content)
    }

    func remove(_ id: String, after seconds: TimeInterval) {
        let center = self.center
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            center.removeDeliveredNotifications(withIdentifiers: [id])
            RingLog.write("removed \(id)")
        }
    }

    // Show the banner; keep it in Notification Center only for alarms that keep their notification,
    // and for missed alarms.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let id = notification.request.identifier
        return id.hasPrefix(keepPrefix) || id.hasPrefix(missedPrefix) ? [.banner, .list] : [.banner]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let id = request.identifier
        center.removeDeliveredNotifications(withIdentifiers: [id])
        let alarm = (request.content.userInfo["alarm"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        await MainActor.run {
            Notifier.shared.respond(action, alarm: alarm, notification: id)
        }
    }

    /// A click anywhere on the notification (or closing it) stops the sound; a snooze button also rings it
    /// again that many minutes later.
    func respond(_ action: String, alarm: UUID?, notification id: String) {
        if let minutes = Snooze.minutes(ofAction: action), let alarm {
            onSnooze?(alarm, minutes)
        } else {
            onClick?(id)
        }
    }
}
