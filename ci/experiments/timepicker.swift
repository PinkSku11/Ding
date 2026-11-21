// Build machine experiment: on a Mac set to 24-hour time, which way of asking for AM/PM
// does the Mac's own time box (NSDatePicker, and SwiftUI's DatePicker) follow?
//
//     timepicker STRATEGY OUT_BASE
//
// Shows a window with both time boxes at 21:00, writes OUT_BASE.txt (what the formatters say)
// and OUT_BASE.wid (the window number, for screencapture -l), then quits after a few seconds.
import AppKit
import SwiftUI

let strategy = CommandLine.arguments[1]
let outBase = CommandLine.arguments[2]

func ampmLocale(_ base: Locale) -> Locale {
    var components = Locale.Components(locale: base)
    components.hourCycle = .oneToTwelve
    return Locale(components: components)
}

func describe(_ locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    let j = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "?"
    return "id=\(locale.identifier) short='\(formatter.dateFormat ?? "")' j='\(j)'"
}

func preferAMPM() {
    UserDefaults.standard.set(false, forKey: "AppleICUForce24HourTime")
    UserDefaults.standard.set(true, forKey: "AppleICUForce12HourTime")
}

let nine = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date())!
var log = ["strategy: \(strategy)"]

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if strategy.hasPrefix("pref-launch") { preferAMPM() }

if strategy.hasPrefix("pref-late") {
    // Use the locale and a date picker first, as Ding would have before you change the setting.
    log.append("before: " + describe(.current))
    let warm = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
    warm.datePickerElements = .hourMinute
    warm.dateValue = nine
    _ = warm.dataWithPDF(inside: warm.bounds)
    preferAMPM()
    if strategy == "pref-late-notify" {
        let center = DistributedNotificationCenter.default()
        for name in ["AppleDatePreferencesChangedNotification", "AppleTimePreferencesChangedNotification"] {
            center.postNotificationName(NSNotification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }
}

let locale: Locale = strategy.hasSuffix("components") ? ampmLocale(.current) : .autoupdatingCurrent
log.append("current: " + describe(.current))
log.append("used: " + describe(locale))

let picker = NSDatePicker()
picker.datePickerStyle = .textFieldAndStepper
picker.datePickerElements = .hourMinute
picker.locale = locale
picker.dateValue = nine
picker.sizeToFit()
picker.setFrameOrigin(NSPoint(x: 20, y: 96))

struct TimeBox: View {
    let locale: Locale
    let date: Date
    var body: some View {
        Form {
            DatePicker("SwiftUI", selection: .constant(date), displayedComponents: .hourAndMinute)
        }
        .formStyle(.grouped)
        .environment(\.locale, locale)
        .frame(width: 300, height: 80)
    }
}

let hosting = NSHostingView(rootView: TimeBox(locale: locale, date: nine))
hosting.frame = NSRect(x: 10, y: 6, width: 300, height: 80)
let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 136))
content.addSubview(hosting)
content.addSubview(picker)

let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 320, height: 136),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = strategy
window.contentView = content
window.orderFrontRegardless()

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
    try? String(window.windowNumber).write(toFile: outBase + ".wid", atomically: true, encoding: .utf8)
    try? (log.joined(separator: "\n") + "\n").write(toFile: outBase + ".txt", atomically: true, encoding: .utf8)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
app.run()
