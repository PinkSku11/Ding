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

    /// The alarm's last ring up to `date`, counting on from `first`, a ring it had then. After the Mac slept
    /// through more than one ring of an alarm set for a time, this is the latest of them.
    static func lastRing(for alarm: Alarm, from first: Date, upTo date: Date, calendar: Calendar = .current) -> Date {
        var last = first
        for _ in 0..<400 {   // more than a year of daily rings
            guard let next = nextRing(for: alarm, after: last, calendar: calendar), next <= date else { break }
            last = next
        }
        return last
    }

    /// Whether the alarm, as it's set now, rings at `date`.
    static func rings(_ alarm: Alarm, at date: Date, calendar: Calendar = .current) -> Bool {
        nextRing(for: alarm, after: date.addingTimeInterval(-1), calendar: calendar) == date
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
    private static var savedTimeFormatter: DateFormatter?
    private static var savedWeekdayFormatter: DateFormatter?
    private static var savedDayFormatter: DateFormatter?

    /// Starts the formatters afresh, after the region (with the Mac's 24-hour switch), the clock or the time zone
    /// changes.
    static func reset() {
        savedTimeFormatter = nil
        savedWeekdayFormatter = nil
        savedDayFormatter = nil
    }

    /// Times as the Mac shows them: "21:00" or "9:00 PM", as set in System Settings.
    private static var timeFormatter: DateFormatter {
        if let formatter = savedTimeFormatter { return formatter }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        savedTimeFormatter = formatter
        return formatter
    }

    /// Short day names: "Mon".
    private static var weekdayFormatter: DateFormatter {
        if let formatter = savedWeekdayFormatter { return formatter }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        savedWeekdayFormatter = formatter
        return formatter
    }

    /// Dates: "14 Nov", in the order the region uses.
    private static var dayFormatter: DateFormatter {
        if let formatter = savedDayFormatter { return formatter }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        savedDayFormatter = formatter
        return formatter
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func time(minute: Int) -> String {
        time(date(minute: minute))
    }

    static func date(minute: Int) -> Date {
        Schedule.at(minute, on: Date()) ?? Date()
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

    /// When a missed ring was: "at 07:00", "yesterday at 07:00", "on Mon at 07:00", or over a week ago
    /// "on 14 Nov at 07:00".
    static func past(_ date: Date, from now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time(date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time(date))"
        }
        if let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= sixDaysAgo {
            return "on \(weekdayFormatter.string(from: date)) at \(time(date))"
        }
        return "on \(dayFormatter.string(from: date)) at \(time(date))"
    }

    /// The notification's last line: "Next at 21:00", "Next tomorrow at 09:00", "Next on Mon at 10:00"
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
        case .minutes: return n == 1 ? "Every minute" : "Every \(n) min"
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
        if days == Set([2, 3, 4, 5, 6]) { return "Weekdays" }
        if days == Set([1, 7]) { return "Weekends" }
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

// MARK: - Times typed into the editor's time boxes

enum TimeText {
    /// A time typed into a time box, as minutes after midnight: "7", "730", "0730", "7:30", "7.30", "19:30",
    /// "7:30 pm", "7pm". `am` and `pm` are how the Mac writes them ("AM", "PM"). Nil when it isn't a time (yet).
    static func minute(from typed: String, am: String = "AM", pm: String = "PM") -> Int? {
        var text = String(typed.lowercased().filter { !$0.isWhitespace })
        var half: Int?   // 0 for AM, 12 for PM
        let marks = [(pm, 12), ("p.m.", 12), ("pm", 12), ("p", 12), (am, 0), ("a.m.", 0), ("am", 0), ("a", 0)]
            .map { mark, value in (String(mark.lowercased().filter { character in !character.isWhitespace }), value) }
            .filter { mark, _ in !mark.isEmpty }
            .sorted { first, second in first.0.count > second.0.count }   // the longest first: "pm" before "p"
        for (mark, value) in marks {
            if text.hasSuffix(mark) {
                text.removeLast(mark.count)
                half = value
                break
            }
            if text.hasPrefix(mark) {   // some languages write it first
                text.removeFirst(mark.count)
                half = value
                break
            }
        }
        func digits(_ part: Substring) -> [Int]? {
            let values = part.map(\.wholeNumberValue)
            return part.isEmpty || values.contains(nil) ? nil : values.compactMap { $0 }
        }
        func number(_ digits: [Int]) -> Int { digits.reduce(0) { $0 * 10 + $1 } }

        var hour: Int
        var minute: Int
        let pieces = text.split(omittingEmptySubsequences: false) { ":.h".contains($0) }
        switch pieces.count {
        case 1:
            guard let all = digits(pieces[0]) else { return nil }
            switch all.count {
            case 1, 2: hour = number(all); minute = 0
            case 3: hour = all[0]; minute = number(Array(all[1...]))
            case 4: hour = number(Array(all[..<2])); minute = number(Array(all[2...]))
            default: return nil
            }
        case 2:
            guard let h = digits(pieces[0]), let m = digits(pieces[1]), h.count <= 2, m.count <= 2 else { return nil }
            hour = number(h)
            minute = number(m)
        default:
            return nil
        }
        guard minute < 60 else { return nil }
        if let half {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + half
        } else if hour > 23 {
            return nil
        }
        return hour * 60 + minute
    }

    /// Where the hour and the minutes are in a time as written ("09:30", "9:30 PM"): its first two runs of digits.
    static func parts(of text: String) -> (hour: NSRange, minute: NSRange)? {
        let characters = text as NSString
        var runs: [NSRange] = []
        var index = 0
        while index < characters.length {
            guard isDigit(characters.character(at: index)) else {
                index += 1
                continue
            }
            let start = index
            while index < characters.length && isDigit(characters.character(at: index)) { index += 1 }
            runs.append(NSRange(location: start, length: index - start))
        }
        return runs.count >= 2 ? (runs[0], runs[1]) : nil
    }

    /// Where AM or PM is, when the time has it: its letters.
    static func half(in text: String) -> NSRange? {
        let characters = text as NSString
        var first: Int?
        var last = 0
        for index in 0..<characters.length where isLetter(characters.character(at: index)) {
            if first == nil { first = index }
            last = index
        }
        guard let first else { return nil }
        return NSRange(location: first, length: last - first + 1)
    }

    private static func isDigit(_ character: unichar) -> Bool {
        UnicodeScalar(character).map { CharacterSet.decimalDigits.contains($0) } ?? false
    }

    private static func isLetter(_ character: unichar) -> Bool {
        UnicodeScalar(character).map { CharacterSet.letters.contains($0) } ?? false
    }
}

// MARK: - Snoozing from the notification

/// The snooze lengths a ringing alarm's notification offers, a button each. With more than one button,
/// macOS shows them in the notification's Options menu.
enum Snooze {
    static let lengths = [5, 10, 15, 30]

    /// A button's id, which macOS hands back when the button is clicked.
    static func action(_ minutes: Int) -> String { "ding.snooze.\(minutes)" }

    static func title(_ minutes: Int) -> String { "Snooze \(minutes) min" }

    /// How long a clicked button snoozes for; nil for anything else, such as a click on the notification itself.
    static func minutes(ofAction id: String) -> Int? {
        lengths.first { action($0) == id }
    }
}
