import AppKit
import PlayerLogic

private final class HoverTimestamp: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A thin seek line with a generous hit area, independent of the controls row.
final class ProgressView: NSControl {
    var interactionBegan: (() -> Void)?
    var positionChanged: ((Double) -> Void)?
    var interactionEnded: (() -> Void)?
    var activity: (() -> Void)?
    var hoverChanged: ((Bool) -> Void)?
    private(set) var position = 0.0
    private(set) var duration = 0.0
    private(set) var isDragging = false
    private(set) var isHovered = false
    private var pointer: NSPoint?
    private var tracking: NSTrackingArea?
    let hoverTime: NSTextField = HoverTimestamp(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        focusRingType = .none
        isEnabled = false
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Playback progress")
        setAccessibilityMinValue(0)
        toolTip = "Click to seek · Drag to scrub"
        hoverTime.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hoverTime.textColor = .white
        hoverTime.alignment = .center
        hoverTime.wantsLayer = true
        hoverTime.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        hoverTime.layer?.cornerRadius = 4
        hoverTime.isHidden = true
        hoverTime.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Leave room for the whole thumb at the stroke's endpoints.
    private var lineStart: CGFloat { 5 }
    private var lineEnd: CGFloat { max(lineStart, bounds.width - 5) }
    var trackWidth: CGFloat { lineEnd - lineStart + 3 }
    private var lineY: CGFloat { min(12, bounds.midY) }
    var thumbCenter: NSPoint {
        let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
        return NSPoint(x: lineStart + (lineEnd - lineStart) * fraction, y: lineY)
    }
    var hoverPosition: Double? {
        guard isEnabled, let pointer, isDragging || abs(pointer.y - lineY) <= 12 else { return nil }
        return Double(min(1, max(0, (pointer.x - lineStart) / max(1, lineEnd - lineStart)))) * duration
    }
    private func updateHoverTime() {
        guard let position = hoverPosition, let pointer else { hoverTime.isHidden = true; return }
        hoverTime.stringValue = PlaybackTime.string(position)
        let width = hoverTime.intrinsicContentSize.width + 8
        let center = min(bounds.width - width / 2, max(width / 2, pointer.x))
        let rect = NSRect(x: center - width / 2, y: lineY + 34, width: width, height: 18)
        hoverTime.frame = convert(rect, to: superview)
        hoverTime.isHidden = false
    }
    override func layout() { super.layout(); updateHoverTime() }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    var isThumbVisible: Bool {
        guard isEnabled else { return false }
        if isDragging { return true }
        guard let pointer else { return false }
        return abs(pointer.x - thumbCenter.x) <= 18 && abs(pointer.y - thumbCenter.y) <= 12
    }

    func update(position: Double, duration: Double) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        if !isDragging { self.position = position.isFinite ? min(self.duration, max(0, position)) : 0 }
        isEnabled = self.duration > 0
        setAccessibilityMaxValue(self.duration)
        updateHoverTime()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawLine(from: lineStart, to: lineEnd, color: .white.withAlphaComponent(0.2))
        if position > 0 { drawLine(from: lineStart, to: thumbCenter.x, color: .white) }
        if isThumbVisible {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: thumbCenter.x - 5, y: thumbCenter.y - 5, width: 10, height: 10)).fill()
        }
    }
    private func drawLine(from start: CGFloat, to end: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: start, y: lineY))
        path.line(to: NSPoint(x: end, y: lineY))
        color.setStroke()
        path.stroke()
    }

    func beginInteraction(at point: NSPoint) {
        guard isEnabled, !isDragging else { return }
        window?.makeFirstResponder(superview)
        isDragging = true
        interactionBegan?()
        drag(to: point)
    }
    func drag(to point: NSPoint) {
        guard isDragging else { return }
        pointer = point
        let fraction = min(1, max(0, (point.x - lineStart) / max(1, lineEnd - lineStart)))
        position = Double(fraction) * duration
        positionChanged?(position)
        activity?()
        updateHoverTime()
        needsDisplay = true
    }
    func endInteraction() {
        guard isDragging else { return }
        isDragging = false
        interactionEnded?()
        activity?()
        updateHoverTime()
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { beginInteraction(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        drag(to: convert(event.locationInWindow, from: nil))
        endInteraction()
    }
    override func mouseMoved(with event: NSEvent) {
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }
    func pointerMoved(to point: NSPoint) {
        pointer = point
        activity?()
        updateHoverTime()
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        mouseMoved(with: event)
        hoverChanged?(true)
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        pointer = nil
        updateHoverTime()
        needsDisplay = true
        hoverChanged?(false)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func accessibilityValue() -> Any? { NSNumber(value: position) }
    override func accessibilityValueDescription() -> String? {
        "\(PlaybackTime.string(position)) of \(PlaybackTime.string(duration))"
    }
    override func setAccessibilityValue(_ value: Any?) {
        guard isEnabled, let value = value as? NSNumber, value.doubleValue.isFinite else { return }
        interactionBegan?()
        position = min(duration, max(0, value.doubleValue))
        positionChanged?(position)
        interactionEnded?()
        activity?()
        needsDisplay = true
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }
        setAccessibilityValue(NSNumber(value: position + 5))
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }
        setAccessibilityValue(NSNumber(value: position - 5))
        return true
    }
}
