// Tests for when alarms ring, how they're described, and what counts as a call. Built and run by the build machine
// together with Sources/Models.swift, Sources/Schedule.swift and Sources/Microphone.swift.
import Foundation

var checks = 0
var failures = 0

func check(_ ok: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("FAIL (tests line \(line)): \(message())")
    }
}

func calendar(_ zone: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    cal.firstWeekday = 1
    return cal
}

let india = calendar("Asia/Kolkata")
let newYork = calendar("America/New_York")

func at(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

func text(_ cal: Calendar, _ date: Date?) -> String {
    guard let date else { return "none" }
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
}

func repeating(_ from: Int, _ until: Int, every: Int, unit: IntervalUnit = .minutes, days: Set<Int>) -> Alarm {
    Alarm(kind: .repeating, fromMinute: from, untilMinute: until, every: every, everyUnit: unit, days: days)
}

func once(_ time: Int, days: Set<Int>) -> Alarm {
    Alarm(kind: .once, timeMinute: time, days: days)
}

let everyDay: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
let weekdays: Set<Int> = [2, 3, 4, 5, 6]
// Week of Mon 23 Nov 2026 – Sun 29 Nov 2026.
let monday = at(india, 2026, 11, 23)

// MARK: Ring times within a day

do {
    let alarm = repeating(9 * 60, 23 * 60, every: 15, days: everyDay)
    let times = Schedule.ringTimes(for: alarm, day: monday, calendar: india)
    check(times.count == 57, "09:00–23:00 every 15 min should ring 57 times, got \(times.count)")
    check(text(india, times.first) == "2026-11-23 09:00:00", "first ring \(text(india, times.first))")
    check(text(india, times.last) == "2026-11-23 23:00:00", "last ring \(text(india, times.last))")
}
do {
    let alarm = repeating(9 * 60, 18 * 60, every: 2, unit: .hours, days: everyDay)
    let times = Schedule.ringTimes(for: alarm, day: monday, calendar: india).map { text(india, $0) }
    check(times == ["2026-11-23 09:00:00", "2026-11-23 11:00:00", "2026-11-23 13:00:00",
                    "2026-11-23 15:00:00", "2026-11-23 17:00:00"], "every 2 hours 09–18: \(times)")
}
do {
    let alarm = repeating(22 * 60, 2 * 60, every: 1, unit: .hours, days: everyDay)   // runs past midnight
    let times = Schedule.ringTimes(for: alarm, day: monday, calendar: india).map { text(india, $0) }
    check(times == ["2026-11-23 22:00:00", "2026-11-23 23:00:00", "2026-11-24 00:00:00",
                    "2026-11-24 01:00:00", "2026-11-24 02:00:00"], "overnight 22–02: \(times)")
}
do {
    let alarm = repeating(9 * 60, 9 * 60, every: 1, unit: .hours, days: everyDay)    // From = Until: all day
    let times = Schedule.ringTimes(for: alarm, day: monday, calendar: india)
    check(times.count == 24, "all day every hour should ring 24 times, got \(times.count)")
    check(Set(times).count == times.count, "all day: no ring twice")
}
do {
    var alarm = repeating(9 * 60, 10 * 60, every: 0, days: everyDay)                 // Every 0 counts as 1 minute
    check(alarm.intervalMinutes == 1, "every 0 -> 1 minute")
    alarm.every = 3
    alarm.everyUnit = .hours
    check(alarm.intervalMinutes == 180, "3 hours -> 180 minutes")
}

// MARK: Next ring

do {
    let alarm = repeating(9 * 60, 23 * 60, every: 15, days: everyDay)
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 23, 10, 7), calendar: india))
          == "2026-11-23 10:15:00", "next after 10:07")
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 23, 22, 59, 59), calendar: india))
          == "2026-11-23 23:00:00", "next after 22:59:59")
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 23, 23, 0, 0), calendar: india))
          == "2026-11-24 09:00:00", "next after exactly 23:00 is tomorrow")
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 23, 3), calendar: india))
          == "2026-11-23 09:00:00", "next in the early morning")
}
do {
    let alarm = repeating(9 * 60, 17 * 60, every: 60, days: weekdays)
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 27, 17, 30), calendar: india))
          == "2026-11-30 09:00:00", "Mon–Fri: after Friday evening comes Monday")
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 28, 12), calendar: india))
          == "2026-11-30 09:00:00", "Mon–Fri: Saturday noon -> Monday")
}
do {
    let alarm = repeating(22 * 60, 2 * 60, every: 1, unit: .hours, days: [6])           // Fridays, past midnight
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 28, 0, 30), calendar: india))
          == "2026-11-28 01:00:00", "Friday night range still rings early Saturday")
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 28, 2, 30), calendar: india))
          == "2026-12-04 22:00:00", "after it ends, next Friday")
}
do {
    let alarm = once(7 * 60, days: everyDay)
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 23, 6, 59, 30), calendar: india))
          == "2026-11-23 07:00:00", "once: 30 s before")
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 23, 7, 0, 0), calendar: india))
          == "2026-11-24 07:00:00", "once: right at the time, next is tomorrow")
}
do {
    let alarm = once(7 * 60, days: [1, 7])
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 27, 8), calendar: india))
          == "2026-11-28 07:00:00", "Sat, Sun: Friday -> Saturday")
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 29, 8), calendar: india))
          == "2026-12-05 07:00:00", "Sat, Sun: Sunday after it rang -> next Saturday")
}
do {
    var alarm = once(7 * 60, days: everyDay)
    alarm.isOn = false
    check(Schedule.nextRing(for: alarm, after: monday, calendar: india) == nil, "an alarm that's off never rings")
}

