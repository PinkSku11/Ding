import AppKit
import SwiftUI

// MARK: - Up and down arrows inside the editor's time and number boxes

/// The up and down arrows on the right of a box: like the Mac's own, without the line it draws between them.
/// A click steps once; holding the mouse button down keeps stepping. The pointer stays an arrow over them.
final class StepArrows: NSView {
    static let width: CGFloat = 13
    static let rightMargin: CGFloat = 4   // from the box's right edge
    var onStep: ((Bool) -> Void)?    // true: up
    var name = ""                    // the box's label, for the build machine's log
    private var held: Bool?          // the arrow being held down: true for up
    private var repeater: Timer?
    private var cursorArea: NSTrackingArea?

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

    // The box around the arrows shows the text cursor; over the arrows it's the normal pointer.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = cursorArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let up = convert(event.locationInWindow, from: nil).y < bounds.midY
        logPosition("clicked")   // the build machine checks the arrows stay put
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

    /// For the build machine: where these arrows are on screen, measured from the top left.
    private func logPosition(_ what: String) {
        guard let window else { return }
        let rect = window.convertToScreen(convert(bounds, to: nil))
        let top = (NSScreen.screens.first?.frame.maxY ?? rect.maxY) - rect.maxY
        let label = name.replacingOccurrences(of: " ", with: "_")
        RingLog.write(String(format: "%@ %@ %.0f %.0f %.0f %.0f", what, label, rect.minX, top, rect.width, rect.height))
    }

    /// The build machine's clicks: where each box's arrows are.
    static func logPositions(in view: NSView) {
        (view as? StepArrows)?.logPosition("arrows")
        view.subviews.forEach { logPositions(in: $0) }
    }
}

// MARK: - A box with arrows: what the time and number boxes are made of

/// A text box with StepArrows on its right. The text stays clear of the arrows, and the text cursor shows only over
/// the text.
class ArrowBox: NSTextField {
    let arrows = StepArrows()

    override class var cellClass: AnyClass? {
        get { RoomForArrowsCell.self }
        set {}
    }

    init(width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 22))
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .roundedBezel
        alignment = .right
        font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        addSubview(arrows)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        arrows.frame = NSRect(x: newSize.width - StepArrows.width - StepArrows.rightMargin, y: 0,
                              width: StepArrows.width, height: newSize.height)
    }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 0, width: arrows.frame.minX, height: bounds.height), cursor: .iBeam)
    }

    override func cursorUpdate(with event: NSEvent) {
        if arrows.frame.contains(convert(event.locationInWindow, from: nil)) {
            NSCursor.arrow.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }
}

/// Keeps the text clear of the arrows.
final class RoomForArrowsCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: rect)
        rect.size.width = max(0, rect.size.width - StepArrows.width - 3)
        return rect
    }
}

// MARK: - The time boxes: From, Until and Time

/// A time, written the Mac's way ("21:30" or "9:30 PM"). Type a time, or click the arrows (hold to keep going), or
/// press ↑ and ↓. Like the Mac's own time boxes, the arrows change the hour, or the minutes when the cursor is in
/// them (or AM/PM when it's there), and the part they change is selected.
final class TimeBoxControl: ArrowBox, NSTextFieldDelegate {
    var onChange: ((Int) -> Void)?
    private(set) var minute = 0   // minutes after midnight
    private enum Part { case hour, minute, half }

    init() {
        super.init(width: TimeBoxControl.width)
        delegate = self
        arrows.onStep = { [weak self] up in self?.step(up) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Wide enough for the longest time the Mac's way, such as "12:58 PM", with room for the arrows.
    static var width: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let widest = [0, 10 * 60 + 58, 12 * 60 + 58, 23 * 60 + 58]
            .map { (Format.time(minute: $0) as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 60
        return ceil(widest) + 34
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: TimeBoxControl.width, height: 22)
    }

    func show(_ minute: Int) {
        self.minute = minute
        stringValue = Format.time(minute: minute)
    }

    /// Each key you type: a time that makes sense counts straight away, so Save (or Return) keeps it.
    func controlTextDidChange(_ obj: Notification) {
        let symbols = DateFormatter()
        guard let typed = TimeText.minute(from: stringValue, am: symbols.amSymbol, pm: symbols.pmSymbol) else { return }
        minute = typed
        onChange?(typed)
    }

    /// Leaving the box: the time written the Mac's way, or back to the last time that made sense.
    func controlTextDidEndEditing(_ obj: Notification) {
        stringValue = Format.time(minute: minute)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            step(true)
            return true
        case #selector(NSResponder.moveDown(_:)):
            step(false)
            return true
        default:
            return false
        }
    }

    private func step(_ up: Bool) {
        guard let window else { return }
        var part = Part.hour
        if let editor = currentEditor() {
            part = self.part(at: editor.selectedRange.location, in: editor.string)
        } else {
            window.makeFirstResponder(self)   // like the Mac's own: the box takes the keyboard, the hour chosen
        }
        var hour = minute / 60
        var minutes = minute % 60
        switch part {
        case .hour: hour = (hour + (up ? 1 : 23)) % 24
        case .minute: minutes = (minutes + (up ? 1 : 59)) % 60   // like the Mac's own, the hour stays
        case .half: hour = (hour + 12) % 24
        }
        show(hour * 60 + minutes)
        onChange?(minute)
        choose(part)
    }

    private func part(at location: Int, in text: String) -> Part {
        guard let parts = TimeText.parts(of: text) else { return .hour }
        if location >= parts.minute.location && location <= NSMaxRange(parts.minute) { return .minute }
        if let half = TimeText.half(in: text), location >= half.location && location <= NSMaxRange(half) { return .half }
        return .hour
    }

    /// Selects the part the arrows just changed, as the Mac's own time boxes do.
    private func choose(_ part: Part) {
        guard let editor = currentEditor(), let parts = TimeText.parts(of: editor.string) else { return }
        switch part {
        case .hour: editor.selectedRange = parts.hour
        case .minute: editor.selectedRange = parts.minute
        case .half: editor.selectedRange = TimeText.half(in: editor.string) ?? parts.hour
        }
    }
}

struct TimeBox: NSViewRepresentable {
    let label: String
    @Binding var minute: Int

    func makeNSView(context: Context) -> TimeBoxControl {
        let box = TimeBoxControl()
        box.setAccessibilityLabel(label)
        box.arrows.name = label
        box.show(minute)
        return box
    }

    func updateNSView(_ box: TimeBoxControl, context: Context) {
        let binding = $minute
        box.onChange = { binding.wrappedValue = $0 }
        if box.minute != minute && box.currentEditor() == nil {
            box.show(minute)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimeBoxControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

// MARK: - The number boxes: Every and Play sound

/// A box for a whole number, with arrows: type it, or click the arrows (hold to keep counting), or press ↑ and ↓.
/// Digits only, four at most.
final class NumberBoxControl: ArrowBox, NSTextFieldDelegate {
    var onChange: ((Int) -> Void)?
    var minimum = 0

    init() {
        super.init(width: 70)
        placeholderString = "0"
        delegate = self
        arrows.onStep = { [weak self] up in self?.step(up ? 1 : -1) }
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
        NSSize(width: 70, height: 22)   // as tall as the time boxes
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
