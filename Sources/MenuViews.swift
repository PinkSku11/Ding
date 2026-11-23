import AppKit

// MARK: - Menu bar icons

enum StatusIcon {
    static var bell: NSImage? { symbol("bell") }
    static var bellOff: NSImage? { symbol("bell.slash") }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Ding")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// The blue bell shown while an alarm rings. Clicking it stops the sound.
    static var ringing: NSImage {
        let size = NSSize(width: 36, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "bell.and.waves.left.and.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - s.width) / 2,
                                       y: (rect.height - s.height) / 2,
                                       width: s.width,
                                       height: s.height))
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Ding is ringing. Click to stop."
        return image
    }
}

// MARK: - Shared measurements, so everything in the menu lines up

enum MenuMetrics {
    static let width: CGFloat = 352      // the menu stretches rows to its full width
    static let cardInset: CGFloat = 16   // equal space on both sides; right edge meets the dividers
    static let textInset: CGFloat = 30   // same column as the menu's other text
    static let labelX: CGFloat = textInset - 2   // a text label draws its text 2 pt in from its frame
}

// MARK: - "Next: …" line with a divider under it

final class NextHeaderView: NSView {
    private let divider = NSView()
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        let width = MenuMetrics.width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 34))
        autoresizingMask = [.width]

        label.lineBreakMode = .byTruncatingTail
        label.attributedStringValue = NextHeaderView.styled(text)
        label.frame = NSRect(x: MenuMetrics.labelX, y: 14,
                             width: width - MenuMetrics.labelX - MenuMetrics.cardInset, height: 17)
        label.autoresizingMask = [.width]
        addSubview(label)

        divider.wantsLayer = true
        divider.frame = NSRect(x: MenuMetrics.textInset, y: 5,
                               width: width - MenuMetrics.textInset - MenuMetrics.cardInset, height: 1)
        divider.autoresizingMask = [.width]
        addSubview(divider)
        updateDivider()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Updates the line while the menu is open (after an alarm is switched on or off).
    func setText(_ text: String) {
        label.attributedStringValue = NextHeaderView.styled(text)
    }

    /// "Next:" softer, the alarm and its time in the normal text colour so they stand out.
    private static func styled(_ text: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 13)
        let prefix = "Next: "
        guard text.hasPrefix(prefix) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        let result = NSMutableAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        result.append(NSAttributedString(string: String(text.dropFirst(prefix.count)),
                                         attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        return result
    }

    private func updateDivider() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDivider()
    }
}

/// Empty space at the bottom of the list, so the last card has room around it like the sides.
final class MenuSpacerView: NSView {
    init(height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: height))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

// MARK: - "Alarms" heading with a + button on the right, in line with the switches

final class AlarmsHeaderView: NSView {
    init(onAdd: @escaping () -> Void) {
        let width = MenuMetrics.width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        autoresizingMask = [.width]

        let label = NSTextField(labelWithString: "Alarms")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.frame = NSRect(x: MenuMetrics.labelX, y: 4, width: 200, height: 14)
        addSubview(label)

        let plus = PlusButton(action: onAdd)
        plus.setFrameOrigin(NSPoint(x: width - MenuMetrics.textInset - plus.frame.width, y: 1))
        plus.autoresizingMask = [.minXMargin]
        addSubview(plus)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class PlusButton: NSView {
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?
    private var hovering = false {
        didSet { updateColor() }
    }

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 20))
        wantsLayer = true
        layer?.cornerRadius = 6          // a rounded rectangle, like the cards

