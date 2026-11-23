import AppKit

/// One line per ring, written only when Ding is started with -DingRingLog <path> (the build machine's live test).
enum RingLog {
    private static let path = UserDefaults.standard.string(forKey: "DingRingLog")

    static func write(_ line: String) {
        guard let path else { return }
        let entry = "\(Date().timeIntervalSince1970) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            handle.closeFile()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// One alarm going off.
struct Ring {
    let alarm: Alarm
    let time: Date
    let next: Date?
    var snoozed = false
}

/// Keeps time: works out when each alarm rings next and fires it.
final class Engine: NSObject {
    static let shared = Engine()

    var onStateChange: (() -> Void)?

    private var ticker: Timer?   // once a second
    private var due: [UUID: Date] = [:]
    private var snoozes: [UUID: Date] = [:]   // snoozed alarms and when each rings again
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

        loadSnoozes()
        recompute()

        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        ticker.tolerance = 0.2
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clockChanged), name: .NSSystemClockDidChange, object: nil)
        center.addObserver(self, selector: #selector(clockChanged), name: .NSSystemTimeZoneDidChange, object: nil)
        center.addObserver(self, selector: #selector(clockChanged), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        // The 24-hour switch in System Settings, which the times on screen follow.
        for name in ["AppleTimePreferencesChangedNotification", "AppleDatePreferencesChangedNotification"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(clockChanged),
                                                                name: NSNotification.Name(name), object: nil)
        }
    }

    /// The clock, the time zone, the region or the 24-hour switch changed: work out the times on screen and the
    /// next rings again.
    @objc private func clockChanged() {
        DispatchQueue.main.async { [weak self] in
            Format.reset()
            self?.recompute()
        }
    }

    /// Rebuilds every alarm's next ring from now.
    func recompute() {
        let now = Date()
        let previous = due
        due = [:]
        var finished: [UUID] = []
        for alarm in AlarmStore.shared.alarms where alarm.isOn {
            if let pending = previous[alarm.id], pending <= now, now.timeIntervalSince(pending) <= 60,
               Schedule.rings(alarm, at: pending) {
                // Due a moment ago, but not rung yet: another alarm was saved or switched in that same second.
                // Keep it so it still rings, unless this alarm itself was changed and no longer rings then.
                due[alarm.id] = pending
            } else if let time = Schedule.nextRing(for: alarm, after: now) {
                due[alarm.id] = time
            } else if alarm.isOneOff {
                finished.append(alarm.id)
            }
        }
        if !finished.isEmpty { AlarmStore.shared.switchOff(finished) }
        let ids = Set(AlarmStore.shared.alarms.map(\.id))
        if snoozes.keys.contains(where: { !ids.contains($0) }) {   // a snoozed alarm was deleted
            snoozes = snoozes.filter { ids.contains($0.key) }
            saveSnoozes()
        }
        updateKeepAwake(now)
        onStateChange?()
    }

    func nextRing(for id: UUID) -> Date? {
        due[id]
    }

    var hasSnoozes: Bool { !snoozes.isEmpty }

    /// The alarm that rings next, and when (a snoozed one included).
    func soonest() -> Ring? {
        var best: Ring?
        for alarm in AlarmStore.shared.alarms {
            if alarm.isOn, let time = due[alarm.id], best == nil || time < best!.time {
                best = Ring(alarm: alarm, time: time, next: nil)
            }
            if let time = snoozes[alarm.id], best == nil || time < best!.time {
                best = Ring(alarm: alarm, time: time, next: nil, snoozed: true)
            }
        }
        return best
    }

    // MARK: Snooze

    /// How long "Snooze 5 min" waits. The build machine's live test makes it shorter.
    private var snoozeLength: TimeInterval {
        let test = UserDefaults.standard.double(forKey: "DingSnoozeSeconds")
        return test > 0 ? test : 5 * 60
    }