// MARK: One-offs (no days picked)

do {
    var alarm = once(7 * 60, days: [])
    let early = at(india, 2026, 11, 23, 6), late = at(india, 2026, 11, 23, 8)
    check(text(india, Schedule.oneOffDay(for: alarm, now: early, calendar: india)) == "2026-11-23 00:00:00",
          "one-off set before its time rings today")
    check(text(india, Schedule.oneOffDay(for: alarm, now: late, calendar: india)) == "2026-11-24 00:00:00",
          "one-off set after its time rings tomorrow")
    alarm.oneOffDay = Schedule.oneOffDay(for: alarm, now: late, calendar: india)
    check(text(india, Schedule.nextRing(for: alarm, after: late, calendar: india)) == "2026-11-24 07:00:00",
          "one-off next ring")
    check(Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 24, 7), calendar: india) == nil,
          "one-off doesn't ring again")
}
do {
    var alarm = repeating(9 * 60, 10 * 60, every: 30, days: [])
    alarm.oneOffDay = Schedule.oneOffDay(for: alarm, now: at(india, 2026, 11, 23, 9, 10), calendar: india)
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 23, 9, 45), calendar: india))
          == "2026-11-23 10:00:00", "one-off range keeps ringing until it ends")
    check(Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 23, 10), calendar: india) == nil,
          "one-off range stops after Until")
}
do {
    var alarm = repeating(23 * 60, 1 * 60, every: 60, days: [])                        // one-off past midnight
    alarm.oneOffDay = Schedule.oneOffDay(for: alarm, now: at(india, 2026, 11, 23, 23, 30), calendar: india)
    check(text(india, alarm.oneOffDay) == "2026-11-23 00:00:00", "armed late evening: belongs to that day")
    check(text(india, Schedule.nextRing(for: alarm, after: at(india, 2026, 11, 24, 0, 30), calendar: india))
          == "2026-11-24 01:00:00", "and still rings after midnight")
}

// MARK: Clock changes (a time zone with daylight saving)

do {
    let alarm = once(2 * 60 + 30, days: everyDay)                                       // 02:30 doesn't exist on 8 Mar
    let next = Schedule.nextRing(for: alarm, after: at(newYork, 2026, 3, 7, 12), calendar: newYork)
    check(next != nil, "a skipped hour doesn't stop the alarm")
    if let next {
        let day = newYork.component(.day, from: next)
        check(day == 8 || day == 9, "rings on the 8th (moved) or the 9th, got \(text(newYork, next))")
    }
    let monday9 = Schedule.nextRing(for: alarm, after: at(newYork, 2026, 3, 9, 1), calendar: newYork)
    check(text(newYork, monday9) == "2026-03-09 02:30:00", "next normal day back to 02:30")
}
do {
    let alarm = repeating(30, 3 * 60, every: 30, days: everyDay)                       // the repeated hour on 1 Nov
    let times = Schedule.ringTimes(for: alarm, day: at(newYork, 2026, 11, 1), calendar: newYork)
    check(times.count >= 6, "fall-back night still rings, got \(times.count)")
    check(zip(times, times.dropFirst()).allSatisfy { $0 < $1 }, "fall-back night: times only move forward")
}

