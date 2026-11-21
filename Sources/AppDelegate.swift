import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var editor: EditorWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "DingDark") {   // build machine screenshots only
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Ding"
        }

        Notifier.shared.setUp()
        Notifier.shared.onClick = { Ringer.shared.stopAll() }
        Ringer.shared.onChange = { [weak self] in self?.refreshIcon() }
        AlarmStore.shared.onChange = { Engine.shared.recompute() }
        Engine.shared.onStateChange = { [weak self] in self?.refreshIcon() }
        Engine.shared.start()
        refreshIcon()

        if !Settings.launchedBefore {
            // First launch: open at login by default, and open the menu once so you can see where Ding lives.
            Settings.launchedBefore = true
            try? SMAppService.mainApp.register()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openMenu()
            }
        }

        // Only used by the build machine, which opens these to take screenshots of the layout.
        if let show = UserDefaults.standard.string(forKey: "DingShow") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                switch show {
                case "menu": self?.openMenu()
                case "editor": self?.openEditor(AlarmStore.shared.alarms.first?.id)
                case "new": self?.openEditor(nil)
                default: break
                }
            }
        }
    }

    /// Opening Ding again (from Spotlight, Finder or Launchpad) shows the alarm list next to the pointer,
    /// so it's always reachable even if the bell is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        buildMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    // MARK: Menu bar icon

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let alarms = AlarmStore.shared.alarms
        if Ringer.shared.isRinging {
            button.image = StatusIcon.ringing
        } else if !alarms.isEmpty && !alarms.contains(where: { $0.isOn }) {
            button.image = StatusIcon.bellOff
        } else {
            button.image = StatusIcon.bell
        }
    }

    /// A click on the bell stops a ringing alarm; otherwise it opens the alarm list.
    @objc private func statusItemClicked(_ sender: Any?) {
        if Ringer.shared.isRinging {
            Ringer.shared.stopAll()
            return
        }
        openMenu()
    }

    private func openMenu() {
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        if statusItem.menu === menu {
            statusItem.menu = nil
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if UserDefaults.standard.bool(forKey: "DingDark") {   // build machine screenshots only
            menu.appearance = NSAppearance(named: .darkAqua)
        }
        let alarms = sortedAlarms()

        if alarms.isEmpty {
            let item = NSMenuItem()
            item.view = EmptyStateView { [weak self, weak menu] in
                menu?.cancelTracking()
                DispatchQueue.main.async { self?.openEditor(nil) }
            }
            menu.addItem(item)
        } else {
            let header = NSMenuItem(title: nextText(), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
            let alarmsHeader = NSMenuItem()
            alarmsHeader.view = AlarmsHeaderView { [weak self, weak menu] in
                menu?.cancelTracking()
                DispatchQueue.main.async { self?.openEditor(nil) }
            }
            menu.addItem(alarmsHeader)

            for alarm in alarms {
                let id = alarm.id
                let item = NSMenuItem()
                item.view = AlarmRowView(
                    alarm: alarm,
                    detail: Format.subtitle(alarm),
                    onToggle: { on in AlarmStore.shared.setOn(id, on) },
                    onOpen: { [weak self, weak menu] in
                        menu?.cancelTracking()
                        DispatchQueue.main.async { self?.openEditor(id) }
                    })
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let awake = NSMenuItem(title: "Keep Mac awake for alarms", action: #selector(toggleKeepAwake), keyEquivalent: "")
        awake.target = self
        awake.state = Settings.keepAwake ? .on : .off
        menu.addItem(awake)

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit Ding", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    /// Soonest ring first; alarms that are off go to the bottom.
    private func sortedAlarms() -> [Alarm] {
        func key(_ alarm: Alarm) -> (Int, Double) {
            if alarm.isOn, let time = Engine.shared.nextRing(for: alarm.id) {
                return (0, time.timeIntervalSinceReferenceDate)
            }
            return (1, Double(alarm.kind == .once ? alarm.timeMinute : alarm.fromMinute))
        }
        return AlarmStore.shared.alarms.sorted { key($0) < key($1) }
    }

    private func nextText() -> String {
        guard let soonest = Engine.shared.soonest() else { return "No alarms are on" }
        return "Next: \(soonest.alarm.displayName) \(Format.when(soonest.time))"
    }

    @objc private func toggleKeepAwake() {
        Settings.keepAwake.toggle()
        Engine.shared.settingsChanged()
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at login"
            alert.informativeText = "You can add Ding yourself in System Settings → General → Login Items."
            NSApp.activate()
            alert.runModal()
        }
    }

    // MARK: Editor

    private func openEditor(_ id: UUID?) {
        editor?.close()
        let alarm: Alarm
        let isNew: Bool
        if let id, let existing = AlarmStore.shared.alarm(id) {
            alarm = existing
            isNew = false
        } else {
            // A new alarm starts blank: no name, no sound, times at 00:00, numbers and volume at 0.
            alarm = Alarm(name: "", kind: .once, fromMinute: 0, untilMinute: 0, every: 0,
                          timeMinute: 0, days: [], sound: "", plays: 0, volume: 0, ringWhenMuted: false)
            isNew = true
        }
        let controller = EditorWindowController(alarm: alarm, isNew: isNew)
        controller.onFinish = { [weak self, weak controller] in
            if let self, self.editor === controller {
                self.editor = nil
            }
        }
        editor = controller
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