    /// "Snooze 5 min" on the notification: stop this alarm's ring, and ring it again five minutes from now.
    /// It rings even if the alarm has switched itself off since (a one-time alarm).
    func snoozeNow(_ id: UUID) {
        Ringer.shared.stop(id)
        guard AlarmStore.shared.alarm(id) != nil else { return }
        let time = Date().addingTimeInterval(snoozeLength)
        snoozes[id] = time
        saveSnoozes()
        RingLog.write("snooze \(id.uuidString) until \(time.timeIntervalSince1970)")
        updateKeepAwake(Date())
        onStateChange?()
    }

    /// Switching an alarm off in the menu also cancels its snooze.
    func cancelSnooze(_ id: UUID) {
        guard snoozes.removeValue(forKey: id) != nil else { return }
        saveSnoozes()
        updateKeepAwake(Date())
        onStateChange?()
    }

    /// Snoozes are kept in Ding's settings, so quitting or restarting Ding doesn't lose them.
    private func loadSnoozes() {
        let saved = UserDefaults.standard.dictionary(forKey: "snoozes") as? [String: Double] ?? [:]
        snoozes = [:]
        for (key, time) in saved {
            if let id = UUID(uuidString: key) { snoozes[id] = Date(timeIntervalSince1970: time) }
        }
    }

    private func saveSnoozes() {
        var saved: [String: Double] = [:]
        for (id, time) in snoozes { saved[id.uuidString] = time.timeIntervalSince1970 }
        UserDefaults.standard.set(saved, forKey: "snoozes")
    }

    private func tick() {
        let now = Date()
        var rings: [Ring] = []
        var missed: [Ring] = []
        var finished: [UUID] = []
        var changed = false

        for alarm in AlarmStore.shared.alarms where alarm.isOn {
            guard var time = due[alarm.id], now >= time else { continue }
            changed = true
            if alarm.kind == .once {
                // The Mac may have slept through more than one of its rings: go by the latest.
                time = Schedule.lastRing(for: alarm, from: time, upTo: now)
            }
            let next = Schedule.nextRing(for: alarm, after: now)
            due[alarm.id] = next
            if now.timeIntervalSince(time) <= 60 {
                rings.append(Ring(alarm: alarm, time: time, next: next))
            } else {
                // More than a minute late: the Mac was asleep. An alarm set for a time says it was missed;
                // one that rings every few minutes or hours just carries on.
                RingLog.write("skipped \(alarm.id.uuidString) due \(time.timeIntervalSince1970)")
                if alarm.kind == .once { missed.append(Ring(alarm: alarm, time: time, next: next)) }
            }
            if next == nil && alarm.isOneOff {
                finished.append(alarm.id)
                RingLog.write("off \(alarm.id.uuidString)")
            }
        }

        for (id, time) in snoozes where now >= time {
            snoozes[id] = nil
            changed = true
            guard let alarm = AlarmStore.shared.alarm(id) else { continue }
            if now.timeIntervalSince(time) <= 60 {
                rings.append(Ring(alarm: alarm, time: time, next: due[id], snoozed: true))
            } else {
                RingLog.write("skipped \(id.uuidString) due \(time.timeIntervalSince1970)")
                missed.append(Ring(alarm: alarm, time: time, next: due[id], snoozed: true))
            }
            saveSnoozes()
        }

        if !finished.isEmpty { AlarmStore.shared.switchOff(finished) }
        if !rings.isEmpty { Ringer.shared.enqueue(rings) }
        for ring in missed {
            RingLog.write("missed \(ring.alarm.id.uuidString) due \(ring.time.timeIntervalSince1970)")
            Notifier.shared.postMissed(ring, now: now)
        }

        ticks += 1
        if changed || ticks % 30 == 0 {
            updateKeepAwake(now)
        }
        if changed {
            onStateChange?()
        }
    }

    /// "Keep Mac awake for this alarm": no idle sleep while that alarm's time range is running,
    /// or in the few minutes before it rings once, or while it's snoozed.
    private func updateKeepAwake(_ now: Date) {
        let snoozedAwake = snoozes.keys.contains { AlarmStore.shared.alarm($0)?.keepAwake == true }
        let wanted = snoozedAwake
            || AlarmStore.shared.alarms.contains { $0.keepAwake && Schedule.wantsMacAwake($0, at: now) }
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
