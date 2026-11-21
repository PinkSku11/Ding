import AppKit

/// One alarm going off.
struct Ring {
    let alarm: Alarm
    let time: Date
    let next: Date?
}

/// Keeps time: works out when each alarm rings next and fires it.
final class Engine: NSObject {
    static let shared = Engine()

    var onStateChange: (() -> Void)?

    private var timer: Timer?
    private var due: [UUID: Date] = [:]
    private var napBlocker: NSObjectProtocol?
    private var sleepBlocker: NSObjectProtocol?
    private var ticks = 0

    private override init() {
        super.init()
    }

    func start() {
        // Stop macOS from napping the app, which would make alarms late. The Mac can still sleep.
        napBlocker = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Ding keeps time for your alarms")

        recompute()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clockChanged), name: .NSSystemClockDidChange, object: nil)
        center.addObserver(self, selector: #selector(clockChanged), name: .NSSystemTimeZoneDidChange, object: nil)
    }

    @objc private func clockChanged() {
        recompute()
    }

    /// Rebuilds every alarm's next ring from now. Anything that was due in between is skipped.
    func recompute() {
        let now = Date()
        due = [:]
        var finished: [UUID] = []
        for alarm in AlarmStore.shared.alarms where alarm.isOn {
            if let time = Schedule.nextRing(for: alarm, after: now) {
                due[alarm.id] = time
            } else if alarm.isOneOff {
                finished.append(alarm.id)
            }
        }
        if !finished.isEmpty { AlarmStore.shared.switchOff(finished) }
        updateKeepAwake(now)
        onStateChange?()
    }

    func nextRing(for id: UUID) -> Date? {
        due[id]
    }

    /// The alarm that rings next, and when.
    func soonest() -> Ring? {
        var best: Ring?
        for alarm in AlarmStore.shared.alarms where alarm.isOn {
            guard let time = due[alarm.id] else { continue }
            if best == nil || time < best!.time {
                best = Ring(alarm: alarm, time: time, next: nil)
            }
        }
        return best
    }

    func settingsChanged() {
        updateKeepAwake(Date())
    }

    private func tick() {
        let now = Date()
        var rings: [Ring] = []
        var finished: [UUID] = []
        var changed = false

        for alarm in AlarmStore.shared.alarms where alarm.isOn {
            guard let time = due[alarm.id], now >= time else { continue }
            changed = true
            let next = Schedule.nextRing(for: alarm, after: now)
            due[alarm.id] = next
            // More than a minute late means the Mac was asleep or off: skip it quietly.
            if now.timeIntervalSince(time) <= 60 {
                rings.append(Ring(alarm: alarm, time: time, next: next))
            }
            if next == nil && alarm.isOneOff {
                finished.append(alarm.id)
            }
        }

        if !finished.isEmpty { AlarmStore.shared.switchOff(finished) }
        if !rings.isEmpty { Ringer.shared.enqueue(rings) }

        ticks += 1
        if changed || ticks % 30 == 0 {
            updateKeepAwake(now)
        }
        if changed {
            onStateChange?()
        }
    }

    /// "Keep Mac awake for alarms": no idle sleep while an alarm's time range is running.
    private func updateKeepAwake(_ now: Date) {
        let wanted = Settings.keepAwake && AlarmStore.shared.alarms.contains { Schedule.wantsMacAwake($0, at: now) }
        if wanted, sleepBlocker == nil {
            sleepBlocker = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Ding keeps your Mac awake for your alarms")
        } else if !wanted, let token = sleepBlocker {
            ProcessInfo.processInfo.endActivity(token)
            sleepBlocker = nil
        }
    }
}
