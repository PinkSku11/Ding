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

// MARK: - One alarm in the menu: its own bubble, with a switch on the right

final class AlarmRowView: NSView {
    private static let width: CGFloat = 352      // the menu stretches rows to its full width
    private static let height: CGFloat = 54
    private static let cardInset: CGFloat = 16    // equal space on both sides; right edge meets the dividers
    private static let textInset: CGFloat = 30    // same column as the menu's other text

    private let bubble = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let toggle: MenuSwitch
    private var trackingArea: NSTrackingArea?
    private var hovering = false {
        didSet { updateBubble() }
    }
    private let onToggle: (Bool) -> Void
    private let onOpen: () -> Void

    init(alarm: Alarm, detail: String, onToggle: @escaping (Bool) -> Void, onOpen: @escaping () -> Void) {
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

        let textWidth = toggle.frame.minX - 12 - AlarmRowView.textInset
        nameLabel.stringValue = alarm.displayName
        nameLabel.font = .menuFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: AlarmRowView.textInset, y: 28, width: textWidth, height: 17)
        nameLabel.autoresizingMask = [.width]
        addSubview(nameLabel)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: AlarmRowView.textInset, y: 11, width: textWidth, height: 15)
        detailLabel.autoresizingMask = [.width]
        addSubview(detailLabel)

        updateName(on: alarm.isOn)
        updateBubble()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateName(on: Bool) {
        nameLabel.textColor = on ? .labelColor : .secondaryLabelColor
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
        onToggle(on)
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
        update(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func update(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        let b = bounds
        track.frame = b
        track.cornerRadius = b.height / 2
        let inset: CGFloat = 2
        let knobHeight = b.height - inset * 2
        let knobWidth = knobHeight + 8          // a pill, like the Mac's own switches
        knob.bounds = CGRect(x: 0, y: 0, width: knobWidth, height: knobHeight)
        knob.cornerRadius = knobHeight / 2
        knob.position = CGPoint(x: isOn ? b.width - inset - knobWidth / 2 : inset + knobWidth / 2, y: b.midY)
        let on = isOn
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = on ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.2)
            self.track.backgroundColor = color.cgColor
        }
        CATransaction.commit()
        setAccessibilityValue(on)
    }

    override func layout() {
        super.layout()
        update(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(animated: false)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -6, dy: -6).contains(point) else { return }
        isOn.toggle()
        update(animated: true)
        onChange?(isOn)
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
}
