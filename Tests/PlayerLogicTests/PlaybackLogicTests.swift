import XCTest
@testable import PlayerLogic

final class PlaybackLogicTests: XCTestCase {
    func testTimeInputAndHourRollover() {
        XCTAssertEqual(PlaybackTime.parse("01:23:45"), 5025)
        XCTAssertEqual(PlaybackTime.parse("83:45"), 5025)
        XCTAssertEqual(PlaybackTime.parse(" 90 "), 90)
        XCTAssertNil(PlaybackTime.parse("01:60:00"))
        XCTAssertNil(PlaybackTime.parse("1::2"))
        XCTAssertNil(PlaybackTime.parse("-20"))
        XCTAssertEqual(PlaybackTime.string(3600), "01:00:00")
        XCTAssertEqual(PlaybackTime.string(.nan), "00:00:00")
    }

    func testHoldThresholdAccelerationAndCap() {
        let gesture = ScanGesture(direction: -1, started: 0)
        XCTAssertNil(gesture.speed(at: 0.399))
        XCTAssertEqual(gesture.speed(at: 0.4), 2)
        XCTAssertEqual(gesture.speed(at: 1.4), 4)
        XCTAssertEqual(gesture.speed(at: 2.4), 8)
        XCTAssertEqual(gesture.speed(at: 3.4), 16)
        XCTAssertEqual(gesture.speed(at: 100), 16)
    }

    func testZoomAnchoringPanBoundsAndReturnToFit() {
        var transform = VideoTransform()
        transform.viewport = CGSize(width: 1000, height: 1000)
        transform.video = CGSize(width: 1000, height: 1000)
        transform.zoom(by: 2, anchor: CGPoint(x: 750, y: 500))
        XCTAssertEqual(transform.offset.width, -250, accuracy: 0.001)
        XCTAssertEqual(transform.normalizedPan.x, -0.125, accuracy: 0.001)
        transform.pan(x: 99999, y: -99999)
        XCTAssertEqual(transform.offset.width, 500)
        XCTAssertEqual(transform.offset.height, -500)
        transform.zoom(by: 0.01, anchor: .zero)
        XCTAssertEqual(transform.scale, 1)
        XCTAssertEqual(transform.offset, .zero)
        transform.zoom(by: 999, anchor: CGPoint(x: 500, y: 500))
        XCTAssertEqual(transform.scale, 8)
    }

    func testLetterboxingPreventsPanningAnUnfilledAxis() {
        var transform = VideoTransform()
        transform.viewport = CGSize(width: 1000, height: 1000)
        transform.video = CGSize(width: 1920, height: 1080)
        transform.zoom(by: 1.5, anchor: CGPoint(x: 500, y: 500))
        transform.pan(x: 1000, y: 1000)
        XCTAssertEqual(transform.offset.width, 250, accuracy: 0.001)
        XCTAssertEqual(transform.offset.height, 0)
    }

    func testResumeRejectsReplacedAndCompletedFiles() {
        let record = ResumeRecord(position: 100, duration: 200, size: 5000, modified: 123, watched: 321)
        XCTAssertEqual(record.resumePosition(size: 5000, modified: 123), 100)
        XCTAssertEqual(record.resumePosition(size: 6000, modified: 123), 0)
        XCTAssertEqual(record.resumePosition(size: 5000, modified: 124), 0)
        let completed = ResumeRecord(position: 199, duration: 200, size: 5000, modified: 123, watched: 321)
        XCTAssertEqual(completed.resumePosition(size: 5000, modified: 123), 0)
    }
}
