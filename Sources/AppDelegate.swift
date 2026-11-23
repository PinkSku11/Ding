import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var editor: EditorController?
    private var lastAddAction: (() -> Void)?   // the + in the most recent alarm list (used by the build machine's test)
    private var reopenListOpen = false   // a list away from the bell is on screen
    private var listComingBack: DispatchWorkItem?   // the list due back after the editor, until it shows

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
        Notifier.shared.onSnooze = { id, minutes in Engine.shared.snoozeNow(id, minutes: minutes) }
        Ringer.shared.onChange = { [weak self] in self?.refreshIcon() }
        AlarmStore.shared.onChange = { Engine.shared.recompute() }
        Engine.shared.onStateChange = { [weak self] in self?.refreshIcon() }
        Engine.shared.start()
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
                case "editor-arrows":   // the editor, and where its arrows are, for clicks on them
                    self?.openEditor(AlarmStore.shared.alarms.first?.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.editor?.logArrows() }
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
            self?.popUpList(at: NSEvent.mouseLocation)
        }
        return false
    }

    /// The alarm list with its top left corner at `point`: next to the pointer when Ding is opened again, or
    /// where it was before the editor. `fromBell`: it was the bell's list, so the bell shows as pressed again.
    private func popUpList(at point: NSPoint, fromBell: Bool = false) {
        cancelListComingBack()
        guard !reopenListOpen else { return }
        reopenListOpen = true
        RingLog.write("list shown | \(nextText())")
        if fromBell { statusItem.button?.highlight(true) }
        buildAlarmMenu(fromBell: fromBell).popUp(positioning: nil, at: point, in: nil)
        if fromBell { statusItem.button?.highlight(false) }
        reopenListOpen = false
    }

    // MARK: Menu bar icon

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let alarms = AlarmStore.shared.alarms
        if Ringer.shared.isRinging {
            button.image = StatusIcon.ringing
        } else if !alarms.isEmpty && !alarms.contains(where: { $0.isOn }) && !Engine.shared.hasSnoozes {
            button.image = StatusIcon.bellOff
        } else {
            button.image = StatusIcon.bell
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
        cancelListComingBack()
        RingLog.write("list shown | \(nextText())")
        openMenu(buildAlarmMenu(fromBell: true))
    }

    /// Another list or the editor opened first (a quick click on the bell after Save): the list doesn't come back too.
    private func cancelListComingBack() {
        listComingBack?.cancel()
        listComingBack = nil
    }

    /// Where an alarm list was, to show it there again when you're done in the editor.
    private struct ListPlace {
        let topLeft: NSPoint
        let fromBell: Bool
    }

    /// For the list's clicks that open the editor: the list to come back to afterwards.
    private func listPlace(fromBell: Bool, anchor: NSRect?) -> ListPlace? {
        anchor.map { ListPlace(topLeft: NSPoint(x: $0.minX, y: $0.maxY), fromBell: fromBell) }
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

    /// Click: the alarm list. When you're done in the editor opened from it, the list comes back.
    private func buildAlarmMenu(fromBell: Bool) -> NSMenu {
        let menu = newMenu()
        let alarms = sortedAlarms()

        if alarms.isEmpty {
            let item = NSMenuItem()
            item.view = EmptyStateView { [weak self, weak menu] in
                let anchor = menu?.items.first?.view?.window?.frame
                menu?.cancelTracking()
                let back = self?.listPlace(fromBell: fromBell, anchor: anchor)
                DispatchQueue.main.async { self?.openEditor(nil, anchor: anchor, backTo: back) }
            }
            menu.addItem(item)
        } else {
            let header = NSMenuItem()
            let headerView = NextHeaderView(text: nextText())
            header.view = headerView
            menu.addItem(header)
            let alarmsHeader = NSMenuItem()
            let addAction = { [weak self, weak menu] in
                let anchor = menu?.items.first?.view?.window?.frame   // where the list is on screen
                menu?.cancelTracking()
                let back = self?.listPlace(fromBell: fromBell, anchor: anchor)
                DispatchQueue.main.async { self?.openEditor(nil, anchor: anchor, backTo: back) }
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
                        let back = self?.listPlace(fromBell: fromBell, anchor: anchor)
                        DispatchQueue.main.async { self?.openEditor(id, anchor: anchor, backTo: back) }
                    })
                menu.addItem(item)
            }
            let spacer = NSMenuItem()
            spacer.view = MenuSpacerView(height: 8)
            menu.addItem(spacer)
        }
        return menu
    }

    /// Times follow the Mac's own format (System Settings → General → Date & Time), so there's nothing to pick here.
    private func addOptions(to menu: NSMenu) {
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

    private func openEditor(_ id: UUID?, anchor: NSRect? = nil, backTo list: ListPlace? = nil) {
        cancelListComingBack()
        editor?.close(restoreFocus: false)
        let alarm: Alarm
        let isNew: Bool
        if let id, let existing = AlarmStore.shared.alarm(id) {
            alarm = existing
            isNew = false
        } else {
            // A new alarm: no name yet, times at 00:00, no interval, and Glass played once at half volume.
            alarm = Alarm(name: "", kind: .once, fromMinute: 0, untilMinute: 0, every: 0, timeMinute: 0, days: [],
                          sound: "Glass", plays: 1, playUnit: .times, volume: 0.5, ringWhenMuted: false)
            isNew = true
        }
        let controller = EditorController(alarm: alarm, isNew: isNew)
        controller.onFinish = { [weak self, weak controller] done in
            guard let self else { return }
            if self.editor === controller {
                self.editor = nil
            }
            // Done (saved, cancelled or deleted): back to the list it was opened from, in the same place.
            // A moment later, so the key or click that closed the editor is over before the list opens.
            guard done, let list else { return }
            RingLog.write("editor done, back to the list")
            let back = DispatchWorkItem { [weak self] in self?.popUpList(at: list.topLeft, fromBell: list.fromBell) }
            self.listComingBack = back
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: back)
        }
        editor = controller
        controller.show(anchor: anchor, below: statusItem.button)
    }
}
