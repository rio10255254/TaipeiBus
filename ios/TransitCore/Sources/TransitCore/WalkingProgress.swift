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
    private let learnsWalkingPace: Bool
    private var paceSamples: [(along: Double, date: Date)] = []
    public private(set) var observedWalkingSpeed: Double?
    private var paceWeight = 0.0
    public init(coordinates: [Coordinate], distance: Double, seconds: Double, learnsWalkingPace: Bool = true) {
        line = RouteLine(coordinates: coordinates); routeDistance = distance; routeSeconds = seconds
        self.learnsWalkingPace = learnsWalkingPace
    }
    public var needsReroute: Bool { outsideCount >= 3 }
    public var remainingDistance: Double {
        guard let match, line.length > 0 else { return routeDistance }
        return max(0, routeDistance * (1 - match.along / line.length))
    }
    public var remainingSeconds: Double {
        guard routeDistance > 0 else { return 0 }
        let planned = routeSeconds * remainingDistance / routeDistance
        guard let speed = observedWalkingSpeed else { return planned }
        return planned * (1-paceWeight) + remainingDistance / speed * paceWeight
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
        if line.length < 1, let end = line.coordinates.last, coordinate.distance(to: end) <= max(10, accuracy) {
            lastFix = timestamp; lastAccuracy = accuracy; locationConfirmed = true; outsideSince = nil; outsideCount = 0
            match = LineMatch(coordinate: end, segment: 0, along: 0, distance: coordinate.distance(to: end))
            return true
        }
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
            if accuracy > 15 { paceSamples = []; observedWalkingSpeed = nil; paceWeight = 0 }
            if learnsWalkingPace, accuracy <= 15 {
                if let latest = paceSamples.last,
                   timestamp.timeIntervalSince(latest.date) > 20 || best.along < latest.along-20 {
                    paceSamples = []; observedWalkingSpeed = nil; paceWeight = 0
                }
                if paceSamples.last.map({ timestamp.timeIntervalSince($0.date) >= 5 }) ?? true {
                    paceSamples.append((best.along,timestamp))
                }
                paceSamples.removeAll { timestamp.timeIntervalSince($0.date) > 90 }
                if let first = paceSamples.first, paceSamples.count >= 4 {
                    let duration = timestamp.timeIntervalSince(first.date), moved = best.along-first.along
                    if duration >= 45, moved >= 30, (0.5...2.5).contains(moved/duration) {
                        observedWalkingSpeed = min(2,max(0.6,moved/duration))
                        paceWeight = min(0.7,duration/120)
                    }
                }
            }
            match = best; locationConfirmed = true; outsideSince = nil; outsideCount = 0
            return true
        }
        locationConfirmed = false
        if outsideSince == nil { outsideSince = timestamp }
        if timestamp.timeIntervalSince(outsideSince!) >= 8 { outsideCount += 1 }
        return false
    }
}
