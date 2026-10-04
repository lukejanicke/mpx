import AppKit
import PlayerLogic

final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    let engine: PlaybackEngine
    let video: VideoView
    let surface: PlayerSurface
    private(set) var fileURL: URL?
    private(set) var snapshot = PlaybackSnapshot()
    private(set) var tracks: [MediaTrack] = []
    private var controls: ControlsView!
    let progress = ProgressView(frame: .zero)
    private var scrubPosition: Double?
    private var beforeScrubPaused = true
    private var scrubLastSeek = 0.0
    private var scrubSeekWork: DispatchWorkItem?
    private let feedback = NSTextField(labelWithString: "")
    private var feedbackWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var historyTimer: Timer?
    private var scanTimer: Timer?
    private var gesture: ScanGesture?
    private var scanActive = false
    private var scanPosition = 0.0
    private var scanLastTick = 0.0
    private var beforeScanPaused = true
    private var beforeScanMuted = false
    private var zoomState = VideoTransform()
    private var loading = false
    private var fittedVideoSize: CGSize?
    private var fullscreenTransition = false
    private var stopped = false
    private let history: HistoryStore
    var onClose: ((PlayerWindowController) -> Void)?

    init(windowSize: NSSize? = nil, history: HistoryStore = .shared) throws {
        self.history = history
        let screen = NSScreen.main ?? NSScreen.screens.first
        let width = (screen?.frame.width ?? 1920) / 2
        let windowSize = windowSize ?? NSSize(width: width, height: width * 9 / 16)
        engine = try PlaybackEngine()
        guard let display = VideoView(surfaceSize: windowSize) else {
            engine.shutdown()
            throw MPXError.playback("Could not create the video display.")
        }
        video = display
        surface = PlayerSurface(frame: NSRect(origin: .zero, size: windowSize))
        let window = PlayerWindow(contentRect: surface.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = "mpx"
        window.backgroundColor = .black
        window.contentMinSize = NSSize(width: min(280, windowSize.width), height: min(280, windowSize.width) * 9 / 16)
        window.contentAspectRatio = NSSize(width: 16.0 / 9.0, height: 1)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = surface
        super.init(window: window)
        window.delegate = self
        surface.player = self
        video.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(video)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            video.topAnchor.constraint(equalTo: surface.topAnchor),
            video.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        surface.layoutSubtreeIfNeeded()
        do { try video.connect(to: engine) } catch { video.shutdown(); engine.shutdown(); throw error }
        setupControls()
        setupFeedback()
        engine.onEvent = { [weak self] event in self?.receive(event) }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.savePosition() }
        if let historyTimer { RunLoop.main.add(historyTimer, forMode: .common) }
        if let screen {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2, y: visible.midY - window.frame.height / 2))
        } else { window.center() }
        window.makeFirstResponder(surface)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupControls() {
        controls = ControlsView(start: { [weak self] in self?.goToStart() }, back: { [weak self] in self?.skip(-10) },
                                toggle: { [weak self] in self?.togglePlayback() }, forward: { [weak self] in self?.skip(10) },
                                end: { [weak self] in self?.goToEnd() },
                                full: { [weak self] in self?.toggleFullscreen() })
        controls.hoverChanged = { [weak self] entered in if entered { self?.showControls() } else { self?.scheduleHide() } }
        controls.timeClicked = { [weak self] in self?.goToTime() }
        surface.addSubview(controls)
        surface.addSubview(progress)
        progress.interactionBegan = { [weak self] in self?.beginScrub() }
        progress.positionChanged = { [weak self] position in self?.scrub(to: position) }
        progress.interactionEnded = { [weak self] in self?.endScrub() }
        progress.activity = { [weak self] in self?.showControls() }
        progress.hoverChanged = { [weak self] entered in if entered { self?.showControls() } else { self?.scheduleHide() } }
        controls.translatesAutoresizingMaskIntoConstraints = true
        layoutControls()
        controls.isHidden = true
        progress.isHidden = true
    }

    private func setupFeedback() {
        feedback.translatesAutoresizingMaskIntoConstraints = false
        feedback.alignment = .center
        feedback.isSelectable = false
        surface.addSubview(feedback)
        feedback.centerXAnchor.constraint(equalTo: surface.centerXAnchor).isActive = true
        feedback.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        feedback.textColor = .white
        feedback.wantsLayer = true
        feedback.topAnchor.constraint(equalTo: surface.topAnchor, constant: 28).isActive = true
        feedback.isHidden = true
    }

    func open(_ url: URL) {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
            presentError("Choose a local video file.")
            return
        }
        progress.endInteraction()
        finishScan(cancelTap: true)
        savePosition()
        loading = true
        fittedVideoSize = nil
        fileURL = url.standardizedFileURL
        snapshot.position = history.position(for: url)
        snapshot.duration = 0
        snapshot.eof = false
        tracks = []
        zoomState.reset()
        applyTransform()
        window?.title = url.lastPathComponent
        window?.representedURL = url
        updateOverlay()
        controls.isHidden = false
        engine.load(url, resume: snapshot.position, volume: snapshot.volume, muted: snapshot.muted)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        showControls()
        window?.makeFirstResponder(surface)
    }

    private func receive(_ event: PlaybackEvent) {
        guard !stopped else { return }
        switch event {
        case .snapshot(let state):
            snapshot = state
            if zoomState.video != state.videoSize { zoomState.video = state.videoSize; zoomState.clamp(); applyTransform() }
            updateOverlay()
        case .loaded: loading = false; showControls()
        case .videoSize(let size):
            zoomState.video = size
            zoomState.clamp()
            applyTransform()
            if fittedVideoSize != size {
                fittedVideoSize = size
                fitWindow(to: size)
            }
            layoutControls()
        case .tracks(let tracks): self.tracks = tracks
        case .failure(let message):
            loading = false
            presentError(message)
        }
    }

    func togglePlayback() {
        guard fileURL != nil else { return }
        progress.endInteraction()
        finishScan(cancelTap: true)
        if snapshot.eof { engine.seek(0); snapshot.eof = false; snapshot.paused = true }
        snapshot.paused.toggle()
        engine.set("pause", snapshot.paused ? "yes" : "no")
        updateOverlay()
        showControls()
    }

    func skip(_ delta: Double) {
        guard fileURL != nil else { return }
        finishScan(cancelTap: true)
        seek(to: snapshot.position + delta)
        showFeedback(delta < 0 ? "−10 s" : "+10 s")
    }

    private func updateOverlay() {
        let position = scrubPosition ?? (scanActive ? scanPosition : snapshot.position)
        controls.update(snapshot, displayedPosition: position)
        progress.update(position: position, duration: snapshot.duration)
        layoutControls()
    }

    private func beginScrub() {
        guard fileURL != nil, snapshot.duration > 0 else { return }
        finishScan(cancelTap: true)
        beforeScrubPaused = snapshot.paused
        scrubPosition = snapshot.position
        scrubLastSeek = 0
        snapshot.paused = true
        engine.set("pause", "yes")
        updateOverlay()
        showControls()
    }
    private func scrub(to position: Double) {
        guard scrubPosition != nil else { return }
        let position = min(snapshot.duration, max(0, position))
        scrubPosition = position
        snapshot.eof = false
        // Limit preview requests while dragging; release always seeks exactly.
        let now = ProcessInfo.processInfo.systemUptime
        if now - scrubLastSeek >= 1.0 / 30 {
            scrubSeekWork?.cancel()
            scrubSeekWork = nil
            scrubLastSeek = now
            engine.seek(position)
        } else if scrubSeekWork == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self, let position = self.scrubPosition else { return }
                self.scrubSeekWork = nil
                self.scrubLastSeek = ProcessInfo.processInfo.systemUptime
                self.engine.seek(position)
            }
            scrubSeekWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30 - (now - scrubLastSeek), execute: work)
        }
        updateOverlay()
    }
    private func endScrub() {
        guard let position = scrubPosition else { return }
        scrubSeekWork?.cancel()
        scrubSeekWork = nil
        scrubPosition = nil
        snapshot.position = position
        snapshot.paused = beforeScrubPaused
        engine.seek(position)
        engine.set("pause", beforeScrubPaused ? "yes" : "no")
        updateOverlay()
        showControls()
    }

    private func seek(to position: Double) {
        guard snapshot.duration > 0 else { return }
        progress.endInteraction()
        snapshot.position = min(snapshot.duration, max(0, position))
        engine.seek(snapshot.position)
        updateOverlay()
        showControls()
    }

    func goToStart() { finishScan(cancelTap: true); seek(to: 0) }
    func goToEnd() { finishScan(cancelTap: true); seek(to: snapshot.duration); engine.set("pause", "yes") }
    func toggleMute() {
        guard fileURL != nil, !scanActive else { return }
        snapshot.muted.toggle()
        engine.set("mute", snapshot.muted ? "yes" : "no")
        updateOverlay()
        showFeedback(snapshot.muted ? "Muted" : "Unmuted")
        showControls()
    }
    func setVolume(_ value: Double) {
        guard fileURL != nil else { return }
        snapshot.volume = min(100, max(0, value))
        engine.set("volume", String(snapshot.volume))
        if !scanActive { snapshot.muted = false; engine.set("mute", "no") }
        updateOverlay()
        showFeedback("Volume \(Int(snapshot.volume))%")
        showControls()
        UserDefaults.standard.set(snapshot.volume, forKey: "volume")
    }

    func applySavedVolume() {
        if UserDefaults.standard.object(forKey: "volume") != nil { snapshot.volume = UserDefaults.standard.double(forKey: "volume") }
    }

    func toggleFullscreen() { showControls(); window?.toggleFullScreen(nil) }
    func resetZoom() { zoomState.reset(); applyTransform(); showFeedback("Fit"); showControls() }
    func zoomFromCenter(by factor: Double) {
        zoom(by: factor, anchor: CGPoint(x: surface.bounds.midX, y: surface.bounds.midY))
    }
    func zoom(by factor: Double, anchor: CGPoint) {
        guard fileURL != nil else { return }
        zoomState.zoom(by: factor, anchor: anchor)
        applyTransform()
        showFeedback(zoomState.scale == 1 ? "Fit" : "\(Int((zoomState.scale * 100).rounded()))%")
        showControls()
    }
    func pan(x: Double, y: Double) {
        guard fileURL != nil, zoomState.scale > 1 else { return }
        zoomState.pan(x: x, y: y)
        applyTransform()
        showControls()
    }
    func viewportChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        zoomState.viewport = size
        zoomState.clamp()
        applyTransform()
        layoutControls()
    }
    private func fitWindow(to videoSize: CGSize) {
        guard let window, videoSize.width > 0, videoSize.height > 0,
              !fullscreenTransition, !window.styleMask.contains(.fullScreen) else { return }
        let aspect = videoSize.width / videoSize.height
        let available = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let titleHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let maxHeight = max(1, available.height - titleHeight)
        let maxWidth = min(available.width, maxHeight * aspect)
        let minimumWidth = min(280, maxWidth)
        window.contentMinSize = NSSize(width: minimumWidth, height: minimumWidth / aspect)
        // Use a normalized ratio: raw pixel dimensions can impose coarse
        // integral resize steps in AppKit.
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        let width = min(maxWidth, max(minimumWidth, surface.bounds.width))
        let roundedWidth = width.rounded(.down)
        let size = NSSize(width: roundedWidth, height: min(maxHeight.rounded(.down), (roundedWidth / aspect).rounded()))
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: min(max(available.minX, center.x - frame.width / 2), available.maxX - frame.width),
                               y: min(max(available.minY, center.y - frame.height / 2), available.maxY - frame.height))
        window.setFrame(frame, display: true)
        surface.layoutSubtreeIfNeeded()
    }

    private func layoutControls() {
        guard let controls, surface.bounds.width > 0, surface.bounds.height > 0 else { return }
        let fitted = zoomState.fitted
        let videoWidth = fileURL == nil ? surface.bounds.width : fitted.width
        let videoHeight = fileURL == nil ? surface.bounds.height : fitted.height
        let width = videoWidth * 0.9
        let size = NSSize(width: width, height: controls.height(for: width))
        let inset = min(16, videoHeight * 0.05)
        controls.frame = NSRect(x: surface.bounds.midX - size.width / 2,
                               y: (surface.bounds.height - videoHeight) / 2 + inset,
                               width: size.width, height: size.height)
        controls.layoutSubtreeIfNeeded()
        // Seven extra hit-area points keep the thumb whole at either end;
        // the visible rounded stroke is exactly 90% of the video width.
        progress.frame = NSRect(x: surface.bounds.midX - (videoWidth * 0.9 + 7) / 2, y: controls.frame.maxY + 4,
                                width: videoWidth * 0.9 + 7, height: 44)
    }

    private func applyTransform() {
        engine.set("video-zoom", String(log2(zoomState.scale)))
        engine.set("video-pan-x", String(Double(zoomState.normalizedPan.x)))
        engine.set("video-pan-y", String(Double(zoomState.normalizedPan.y)))
    }

    func showControls() {
        guard fileURL != nil, !stopped else { return }
        hideWork?.cancel()
        controls.isHidden = false
        controls.layer?.removeAllAnimations()
        controls.alphaValue = 1
        progress.isHidden = false
        progress.layer?.removeAllAnimations()
        progress.alphaValue = 1
        scheduleHide()
    }
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.controls.isHovered, !self.progress.isHovered, !self.progress.isDragging, self.gesture == nil else { return }
            if let focus = self.window?.firstResponder as? NSView, focus.isDescendant(of: self.controls) { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
                self.controls.animator().alphaValue = 0
                self.progress.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.controls.alphaValue == 0 else { return }
                self.controls.isHidden = true
                self.progress.isHidden = true
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
    func pointerLeft() { if !controls.isHovered, !progress.isHovered { scheduleHide() } }
    private func showFeedback(_ text: String, persistent: Bool = false) {
        feedbackWork?.cancel()
        feedback.stringValue = text
        feedback.isHidden = false
        if !persistent {
            let work = DispatchWorkItem { [weak self] in self?.feedback.isHidden = true }
            feedbackWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        switch event.keyCode {
        case 123, 124:
            guard fileURL != nil else { return false }
            if modifiers.contains(.option) {
                if event.type == .keyDown, !event.isARepeat { event.keyCode == 123 ? goToStart() : goToEnd() }
            } else if event.type == .keyDown {
                if !event.isARepeat { beginScan(direction: event.keyCode == 123 ? -1 : 1) }
            } else if gesture?.direction == (event.keyCode == 123 ? -1 : 1) { finishScan(cancelTap: false) }
            return true
        case 49:
            if event.type == .keyDown, !event.isARepeat { togglePlayback() }
            return true
        case 126, 125:
            if event.type == .keyDown { setVolume(snapshot.volume + (event.keyCode == 126 ? 5 : -5)) }
            return true
        case 46:
            if event.type == .keyDown, !event.isARepeat { toggleMute() }
            return true
        case 53:
            if event.type == .keyDown {
                if gesture != nil { finishScan(cancelTap: true) }
                else if window?.styleMask.contains(.fullScreen) == true { toggleFullscreen() }
            }
            return true
        default: return false
        }
    }

    func beginScan(direction: Double) {
        progress.endInteraction()
        finishScan(cancelTap: true)
        guard snapshot.duration > 0 else { return }
        gesture = ScanGesture(direction: direction, started: ProcessInfo.processInfo.systemUptime)
        showControls()
        scanTimer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in self?.scanTick() }
        RunLoop.main.add(scanTimer!, forMode: .common)
    }
    private func scanTick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let gesture, let speed = gesture.speed(at: now) else { return }
        if !scanActive {
            scanActive = true
            beforeScanPaused = snapshot.paused
            beforeScanMuted = snapshot.muted
            scanPosition = snapshot.position
            scanLastTick = now
            engine.set("pause", "yes")
            engine.set("mute", "yes")
        }
        let dt = min(0.25, max(0, now - scanLastTick))
        scanLastTick = now
        scanPosition = min(snapshot.duration, max(0, scanPosition + gesture.direction * speed * dt))
        engine.seek(scanPosition, exact: speed <= 4)
        updateOverlay()
        showFeedback("\(gesture.direction < 0 ? "◀" : "▶") \(Int(speed))×", persistent: true)
    }
    func finishScan(cancelTap: Bool) {
        guard let gesture else { return }
        if !cancelTap, !scanActive, gesture.speed(at: ProcessInfo.processInfo.systemUptime) != nil { scanTick() }
        scanTimer?.invalidate(); scanTimer = nil
        self.gesture = nil
        if scanActive {
            scanActive = false
            snapshot.position = scanPosition
            snapshot.paused = beforeScanPaused
            snapshot.muted = beforeScanMuted
            engine.seek(scanPosition)
            engine.set("mute", beforeScanMuted ? "yes" : "no")
            engine.set("pause", beforeScanPaused ? "yes" : "no")
            feedback.isHidden = true
            updateOverlay()
        } else if !cancelTap {
            skip(gesture.direction * 10)
        }
        showControls()
    }

    func goToTime() {
        guard snapshot.duration > 0, let window else { return }
        finishScan(cancelTap: true)
        hideWork?.cancel()
        let alert = NSAlert()
        alert.messageText = "Go to Time"
        alert.informativeText = "Enter HH:MM:SS, MM:SS, or seconds."
        alert.addButton(withTitle: "Go"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = PlaybackTime.string(snapshot.position)
        field.setAccessibilityLabel("Time")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                if let time = PlaybackTime.parse(field.stringValue) { self.seek(to: time) }
                else { self.presentError("Enter a valid time, for example 01:23:45.") }
            }
            self.window?.makeFirstResponder(self.surface)
            self.showControls()
        }
    }

    func savePosition() {
        guard !loading, let fileURL else { return }
        history.save(fileURL, position: scrubPosition ?? (scanActive ? scanPosition : snapshot.position),
                                 duration: snapshot.duration, completed: snapshot.eof && !scanActive)
    }
    func shutdown() {
        guard !stopped else { return }
        progress.endInteraction()
        finishScan(cancelTap: true)
        savePosition()
        stopped = true
        historyTimer?.invalidate(); scanTimer?.invalidate()
        hideWork?.cancel(); feedbackWork?.cancel()
        engine.onEvent = nil
        video.shutdown()
        engine.shutdown()
    }
    func windowWillClose(_ notification: Notification) { shutdown(); onClose?(self) }
    func windowDidResignKey(_ notification: Notification) { progress.endInteraction(); finishScan(cancelTap: true) }
    func windowWillEnterFullScreen(_ notification: Notification) {
        fullscreenTransition = true
        window?.contentResizeIncrements = NSSize(width: 1, height: 1)
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        fullscreenTransition = false
        controls.setFullscreen(true)
        layoutControls()
        showControls()
    }
    func windowWillExitFullScreen(_ notification: Notification) { fullscreenTransition = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullscreenTransition = false
        fitWindow(to: fittedVideoSize ?? NSSize(width: 16, height: 9))
        controls.setFullscreen(false)
        showControls()
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullscreenTransition = false
        fitWindow(to: fittedVideoSize ?? NSSize(width: 16, height: 9))
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { fullscreenTransition = false }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "mpx"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
