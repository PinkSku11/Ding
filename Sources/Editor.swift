import AppKit
import Combine
import SwiftUI

// MARK: - Editing state

final class EditorModel: ObservableObject {
    @Published var alarm: Alarm
    @Published var kind: AlarmKind?          // nothing chosen yet for a new alarm
    @Published var confirmingDelete = false
    var choosingFile = false                 // the file chooser is open; don't close on outside clicks
    let isNew: Bool

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

    var hasSoundToPlay: Bool {
        !alarm.sound.isEmpty && alarm.plays > 0 && alarm.volume > 0
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

                    LabeledContent("Rings") {
                        KindPicker(kind: $model.kind)
                    }

                    if model.kind == .repeating {
                        DatePicker("From", selection: minuteBinding(\.fromMinute), displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: minuteBinding(\.untilMinute), displayedComponents: .hourAndMinute)
                        LabeledContent("Every") {
                            HStack(spacing: 6) {
                                NumberField(value: $model.alarm.every)
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
                        DatePicker("Time", selection: minuteBinding(\.timeMinute), displayedComponents: .hourAndMinute)
                    }

                    LabeledContent("Days") {
                        DaysPicker(days: $model.alarm.days)
                    }

                    LabeledContent("Sound") {
                        HStack(spacing: 6) {
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
                    }

                    LabeledContent("Play sound") {
                        HStack(spacing: 6) {
                            NumberField(value: $model.alarm.plays)
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
                            Slider(value: $model.alarm.volume, in: 0...1)
                                .frame(width: 210)
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Ring even when muted", isOn: $model.alarm.ringWhenMuted)
                        .toggleStyle(.switch)

                    Toggle("Keep Mac awake", isOn: $model.alarm.keepAwake)
                        .toggleStyle(.switch)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .scrollIndicators(.never)
            .frame(height: formHeight)

            HStack(spacing: 8) {
                if model.confirmingDelete {
                    Text(verbatim: "Delete \(model.alarm.displayName)?")
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
                        Button(role: .destructive) {
                            model.confirmingDelete = true
                        } label: {
                            Text("Delete").foregroundStyle(.red)
                        }
                    }
                    Button("Cancel", action: onCancel)
                    Button("Save", action: onSave)
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
        case .some(.repeating): return 497
        case .some(.once): return 415
        case .none: return 375
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
            get: { model.alarm.sound },
            set: { newValue in
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

    /// Plays the chosen sound right away, the way the alarm is set to play it.
    /// While Play sound or Volume are still 0, it plays once at half volume so you can hear it.
    private func playSample() {
        guard !model.alarm.sound.isEmpty else {
            Ringer.shared.stopPreview()
            return
        }
        var sample = model.alarm
        if sample.plays <= 0 {
            sample.plays = 1
            sample.playUnit = .times
        }
        if sample.volume <= 0 {
            sample.volume = 0.5
        }
        Ringer.shared.preview(sample) {}
    }
}

// MARK: - A small number box that updates the alarm as you type

struct NumberField: View {
    @Binding var value: Int
    @State private var text = ""

    var body: some View {
        TextField("", text: $text, prompt: Text("0"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 54)
            .onAppear { text = value == 0 ? "" : String(value) }
            .onChange(of: text) { _, newText in
                let digits = String(newText.filter { $0.isASCII && $0.isNumber }.prefix(4))
                let number = Int(digits) ?? 0
                let tidy = number == 0 ? (digits.isEmpty ? "" : "0") : String(number)
                if tidy != newText { text = tidy }
                value = number
            }
    }
}

// MARK: - "Several times a day" / "Once a day", each in its own bubble like the days

struct KindPicker: View {
    @Binding var kind: AlarmKind?

    var body: some View {
        HStack(spacing: 6) {
            pill("Repeating", .repeating)
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
                let state: String = on ? "On" : "Off"
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
                .accessibilityValue(state)
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
    var onFinish: (() -> Void)?
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
                              onCancel: { [weak self] in self?.close() },
                              onDelete: { [weak self] in self?.delete() })
        let hosting = NSHostingView(rootView: view)
        self.hosting = hosting
        panel.contentView = EditorController.background(around: hosting)
        panel.onEscape = { [weak self] in self?.close() }
        // Switching between "Several times a day" and "Once a day" changes the height; keep the top in place.
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
        let screen = button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
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

    func close(restoreFocus: Bool = true) {
        guard opened else { return }
        opened = false
        stopWatching()
        Ringer.shared.stopPreview()
        panel.orderOut(nil)
        // Ding only becomes the active app if you used the file chooser; then hand the keyboard back.
        if restoreFocus && NSApp.isActive, let app = previousApp, !app.isTerminated {
            app.activate(options: [])
        }
        onFinish?()
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
        close()
    }

    private func delete() {
        AlarmStore.shared.delete(model.alarm.id)
        close()
    }
}
