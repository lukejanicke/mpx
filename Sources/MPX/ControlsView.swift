import AppKit
import PlayerLogic

final class SymbolButton: NSButton {
    var actionHandler: (() -> Void)?

    init(symbol: String, label: String, size: CGFloat = 20) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        focusRingType = .none
        contentTintColor = .white
        alphaValue = 1
        wantsLayer = true
        setSymbol(symbol, size: size)
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(performAction)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 34), heightAnchor.constraint(equalToConstant: 36)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setSymbol(_ symbol: String, size: CGFloat = 20) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.transform = CATransform3DMakeTranslation(0, flag ? -1 : 0, 0)
    }
    @objc private func performAction() { actionHandler?() }
}

private final class TimeButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.transform = CATransform3DMakeTranslation(0, flag ? -1 : 0, 0)
    }
}

final class ControlsView: NSView {
    let play = SymbolButton(symbol: "play.fill", label: "Play / Pause (Space)", size: 23)
    private let volume = NSImageView()
    let fullscreen = SymbolButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Toggle Full Screen (Control–Command–F)", size: 18)
    private let time = TimeButton(title: "00:00:00 / 00:00:00", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private(set) var transport: NSStackView!
    private(set) var utilities: NSStackView!
    private(set) var isCompact = false
    var timeFrame: NSRect { time.frame }
    var hoverChanged: ((Bool) -> Void)?
    var timeClicked: (() -> Void)?
    private(set) var isHovered = false

    init(start: @escaping () -> Void, back: @escaping () -> Void, toggle: @escaping () -> Void,
         forward: @escaping () -> Void, end: @escaping () -> Void, full: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        let beginning = SymbolButton(symbol: "backward.end.fill", label: "Go to Start (Option–Left Arrow)")
        let rewind = SymbolButton(symbol: "backward.fill", label: "Back 10 Seconds (Left Arrow)", size: 22)
        let advance = SymbolButton(symbol: "forward.fill", label: "Forward 10 Seconds (Right Arrow)", size: 22)
        let ending = SymbolButton(symbol: "forward.end.fill", label: "Go to End (Option–Right Arrow)")
        beginning.actionHandler = start; rewind.actionHandler = back; play.actionHandler = toggle
        advance.actionHandler = forward; ending.actionHandler = end
        fullscreen.actionHandler = full
        volume.contentTintColor = .white
        volume.alphaValue = 1
        volume.imageScaling = .scaleProportionallyDown
        volume.toolTip = "Volume: Up / Down · Mute: M"
        volume.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([volume.widthAnchor.constraint(equalToConstant: 34), volume.heightAnchor.constraint(equalToConstant: 36)])

        time.isBordered = false
        time.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        time.contentTintColor = .white
        time.alphaValue = 1
        time.focusRingType = .none
        time.toolTip = "Go to Time… (Shift–Command–G)"
        time.setAccessibilityLabel("Playback time. Click to go to a time.")
        time.target = self; time.action = #selector(goToTime)
        time.wantsLayer = true
        transport = NSStackView(views: [beginning, rewind, play, advance, ending])
        utilities = NSStackView(views: [volume, fullscreen])
        for stack in [transport!, utilities!] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            addSubview(stack)
        }
        transport.spacing = 10
        utilities.spacing = 8
        addSubview(time)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func goToTime() { timeClicked?() }

    /// The transport stays centred; time and utilities share the seek-line edges.
    /// In small windows the information moves above the buttons instead of
    /// scaling their symbols or click targets down.
    func height(for width: CGFloat) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let timeWidth = max(178, (time.title as NSString).size(withAttributes: [.font: font]).width + 8)
        return width >= 210 + 2 * (timeWidth + 20) ? 36 : 78
    }

    override func layout() {
        super.layout()
        isCompact = height(for: bounds.width) > 36
        transport.spacing = isCompact ? 8 : 10
        let transportWidth = transport.fittingSize.width
        let utilityWidth = utilities.fittingSize.width
        transport.frame = NSRect(x: bounds.midX - transportWidth / 2, y: 0, width: transportWidth, height: 36)
        time.font = .monospacedDigitSystemFont(ofSize: isCompact ? 11 : 13, weight: .medium)
        time.alignment = .left
        let timeWidth = max(isCompact ? 150 : 178, time.intrinsicContentSize.width)
        let informationY: CGFloat = isCompact ? 42 : 0
        time.frame = NSRect(x: 0, y: informationY, width: timeWidth, height: 36)
        utilities.frame = NSRect(x: bounds.width - utilityWidth, y: informationY, width: utilityWidth, height: 36)
    }

    func update(_ state: PlaybackSnapshot, displayedPosition: Double? = nil) {
        play.setSymbol(state.paused ? "play.fill" : "pause.fill", size: 23)
        play.setAccessibilityLabel(state.paused ? "Play" : "Pause")
        time.title = "\(PlaybackTime.string(displayedPosition ?? state.position)) / \(PlaybackTime.string(state.duration))"
        needsLayout = true
        let symbol = Self.volumeSymbol(volume: state.volume, muted: state.muted)
        volume.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        volume.setAccessibilityLabel(state.muted ? "Muted" : "Volume \(Int(state.volume))%")
    }

    func setFullscreen(_ value: Bool) {
        fullscreen.setSymbol(value ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", size: 18)
    }

    static func volumeSymbol(volume: Double, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume <= 25 { return "speaker.fill" }
        if volume <= 50 { return "speaker.wave.1.fill" }
        if volume <= 75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { isHovered = false; hoverChanged?(false) }
}

final class PlayerSurface: NSView {
    weak var player: PlayerWindowController?
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("Video")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseMoved(with event: NSEvent) { player?.showControls() }
    override func mouseEntered(with event: NSEvent) { player?.showControls() }
    override func mouseExited(with event: NSEvent) { player?.pointerLeft() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        player?.showControls()
        if event.clickCount == 2 { player?.toggleFullscreen() }
    }
    override func magnify(with event: NSEvent) {
        let position = convert(event.locationInWindow, from: nil)
        player?.zoom(by: max(0.01, 1 + event.magnification), anchor: CGPoint(x: position.x, y: bounds.height - position.y))
    }
    override func scrollWheel(with event: NSEvent) {
        player?.pan(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
    }
    override func layout() { super.layout(); player?.viewportChanged(bounds.size) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return droppedURL(sender) == nil ? [] : .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { droppedURL(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(sender) else { return false }
        player?.open(url)
        return true
    }
    private func droppedURL(_ sender: NSDraggingInfo) -> URL? {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first
    }
}

final class PlayerWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if (event.type == .keyDown || event.type == .keyUp), !(firstResponder is NSTextView),
           let player = windowController as? PlayerWindowController, player.handleKey(event) { return }
        super.sendEvent(event)
    }
}
