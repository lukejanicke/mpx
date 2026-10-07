import XCTest
import CMPV
import AppKit
@testable import MPX

final class PlaybackIntegrationTests: XCTestCase {
    private func makePlayer(history: HistoryStore = .shared) throws -> PlayerWindowController {
        do { return try PlayerWindowController(history: history) }
        catch let error as MPXError {
            if case .playback(let message) = error,
               message == "Could not create the video display.",
               ProcessInfo.processInfo.environment["MPX_ALLOW_NO_OPENGL_TESTS"] == "1" {
                throw XCTSkip("This runner cannot create accelerated OpenGL. Run the full display suite on a supported physical Mac before approving a release.")
            }
            throw error
        }
    }

    func testRealPlaybackResumeAndPreciseSeek() throws {
        guard let path = ProcessInfo.processInfo.environment["MPX_TEST_VIDEO_PATH"] else {
            throw XCTSkip("Set MPX_TEST_VIDEO_PATH to a local video for the playback integration test.")
        }
        try verifyPlayback(path: path)
    }

    func testCodecFixtures() throws {
        guard let directory = ProcessInfo.processInfo.environment["MPX_TEST_FIXTURE_DIRECTORY"] else {
            throw XCTSkip("Set MPX_TEST_FIXTURE_DIRECTORY to run the codec suite.")
        }
        for filename in ["h264.mp4", "hevc.mkv", "vp9.webm", "av1.mkv", "mpeg4.avi", "ffv1.mkv"] {
            try verifyPlayback(path: URL(fileURLWithPath: directory).appendingPathComponent(filename).path)
            print("Verified decoding, resume and seek: \(filename)")
        }
    }

    private func verifyPlayback(path: String) throws {
        let engine = try PlaybackEngine(headless: true)
        defer { engine.onEvent = nil; engine.shutdown() }
        let resumed = expectation(description: "Autoplay from requested resume position")
        let seeking = expectation(description: "Paused exact seek")
        let tracks = expectation(description: "Decoded track metadata")
        var stage = 0
        var gotTracks = false
        engine.onEvent = { event in
            switch event {
            case .snapshot(let state):
                if stage == 0, state.duration > 20, state.position >= 10, state.position < 13, !state.paused {
                    stage = 1
                    resumed.fulfill()
                    engine.set("pause", "yes")
                    engine.seek(20)
                } else if stage == 1, state.paused, abs(state.position - 20) < 0.2 {
                    stage = 2
                    seeking.fulfill()
                }
            case .tracks(let value):
                if !gotTracks, value.contains(where: { $0.type == "video" }) {
                    gotTracks = true
                    tracks.fulfill()
                }
            case .failure(let message): XCTFail(message)
            default: break
            }
        }
        engine.load(URL(fileURLWithPath: path), resume: 10, volume: 50, muted: false)
        wait(for: [resumed, seeking, tracks], timeout: 12)
    }

    func testPlaybackFailureIsReported() throws {
        let engine = try PlaybackEngine(headless: true)
        defer { engine.onEvent = nil; engine.shutdown() }
        let failure = expectation(description: "Failed opening is reported")
        var received = false
        engine.onEvent = { event in
            if case .failure = event, !received { received = true; failure.fulfill() }
        }
        engine.load(URL(fileURLWithPath: "/mpx-nonexistent-test-video"), resume: 0, volume: 100, muted: false)
        wait(for: [failure], timeout: 5)
    }

    func testScanRestoresPausedMutedState() throws { try verifyScan(paused: true, muted: true) }
    func testScanRestoresPlayingUnmutedState() throws { try verifyScan(paused: false, muted: false) }