        let icon = NSImageView(frame: bounds)
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleNone
        addSubview(icon)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("New alarm")
        updateColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateColor() {
        let alpha: CGFloat = hovering ? 0.18 : 0.09
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -4, dy: -4).contains(point) {
            action()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

// MARK: - Timer: one click on a length, other lengths with − and +, or the timer that's running

final class TimerSectionView: NSView {
    static let idleHeight: CGFloat = 72
    static let runningHeight: CGFloat = 90

    private let timer: DingTimer?
    private let onStart: (TimeInterval) -> Void
    private let onStop: () -> Void
    private let divider = NSView()
    private let bubble = NSView()
    private let presets = NSView()                             // 5 / 10 / 15 / 30 min and …
    private let other = NSView()                               // − 20 min +  Start
    private let otherLabel = NSTextField(labelWithString: "")
    private let leftLabel = NSTextField(labelWithString: "")   // "9:42 left"
    private var otherIndex: Int

    init(timer: DingTimer?, onStart: @escaping (TimeInterval) -> Void, onStop: @escaping () -> Void) {
        self.timer = timer
        self.onStart = onStart
        self.onStop = onStop
        let lastOther = UserDefaults.standard.integer(forKey: "timerOtherMinutes")
        otherIndex = DingTimer.lengths.firstIndex(of: lastOther) ?? DingTimer.lengths.firstIndex(of: 20) ?? 0
        let width = MenuMetrics.width
        let height = timer == nil ? TimerSectionView.idleHeight : TimerSectionView.runningHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        autoresizingMask = [.width]

        let title = NSTextField(labelWithString: "Timer")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .tertiaryLabelColor
        title.frame = NSRect(x: MenuMetrics.labelX, y: height - 20, width: 200, height: 14)
        addSubview(title)

        divider.wantsLayer = true
        divider.frame = NSRect(x: MenuMetrics.textInset, y: 5,
                               width: width - MenuMetrics.textInset - MenuMetrics.cardInset, height: 1)
        divider.autoresizingMask = [.width]
        addSubview(divider)

        if let timer {
            addRunning(timer)
        } else {
            addPresets()
            addOther()
        }
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The time left, while the menu is open.
    func refresh() {
        guard let timer else { return }
        leftLabel.stringValue = "\(Format.countdown(Int(ceil(timer.end.timeIntervalSinceNow)))) left"
    }

    private func addPresets() {
        presets.frame = NSRect(x: 0, y: 12, width: MenuMetrics.width, height: 36)
        presets.autoresizingMask = [.width]
        addSubview(presets)
        let inset = MenuMetrics.cardInset
        let gap: CGFloat = 6
        let moreWidth: CGFloat = 40
        let pillWidth = ((MenuMetrics.width - inset * 2 - moreWidth - gap * 4) / 4).rounded(.down)
        var x = inset
        for minutes in [5, 10, 15, 30] {
            let pill = PillButton(title: "\(minutes) min", width: pillWidth) { [weak self] in
                self?.onStart(TimeInterval(minutes * 60))
            }
            pill.setAccessibilityLabel("Start a \(minutes) min timer")
            pill.setFrameOrigin(NSPoint(x: x, y: 4))
            presets.addSubview(pill)
            x += pillWidth + gap
        }
        let more = PillButton(title: "…", width: moreWidth) { [weak self] in self?.showOther() }
        more.setAccessibilityLabel("Another length")
        more.setFrameOrigin(NSPoint(x: x, y: 4))
        presets.addSubview(more)
    }

    private func addOther() {
        other.frame = presets.frame
        other.autoresizingMask = [.width]
        other.isHidden = true
        addSubview(other)
        let inset = MenuMetrics.cardInset
        let minus = PillButton(symbol: "minus", width: 32) { [weak self] in self?.step(-1) }
        minus.setAccessibilityLabel("Shorter")
        minus.setFrameOrigin(NSPoint(x: inset, y: 4))
        other.addSubview(minus)
        otherLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        otherLabel.alignment = .center
        otherLabel.frame = NSRect(x: inset + 36, y: 9, width: 92, height: 17)
        other.addSubview(otherLabel)
        let plus = PillButton(symbol: "plus", width: 32) { [weak self] in self?.step(1) }
        plus.setAccessibilityLabel("Longer")
        plus.setFrameOrigin(NSPoint(x: inset + 132, y: 4))
        other.addSubview(plus)
        let start = AccentButton(title: "Start") { [weak self] in self?.startOther() }
        start.setFrameOrigin(NSPoint(x: MenuMetrics.width - inset - start.frame.width, y: 4))
        start.autoresizingMask = [.minXMargin]
        other.addSubview(start)
        showLength()
    }

    private func addRunning(_ timer: DingTimer) {
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.frame = NSRect(x: MenuMetrics.cardInset, y: 15,
                              width: MenuMetrics.width - MenuMetrics.cardInset * 2, height: 48)
        bubble.autoresizingMask = [.width]
        addSubview(bubble)

        let icon = NSImageView(frame: NSRect(x: MenuMetrics.textInset, y: 30, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        icon.contentTintColor = .labelColor
        addSubview(icon)

        let stop = PillButton(title: "Stop", width: 56) { [weak self] in self?.onStop() }
        stop.setAccessibilityLabel("Stop the timer")
        stop.setFrameOrigin(NSPoint(x: MenuMetrics.width - MenuMetrics.textInset - 56, y: 25))
        stop.autoresizingMask = [.minXMargin]
        addSubview(stop)

        let textX = MenuMetrics.labelX + 26
        let textWidth = stop.frame.minX - 10 - textX
        leftLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        leftLabel.frame = NSRect(x: textX, y: 40, width: textWidth, height: 17)
        leftLabel.autoresizingMask = [.width]
        addSubview(leftLabel)

        let detail = NSTextField(labelWithString: "\(Format.timerName(timer.length)) · rings at \(Format.time(timer.end))")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: textX, y: 23, width: textWidth, height: 15)
        detail.autoresizingMask = [.width]
        addSubview(detail)
        refresh()
    }

    private func showOther() {
        presets.isHidden = true
        other.isHidden = false
        RingLog.write("timer other")
    }

    private func step(_ by: Int) {
        otherIndex = min(max(otherIndex + by, 0), DingTimer.lengths.count - 1)
        showLength()
    }

    private func showLength() {
        otherLabel.stringValue = Format.length(TimeInterval(DingTimer.lengths[otherIndex] * 60))
    }

    private func startOther() {
        let minutes = DingTimer.lengths[otherIndex]
        UserDefaults.standard.set(minutes, forKey: "timerOtherMinutes")   // where − and + start next time
        onStart(TimeInterval(minutes * 60))
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
            self.bubble.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}

/// A small rounded button in the timer row: a word ("10 min", "Stop") or a symbol (− and +).
final class PillButton: NSView {
    private let action: () -> Void
    private var trackingArea: NSTrackingArea?
    private var hovering = false {
        didSet { updateColor() }
    }
    private var pressed = false {
        didSet { updateColor() }
    }

    init(title: String? = nil, symbol: String? = nil, width: CGFloat, action: @escaping () -> Void) {
        self.action = action
        let height: CGFloat = 28
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = height / 2

        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.alignment = .center
            label.sizeToFit()
            label.frame = NSRect(x: 0, y: ((height - label.frame.height) / 2).rounded(),
                                 width: width, height: label.frame.height)
            addSubview(label)
            setAccessibilityLabel(title)
        } else if let symbol {
            let icon = NSImageView(frame: bounds)
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            icon.contentTintColor = .labelColor
            icon.imageScaling = .scaleNone
            addSubview(icon)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateColor() {
        let alpha: CGFloat = pressed ? 0.26 : (hovering ? 0.18 : 0.09)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        let point = convert(event.locationInWindow, from: nil)
        if bounds.insetBy(dx: -3, dy: -3).contains(point) {
            action()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}

// MARK: - One alarm in the menu: its own bubble, with a switch on the right

final class AlarmRowView: NSView {
    private static let width = MenuMetrics.width
    private static let height: CGFloat = 54
    private static let cardInset = MenuMetrics.cardInset
    private static let textInset = MenuMetrics.textInset

    private let bubble = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let toggle: MenuSwitch
    private var trackingArea: NSTrackingArea?
    private var hovering = false {
        didSet { updateBubble() }
    }
    private let onToggle: (Bool) -> String?   // saves the switch; returns the alarm's details as they are now
    private let onOpen: () -> Void

    init(alarm: Alarm, detail: String, onToggle: @escaping (Bool) -> String?, onOpen: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        toggle = MenuSwitch(isOn: alarm.isOn)
        super.init(frame: NSRect(x: 0, y: 0, width: AlarmRowView.width, height: AlarmRowView.height))
        autoresizingMask = [.width]

        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.frame = NSRect(x: AlarmRowView.cardInset,
                              y: 3,
                              width: AlarmRowView.width - AlarmRowView.cardInset * 2,
                              height: AlarmRowView.height - 6)
        bubble.autoresizingMask = [.width]
        addSubview(bubble)

        toggle.setAccessibilityLabel(alarm.displayName)
        toggle.onChange = { [weak self] on in self?.switched(on) }
        let size = MenuSwitch.size
        toggle.frame = NSRect(x: AlarmRowView.width - AlarmRowView.textInset - size.width,
                              y: (AlarmRowView.height - size.height) / 2,
                              width: size.width,
                              height: size.height)
        toggle.autoresizingMask = [.minXMargin]
        addSubview(toggle)

        let textWidth = toggle.frame.minX - 12 - MenuMetrics.labelX
        nameLabel.stringValue = alarm.displayName
        nameLabel.font = .menuFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: MenuMetrics.labelX, y: 28, width: textWidth, height: 17)
        nameLabel.autoresizingMask = [.width]
        addSubview(nameLabel)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: MenuMetrics.labelX, y: 11, width: textWidth, height: 15)
        detailLabel.autoresizingMask = [.width]
        addSubview(detailLabel)

        updateName(on: alarm.isOn)
        updateBubble()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateName(on: Bool) {
        // An alarm that's off greys out completely, so you can tell at a glance.
        nameLabel.textColor = on ? .labelColor : .tertiaryLabelColor
        detailLabel.textColor = on ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func updateBubble() {
        let alpha: CGFloat = hovering ? 0.13 : 0.07
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.bubble.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBubble()
    }

    private func switched(_ on: Bool) {
        updateName(on: on)
        // Save once the knob has settled, so nothing on the main thread interrupts the animation.
        // A one-time alarm's details change too ("One time" becomes "Today only").
        let save = onToggle
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            if let detail = save(on) { self?.detailLabel.stringValue = detail }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggle.frame.insetBy(dx: -4, dy: -4).contains(point) { return }
        onOpen()
    }
}

// MARK: - The menu before any alarm exists

final class EmptyStateView: NSView {
    private let circle = NSView()
    private let onNew: () -> Void

    init(onNew: @escaping () -> Void) {
        self.onNew = onNew
        let width: CGFloat = 300
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 156))
        autoresizingMask = [.width]

        circle.wantsLayer = true
        circle.layer?.cornerRadius = 22
        circle.frame = NSRect(x: (width - 44) / 2, y: 98, width: 44, height: 44)
        circle.autoresizingMask = [.minXMargin, .maxXMargin]
        addSubview(circle)

        let bell = NSImageView(frame: NSRect(x: (width - 22) / 2, y: 109, width: 22, height: 22))
        bell.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        bell.contentTintColor = .labelColor
        bell.autoresizingMask = [.minXMargin, .maxXMargin]
        addSubview(bell)

        let title = NSTextField(labelWithString: "Set up your first alarm")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 62, width: width, height: 20)
        title.autoresizingMask = [.width]
        addSubview(title)

        let button = AccentButton(title: "New alarm") { [weak self] in self?.onNew() }
        button.setFrameOrigin(NSPoint(x: (width - button.frame.width) / 2, y: 16))
        button.autoresizingMask = [.minXMargin, .maxXMargin]
        addSubview(button)

        updateCircle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateCircle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.circle.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCircle()
    }
}

// MARK: - Switch for the alarm rows
// Draws itself, so "on" always shows your accent color. (A standard switch turns grey in a menu,
// because menus never become the active window.)

final class MenuSwitch: NSView {
    static let size = NSSize(width: 44, height: 22)

    private(set) var isOn: Bool
    var onChange: ((Bool) -> Void)?
    private let track = CALayer()
    private let knob = CALayer()
    private var pressed = false
    private var laidOutSize = NSSize.zero

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: MenuSwitch.size))
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        apply(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func knobRect() -> CGRect {
        let inset: CGFloat = 2
        let height = bounds.height - inset * 2
        let width = height + 8 + (pressed ? 5 : 0)   // a pill that stretches a little while held, like the Mac's own
        let x = isOn ? bounds.width - inset - width : inset
        return CGRect(x: x, y: inset, width: width, height: height)
    }

    private func trackColor() -> CGColor {
        var color = NSColor.clear.cgColor
        let on = isOn
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.2)).cgColor
        }
        return color
    }

    /// Moves the knob and recolours the track, animated with a soft spring like the system switch.
    private func apply(animated: Bool) {
        let rect = knobRect()
        let newPosition = CGPoint(x: rect.midX, y: rect.midY)
        let newBounds = CGRect(origin: .zero, size: rect.size)
        let newColor = trackColor()

        // Start from wherever the knob is on screen right now, so a quick second click stays smooth.
        let oldPosition = knob.presentation()?.position ?? knob.position
        let oldBounds = knob.presentation()?.bounds ?? knob.bounds
        let oldColor = track.presentation()?.backgroundColor ?? track.backgroundColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        track.backgroundColor = newColor
        knob.bounds = newBounds
        knob.position = newPosition
        knob.cornerRadius = rect.height / 2
        CATransaction.commit()

        if animated {
            knob.add(spring("position", from: NSValue(point: oldPosition), to: NSValue(point: newPosition)), forKey: "position")
            knob.add(spring("bounds", from: NSValue(rect: oldBounds), to: NSValue(rect: newBounds)), forKey: "bounds")
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = oldColor
            fade.toValue = newColor
            fade.duration = 0.25
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            track.add(fade, forKey: "backgroundColor")
        }
        setAccessibilityValue(isOn)
    }

    private func spring(_ keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.mass = 1
        animation.stiffness = 420
        animation.damping = 32
        animation.duration = animation.settlingDuration
        return animation
    }

    override func layout() {
        super.layout()
        guard bounds.size != laidOutSize else { return }   // only when the size really changes, never mid-animation
        laidOutSize = bounds.size
        apply(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        apply(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        let point = convert(event.locationInWindow, from: nil)
        let toggled = bounds.insetBy(dx: -6, dy: -6).contains(point)
        if toggled { isOn.toggle() }
        apply(animated: true)
        if toggled { onChange?(isOn) }
    }

    override func accessibilityPerformPress() -> Bool {
        isOn.toggle()
        apply(animated: true)
        onChange?(isOn)
        return true
    }
}

// MARK: - Blue pill button for the empty menu

final class AccentButton: NSView {
    private let label = NSTextField(labelWithString: "")
    private let action: () -> Void
    private var pressed = false {
        didSet { updateColor() }
    }

    init(title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 36, height: 28)
        setFrameSize(size)
        layer?.cornerRadius = size.height / 2
        label.frame = NSRect(x: 0,
                             y: ((size.height - label.frame.height) / 2).rounded(),
                             width: size.width,
                             height: label.frame.height)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        updateColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateColor() {
        let down = pressed
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = NSColor.controlAccentColor
            let fill = down ? (base.blended(withFraction: 0.2, of: .black) ?? base) : base
            self.layer?.backgroundColor = fill.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            action()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
