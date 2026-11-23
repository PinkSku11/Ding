import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var editor: EditorController?
    private var lastAddAction: (() -> Void)?   // the + in the most recent alarm list (used by the build machine's test)
    private weak var timerSection: TimerSectionView?   // the timer row in the open menu, to count down in
    private var countdownTicker: Timer?
    private var shownCountdown = ""
    private var reopenListOpen = false   // the list shown when Ding is opened again is on screen

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one Ding at a time, or every alarm would ring twice. The copy you just opened wins.
        if let bundleID = Bundle.main.bundleIdentifier {
            for other in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where other != NSRunningApplication.current {
                other.terminate()
            }
        }
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
        Notifier.shared.onClick = { id in Ringer.shared.notificationClicked(id) }
        Notifier.shared.onSnooze = { id in Engine.shared.snoozeNow(id) }
        Ringer.shared.onChange = { [weak self] in self?.refreshIcon() }
        AlarmStore.shared.onChange = { Engine.shared.recompute() }
        Engine.shared.onStateChange = { [weak self] in self?.refreshIcon() }
        AlarmStore.shared.moveKeepAwakeIntoAlarms()
        Engine.shared.start()
        let testTimer = UserDefaults.standard.double(forKey: "DingTestTimer")   // the build machine's timer test
        if testTimer > 0 { Engine.shared.startTimer(testTimer) }
        refreshIcon()

        if !Settings.launchedBefore {
            // First launch: open the menu once so you can see where Ding lives.
            // "Open at login" starts off, and so does "Keep Mac awake" in each new alarm.
            Settings.launchedBefore = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openAlarmMenu()
            }
        }

        // The build machine's missed-alarm test: Ding stands still for a while, as if the Mac were asleep.
        let freeze = UserDefaults.standard.double(forKey: "DingTestFreeze")
        if freeze > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Thread.sleep(forTimeInterval: freeze) }
        }

        // Only used by the build machine, which opens these to take screenshots of the layout.
        if let show = UserDefaults.standard.string(forKey: "DingShow") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                switch show {
                case "menu": self?.openAlarmMenu()
                case "options": self?.openMenu(self?.buildOptionsMenu())
                case "editor-cycle":   // another app in front; open, close like Cancel, open again
                    let first = AlarmStore.shared.alarms.first?.id
                    NSWorkspace.shared.runningApplications
                        .first { $0.bundleIdentifier == "com.apple.finder" }?
                        .activate(options: [])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self?.openEditor(first)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self?.editor?.close()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                self?.openEditor(first)
                            }
                        }
                    }
                case "menu-plus":
                    // A run-loop timer still fires while the list is open (a queued block would wait).
                    let press = Timer(timeInterval: 2, repeats: false) { _ in self?.lastAddAction?() }
                    RunLoop.main.add(press, forMode: .common)
                    self?.openAlarmMenu()
                case "editor-switch":   // the editor, then AM/PM picked as from the menu, then the editor again
                    let first = AlarmStore.shared.alarms.first?.id
                    self?.openEditor(first)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self?.editor?.close()
                        self?.use12Hour()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.openEditor(first) }
                    }
                case "editor-duplicate":   // the editor, then Duplicate, as a click would
                    self?.openEditor(AlarmStore.shared.alarms.first?.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.editor?.duplicate() }
                case "editor-note":   // the editor with a note next to the sound, to check how it fits
                    self?.openEditor(AlarmStore.shared.alarms.first?.id)
                    let text = UserDefaults.standard.string(forKey: "DingTestNote") ?? "No sound: the Mac is muted"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.editor?.showNote(text) }
                case "ring":   // the first alarm rings now, as at its time
                    if let alarm = AlarmStore.shared.alarms.first {
                        let now = Date()
                        Ringer.shared.enqueue([Ring(alarm: alarm, time: now, next: Schedule.nextRing(for: alarm, after: now))])
                    }
                case "editor": self?.openEditor(AlarmStore.shared.alarms.first?.id)
                case "new": self?.openEditor(nil)
                default: break
                }
            }
        }
    }

    /// Quitting while an alarm rings: stop it and put the Mac's volume back first.
    func applicationWillTerminate(_ notification: Notification) {
        Ringer.shared.stopAll()
    }

    /// Opening Ding again (from Spotlight, Finder or Launchpad, or a click on its notification) shows the alarm
    /// list next to the pointer, so it's always reachable even if the bell is hidden behind the notch.
    /// The options stay on a right click on the bell.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Answer macOS first, then show the list. A list shown right here would keep macOS waiting for as
        // long as it stayed open, and macOS would then say Ding isn't responding.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.reopenListOpen else { return }
            self.reopenListOpen = true
            self.buildAlarmMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            self.reopenListOpen = false
        }
        return false
    }

    // MARK: Menu bar icon

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let alarms = AlarmStore.shared.alarms
        if Ringer.shared.isRinging {
            button.image = StatusIcon.ringing
        } else if !alarms.isEmpty && !alarms.contains(where: { $0.isOn }) && !Engine.shared.hasSnoozes
                    && Engine.shared.runningTimer == nil {
            button.image = StatusIcon.bellOff
        } else {
            button.image = StatusIcon.bell
        }
        updateCountdown()
    }

    /// While the timer runs, the time left shows next to the bell, and in the menu while it's open.
    private func updateCountdown() {
        guard let button = statusItem?.button else { return }
        let timer = Engine.shared.runningTimer
        var text = ""
        if let timer, !Ringer.shared.isRinging {
            text = Format.countdown(Int(ceil(timer.end.timeIntervalSinceNow)))
        }
        if text != shownCountdown {
            shownCountdown = text
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            button.title = text
            button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        }
        timerSection?.refresh()
        if timer != nil {
            if countdownTicker == nil {
                let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateCountdown() }
                RunLoop.main.add(ticker, forMode: .common)
                countdownTicker = ticker
            }
        } else if let ticker = countdownTicker {
            ticker.invalidate()
            countdownTicker = nil
        }
    }

    /// A click on the bell stops a ringing alarm. Otherwise a click opens the alarm list,
    /// and a right click (or Control-click) opens the options.
    @objc private func statusItemClicked(_ sender: Any?) {
        if Ringer.shared.isRinging {
            Ringer.shared.stopAll()
            return
        }
        if let editor, editor.isOpen {
            editor.close()
            return
        }
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if rightClick {
            openMenu(buildOptionsMenu())
        } else {
            openAlarmMenu()
        }
    }

    private func openAlarmMenu() {
        openMenu(buildAlarmMenu())
    }

    private func openMenu(_ menu: NSMenu?) {
        guard let menu else { return }
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

    private func newMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if UserDefaults.standard.bool(forKey: "DingDark") {   // build machine screenshots only
            menu.appearance = NSAppearance(named: .darkAqua)
        }
        return menu
    }

    /// Right click: the options and Quit.
    private func buildOptionsMenu() -> NSMenu {
        let menu = newMenu()
        addOptions(to: menu)
        return menu
    }

    /// Click: the alarm list.
    private func buildAlarmMenu() -> NSMenu {
        let menu = newMenu()
        let alarms = sortedAlarms()

        if alarms.isEmpty {
            menu.addItem(timerItem(in: menu))   // the timer works without any alarm
            let item = NSMenuItem()
            item.view = EmptyStateView { [weak self, weak menu] in
                let anchor = menu?.items.first?.view?.window?.frame
                menu?.cancelTracking()
                DispatchQueue.main.async { self?.openEditor(nil, anchor: anchor) }
            }
            menu.addItem(item)
        } else {
            let header = NSMenuItem()
            let headerView = NextHeaderView(text: nextText())
            header.view = headerView
            menu.addItem(header)
            menu.addItem(timerItem(in: menu))
            let alarmsHeader = NSMenuItem()
            let addAction = { [weak self, weak menu] in
                let anchor = menu?.items.first?.view?.window?.frame   // where the list is on screen
                menu?.cancelTracking()
                DispatchQueue.main.async { self?.openEditor(nil, anchor: anchor) }
            }
            lastAddAction = addAction
            alarmsHeader.view = AlarmsHeaderView(onAdd: addAction)
            menu.addItem(alarmsHeader)

            for alarm in alarms {
                let id = alarm.id
                let item = NSMenuItem()
                item.view = AlarmRowView(
                    alarm: alarm,
                    detail: Format.subtitle(alarm),
                    onToggle: { [weak self, weak headerView] on in
                        AlarmStore.shared.setOn(id, on)
                        if !on { Engine.shared.cancelSnooze(id) }   // switched off: no snoozed ring either
                        if let self { headerView?.setText(self.nextText()) }
                        return AlarmStore.shared.alarm(id).map(Format.subtitle)
                    },
                    onOpen: { [weak self, weak menu] in
                        let anchor = menu?.items.first?.view?.window?.frame
                        menu?.cancelTracking()
                        DispatchQueue.main.async { self?.openEditor(id, anchor: anchor) }
                    })
                menu.addItem(item)
            }
            let spacer = NSMenuItem()
            spacer.view = MenuSpacerView(height: 8)
            menu.addItem(spacer)
        }
        return menu
    }

    /// The timer row. Picking a length starts the timer and closes the menu, so the countdown shows next
    /// to the bell; Stop stops it.
    private func timerItem(in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        let view = TimerSectionView(
            timer: Engine.shared.runningTimer,
            onStart: { [weak menu] length in
                Engine.shared.startTimer(length)
                menu?.cancelTracking()
            },
            onStop: { [weak menu] in
                Engine.shared.stopTimer()
                menu?.cancelTracking()
            })
        item.view = view
        timerSection = view
        return item
    }

    private func addOptions(to menu: NSMenu) {
        menu.addItem(NSMenuItem.sectionHeader(title: "Time format"))
        let uses24Hour = Settings.uses24Hour
        let twentyFour = NSMenuItem(title: "24-hour", action: #selector(use24Hour), keyEquivalent: "")
        twentyFour.target = self
        twentyFour.state = uses24Hour ? .on : .off
        menu.addItem(twentyFour)
        let twelve = NSMenuItem(title: "AM/PM", action: #selector(use12Hour), keyEquivalent: "")
        twelve.target = self
        twelve.state = uses24Hour ? .off : .on
        menu.addItem(twelve)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit Ding", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
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
        guard let soonest = Engine.shared.soonest() else { return "All alarms are off" }
        let snoozed = soonest.snoozed ? " (snoozed)" : ""
        return "Next: \(soonest.alarm.displayName) \(Format.when(soonest.time))\(snoozed)"
    }

    @objc private func use24Hour() {
        Settings.timeFormat = .twentyFourHour
        Format.reset()
        Engine.shared.recompute()
    }

    @objc private func use12Hour() {
        Settings.timeFormat = .twelveHour
        Format.reset()
        Engine.shared.recompute()
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        let turningOn = service.status != .enabled
        do {
            if turningOn {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            showLoginItemsHelp(
                "Ding couldn't turn \(turningOn ? "on" : "off") Open at login",
                "You can turn it \(turningOn ? "on" : "off") yourself in System Settings, under General → \(loginItemsPane).")
            return
        }
        if turningOn && service.status == .requiresApproval {
            showLoginItemsHelp(
                "Allow Ding to open at login",
                "Turn on Ding in System Settings, under General → \(loginItemsPane).")
        }
    }

    private var loginItemsPane: String {
        if #available(macOS 15.0, *) { return "Login Items & Extensions" }
        return "Login Items"
    }

    private func showLoginItemsHelp(_ message: String, _ details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: Editor

    private func openEditor(_ id: UUID?, anchor: NSRect? = nil) {
        editor?.close(restoreFocus: false)
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
        let controller = EditorController(alarm: alarm, isNew: isNew)
        controller.onFinish = { [weak self, weak controller] in
            if let self, self.editor === controller {
                self.editor = nil
            }
        }
        editor = controller
        controller.show(anchor: anchor, below: statusItem.button)
    }
}