// MARK: A ring that's due while you save another alarm still rings, unless its own alarm changed

do {
    var water = repeating(9 * 60, 23 * 60, every: 15, days: everyDay)
    let due = at(india, 2026, 11, 23, 10, 15)
    check(Schedule.rings(water, at: due, calendar: india), "10:15 is one of its rings")
    check(!Schedule.rings(water, at: at(india, 2026, 11, 23, 10, 16), calendar: india), "10:16 isn't")
    check(!Schedule.rings(water, at: at(india, 2026, 11, 22, 23, 15), calendar: india), "nor after Until")
    water.fromMinute = 9 * 60 + 5                                                      // edited: now :05, :20, :35, :50
    check(!Schedule.rings(water, at: due, calendar: india), "after an edit, the old ring time is dropped")
    water.isOn = false
    check(!Schedule.rings(water, at: at(india, 2026, 11, 23, 10, 20), calendar: india), "an alarm that's off doesn't ring")

    var oneOff = once(7 * 60, days: [])
    oneOff.oneOffDay = at(india, 2026, 11, 23)
    check(Schedule.rings(oneOff, at: at(india, 2026, 11, 23, 7), calendar: india), "one-off: today at 07:00")
    oneOff.oneOffDay = at(india, 2026, 11, 24)                                        // saved again: moved to tomorrow
    check(!Schedule.rings(oneOff, at: at(india, 2026, 11, 23, 7), calendar: india), "one-off moved to tomorrow")
}

// MARK: Keeping the Mac awake

do {
    let alarm = repeating(9 * 60, 23 * 60, every: 15, days: everyDay)
    check(Schedule.wantsMacAwake(alarm, at: at(india, 2026, 11, 23, 10, 7), calendar: india), "awake inside the range")
    check(Schedule.wantsMacAwake(alarm, at: at(india, 2026, 11, 23, 8, 50), calendar: india), "awake just before it starts")
    check(!Schedule.wantsMacAwake(alarm, at: at(india, 2026, 11, 23, 8), calendar: india), "not an hour before")
    check(!Schedule.wantsMacAwake(alarm, at: at(india, 2026, 11, 23, 23, 30), calendar: india), "not after it ends")
    let daily = once(7 * 60, days: everyDay)
    check(Schedule.wantsMacAwake(daily, at: at(india, 2026, 11, 23, 6, 55), calendar: india), "awake 5 min before a once alarm")
    check(!Schedule.wantsMacAwake(daily, at: at(india, 2026, 11, 23, 6), calendar: india), "not an hour before a once alarm")
}

// MARK: Words in the menu and notifications (this process runs in India time, English)