    func testVideoAspectAndRenderFillAfterPausedWindowResize() throws {
        guard let path = ProcessInfo.processInfo.environment["MPX_TEST_VIDEO_PATH"] else { throw XCTSkip("Set MPX_TEST_VIDEO_PATH.") }
        _ = NSApplication.shared
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent("mpx-resize-test-\(UUID().uuidString).json")
        let player = try makePlayer(history: HistoryStore(file: historyURL))
        defer { player.shutdown(); try? FileManager.default.removeItem(at: historyURL) }
        let ready = expectation(description: "Paused video ready for resize")
        let original = player.engine.onEvent
        var pausing = false
        var paused = false
        player.engine.onEvent = { event in
            original?(event)
            guard case .snapshot(let state) = event else { return }
            if !pausing, state.duration > 0, state.position > 0 {
                pausing = true
                player.engine.set("pause", "yes")
            } else if pausing, state.paused, !paused { paused = true; ready.fulfill() }
        }
        player.open(URL(fileURLWithPath: path))
        wait(for: [ready], timeout: 8)
        let window = try XCTUnwrap(player.window)
        let aspect = player.snapshot.videoSize.width / player.snapshot.videoSize.height
        XCTAssertEqual(window.contentAspectRatio.width / window.contentAspectRatio.height, aspect, accuracy: 0.001)
        XCTAssertEqual(player.surface.bounds.height, player.surface.bounds.width / aspect, accuracy: 1)
        for width in [1200.0, 600.0, 960.0, 280.0] {
            // AppKit applies contentAspectRatio to user resizing, not arbitrary
            // programmatic setContentSize calls. Exercise the constrained sizes.
            let size = NSSize(width: width, height: width / aspect)
            window.setContentSize(size)
            player.surface.layoutSubtreeIfNeeded()
            player.video.display()
            XCTAssertEqual(player.video.frame, player.surface.bounds)
            let measured = expectation(description: "Measure rendered geometry")
            player.engine.inspectProperty("osd-dimensions") { value in
                guard let dimensions = value as? [String: Any],
                      let width = dimensions["w"] as? Int64, let height = dimensions["h"] as? Int64,
                      let left = dimensions["ml"] as? Int64, let right = dimensions["mr"] as? Int64,
                      let top = dimensions["mt"] as? Int64, let bottom = dimensions["mb"] as? Int64 else {
                    XCTFail("No rendered video geometry")
                    measured.fulfill()
                    return
                }
                let backing = player.surface.convertToBacking(player.surface.bounds).size
                XCTAssertEqual(Double(width), backing.width, accuracy: 1)
                XCTAssertEqual(Double(height), backing.height, accuracy: 1)
                XCTAssertLessThanOrEqual(abs(left) + abs(right) + abs(top) + abs(bottom), 2,
                                         "Aspect-constrained content must have no added black bars")
                print("Rendered \(width)×\(height); margins left/right/top/bottom: \(left)/\(right)/\(top)/\(bottom)")
                measured.fulfill()
            }
            wait(for: [measured], timeout: 5)
        }
    }

