import AppKit
import SwiftUI

// MARK: - Editing state

final class EditorModel: ObservableObject {
    @Published var alarm: Alarm
    @Published var kind: AlarmKind?          // nothing chosen yet for a new alarm
    @Published var previewing = false
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
            Form {
                Section {
                    TextField("Name", text: $model.alarm.name, prompt: Text("Alarm"))

                    Picker("Rings", selection: $model.kind) {
                        Text("Several times a day").tag(AlarmKind?.some(.repeating))
                        Text("Once a day").tag(AlarmKind?.some(.once))
                    }
                    .pickerStyle(.segmented)

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

                            Button(action: togglePreview) {
                                if model.previewing {
                                    Label("Stop", systemImage: "stop.fill")
                                } else {
                                    Label("Preview", systemImage: "play.fill")
                                }
                            }
                            .disabled(!model.previewing && !model.hasSoundToPlay)
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
                                .frame(width: 170)
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundStyle(.secondary)
                            Text(verbatim: "\(Int((model.alarm.volume * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }

                    Toggle("Ring when Mac is muted", isOn: $model.alarm.ringWhenMuted)
                        .toggleStyle(.switch)
                }
            }
            .formStyle(.grouped)
            .frame(height: formHeight)

            HStack(spacing: 8) {
                Spacer()
                if !model.isNew {
                    Button(role: .destructive, action: onDelete) {
                        Text("Delete").foregroundStyle(.red)
                    }
                }
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .disabled(!model.canSave)
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 18)
        }
        .frame(width: 520)
    }

    private var formHeight: CGFloat {
        switch model.kind {
        case .some(.repeating): return 450
        case .some(.once): return 368
        case .none: return 328
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
                    return
                }
                // Keep the current sound showing while the file chooser is open.
                let current = model.alarm.sound
                model.alarm.sound = current
                DispatchQueue.main.async {
                    if let id = SoundLibrary.addFile() {
                        customSounds = SoundLibrary.custom()
                        model.alarm.sound = id
                    }
                }
            }
        )
    }

    private func togglePreview() {
        if model.previewing {
            Ringer.shared.stopPreview()
            model.previewing = false
            return
        }
        model.previewing = true
        let previewModel = model
        Ringer.shared.preview(model.alarm) {
            previewModel.previewing = false
        }
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

// MARK: - Window

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    var onFinish: (() -> Void)?
    private let model: EditorModel

    init(alarm: Alarm, isNew: Bool) {
        model = EditorModel(alarm: alarm, isNew: isNew)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = isNew ? "New alarm" : "Edit alarm"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let view = EditorView(model: model,
                              onSave: { [weak self] in self?.save() },
                              onCancel: { [weak self] in self?.close() },
                              onDelete: { [weak self] in self?.confirmDelete() })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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

    private func confirmDelete() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(model.alarm.displayName)?"
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let id = model.alarm.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            AlarmStore.shared.delete(id)
            self?.close()
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !model.isNew else { return }   // a new alarm starts with the cursor in Name
        // Opening an existing alarm shouldn't select its name, so a stray key press can't replace it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.window?.makeFirstResponder(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Ringer.shared.stopPreview()
        onFinish?()
    }
}