do {
    check(Format.every(repeating(0, 60, every: 15, days: everyDay)) == "Every 15 min", "every 15")
    check(Format.every(repeating(0, 60, every: 1, unit: .hours, days: everyDay)) == "Every hour", "every hour")
    check(Format.every(repeating(0, 60, every: 2, unit: .hours, days: everyDay)) == "Every 2 hours", "every 2 hours")
    check(Format.every(repeating(0, 60, every: 1, days: everyDay)) == "Every minute", "every 1 minute")
    check(Format.every(repeating(0, 60, every: 0, days: everyDay)) == "Every minute", "every 0")

    check(Format.days(once(60, days: everyDay)) == "Daily", "daily")
    check(Format.days(once(60, days: weekdays)) == "Weekdays", "Mon–Fri: \(Format.days(once(60, days: weekdays)))")
    check(Format.days(once(60, days: [1, 7])) == "Weekends", "Sat, Sun: \(Format.days(once(60, days: [1, 7])))")
    check(Format.days(once(60, days: [2, 4, 6])) == "Mon, Wed, Fri", "Mon, Wed, Fri: \(Format.days(once(60, days: [2, 4, 6])))")
    let sixDays = Format.days(once(60, days: [1, 2, 3, 4, 5, 6]))
    check(sixDays == "Sun, Mon, Tue, Wed, Thu, Fri" || sixDays == "Mon, Tue, Wed, Thu, Fri, Sun",
          "six days, in the order the week starts: \(sixDays)")

    var today = once(23 * 60 + 59, days: [])
    today.oneOffDay = Date()
    check(Format.days(today) == "Today only", "one-off today: \(Format.days(today))")
    today.oneOffDay = Calendar.current.date(byAdding: .day, value: 1, to: Date())
    check(Format.days(today) == "Tomorrow only", "one-off tomorrow: \(Format.days(today))")
    today.isOn = false
    check(Format.days(today) == "One time", "one-off that's off: \(Format.days(today))")

    let water = repeating(9 * 60, 23 * 60, every: 15, days: everyDay)
    let line = Format.subtitle(water)
    check(line.hasPrefix("Every 15 min · ") && line.hasSuffix(" · Daily") && line.contains("–"), "repeating subtitle: \(line)")
    let allDay = Format.subtitle(repeating(9 * 60, 9 * 60, every: 30, days: weekdays))
    check(allDay == "Every 30 min · All day · Weekdays", "all-day subtitle: \(allDay)")
    let vitamins = Format.subtitle(once(21 * 60, days: everyDay))
    check(!vitamins.contains("Once") && vitamins.hasSuffix(" · Daily"), "once subtitle: \(vitamins)")

    let now = Date()
    let cal = Calendar.current
    let later = cal.date(byAdding: .minute, value: 1, to: now)!
    let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
    let inThreeDays = cal.date(byAdding: .day, value: 3, to: now)!
    if cal.isDate(later, inSameDayAs: now) {
        check(Format.nextLine(later, from: now).hasPrefix("Next at "), "next line today: \(Format.nextLine(later, from: now))")
        check(Format.when(later, from: now).hasPrefix("at "), "when today: \(Format.when(later, from: now))")
    }
    check(Format.nextLine(tomorrow, from: now).hasPrefix("Next tomorrow at "), "next line tomorrow")
    check(Format.nextLine(inThreeDays, from: now).hasPrefix("Next on "), "next line later: \(Format.nextLine(inThreeDays, from: now))")
    check(Format.when(inThreeDays, from: now).hasPrefix("on "), "when later: \(Format.when(inThreeDays, from: now))")
}

// MARK: Times the Mac's way

do {
    let mac = DateFormatter()
    mac.dateStyle = .none
    mac.timeStyle = .short
    let afternoon = Format.date(minute: 13 * 60 + 5)
    check(Format.time(minute: 13 * 60 + 5) == mac.string(from: afternoon),
          "times follow the Mac's own format: \(Format.time(minute: 13 * 60 + 5))")
    // After the region, the 24-hour switch or the time zone changes, the formatters start afresh and still work.
    Format.reset()
    check(Format.time(minute: 13 * 60 + 5) == mac.string(from: afternoon), "the Mac's own format after a reset")
}

// MARK: Settings older versions left behind are cleared

do {
    let defaults = UserDefaults.standard
    let old = ["timerEnd", "timerLength", "timerOtherMinutes", "timeFormat",
               "AppleICUForce24HourTime", "AppleICUForce12HourTime", "keepAwake", "keepAwakeMoved"]
    for key in old { defaults.set("left by an older Ding", forKey: key) }   // a value the Mac itself never has
    defaults.set(true, forKey: "launchedBefore")
    Settings.forgetOldSettings()
    check(old.allSatisfy { defaults.string(forKey: $0) != "left by an older Ding" },
          "the timer's, the time format's and the old Keep awake settings go")
    check(defaults.bool(forKey: "launchedBefore"), "settings still in use stay")
    defaults.removeObject(forKey: "launchedBefore")
}

// MARK: A new alarm

do {
    let fresh = Alarm()
    check(fresh.sound == "Glass" && fresh.plays == 1 && fresh.playUnit == .times && fresh.volume == 0.5,
          "a new alarm plays Glass once at half volume")
}

// MARK: Saved alarms from older versions still load

