import Foundation

/// Counts display delivery, not just time spent in the app's drawing function.
/// No route, vehicle, location or personal data is retained.
public struct FramePacingWindow: Sendable {
    public struct Report: Equatable, Sendable {
        public let frames: Int
        public let delayedFrames: Int
        public let seconds: Double
        public let longestGapMilliseconds: Double
        public var framesPerSecond: Double { seconds > 0 ? Double(frames) / seconds : 0 }
    }
    private let interval: Double
    private var start: Double?
    private var last: Double?
    private var frames = 0
    private var delayed = 0
    private var longest = 0.0
    public init(interval: Double = 60) { self.interval = max(1,interval) }
    public mutating func reset() { start = nil; last = nil; frames = 0; delayed = 0; longest = 0 }
    public mutating func observe(timestamp: Double, targetInterval: Double) -> Report? {
        guard timestamp.isFinite, targetInterval.isFinite, targetInterval > 0 else { reset(); return nil }
        guard let previous = last, timestamp > previous, let began = start else {
            reset(); start = timestamp; last = timestamp; return nil
        }
        let gap = timestamp - previous
        frames += 1; longest = max(longest,gap)
        if gap > targetInterval * 1.8 { delayed += 1 }
        last = timestamp
        guard timestamp - began >= interval else { return nil }
        let result = Report(frames: frames, delayedFrames: delayed, seconds: timestamp-began,
            longestGapMilliseconds: longest*1000)
        reset(); start = timestamp; last = timestamp
        return result
    }
}
