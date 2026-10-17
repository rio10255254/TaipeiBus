import Foundation

/// The passenger's explicitly confirmed ride, independent of the provider's
/// vehicle list. It never infers boarding, alighting or a vehicle identity.
public struct OnboardProgress: Sendable {
    public let rideID: String
    public let line: RouteLine
    private let anchors: [RouteJourney.Anchor]
    private let direction: Int
    public private(set) var match: LineMatch?
    public private(set) var confirmedAt: Date?

    public init?(ride: TransitRide, metadata: TransitMetadata) {
        guard ride.route.mode == .bus else { return nil }
        let source: RouteLine, journey: RouteJourney
        if let road = metadata.line(ride.route.id, direction: ride.direction),
           let ordered = metadata.journey(routeID: ride.route.id, direction: ride.direction) {
            source = road; journey = ordered
        } else {
            let road = RouteLine(coordinates: ride.coordinates)
            guard let ordered = RouteJourney.build(stops: ride.stops, line: road, stations: metadata.stations) else { return nil }
            source = road; journey = ordered
        }
        guard let first = journey.anchors.firstIndex(where: { $0.stop.id == ride.boarding.id }),
              let last = journey.anchors.firstIndex(where: { $0.stop.id == ride.alighting.id }), last > first else { return nil }
        rideID = ride.id; line = source; direction = journey.direction
        anchors = Array(journey.anchors[first...last])
    }
    private var start: Double { anchors[0].match.along * Double(direction) }
    private var end: Double { anchors[anchors.count-1].match.along * Double(direction) }
    public var hasConfirmedProgress: Bool { match != nil && confirmedAt != nil }
    public func isFresh(at date: Date) -> Bool {
        confirmedAt.map { (-2...20).contains(date.timeIntervalSince($0)) } == true
    }
    public var remainingFraction: Double {
        guard let match, end > start else { return 1 }
        return min(1,max(0,(end-match.along * Double(direction))/(end-start)))
    }
    public var upcomingStops: [BusStop] {
        let along = match.map { $0.along * Double(direction) } ?? start
        return anchors.dropFirst().filter { $0.match.along * Double(direction) >= along-20 }.map(\.stop)
    }
    public var passedStopIDs: Set<String> {
        guard let match else { return [] }
        let along = match.along * Double(direction)
        return Set(anchors.dropFirst().filter { $0.match.along * Double(direction) < along-20 }.map { $0.stop.id })
    }
    public func remainingSegmentFraction(from fromID: String, to toID: String) -> Double? {
        guard let a = anchors.first(where: { $0.stop.id == fromID }),
              let b = anchors.first(where: { $0.stop.id == toID }) else { return nil }
        let first = a.match.along * Double(direction), last = b.match.along * Double(direction)
        guard last > first else { return nil }
        let along = match.map { $0.along * Double(direction) } ?? start
        return min(1,max(0,(last-max(first,along))/(last-first)))
    }
    @discardableResult
    public mutating func update(coordinate: Coordinate, accuracy: Double, timestamp: Date,
                                boardedAt: Date, now: Date, maximumAge: TimeInterval = 15) -> Bool {
        guard accuracy.isFinite, (0...35).contains(accuracy),
              (-2...min(90,maximumAge)).contains(now.timeIntervalSince(timestamp)),
              timestamp >= boardedAt.addingTimeInterval(-15),
              confirmedAt.map({ timestamp > $0 }) ?? true else { return false }
        let previous = match.map { $0.along * Double(direction) } ?? start
        let elapsed = max(0,timestamp.timeIntervalSince(confirmedAt ?? boardedAt))
        let reach = 100 + elapsed * 25
        let candidates = line.candidates(coordinate, maximumDistance: min(35,max(15,accuracy)))
            .filter {
                let along = $0.along * Double(direction)
                return along >= start-40 && along <= end+80 && along >= previous-40 && along <= previous+reach
            }
        guard let next = candidates.min(by: {
            $0.distance + abs($0.along * Double(direction)-previous)*0.02 <
            $1.distance + abs($1.along * Double(direction)-previous)*0.02
        }) else { return false }
        // Small GPS jitter may hold the last position, but cannot rewind it.
        if next.along * Double(direction) >= previous || match == nil { match = next }
        confirmedAt = timestamp
        return true
    }
}
