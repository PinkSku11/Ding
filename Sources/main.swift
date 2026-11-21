import AppKit

// Before anything shows a time: Ding's own 24-hour / AM/PM choice (see Settings.applyHourStyle).
Settings.applyHourStyle()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
