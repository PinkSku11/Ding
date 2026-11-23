import AppKit

// Before anything shows a time, so times follow the Mac's own 24-hour switch (see Settings.forgetOldSettings).
Settings.forgetOldSettings()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
