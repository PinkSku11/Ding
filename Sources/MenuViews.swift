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
    private static let width: CGFloat = 340
    private static let height: CGFloat = 54

    private let bubble = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let toggle = NSSwitch()
    private var trackingArea: NSTrackingArea?
    private var hovering = false {
        didSet { updateBubble() }
    }
    private let onToggle: (Bool) -> Void
    private let onOpen: () -> Void

    init(alarm: Alarm, detail: String, onToggle: @escaping (Bool) -> Void, onOpen: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onOpen = onOpen
        super.init(frame: NSRect(x: 0, y: 0, width: AlarmRowView.width, height: AlarmRowView.height))

        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.frame = NSRect(x: 8, y: 3, width: AlarmRowView.width - 16, height: AlarmRowView.height - 6)
        addSubview(bubble)

        toggle.controlSize = .small
        toggle.state = alarm.isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(switched)
        toggle.setAccessibilityLabel(alarm.displayName)
        let size = toggle.fittingSize
        toggle.frame = NSRect(x: AlarmRowView.width - 22 - size.width,
                              y: (AlarmRowView.height - size.height) / 2,
                              width: size.width,
                              height: size.height)
        addSubview(toggle)

        let textWidth = toggle.frame.minX - 12 - 22
        nameLabel.stringValue = alarm.displayName
        nameLabel.font = .menuFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 22, y: 28, width: textWidth, height: 17)
        addSubview(nameLabel)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 22, y: 11, width: textWidth, height: 15)
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

    @objc private func switched() {
        let on = toggle.state == .on
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

        circle.wantsLayer = true
        circle.layer?.cornerRadius = 22
        circle.frame = NSRect(x: (width - 44) / 2, y: 98, width: 44, height: 44)
        addSubview(circle)

        let bell = NSImageView(frame: NSRect(x: (width - 22) / 2, y: 109, width: 22, height: 22))
        bell.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        bell.contentTintColor = .labelColor
        addSubview(bell)

        let title = NSTextField(labelWithString: "Set up your first alarm")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 62, width: width, height: 20)
        addSubview(title)

        let button = NSButton(title: "New alarm", target: self, action: #selector(newAlarm))
        button.bezelColor = .controlAccentColor
        button.sizeToFit()
        button.frame = NSRect(x: (width - button.frame.width - 16) / 2,
                              y: 18,
                              width: button.frame.width + 16,
                              height: button.frame.height)
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

    @objc private func newAlarm() {
        onNew()
    }
}