do {
    let old = #"[{"id":"6F1C1D2E-0000-4000-8000-000000000001","name":"Old","kind":"once","timeMinute":420,"days":[2]}]"#
    let list = try? JSONDecoder().decode([Alarm].self, from: Data(old.utf8))
    check(list?.count == 1, "an older file still loads")
    check(list?.first?.keepAwake == false && list?.first?.sound == "Glass" && list?.first?.isOn == true,
          "missing settings get their defaults")
    check(list?.first?.keepNotification == false, "older alarms clear their notification after the ring, as before")

    var kept = Alarm()
    kept.keepNotification = true
    let again = (try? JSONEncoder().encode([kept])).flatMap { try? JSONDecoder().decode([Alarm].self, from: $0) }
    check(again?.first?.keepNotification == true, "Keep in Notification Center is saved")
}

// MARK: Duplicate names

do {
    check(Alarm.copyName(of: "Water break", taken: ["Water break"]) == "Water break copy", "first copy")
    check(Alarm.copyName(of: "Water break", taken: ["Water break", "Water break copy"]) == "Water break copy 2",
          "second copy")
    check(Alarm.copyName(of: "Water break copy", taken: ["Water break", "Water break copy"]) == "Water break copy 2",
          "a copy of a copy: \(Alarm.copyName(of: "Water break copy", taken: ["Water break", "Water break copy"]))")
    check(Alarm.copyName(of: "Water break copy 2", taken: ["Water break copy", "Water break copy 2"]) == "Water break copy 3",
          "a copy of copy 2")
    check(Alarm.copyName(of: "Alarm", taken: []) == "Alarm copy", "an unnamed alarm")
    check(Alarm.copyName(of: "Photocopy", taken: []) == "Photocopy copy", "a name that only ends in \"copy\"")
}

// MARK: Missed while the Mac slept

do {
    let daily = once(7 * 60, days: everyDay)
    let monday7 = at(india, 2026, 11, 23, 7)
    func last(_ alarm: Alarm, _ first: Date, _ upTo: Date) -> String {
        text(india, Schedule.lastRing(for: alarm, from: first, upTo: upTo, calendar: india))
    }
    check(last(daily, monday7, at(india, 2026, 11, 23, 8)) == "2026-11-23 07:00:00", "slept through one ring")
    check(last(daily, monday7, at(india, 2026, 11, 25, 8)) == "2026-11-25 07:00:00",
          "slept through three rings: the latest, \(last(daily, monday7, at(india, 2026, 11, 25, 8)))")
    check(last(daily, monday7, at(india, 2026, 11, 25, 6, 59)) == "2026-11-24 07:00:00", "a ring still ahead doesn't count")
    let workdays = once(7 * 60, days: weekdays)
    let friday7 = at(india, 2026, 11, 27, 7)
    check(last(workdays, friday7, at(india, 2026, 11, 30, 9)) == "2026-11-30 07:00:00",
          "over a weekend: Monday's ring, \(last(workdays, friday7, at(india, 2026, 11, 30, 9)))")
}
do {
    let now = at(india, 2026, 11, 25, 9)   // Wednesday 09:00
    let weekday = DateFormatter()
    weekday.setLocalizedDateFormatFromTemplate("EEE")
    let day = DateFormatter()
    day.setLocalizedDateFormatFromTemplate("dMMM")
    let today = at(india, 2026, 11, 25, 7)
    check(Format.past(today, from: now) == "at \(Format.time(today))", "missed today: \(Format.past(today, from: now))")
    let yesterday = at(india, 2026, 11, 24, 7)
    check(Format.past(yesterday, from: now) == "yesterday at \(Format.time(yesterday))",
          "missed yesterday: \(Format.past(yesterday, from: now))")
    let monday7 = at(india, 2026, 11, 23, 7)
    check(Format.past(monday7, from: now) == "on \(weekday.string(from: monday7)) at \(Format.time(monday7))",
          "missed this week: \(Format.past(monday7, from: now))")
    let longAgo = at(india, 2026, 11, 14, 7)
    check(Format.past(longAgo, from: now) == "on \(day.string(from: longAgo)) at \(Format.time(longAgo))",
          "missed over a week ago: \(Format.past(longAgo, from: now))")
}

// MARK: Times typed into a time box

