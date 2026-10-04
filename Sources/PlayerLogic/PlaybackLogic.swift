import Foundation
import CoreGraphics

public enum PlaybackTime {
    public static func string(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(min(Double(Int.max / 2), max(0, seconds))) : 0
        let parts = [value / 3600, value / 60 % 60, value % 60]
        return parts.map { $0 < 10 ? "0\($0)" : String($0) }.joined(separator: ":")
    }

    public static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var result = 0.0
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }), let number = Double(part), number.isFinite,
                  index == 0 || number < 60 else { return nil }
            result = result * 60 + number
        }
        return result.isFinite ? result : nil
    }
}

public struct ScanGesture {
    public static let holdDelay = 0.4
    public let direction: Double
    public let started: TimeInterval

    public init(direction: Double, started: TimeInterval) {
        self.direction = direction < 0 ? -1 : 1
        self.started = started
    }

    public func speed(at now: TimeInterval) -> Double? {
        let held = now - started - Self.holdDelay
        guard held >= 0 else { return nil }
        return pow(2, Double(min(3, Int(floor(held + 1e-9)))) + 1)
    }
}

public struct VideoTransform {
    public private(set) var scale = 1.0
    /// Offsets in view points, with positive Y downward (mpv coordinates).
    public private(set) var offset = CGSize.zero
    public var viewport = CGSize(width: 960, height: 540)
    public var video = CGSize(width: 16, height: 9)

    public init() {}

    public var fitted: CGSize {
        guard video.width > 0, video.height > 0, viewport.width > 0, viewport.height > 0 else { return .zero }
        let factor = min(viewport.width / video.width, viewport.height / video.height)
        return CGSize(width: video.width * factor, height: video.height * factor)
    }

    public var normalizedPan: CGPoint {
        let size = fitted
        return CGPoint(x: size.width > 0 ? offset.width / (size.width * scale) : 0,
                       y: size.height > 0 ? offset.height / (size.height * scale) : 0)
    }

    public mutating func zoom(by factor: Double, anchor: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let next = min(8, max(1, scale * factor))
        let ratio = next / scale
        let x = anchor.x - viewport.width / 2
        let y = anchor.y - viewport.height / 2
        offset = CGSize(width: x - (x - offset.width) * ratio, height: y - (y - offset.height) * ratio)
        scale = next
        clamp()
    }

    public mutating func pan(x: Double, y: Double) {
        offset.width += x
        offset.height += y
        clamp()
    }

    public mutating func clamp() {
        let size = fitted
        let x = max(0, (size.width * scale - viewport.width) / 2)
        let y = max(0, (size.height * scale - viewport.height) / 2)
        offset.width = min(x, max(-x, offset.width))
        offset.height = min(y, max(-y, offset.height))
    }

    public mutating func reset() {
        scale = 1
        offset = .zero
    }
}

public struct ResumeRecord: Codable {
    public let position: Double
    public let duration: Double
    public let size: Int64
    public let modified: TimeInterval
    public let watched: TimeInterval

    public init(position: Double, duration: Double, size: Int64, modified: TimeInterval, watched: TimeInterval) {
        self.position = position
        self.duration = duration
        self.size = size
        self.modified = modified
        self.watched = watched
    }

    public func resumePosition(size: Int64, modified: TimeInterval) -> Double {
        guard self.size == size, self.modified == modified, position.isFinite, duration.isFinite,
              position > 0, duration > 0, position < duration - 2 else { return 0 }
        return position
    }
}
