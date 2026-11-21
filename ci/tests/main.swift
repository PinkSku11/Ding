// Tests for when alarms ring and how they're described. Built and run by the build machine
// together with Sources/Models.swift and Sources/Schedule.swift.
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
    check(Format.every(repeating(0, 60, every: 0, days: everyDay)) == "Every 1 min", "every 0")

    check(Format.days(once(60, days: everyDay)) == "Daily", "daily")
    check(Format.days(once(60, days: weekdays)) == "Mon–Fri", "Mon–Fri: \(Format.days(once(60, days: weekdays)))")
    check(Format.days(once(60, days: [1, 7])) == "Sat, Sun", "Sat, Sun: \(Format.days(once(60, days: [1, 7])))")
    check(Format.days(once(60, days: [2, 4, 6])) == "Mon, Wed, Fri", "Mon, Wed, Fri: \(Format.days(once(60, days: [2, 4, 6])))")

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
    check(allDay == "Every 30 min · All day · Mon–Fri", "all-day subtitle: \(allDay)")
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

// MARK: Saved alarms from older versions still load

do {
    let old = #"[{"id":"6F1C1D2E-0000-4000-8000-000000000001","name":"Old","kind":"once","timeMinute":420,"days":[2]}]"#
    let list = try? JSONDecoder().decode([Alarm].self, from: Data(old.utf8))
    check(list?.count == 1, "an older file still loads")
    check(list?.first?.keepAwake == false && list?.first?.sound == "Glass" && list?.first?.isOn == true,
          "missing settings get their defaults")
}

print("\(checks - failures) of \(checks) checks passed")
exit(failures == 0 ? 0 : 1)
