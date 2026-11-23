import AppKit
import Combine
import SwiftUI

// MARK: - Editing state

final class EditorModel: ObservableObject {
    @Published var alarm: Alarm
    @Published var kind: AlarmKind?          // nothing chosen yet for a new alarm
    @Published var confirmingDelete = false
    @Published var isNew: Bool               // a new alarm, or a copy that isn't saved yet
    @Published var focusName = 0             // bumped to put the cursor in the name box
    @Published var note: String?             // why the sound you're trying is silent, shown for a few seconds
    private var noteTimer: DispatchWorkItem?
    var choosingFile = false                 // the file chooser is open; don't close on outside clicks

    init(alarm: Alarm, isNew: Bool) {
        self.alarm = alarm
        self.kind = isNew ? nil : alarm.kind
        self.isNew = isNew
    }

    /// An alarm can be saved once it knows how it rings.
    var canSave: Bool {
        switch kind {
        case .none: return false
        case .some(.repeating): return alarm.every > 0
        case .some(.once): return true
        }
    }

    func showNote(_ text: String?) {
        noteTimer?.cancel()
        note = text
        guard text != nil else { return }
        let timer = DispatchWorkItem { [weak self] in self?.note = nil }
        noteTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timer)   // long enough to notice after a pause
    }

    /// "Duplicate": the window becomes a new alarm with the same settings, named "… copy", ready to rename.
    /// Nothing is saved until you click Save, and the original stays as it was saved.
    func duplicate() {
        var copy = alarm
        copy.id = UUID()
        copy.name = Alarm.copyName(of: alarm.displayName, taken: Set(AlarmStore.shared.alarms.map(\.displayName)))
        copy.oneOffDay = nil   // a one-time copy works out its own day when saved
        alarm = copy
        confirmingDelete = false
        isNew = true
        focusName += 1
    }
}