    func testEmptyWindowDefaultSizeAndCenter() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let player = try makePlayer()
        defer { player.shutdown() }
        let window = try XCTUnwrap(player.window)
        XCTAssertEqual(player.surface.bounds.width, screen.frame.width / 2, accuracy: 0.5)
        XCTAssertEqual(player.surface.bounds.height, player.surface.bounds.width * 9 / 16, accuracy: 1)
        XCTAssertEqual(window.frame.midX, screen.visibleFrame.midX, accuracy: 0.5)
        XCTAssertEqual(window.frame.midY, screen.visibleFrame.midY, accuracy: 0.5)
    }

    func testVolumeSymbolBoundariesAndMute() {
        for (volume, expected) in [(0.0, "speaker.slash.fill"), (0.1, "speaker.fill"), (25.0, "speaker.fill"),
                                   (25.1, "speaker.wave.1.fill"), (50.0, "speaker.wave.1.fill"),
                                   (50.1, "speaker.wave.2.fill"), (75.0, "speaker.wave.2.fill"),
                                   (75.1, "speaker.wave.3.fill"), (100.0, "speaker.wave.3.fill")] {
            XCTAssertEqual(ControlsView.volumeSymbol(volume: volume, muted: false), expected)
            XCTAssertEqual(ControlsView.volumeSymbol(volume: volume, muted: true), "speaker.slash.fill")
        }
    }

    func testWindowRefitsForPortraitAndUltrawideReplacement() throws {
        guard let directory = ProcessInfo.processInfo.environment["MPX_TEST_FIXTURE_DIRECTORY"] else { throw XCTSkip("Set MPX_TEST_FIXTURE_DIRECTORY.") }
        _ = NSApplication.shared
        let player = try makePlayer()
        defer { player.shutdown() }
        let window = try XCTUnwrap(player.window)
        let original = player.engine.onEvent
        for (filename, aspect) in [("portrait.mp4", 9.0 / 16.0), ("ultrawide.mp4", 21.0 / 9.0), ("h264.mp4", 16.0 / 9.0)] {
            let sized = expectation(description: "Window fits \(filename)")
            var received = false
            player.engine.onEvent = { event in
                original?(event)
                if case .videoSize = event, !received {
                    received = true
                    sized.fulfill()
                }
            }
            player.open(URL(fileURLWithPath: directory).appendingPathComponent(filename))
            wait(for: [sized], timeout: 8)
            player.engine.set("pause", "yes")
            XCTAssertEqual(window.contentAspectRatio.width / window.contentAspectRatio.height, aspect, accuracy: 0.001)
            XCTAssertEqual(player.surface.bounds.height, player.surface.bounds.width / aspect, accuracy: 1)
            let visible = try XCTUnwrap(window.screen).visibleFrame
            XCTAssertLessThanOrEqual(window.frame.height, visible.height + 1)
            XCTAssertLessThanOrEqual(window.frame.width, visible.width + 1)
        }
    }

    func testScrubRestoresPlayingState() throws { try verifyScrub(paused: false, muted: false) }
    func testScrubPreservesPausedMutedState() throws { try verifyScrub(paused: true, muted: true) }

    private func verifyScrub(paused: Bool, muted: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["MPX_TEST_VIDEO_PATH"] else { throw XCTSkip("Set MPX_TEST_VIDEO_PATH.") }
        _ = NSApplication.shared
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent("mpx-scrub-test-\(UUID().uuidString).json")
        let player = try makePlayer(history: HistoryStore(file: historyURL))
        defer { player.shutdown(); try? FileManager.default.removeItem(at: historyURL) }
        let ready = expectation(description: "Original playback state is ready")
        let preview = expectation(description: "Paused preview during drag")
        let restored = expectation(description: "Core seek and original state restored")
        restored.expectedFulfillmentCount = 3
        let original = player.engine.onEvent
        var configured = false
        var started = false
        var released = false
        player.engine.onEvent = { event in
            original?(event)
            guard case .snapshot(let state) = event else { return }
            if !configured, state.duration > 20, state.position > 0 {
                configured = true
                player.engine.set("pause", paused ? "yes" : "no")
                player.engine.set("mute", muted ? "yes" : "no")
            } else if configured, !started, state.paused == paused, state.muted == muted {
                started = true
                ready.fulfill()
                let bar = player.progress
                let videoWidth = player.surface.bounds.width
                let margin = min(16, max(4, (videoWidth - 272) / 2))
                XCTAssertEqual(bar.trackWidth, videoWidth - 2 * margin - 39, accuracy: 1)
                bar.beginInteraction(at: bar.thumbCenter)
                bar.drag(to: NSPoint(x: 5 + (bar.bounds.width - 10) * 20 / state.duration, y: bar.bounds.midY))
                XCTAssertTrue(bar.isThumbVisible)
            } else if started, !released, state.paused, abs(state.position - 20) < 0.2 {
                preview.fulfill()
                XCTAssertEqual(player.progress.position, 20, accuracy: 0.01, "Core snapshots must not move a thumb during dragging")
                released = true
                player.progress.endInteraction()
                // A paused seek to the already-previewed frame need not emit a
                // new snapshot. Inspect the core after the queued final commands.
                player.engine.inspectProperty("time-pos") { value in
                    XCTAssertEqual(value as? Double ?? -1, 20, accuracy: 0.3)
                    restored.fulfill()
                }
                player.engine.inspectProperty("pause") { value in
                    XCTAssertEqual(value as? Bool, paused)
                    restored.fulfill()
                }
                player.engine.inspectProperty("mute") { value in
                    XCTAssertEqual(value as? Bool, muted)
                    restored.fulfill()
                }
            }
        }
        player.open(URL(fileURLWithPath: path))
        wait(for: [ready, preview, restored], timeout: 10)
        player.savePosition()
        XCTAssertEqual(HistoryStore(file: historyURL).position(for: URL(fileURLWithPath: path)), 20, accuracy: 0.3)
    }

    func testProgressClampsInputAndKeepsDragPreview() {
        let bar = ProgressView(frame: NSRect(x: 0, y: 0, width: 500, height: 24))
        bar.update(position: 45, duration: 90)
        XCTAssertFalse(bar.isThumbVisible)
        bar.beginInteraction(at: NSPoint(x: -100, y: 12))
        XCTAssertEqual(bar.position, 0)
        bar.drag(to: NSPoint(x: 250, y: 12))
        XCTAssertEqual(bar.position, 45)
        bar.update(position: 1, duration: 90)
        XCTAssertEqual(bar.position, 45)
        bar.drag(to: NSPoint(x: 900, y: 12))
        XCTAssertEqual(bar.position, 90)
        bar.endInteraction()
        bar.update(position: 25, duration: 90)
        XCTAssertEqual(bar.position, 25)
        bar.update(position: .nan, duration: .nan)
        XCTAssertEqual(bar.position, 0)
        XCTAssertFalse(bar.isEnabled)
        XCTAssertFalse(bar.accessibilityPerformIncrement())
    }

    func testProgressThumbAppearsOnlyNearCurrentPositionOrDuringDrag() {
        let bar = ProgressView(frame: NSRect(x: 0, y: 0, width: 500, height: 24))
        bar.update(position: 45, duration: 90)
        let center = bar.thumbCenter
        bar.pointerMoved(to: NSPoint(x: center.x + 17, y: center.y))
        XCTAssertTrue(bar.isThumbVisible)
        bar.pointerMoved(to: NSPoint(x: center.x + 19, y: center.y))
        XCTAssertFalse(bar.isThumbVisible)
        bar.pointerMoved(to: NSPoint(x: center.x, y: center.y + 13))
        XCTAssertFalse(bar.isThumbVisible)
        bar.pointerMoved(to: center)
        bar.update(position: 70, duration: 90)
        XCTAssertFalse(bar.isThumbVisible, "Advancing playback must update hover proximity even with a stationary pointer")
        bar.beginInteraction(at: center)
        bar.drag(to: NSPoint(x: 900, y: 900))
        XCTAssertTrue(bar.isThumbVisible)
        bar.endInteraction()
        XCTAssertFalse(bar.isThumbVisible)
    }

    func testOverlayGroupsStayCentredAndDoNotOverlapInSmallWindows() {
        _ = NSApplication.shared
        let controls = ControlsView(start: {}, back: {}, toggle: {}, forward: {}, end: {}, full: {})
        for width in [900.0, 680.0, 600.0, 400.0, 252.0, 680.0] {
            controls.frame = NSRect(x: 0, y: 0, width: width, height: controls.height(for: width))
            controls.needsLayout = true
            controls.layoutSubtreeIfNeeded()
            let transport = controls.transport.frame
            let utilities = controls.utilities.frame
            let time = controls.timeFrame
            XCTAssertEqual(transport.midX, width / 2, accuracy: 0.5)
            XCTAssertEqual(time.minX, 0, accuracy: 0.5)
            XCTAssertEqual(utilities.maxX, width, accuracy: 0.5)
            XCTAssertFalse(time.intersects(transport))
            XCTAssertFalse(utilities.intersects(transport))
            XCTAssertFalse(time.intersects(utilities))
            for button in controls.transport.views {
                XCTAssertEqual(button.frame.width, 44, accuracy: 0.5)
                XCTAssertEqual(button.frame.height, 44, accuracy: 0.5)
                let imageRect = (button as! NSButton).cell!.imageRect(forBounds: button.bounds)
                XCTAssertEqual(imageRect.midX, button.bounds.midX, accuracy: 0.5)
                XCTAssertEqual(imageRect.midY, button.bounds.midY, accuracy: 0.5)
            }
            XCTAssertEqual(controls.isCompact, controls.height(for: width) > 44)
        }
    }

    func testPanelContainsCentredHitAreasAndTimestampIsNoninteractive() throws {
        let player = try makePlayer()
        defer { player.shutdown() }
        for width in [900.0, 600.0, 280.0] {
            player.window!.setContentSize(NSSize(width: width, height: width * 9 / 16))
            player.surface.layoutSubtreeIfNeeded()
            let controls = player.surface.subviews.compactMap { $0 as? ControlsView }.first!
            let panel = player.controlsPanelFrame
            XCTAssertEqual(panel.minX, panel.minY, accuracy: 0.5)
            XCTAssertEqual(player.surface.bounds.maxX - panel.maxX, panel.minY, accuracy: 0.5)
            XCTAssertEqual(controls.frame.minY - panel.minY, 16, accuracy: 0.5)
            XCTAssertEqual(panel.maxY - player.progress.frame.maxY, 16, accuracy: 0.5)
            XCTAssertTrue(panel.contains(player.progress.frame))
            for button in controls.transport.views + [controls.fullscreen] {
                XCTAssertTrue(panel.contains(button.convert(button.bounds, to: player.surface)))
            }
            XCTAssertEqual(player.progress.bounds.height, 24)
            XCTAssertEqual(player.progress.thumbCenter.y, player.progress.bounds.midY)
            player.progress.update(position: 10, duration: 90)
            player.progress.pointerMoved(to: player.progress.thumbCenter)
            XCTAssertGreaterThan(player.progress.hoverTime.frame.minY, panel.maxY)
            XCTAssertNil(player.progress.hoverTime.hitTest(player.progress.hoverTime.frame.origin))
            XCTAssertTrue(player.progress.hoverTime.superview === player.surface)
        }
    }

    func testScrubHoverTimeClampsAtEndsAndTracksPointerWithoutSeeking() {
        let bar = ProgressView(frame: NSRect(x: 0, y: 0, width: 500, height: 44))
        bar.update(position: 10, duration: 90)
        bar.pointerMoved(to: NSPoint(x: 250, y: 12))
        XCTAssertEqual(bar.hoverPosition ?? -1, 45, accuracy: 0.01)
        XCTAssertEqual(bar.position, 10, "Hovering must not seek")
        bar.pointerMoved(to: NSPoint(x: -10, y: 12))
        XCTAssertEqual(bar.hoverPosition, 0)
        bar.pointerMoved(to: NSPoint(x: 600, y: 12))
        XCTAssertEqual(bar.hoverPosition, 90)
        bar.pointerMoved(to: NSPoint(x: 250, y: 30))
        XCTAssertNil(bar.hoverPosition)
        bar.update(position: 0, duration: 0)
        XCTAssertNil(bar.hoverPosition)
    }

    private func verifyScan(paused: Bool, muted: Bool) throws {
        guard let path = ProcessInfo.processInfo.environment["MPX_TEST_VIDEO_PATH"] else { throw XCTSkip("Set MPX_TEST_VIDEO_PATH.") }
        _ = NSApplication.shared
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent("mpx-history-test-\(UUID().uuidString).json")
        let player = try makePlayer(history: HistoryStore(file: historyURL))
        defer { player.shutdown(); try? FileManager.default.removeItem(at: historyURL) }
        let started = expectation(description: "Video ready for scan")
        let restored = expectation(description: "Scan restores pause and mute")
        let original = player.engine.onEvent
        var ready = false
        var released = false
        var start = 0.0
        player.engine.onEvent = { event in
            original?(event)
            guard case .snapshot(let state) = event else { return }
            if !ready, state.duration > 20, state.position > 0, !state.paused {
                ready = true
                started.fulfill()
                if paused { player.togglePlayback() }
                if muted { player.toggleMute() }
                start = state.position
                player.beginScan(direction: 1)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    player.finishScan(cancelTap: false)
                    released = true
                }
            } else if released, state.paused == paused, state.muted == muted, state.position > start + 0.5 {
                released = false
                restored.fulfill()
            }
        }
        player.open(URL(fileURLWithPath: path))
        wait(for: [started, restored], timeout: 8)
        player.savePosition()
        XCTAssertGreaterThan(HistoryStore(file: historyURL).position(for: URL(fileURLWithPath: path)), start + 0.5)
    }
}