do {
    let t = { (typed: String) in TimeText.minute(from: typed) }
    check(t("7") == 420 && t("07") == 420 && t("730") == 450 && t("0730") == 450 && t("7:30") == 450
          && t("7.30") == 450 && t("19:30") == 1170 && t("0:05") == 5 && t("23:59") == 1439,
          "typed 24-hour times: 7:30 is \(String(describing: t("7:30"))), 730 is \(String(describing: t("730")))")
    check(t("7:30 pm") == 1170 && t("7:30PM") == 1170 && t("7pm") == 1140 && t("12 am") == 0 && t("12:15 pm") == 735
          && t("7:30 a.m.") == 450 && t("7:30\u{202F}PM") == 1170,
          "typed AM/PM times: 7:30 pm is \(String(describing: t("7:30 pm")))")
    check(t("") == nil && t("7:") == nil && t("24:00") == nil && t("7:60") == nil && t("13 pm") == nil
          && t("abc") == nil && t("12345") == nil && t("7:3:0") == nil, "things that aren't a time")
    check(TimeText.minute(from: "오후 7:30", am: "오전", pm: "오후") == 1170, "AM/PM written first, as in Korean")

    let ampm = "9:05\u{202F}PM"
    check(TimeText.parts(of: ampm).map { [$0.hour, $0.minute] }
          == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 2)], "the hour and the minutes in 9:05 PM")
    check(TimeText.half(in: ampm) == NSRange(location: 5, length: 2), "PM in 9:05 PM")
    check(TimeText.parts(of: "21:05").map { [$0.hour, $0.minute] }
          == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)], "the hour and the minutes in 21:05")
    check(TimeText.half(in: "21:05") == nil, "no AM/PM in 21:05")

    // Every time as the Mac writes it can be read back, so editing a time in the box keeps it.
    let symbols = DateFormatter()
    let samples = [0, 5, 59, 60, 61, 719, 720, 721, 1170, 1439]
    let unread = samples.filter {
        TimeText.minute(from: Format.time(minute: $0), am: symbols.amSymbol, pm: symbols.pmSymbol) != $0
    }
    check(unread.isEmpty, "times as shown read back: \(unread.map { Format.time(minute: $0) })")
}

// MARK: Snooze buttons on the notification

do {
    check(Snooze.lengths == [5, 10, 15, 30], "snooze lengths: \(Snooze.lengths)")
    let titles = Snooze.lengths.map(Snooze.title)
    check(titles == ["Snooze 5 min", "Snooze 10 min", "Snooze 15 min", "Snooze 30 min"], "button names: \(titles)")
    check(Set(Snooze.lengths.map(Snooze.action)).count == Snooze.lengths.count, "each button has its own id")
    check(Snooze.lengths.allSatisfy { Snooze.minutes(ofAction: Snooze.action($0)) == $0 },
          "each button snoozes for its own minutes")
    // A click on the notification itself, closing it, or a button Ding doesn't have isn't a snooze.
    for other in ["com.apple.UNNotificationDefaultActionIdentifier", "com.apple.UNNotificationDismissActionIdentifier",
                  "ding.snooze", "ding.snooze.7", ""] {
        check(Snooze.minutes(ofAction: other) == nil, "\"\(other)\" isn't a snooze button")
    }
}

// MARK: What counts as a call

do {
    check(!Microphone.meansCall("corespeechd"), "Siri listening for \"Hey Siri\" isn't a call")
    check(!Microphone.meansCall("corespeechd_system"), "nor is the system-wide part of it")
    check(Microphone.meansCall("zoom.us"), "Zoom is a call")
    check(Microphone.meansCall("FaceTime"), "FaceTime is a call")
    check(Microphone.meansCall("Google Chrome Helper"), "a browser recording (Google Meet) is a call")
    check(Microphone.meansCall(""), "a program that can't be told still counts, to be safe")
    check(Microphone.programName(1) == "launchd",
          "a program run by macOS itself can be named: \(Microphone.programName(1))")
    check(Microphone.programName(getpid()) == "schedule-tests",
          "this program can be named: \(Microphone.programName(getpid()))")
}

print("\(checks - failures) of \(checks) checks passed")
exit(failures == 0 ? 0 : 1)
