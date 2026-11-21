import Foundation

// MARK: - When alarms ring

enum Schedule {
    /// The time `minute` minutes after midnight on `day`.
    static func at(_ minute: Int, on day: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
    }

    /// Every ring of the occurrence that starts on `day`.
    static func ringTimes(for alarm: Alarm, day: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: day)
        switch alarm.kind {
        case .once:
            guard let time = at(alarm.timeMinute, on: start, calendar: calendar) else { return [] }
            return [time]
        case .repeating:
            guard let from = at(alarm.fromMinute, on: start, calendar: calendar) else { return [] }
            var until: Date
            if alarm.untilMinute > alarm.fromMinute {
                guard let end = at(alarm.untilMinute, on: start, calendar: calendar) else { return [] }
                until = end
            } else {
                // Until is earlier than (or the same as) From: the range runs past midnight.
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start),
                      let end = at(alarm.untilMinute, on: nextDay, calendar: calendar) else { return [] }
                until = end
                if alarm.untilMinute == alarm.fromMinute {
                    until = end.addingTimeInterval(-1)   // a full day, without ringing twice at the seam
                }
            }
            let step = TimeInterval(alarm.intervalMinutes * 60)
            var times: [Date] = []
            var time = from
            while time <= until && times.count < 1500 {
                times.append(time)
                time = time.addingTimeInterval(step)
            }
            return times
        }
    }

    private static func occurs(_ alarm: Alarm, on day: Date, calendar: Calendar) -> Bool {
        if alarm.isOneOff {
            guard let oneOffDay = alarm.oneOffDay else { return false }
            return calendar.isDate(oneOffDay, inSameDayAs: day)
        }
        return alarm.days.contains(calendar.component(.weekday, from: day))
    }

    /// The alarm's first ring after `date`, or nil if it won't ring again.
    static func nextRing(for alarm: Alarm, after date: Date, calendar: Calendar = .current) -> Date? {
        guard alarm.isOn else { return nil }
        let today = calendar.startOfDay(for: date)
        var best: Date?
        // Yesterday too, for ranges that run past midnight.
        for offset in -1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  occurs(alarm, on: day, calendar: calendar) else { continue }
            if let time = ringTimes(for: alarm, day: day, calendar: calendar).first(where: { $0 > date }) {
                if best == nil || time < best! { best = time }
            }
        }
        return best
    }

    /// The day a one-off alarm rings on: the first occurrence that still has a ring ahead.
    static func oneOffDay(for alarm: Alarm, now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        for offset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            if ringTimes(for: alarm, day: day, calendar: calendar).contains(where: { $0 > now }) {
                return day
            }
        }
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// Whether the alarm needs the Mac awake right now: its time range is running,
    /// or a once-a-day alarm is about to ring.
    static func wantsMacAwake(_ alarm: Alarm, at date: Date, calendar: Calendar = .current) -> Bool {
        guard alarm.isOn, let next = nextRing(for: alarm, after: date, calendar: calendar) else { return false }
        let wait = next.timeIntervalSince(date)
        switch alarm.kind {
        case .once:
            return wait <= 10 * 60
        case .repeating:
            // Inside a range the next ring is never more than one interval away.
            return wait <= TimeInterval(alarm.intervalMinutes * 60 + 5 * 60)
        }
    }
}

// MARK: - Words and times on screen

enum Format {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func time(minute: Int) -> String {
        time(date(minute: minute))
    }

    static func date(minute: Int) -> Date {
        Schedule.at(minute, on: Date()) ?? Date()
    }

    static func minute(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// "at 20:45", "tomorrow at 07:00", "on Mon at 10:00"
    static func when(_ date: Date, from now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time(date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time(date))"
        }
        return "on \(weekdayFormatter.string(from: date)) at \(time(date))"
    }

    /// The notification's last line: "Next at 21:00", "Next tomorrow at 09:00", "Next Mon at 10:00"
    static func nextLine(_ date: Date, from now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Next at \(time(date))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Next tomorrow at \(time(date))"
        }
        return "Next on \(weekdayFormatter.string(from: date)) at \(time(date))"
    }

    static func every(_ alarm: Alarm) -> String {
        let n = max(1, alarm.every)
        switch alarm.everyUnit {
        case .minutes: return "Every \(n) min"
        case .hours: return n == 1 ? "Every hour" : "Every \(n) hours"
        }
    }

    static func days(_ alarm: Alarm) -> String {
        let calendar = Calendar.current
        if alarm.isOneOff {
            // No days picked: it rings one time, then switches itself off.
            guard alarm.isOn, let day = alarm.oneOffDay else { return "One time" }
            if calendar.isDateInToday(day) || calendar.isDateInYesterday(day) { return "Today only" }
            if calendar.isDateInTomorrow(day) { return "Tomorrow only" }
            return "\(weekdayFormatter.string(from: day)) only"
        }
        let days = alarm.days
        let symbols = calendar.shortWeekdaySymbols   // index 0 is Sunday
        if days.count == 7 { return "Daily" }
        if days == Set([2, 3, 4, 5, 6]) { return "\(symbols[1])–\(symbols[5])" }
        if days == Set([1, 7]) { return "\(symbols[6]), \(symbols[0])" }
        let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        return order.filter { days.contains($0) }.map { symbols[$0 - 1] }.joined(separator: ", ")
    }

    /// The second line of an alarm in the menu.
    static func subtitle(_ alarm: Alarm) -> String {
        switch alarm.kind {
        case .repeating:
            let range = alarm.fromMinute == alarm.untilMinute
                ? "All day"
                : "\(time(minute: alarm.fromMinute))–\(time(minute: alarm.untilMinute))"
            return "\(every(alarm)) · \(range) · \(days(alarm))"
        case .once:
            return "\(time(minute: alarm.timeMinute)) · \(days(alarm))"
        }
    }
}