// MARK: - The "New alarm" / "Edit alarm" window

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var systemSounds = SoundLibrary.system()
    @State private var customSounds = SoundLibrary.custom()
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: model.isNew ? "New alarm" : "Edit alarm")
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 16)

            Form {
                Section {
                    TextField("Name", text: $model.alarm.name, prompt: Text("Alarm"))
                        .focused($nameFocused)
                        .onChange(of: model.focusName) {
                            DispatchQueue.main.async { nameFocused = true }   // selects the name, ready to type over
                        }

                    LabeledContent("Rings") {
                        KindPicker(kind: $model.kind)
                    }

                    if model.kind == .repeating {
                        LabeledContent("From") {
                            TimeBox(label: "From", date: minuteBinding(\.fromMinute))
                        }
                        LabeledContent("Until") {
                            TimeBox(label: "Until", date: minuteBinding(\.untilMinute))
                        }
                        LabeledContent("Every") {
                            HStack(spacing: 6) {
                                NumberBox(label: "Every", value: $model.alarm.every, minimum: 1)
                                Picker("Every", selection: $model.alarm.everyUnit) {
                                    Text(verbatim: model.alarm.every == 1 ? "minute" : "minutes").tag(IntervalUnit.minutes)
                                    Text(verbatim: model.alarm.every == 1 ? "hour" : "hours").tag(IntervalUnit.hours)
                                }
                                .labelsHidden()
                                .fixedSize()
                                .padding(.trailing, -3)   // line the arrows up with the controls above and below
                            }
                        }
                    } else if model.kind == .once {
                        LabeledContent("Time") {
                            TimeBox(label: "Time", date: minuteBinding(\.timeMinute))
                        }
                    }

                    LabeledContent("Days") {
                        DaysPicker(days: $model.alarm.days)
                    }

                    LabeledContent("Sound") {
                        HStack(spacing: 8) {
                            if let note = model.note {
                                // Why the sound you just tried stayed quiet, beside the sound itself.
                                Text(verbatim: note)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)   // a long app name loses its middle, never "is using the mic"
                                    .help(note)
                                    .layoutPriority(-1)
                                    .transition(.opacity)
                            }
                            Picker("Sound", selection: soundBinding) {
                                Text("None").tag("")
                                Section("Mac sounds") {
                                    ForEach(systemSounds) { sound in
                                        Text(sound.name).tag(sound.id)
                                    }
                                }
                                Section("Your sounds") {
                                    ForEach(customSounds) { sound in
                                        Text(sound.name).tag(sound.id)
                                    }
                                    Text("Add sound file…").tag(SoundLibrary.addFileTag)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .padding(.trailing, -3)   // line the arrows up with the controls above and below
                        }
                        .animation(.easeInOut(duration: 0.2), value: model.note)
                    }

                    LabeledContent("Play sound") {
                        HStack(spacing: 6) {
                            NumberBox(label: "Play sound", value: $model.alarm.plays)
                            Picker("Play sound", selection: $model.alarm.playUnit) {
                                Text(verbatim: model.alarm.plays == 1 ? "time" : "times").tag(PlayUnit.times)
                                Text(verbatim: model.alarm.plays == 1 ? "second" : "seconds").tag(PlayUnit.seconds)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .padding(.trailing, -3)
                        }
                    }

                    LabeledContent("Volume") {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Slider(value: $model.alarm.volume, in: 0...1, onEditingChanged: { editing in
                                RingLog.write("slider \(editing ? "pressed" : "let go") at \(String(format: "%.2f", model.alarm.volume))")
                                if !editing { playAtNewVolume() }   // let go: hear how loud it is
                            })
                            .frame(width: 210)
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }

                    Toggle("Ring even when muted", isOn: $model.alarm.ringWhenMuted)
                        .toggleStyle(.switch)

                    Toggle("Keep Mac awake for this alarm", isOn: $model.alarm.keepAwake)
                        .toggleStyle(.switch)

                    Toggle("Keep in Notification Center", isOn: $model.alarm.keepNotification)
                        .toggleStyle(.switch)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .scrollIndicators(.never)
            .environment(\.locale, Settings.timeLocale)   // the time boxes follow the 24-hour / AM/PM choice
            .frame(height: formHeight)

            HStack(spacing: 8) {
                if model.confirmingDelete {
                    Text(verbatim: "Delete “\(model.alarm.displayName)”?")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.leading, 10)
                    Spacer()
                    Button("Cancel") { model.confirmingDelete = false }
                    Button(role: .destructive, action: onDelete) {
                        Text("Delete").foregroundStyle(.red)
                    }
                } else {
                    Spacer()
                    if !model.isNew {
                        Button("Duplicate") { model.duplicate() }
                            .keyboardShortcut("d", modifiers: .command)
                        Button(role: .destructive) {
                            model.confirmingDelete = true
                        } label: {
                            Text("Delete").foregroundStyle(.red)
                        }
                    }
                    Button("Cancel", action: onCancel)
                    Button("Save", action: onSave)
                        .keyboardShortcut(.defaultAction)   // Return saves, like other Mac windows
                        .disabled(!model.canSave)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 18)
        }
        .frame(width: 520)
    }

    private var formHeight: CGFloat {
        switch model.kind {
        case .some(.repeating): return 534
        case .some(.once): return 452
        case .none: return 412
        }
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<Alarm, Int>) -> Binding<Date> {
        Binding(
            get: { Format.date(minute: model.alarm[keyPath: keyPath]) },
            set: { model.alarm[keyPath: keyPath] = Format.minute(of: $0) }
        )
    }

    private var soundBinding: Binding<String> {
        Binding(
            get: {
                let id = model.alarm.sound
                if id.isEmpty || (customSounds + systemSounds).contains(where: { $0.id == id }) { return id }
                return SoundLibrary.fallbackID(in: systemSounds)   // its file is gone: show what plays instead
            },
            set: { newValue in
                RingLog.write("picked \(newValue) (was \(model.alarm.sound))")
                guard newValue == SoundLibrary.addFileTag else {
                    model.alarm.sound = newValue
                    playSample()
                    return
                }
                // Keep the current sound showing while the file chooser is open.
                let current = model.alarm.sound
                model.alarm.sound = current
                DispatchQueue.main.async {
                    model.choosingFile = true
                    let id = SoundLibrary.addFile()
                    model.choosingFile = false
                    if let id {
                        customSounds = SoundLibrary.custom()
                        model.alarm.sound = id
                        playSample()
                    }
                }
            }
        )
    }

    /// Plays the sound you just picked for as long as the alarm will play it (Play sound), at its volume.
    /// While Play sound or Volume is still 0 (a new alarm), it plays once, at half volume, so you can hear it.
    private func playSample() {
        guard !model.alarm.sound.isEmpty else {
            Ringer.shared.stopPreview(because: "None was picked")
            model.showNote(nil)
            return
        }
        var sample = model.alarm
        if sample.plays <= 0 {
            sample.plays = 1
            sample.playUnit = .times
        }
        if sample.volume <= 0 { sample.volume = 0.5 }
        model.showNote(Ringer.shared.preview(sample))
    }

    /// After you let go of the volume slider: the sound once, at the new volume (nothing at 0).
    private func playAtNewVolume() {
        guard !model.alarm.sound.isEmpty, model.alarm.volume > 0 else {
            Ringer.shared.stopPreview(because: "the volume went to 0")
            model.showNote(nil)
            return
        }
        var sample = model.alarm
        sample.plays = 1
        sample.playUnit = .times
        model.showNote(Ringer.shared.preview(sample))
    }
}

// MARK: - Rings "Repeatedly" / "Once", each in its own bubble like the days

struct KindPicker: View {
    @Binding var kind: AlarmKind?

    var body: some View {
        HStack(spacing: 6) {
            pill("Repeatedly", .repeating)
            pill("Once", .once)
        }
    }

    private func pill(_ title: String, _ value: AlarmKind) -> some View {
        let on = kind == value
        return Button {
            kind = value
        } label: {
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - S M T W T F S

struct DaysPicker: View {
    @Binding var days: Set<Int>

    private var order: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        let letters = Calendar.current.veryShortWeekdaySymbols
        let names = Calendar.current.weekdaySymbols
        HStack(spacing: 5) {
            ForEach(order, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on {
                        days.remove(day)
                    } else {
                        days.insert(day)
                    }
                } label: {
                    Text(verbatim: letters[day - 1])
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.18)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: - The panel that drops down from the bell, where the alarm list was

final class EditorPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        // Non-activating, like Spotlight: it takes clicks and typing while the app you were in stays active.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

final class EditorController: NSObject {
    /// Called once it has closed: true when through its own buttons (Save, Cancel, Delete) or Escape.
    var onFinish: ((_ done: Bool) -> Void)?
    private var opened = false
    /// Open and actually on screen.
    var isOpen: Bool { opened && panel.isVisible }
    private var previousApp: NSRunningApplication?   // the app you were using, to hand the keyboard back to
    private let model: EditorModel
    private let panel = EditorPanel()
    private var hosting: NSHostingView<EditorView>!
    private var anchorTop: CGFloat = 0
    private var mouseMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var kindWatcher: AnyCancellable?

    init(alarm: Alarm, isNew: Bool) {
        model = EditorModel(alarm: alarm, isNew: isNew)
        super.init()
        let view = EditorView(model: model,
                              onSave: { [weak self] in self?.save() },
                              onCancel: { [weak self] in self?.close(done: true) },
                              onDelete: { [weak self] in self?.delete() })
        let hosting = NSHostingView(rootView: view)
        self.hosting = hosting
        panel.contentView = EditorController.background(around: hosting)
        panel.onEscape = { [weak self] in self?.close(done: true) }
        // Switching between Repeatedly and Once changes the height; keep the top in place.
        kindWatcher = model.$kind.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }
    }

    /// The same glass as the menu (macOS 26 and later), or the menu material on older systems.
    private static func background(around content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 12
            glass.contentView = content
            // Clip the glass to the rounded shape. Unclipped, its blur filled the whole rectangle
            // and the shadow followed that rectangle, which showed as dark square corners.
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.cornerRadius = 12
            clip.layer?.cornerCurve = .continuous
            clip.layer?.masksToBounds = true
            glass.frame = clip.bounds
            glass.autoresizingMask = [.width, .height]
            clip.addSubview(glass)
            return clip
        }
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        content.frame = effect.bounds
        content.autoresizingMask = [.width, .height]
        effect.addSubview(content)
        return effect
    }

    /// Opens with its top-left corner where the alarm list was (`anchor`, the list's frame on screen),
    /// or right under the bell when there's no list.
    func show(anchor: NSRect?, below button: NSStatusBarButton?) {
        let size = fittingSize()
        let anchorScreen = anchor.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
        let screen = anchorScreen ?? button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var x = visible.maxX - size.width - 8
        var top = visible.maxY - 1
        if let anchor {
            x = anchor.minX
            top = anchor.maxY
        } else if let button, let barWindow = button.window {
            let buttonRect = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
            x = buttonRect.minX - 4
            top = barWindow.frame.minY - 1
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        top = min(top, visible.maxY)
        anchorTop = top
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)

        opened = true
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
        watchForOutsideClicks()
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.panel.invalidateShadow() }
        if !model.isNew {
            // Opening an existing alarm shouldn't select its name, so a stray key press can't replace it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.panel.makeFirstResponder(nil)
            }
        }
    }

    private func fittingSize() -> NSSize {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    private func fit() {
        guard opened else { return }
        let size = fittingSize()
        var frame = panel.frame
        frame.origin.y = anchorTop - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// Like the menu: a click in any other app (or the desktop), or switching to another app, closes it.
    private func watchForOutsideClicks() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeFromOutside()
        }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app != NSRunningApplication.current { self?.closeFromOutside() }
        }
    }

    private func stopWatching() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
        }
    }

    private func closeFromOutside() {
        if model.choosingFile { return }
        close()
    }

    func close(restoreFocus: Bool = true, done: Bool = false) {
        guard opened else { return }
        opened = false
        stopWatching()
        Ringer.shared.stopPreview()
        panel.orderOut(nil)
        // Ding only becomes the active app if you used the file chooser; then hand the keyboard back.
        if restoreFocus && NSApp.isActive, let app = previousApp, !app.isTerminated {
            app.activate(options: [])
        }
        onFinish?(done)
    }

    private func save() {
        guard model.canSave, let kind = model.kind else { return }
        var alarm = model.alarm
        alarm.kind = kind
        alarm.every = max(1, alarm.every)
        alarm.plays = max(0, alarm.plays)
        alarm.volume = max(0, min(1, alarm.volume))
        if alarm.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            alarm.name = "Alarm"
        }
        alarm.isOn = true   // saving an alarm sets it, like the Clock app
        AlarmStore.shared.save(alarm)
        close(done: true)
    }

    private func delete() {
        AlarmStore.shared.delete(model.alarm.id)
        close(done: true)
    }

    /// The Duplicate button's action, for the build machine's test.
    func duplicate() {
        model.duplicate()
    }

    /// Shows a note next to the sound, for the build machine's layout check.
    func showNote(_ text: String) {
        model.showNote(text)
    }

    /// Where the arrows of the time and number boxes are, for the build machine's clicks.
    func logArrows() {
        if let content = panel.contentView {
            StepArrows.logPositions(in: content)
        }
    }
}
