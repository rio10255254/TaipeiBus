import Foundation

/// A rider who has confirmed their plate is on that bus. The official feed reports
/// each bus only every 20–60 s, so the phone's own recent fix is the fresher reading
/// of the same vehicle. Nothing is predicted: the position is a real fix that lies on
/// the bus's own route, ahead of its last report by a distance a bus could travel.
public enum RiderAnchor {
    public static let maximumAccuracy = 50.0
    public static let maximumFixAge: TimeInterval = 15
    public static let maximumRouteDistance = 40.0
    /// Fastest plausible city bus movement since the feed's last report, in metres per second.
    static let maximumSpeed = 25.0

    public static func anchor(_ bus: BusVehicle, rider: Coordinate, accuracy: Double, fixedAt: Date,
                              previous: LineMatch?, line: RouteLine, journey: RouteJourney?, now: Date) -> BusVehicle? {
        guard accuracy > 0, accuracy <= maximumAccuracy,
              (-2...maximumFixAge).contains(now.timeIntervalSince(fixedAt)),
              fixedAt > bus.observedAt else { return nil }
        let direction = journey?.direction ?? bus.travelDirection
        let reported = bus.roadMatch ?? line.match(bus.coordinate, heading: nil, travelDirection: direction, alongRange: journey?.range)
        guard let match = line.match(rider, heading: nil, previous: previous ?? reported,
                                     travelDirection: direction, alongRange: journey?.range),
              match.distance <= maximumRouteDistance else { return nil }
        let reach = 120 + max(0, fixedAt.timeIntervalSince(bus.observedAt)) * maximumSpeed
        if let reported, direction != 0 {
            // On board, the rider is at or ahead of the bus's last report, never further than it could travel.
            let lead = (match.along - reported.along) * Double(direction)
            guard lead >= -60, lead <= reach else { return nil }
        } else if rider.distance(to: bus.coordinate) > reach {
            return nil
        }
        var target = match
        // A fix slightly behind the last anchor holds the bus instead of reversing it.
        if direction != 0, let previous, (match.along - previous.along) * Double(direction) < 0 { target = previous }
        let start = previous ?? reported ?? target
        var anchored = bus
        anchored.coordinate = target.coordinate
        anchored.roadMatch = target
        anchored.aligned = true
        anchored.travelDirection = direction
        anchored.observedAt = fixedAt
        anchored.trackingIssue = nil
        anchored.rejectedObservation = nil
        anchored.heading = line.bearing(at: target, direction: direction < 0 ? -1 : 1)
        anchored.path = line.slice(from: start, to: target)
        if anchored.path.isEmpty { anchored.path = [target.coordinate] }
        return anchored
    }
}
