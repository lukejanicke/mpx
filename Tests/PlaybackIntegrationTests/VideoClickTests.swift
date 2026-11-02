import AppKit
import XCTest
@testable import MPX

private final class FullscreenRecordingWindow: NSWindow {
    var fullscreenToggleCount = 0
    override func toggleFullScreen(_ sender: Any?) { fullscreenToggleCount += 1 }
}

final class VideoClickTests: XCTestCase {
    private var clickWait: TimeInterval { NSEvent.doubleClickInterval + 0.15 }

    private func makeLoadedPlayer() throws -> PlayerWindowController {
        guard let path = ProcessInfo.processInfo.environment["MPX_TEST_VIDEO_PATH"] else {
            throw XCTSkip("Set MPX_TEST_VIDEO_PATH to run video-click playback tests.")
        }
        _ = NSApplication.shared
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent("mpx-click-test-\(UUID().uuidString).json")
        let player: PlayerWindowController
        do {
            player = try PlayerWindowController(windowSize: NSSize(width: 960, height: 540),
                                                history: HistoryStore(file: historyURL))
        } catch let error as MPXError {
            if case .playback(let message) = error,
               message == "Could not create the video display.",
               ProcessInfo.processInfo.environment["MPX_ALLOW_NO_OPENGL_TESTS"] == "1" {
                throw XCTSkip("This runner cannot create accelerated OpenGL. Run video-click tests on a supported physical Mac.")
            }
            throw error
        }
        addTeardownBlock {
            player.shutdown()
            try? FileManager.default.removeItem(at: historyURL)
        }
        load(player, url: URL(fileURLWithPath: path))
        return player
    }

    private func load(_ player: PlayerWindowController, url: URL) {
        let ready = expectation(description: "Video is loaded and playing")
        let original = player.engine.onEvent
        var loaded = false
        var fulfilled = false
        player.engine.onEvent = { event in
            original?(event)
            if case .loaded = event { loaded = true }
            if case .snapshot(let state) = event, loaded, state.duration > 0,
               state.position > 0, !state.paused, !fulfilled {
                fulfilled = true
                ready.fulfill()
            }
            if case .failure(let message) = event { XCTFail(message) }
        }
        player.open(url)
        wait(for: [ready], timeout: 8)
        player.engine.onEvent = original
    }

    private func videoPoint(_ player: PlayerWindowController) -> NSPoint {
        NSPoint(x: player.surface.bounds.midX, y: player.surface.bounds.height * 0.75)
    }

