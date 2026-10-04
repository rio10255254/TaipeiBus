import Foundation

/// Progress along a verified pedestrian route. The device dot remains at the
/// measured GPS position; this match only trims the route and estimates distance.
public struct WalkingProgress: Sendable {
    public let line: RouteLine
    public let routeDistance: Double
    public let routeSeconds: Double
    public private(set) var match: LineMatch?
    public private(set) var lastFix: Date?
    public private(set) var locationConfirmed = false
    private var lastAccuracy = 0.0
    private var outsideSince: Date?
    private var outsideCount = 0
    public init(coordinates: [Coordinate], distance: Double, seconds: Double) {
        line = RouteLine(coordinates: coordinates); routeDistance = distance; routeSeconds = seconds
    }
    public var needsReroute: Bool { outsideCount >= 3 }
    public var remainingDistance: Double {
        guard let match, line.length > 0 else { return routeDistance }
        return max(0, routeDistance * (1 - match.along / line.length))
    }
    public var remainingSeconds: Double {
        guard routeDistance > 0 else { return 0 }
        return routeSeconds * remainingDistance / routeDistance
    }
    public var remainingCoordinates: [Coordinate] {
        guard let match, let end = line.coordinates.last, line.coordinates.count >= 2 else { return line.coordinates }
        return line.slice(from: match, to: LineMatch(coordinate: end, segment: line.coordinates.count - 2,
                                                   along: line.length, distance: 0))
    }
    @discardableResult
    public mutating func update(coordinate: Coordinate, accuracy: Double, timestamp: Date, now: Date) -> Bool {
        guard accuracy.isFinite, accuracy >= 0, accuracy <= 35,
              now.timeIntervalSince(timestamp) >= -2, now.timeIntervalSince(timestamp) <= 15 else {
            locationConfirmed = false; outsideSince = nil; outsideCount = 0; return false
        }
        guard lastFix.map({ timestamp > $0 }) ?? true else { return false }
        let elapsed = lastFix.map { timestamp.timeIntervalSince($0) } ?? 0
        let candidates = line.candidates(coordinate, maximumDistance: max(20, accuracy * 1.5))
        let limit = max(45, min(180, elapsed * 3 + accuracy + lastAccuracy))
        let nearby = candidates.filter { candidate in
            match.map { abs(candidate.along - $0.along) <= limit } ?? true
        }
        let best = nearby.min { a, b in
            func score(_ x: LineMatch) -> Double {
                x.distance + (match.map { abs(x.along - $0.along) * 0.05 } ?? x.along * 0.0005)
            }
            return score(a) < score(b)
        }
        lastFix = timestamp; lastAccuracy = accuracy
        if let best {
            match = best; locationConfirmed = true; outsideSince = nil; outsideCount = 0
            return true
        }
        locationConfirmed = false
        if outsideSince == nil { outsideSince = timestamp }
        if timestamp.timeIntervalSince(outsideSince!) >= 8 { outsideCount += 1 }
        return false
    }
}
