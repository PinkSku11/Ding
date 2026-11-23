import AppKit
import SwiftUI

// MARK: - Up and down arrows inside the editor's time and number boxes

/// The up and down arrows on the right of a box: like the Mac's own, without the line it draws between them.
/// A click steps once; holding the mouse button down keeps stepping.
final class StepArrows: NSView {
    static let width: CGFloat = 13
    var onStep: ((Bool) -> Void)?    // true: up
    var name = ""                    // the box's label, for the build machine's log
    private var held: Bool?          // the arrow being held down: true for up
    private var repeater: Timer?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: StepArrows.width, height: 22))
        setAccessibilityElement(true)
        setAccessibilityRole(.incrementor)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        for up in [true, false] {
            NSColor.labelColor.withAlphaComponent(held == up ? 0.35 : 1).setStroke()
            let center = NSPoint(x: bounds.midX, y: bounds.midY + (up ? -5 : 5))
            let tip: CGFloat = up ? -1.9 : 1.9
            let path = NSBezierPath()
            path.move(to: NSPoint(x: center.x - 3.6, y: center.y - tip))
            path.line(to: NSPoint(x: center.x, y: center.y + tip))
            path.line(to: NSPoint(x: center.x + 3.6, y: center.y - tip))
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let up = convert(event.locationInWindow, from: nil).y < bounds.midY
        held = up
        needsDisplay = true
        onStep?(up)
        repeater?.invalidate()
        let wait = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in self?.keepStepping() }
        RunLoop.main.add(wait, forMode: .common)
        repeater = wait
    }

    private func keepStepping() {
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let up = self.held, let window = self.window else { return }
            // Only while the pointer stays on the arrow being held, like the Mac's own.
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard self.bounds.contains(point), (point.y < self.bounds.midY) == up else { return }
            self.onStep?(up)
        }
        RunLoop.main.add(timer, forMode: .common)
        repeater = timer
    }

    override func mouseUp(with event: NSEvent) {
        stop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }

    private func stop() {
        repeater?.invalidate()
        repeater = nil
        held = nil
        needsDisplay = true
    }

    override func accessibilityPerformIncrement() -> Bool {
        onStep?(true)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onStep?(false)
        return true
    }

    /// The build machine's clicks: where each box's arrows are on screen, measured from the top left.
    static func logPositions(in view: NSView) {
        if let arrows = view as? StepArrows, let window = arrows.window {
            let rect = window.convertToScreen(arrows.convert(arrows.bounds, to: nil))
            let top = (NSScreen.screens.first?.frame.maxY ?? rect.maxY) - rect.maxY
            let name = arrows.name.replacingOccurrences(of: " ", with: "_")
            RingLog.write(String(format: "arrows %@ %.0f %.0f %.0f %.0f", name, rect.minX, top, rect.width, rect.height))
        }
        view.subviews.forEach { logPositions(in: $0) }
    }
}

// MARK: - The time boxes: From, Until and Time

/// The Mac's own time box, with Ding's arrows. As with the Mac's arrows, they change the hour or the minute you
/// clicked, or the hour if you haven't clicked either.
final class TimeBoxControl: NSDatePicker {
    var onChange: ((Date) -> Void)?
    let arrows = StepArrows()

    init() {
        super.init(frame: .zero)
        datePickerStyle = .textField   // the time without the Mac's arrows
        datePickerElements = .hourMinute
        target = self
        action = #selector(changed)
        arrows.onStep = { [weak self] up in self?.step(up) }
        addSubview(arrows)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let size = cell?.cellSize ?? super.intrinsicContentSize
        return NSSize(width: ceil(size.width) + StepArrows.width + 6, height: ceil(size.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrows.frame = NSRect(x: newSize.width - StepArrows.width - 5, y: 0, width: StepArrows.width, height: newSize.height)
    }

    @objc private func changed() {
        onChange?(dateValue)
    }

    /// Steps the hour or minute the way the arrow keys do, which is how the Mac's own arrows work.
    private func step(_ up: Bool) {
        guard let window else { return }
        if window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        let characters = String(utf16CodeUnits: [unichar(up ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)], count: 1)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: up ? 126 : 125) else { return }
        keyDown(with: event)
        changed()
    }
}

struct TimeBox: NSViewRepresentable {
    let label: String
    @Binding var date: Date

    func makeNSView(context: Context) -> TimeBoxControl {
        let box = TimeBoxControl()
        box.setAccessibilityLabel(label)
        box.arrows.name = label
        box.locale = context.environment.locale   // the 24-hour or AM/PM choice
        box.dateValue = date
        return box
    }

    func updateNSView(_ box: TimeBoxControl, context: Context) {
        let binding = $date
        box.onChange = { binding.wrappedValue = $0 }
        let locale = context.environment.locale
        if box.locale?.identifier != locale.identifier {
            box.locale = locale
            box.invalidateIntrinsicContentSize()
        }
        if Format.minute(of: box.dateValue) != Format.minute(of: date) {
            box.dateValue = date
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimeBoxControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

// MARK: - The number boxes: Every and Play sound

/// A box for a whole number, with arrows: type it, or click the arrows (hold to keep counting), or press ↑ and ↓.
/// Digits only, four at most.
final class NumberBoxControl: NSTextField, NSTextFieldDelegate {
    var onChange: ((Int) -> Void)?
    var minimum = 0
    let arrows = StepArrows()

    override class var cellClass: AnyClass? {
        get { RoomForArrowsCell.self }
        set {}
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .right
        placeholderString = "0"
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        delegate = self
        arrows.onStep = { [weak self] up in self?.step(up ? 1 : -1) }
        addSubview(arrows)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 0 shows as an empty box with a grey 0 in it.
    var value: Int {
        get { Int(stringValue) ?? 0 }
        set { stringValue = newValue == 0 ? "" : String(newValue) }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 70, height: super.intrinsicContentSize.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrows.frame = NSRect(x: newSize.width - StepArrows.width - 5, y: 0, width: StepArrows.width, height: newSize.height)
    }

    func controlTextDidChange(_ obj: Notification) {
        let digits = String(stringValue.filter { $0.isASCII && $0.isWholeNumber }.prefix(4))
        let number = Int(digits) ?? 0
        let tidy = number == 0 ? (digits.isEmpty ? "" : "0") : String(number)
        if tidy != stringValue {
            stringValue = tidy   // letters, leading zeros and a fifth digit don't go in
        }
        onChange?(number)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            step(1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            step(-1)
            return true
        default:
            return false
        }
    }

    private func step(_ by: Int) {
        let current = value
        if by < 0 && current <= minimum { return }   // as low as it goes
        let next = min(max(current + by, minimum), 9999)
        stringValue = String(next)
        onChange?(next)
    }
}

/// Keeps the digits clear of the arrows.
final class RoomForArrowsCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: rect)
        rect.size.width = max(0, rect.size.width - StepArrows.width - 4)
        return rect
    }
}

struct NumberBox: NSViewRepresentable {
    let label: String
    @Binding var value: Int
    var minimum = 0

    func makeNSView(context: Context) -> NumberBoxControl {
        let box = NumberBoxControl()
        box.setAccessibilityLabel(label)
        box.arrows.name = label
        box.minimum = minimum
        box.value = value
        return box
    }

    func updateNSView(_ box: NumberBoxControl, context: Context) {
        let binding = $value
        box.onChange = { binding.wrappedValue = $0 }
        box.minimum = minimum
        if box.value != value {
            box.value = value
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NumberBoxControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