    private func mouse(_ type: NSEvent.EventType, in player: PlayerWindowController,
                       at point: NSPoint, count: Int = 1,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: player.surface.convert(point, to: nil),
                          modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: player.surface.window!.windowNumber, context: nil,
                          eventNumber: 0, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func click(_ player: PlayerWindowController, at point: NSPoint? = nil, count: Int = 1) {
        let point = point ?? videoPoint(player)
        player.surface.mouseDown(with: mouse(.leftMouseDown, in: player, at: point, count: count))
        player.surface.mouseUp(with: mouse(.leftMouseUp, in: player, at: point, count: count))
    }

    private func recordFullscreen(_ player: PlayerWindowController) throws -> (PlayerWindow, FullscreenRecordingWindow) {
        let original = try XCTUnwrap(player.window as? PlayerWindow)
        let recorder = FullscreenRecordingWindow(contentRect: player.surface.frame,
                                                 styleMask: [.titled], backing: .buffered, defer: false)
        recorder.isReleasedWhenClosed = false
        // Keep the surface attached to the real input window; only fullscreen targets the recorder.
        player.window = recorder
        original.windowController = player
        addTeardownBlock {
            player.window = original
            original.windowController = player
        }
        return (original, recorder)
    }

    private func expectPause(_ paused: Bool, in player: PlayerWindowController, action: () -> Void) {
        let changed = expectation(description: "Playback pause becomes \(paused)")
        let original = player.engine.onEvent
        var fulfilled = false
        player.engine.onEvent = { event in
            original?(event)
            if case .snapshot(let state) = event, state.duration > 0, state.paused == paused, !fulfilled {
                fulfilled = true
                changed.fulfill()
            }
        }
        action()
        wait(for: [changed], timeout: clickWait + 5)
        player.engine.onEvent = original
        XCTAssertEqual(player.snapshot.paused, paused)
        assertCorePause(paused, in: player)
    }

    private func assertCorePause(_ paused: Bool, in player: PlayerWindowController) {
        let verified = expectation(description: "Playback core agrees with pause state")
        player.engine.inspectProperty("pause") { value in
            XCTAssertEqual(value as? Bool, paused)
            verified.fulfill()
        }
        wait(for: [verified], timeout: 5)
    }

    private func expectUnchanged(_ player: PlayerWindowController, action: () -> Void = {}) {
        let paused = player.snapshot.paused
        let unexpected = expectation(description: "Playback must retain its current state")
        unexpected.isInverted = true
        let original = player.engine.onEvent
        var fulfilled = false
        player.engine.onEvent = { event in
            original?(event)
            if case .snapshot(let state) = event, state.duration > 0, state.paused != paused, !fulfilled {
                fulfilled = true
                unexpected.fulfill()
            }
        }
        action()
        wait(for: [unexpected], timeout: clickWait)
        if player.engine.handle != nil { player.engine.onEvent = original }
        XCTAssertEqual(player.snapshot.paused, paused)
    }

    func testSingleClickTogglesImmediatelyOnRelease() throws {
        let player = try makeLoadedPlayer()
        let point = videoPoint(player)
        let down = mouse(.leftMouseDown, in: player, at: point)
        XCTAssertFalse(player.surface.acceptsFirstMouse(for: down),
                       "A click that only activates an inactive window must retain its existing behavior")
        expectUnchanged(player) {
            player.surface.mouseDown(with: down)
        }
        expectPause(true, in: player) {
            player.surface.mouseUp(with: mouse(.leftMouseUp, in: player, at: point))
            XCTAssertTrue(player.snapshot.paused, "Pausing must not wait for the double-click interval")
        }
        expectPause(false, in: player) {
            click(player)
            XCTAssertFalse(player.snapshot.paused, "Resuming must not wait for the double-click interval")
        }
    }

    func testDoubleClickRestoresOriginalPlaybackAndTogglesFullscreen() throws {
        let player = try makeLoadedPlayer()
        let (inputWindow, recorder) = try recordFullscreen(player)
        for paused in [false, true] {
            if player.snapshot.paused != paused { expectPause(paused, in: player) { player.togglePlayback() } }
            let before = recorder.fullscreenToggleCount
            expectPause(!paused, in: player) {
                click(player)
                XCTAssertEqual(player.snapshot.paused, !paused, "The first click still acts immediately")
            }
            let completed = expectation(description: "Second click restores playback and toggles fullscreen")
            let secondClick = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let point = self.videoPoint(player)
                let down = self.mouse(.leftMouseDown, in: player, at: point, count: 2)
                // A hidden test window does not route activation clicks. Exercise its
                // cancellation filter, then deliver the same press to the surface.
                inputWindow.sendEvent(down)
                player.surface.mouseDown(with: down)
                player.surface.mouseUp(with: self.mouse(.leftMouseUp, in: player, at: point, count: 2))
                XCTAssertEqual(player.snapshot.paused, paused)
                completed.fulfill()
            }
            defer { secondClick.cancel() }
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval / 2,
                                          execute: secondClick)
            wait(for: [completed], timeout: clickWait + 1)
            XCTAssertEqual(recorder.fullscreenToggleCount, before + 1)
            assertCorePause(paused, in: player)
        }
    }

    func testDoubleClickRestoresSavedStateDespiteAnOlderPlaybackSnapshot() throws {
        let player = try makeLoadedPlayer()
        let (_, recorder) = try recordFullscreen(player)
        for paused in [false, true] {
            if player.snapshot.paused != paused { expectPause(paused, in: player) { player.togglePlayback() } }
            let olderSnapshot = player.snapshot
            click(player)
            XCTAssertEqual(player.snapshot.paused, !paused)
            // An already-queued engine event can overwrite the optimistic first-click state.
            player.engine.onEvent?(.snapshot(olderSnapshot))
            XCTAssertEqual(player.snapshot.paused, paused)
            let before = recorder.fullscreenToggleCount
            click(player, count: 2)
            XCTAssertEqual(player.snapshot.paused, paused, "Restore the saved value rather than toggling a stale snapshot")
            XCTAssertEqual(recorder.fullscreenToggleCount, before + 1)
            assertCorePause(paused, in: player)
        }
    }

    func testDoubleClickRestoresPlaybackBeforeScrubbingOrScanning() throws {
        let player = try makeLoadedPlayer()
        _ = try recordFullscreen(player)
        player.progress.beginInteraction(at: player.progress.thumbCenter)
        XCTAssertTrue(player.snapshot.paused)
        click(player)
        XCTAssertTrue(player.snapshot.paused, "Ending the scrub restores playing, then the first click pauses")
        click(player, count: 2)
        XCTAssertFalse(player.snapshot.paused, "Restore playback from before the scrub")
        assertCorePause(false, in: player)

        let scanning = expectation(description: "Muted scan is active")
        let original = player.engine.onEvent
        var fulfilled = false
        player.engine.onEvent = { event in
            original?(event)
            if case .snapshot(let state) = event, state.paused, state.muted, !fulfilled {
                fulfilled = true
                scanning.fulfill()
            }
        }
        player.beginScan(direction: 1)
        wait(for: [scanning], timeout: 5)
        player.engine.onEvent = original
        click(player)
        XCTAssertTrue(player.snapshot.paused)
        XCTAssertFalse(player.snapshot.muted)
        click(player, count: 2)
        XCTAssertFalse(player.snapshot.paused, "Restore playback from before the scan")
        XCTAssertFalse(player.snapshot.muted)
        assertCorePause(false, in: player)
    }

    func testVisiblePanelPaddingIsExcludedButHiddenPanelLocationAcceptsClick() throws {
        let player = try makeLoadedPlayer()
        let panel = try XCTUnwrap(player.visibleControlsPanelFrame)
        let padding = NSPoint(x: panel.minX + 2, y: panel.minY + 2)
        XCTAssertTrue(player.surface.hitTest(padding) === player.surface,
                      "The background passes clicks through, so the surface must exclude visible panel padding")
        expectUnchanged(player) { click(player, at: padding) }

        // Reproduce the overlay's hidden state without waiting for its separate hide timer.
        for view in player.surface.subviews where view !== player.video { view.isHidden = true }
        XCTAssertNil(player.visibleControlsPanelFrame)
        expectPause(true, in: player) {
            player.surface.mouseDown(with: mouse(.leftMouseDown, in: player, at: padding))
            XCTAssertNotNil(player.visibleControlsPanelFrame, "The press immediately reveals the controls")
            player.surface.mouseUp(with: mouse(.leftMouseUp, in: player, at: padding))
        }
    }

    func testDragOutsideReleaseAndControlClickDoNotTogglePlayback() throws {
        let player = try makeLoadedPlayer()
        let start = videoPoint(player)
        expectUnchanged(player) {
            player.surface.mouseDown(with: mouse(.leftMouseDown, in: player, at: start))
            player.surface.mouseDragged(with: mouse(.leftMouseDragged, in: player,
                                                    at: NSPoint(x: start.x + 20, y: start.y)))
            player.surface.mouseUp(with: mouse(.leftMouseUp, in: player, at: start))
        }
        let edge = NSPoint(x: 1, y: start.y)
        expectUnchanged(player) {
            player.surface.mouseDown(with: mouse(.leftMouseDown, in: player, at: edge))
            player.surface.mouseUp(with: mouse(.leftMouseUp, in: player, at: NSPoint(x: -1, y: start.y)))
        }
        expectUnchanged(player) {
            player.surface.mouseDown(with: mouse(.leftMouseDown, in: player, at: start, modifiers: .control))
            player.surface.mouseUp(with: mouse(.leftMouseUp, in: player, at: start, modifiers: .control))
        }
    }

    func testSpaceAndPlayButtonDiscardDoubleClickRestoration() throws {
        let player = try makeLoadedPlayer()
        let (window, _) = try recordFullscreen(player)
        let controls = try XCTUnwrap(player.surface.subviews.compactMap { $0 as? ControlsView }.first)
        expectPause(true, in: player) { click(player) }
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: " ", charactersIgnoringModifiers: " ",
                                    isARepeat: false, keyCode: 49)!
        // Two newer inputs leave a state different from the original pre-click value.
        // A stale restoration on the second click would therefore be observable.
        window.sendEvent(space)
        window.sendEvent(space)
        XCTAssertTrue(player.snapshot.paused)
        assertCorePause(true, in: player)
        expectUnchanged(player) { click(player, count: 2) }

        expectPause(false, in: player) { click(player) }
        controls.play.performClick(nil)
        controls.play.performClick(nil)
        XCTAssertFalse(player.snapshot.paused)
        assertCorePause(false, in: player)
        expectUnchanged(player) { click(player, count: 2) }
    }

    func testNewMouseInputAndScrubbingDiscardDoubleClickRestoration() throws {
        let player = try makeLoadedPlayer()
        let (window, _) = try recordFullscreen(player)
        expectPause(true, in: player) { click(player) }
        expectUnchanged(player) {
            window.sendEvent(mouse(.rightMouseDown, in: player, at: videoPoint(player)))
            click(player, count: 2)
        }
        expectPause(false, in: player) { click(player) }
        player.progress.beginInteraction(at: player.progress.thumbCenter)
        player.progress.endInteraction()
        // Scrubbing briefly pauses playback; wait for its restoration before observing cancellation.
        let restored = expectation(description: "Scrubbing restores the playing state")
        player.engine.inspectProperty("pause") { value in
            XCTAssertEqual(value as? Bool, false)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 5)
        expectUnchanged(player) { click(player, count: 2) }
    }

    func testFocusLossFileReplacementAndShutdownDiscardDoubleClickRestoration() throws {
        let player = try makeLoadedPlayer()
        _ = try recordFullscreen(player)
        expectPause(true, in: player) { click(player) }
        expectUnchanged(player) {
            player.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: player.window))
            click(player, count: 2)
        }
        expectPause(false, in: player) { click(player) }
        load(player, url: try XCTUnwrap(player.fileURL))
        expectUnchanged(player) { click(player, count: 2) }
        expectPause(true, in: player) { click(player) }
        expectUnchanged(player) {
            player.shutdown()
            click(player, count: 2)
        }
    }
}
