import Foundation

/// Physical-car continuity and conservative GPS filtering, independent of rendering cadence.
public enum VehicleTracker {
    public static func accept(_ observation: BusVehicle, previous: BusVehicle?, metadata: TransitMetadata, now: Date) -> BusVehicle {
        if let previous, observation.observedAt <= previous.observedAt {
            var retained = previous
            if retained.trackingIssue == .missing { retained.trackingIssue = nil }
            return retained
        }
        var vehicle = observation
        vehicle.coordinate = observation.rawCoordinate
        vehicle.aligned = false; vehicle.roadMatch = nil; vehicle.travelDirection = 0
        vehicle.path = []; vehicle.trackingIssue = nil; vehicle.rejectedObservation = nil
        let sameJourney = previous?.routeID == vehicle.routeID && previous?.direction == vehicle.direction
        let old = sameJourney ? previous : nil
        let interval = old.map { vehicle.observedAt.timeIntervalSince($0.observedAt) } ?? .infinity
        var reacquired = false
        if let old, interval <= 90, old.isFresh(at: now) {
            let limit = 45 + interval * max(18, min(28, max(old.speed, vehicle.speed) / 3.6 + 10))
            if old.rawCoordinate.distance(to: vehicle.rawCoordinate) > limit {
                if let pending = old.rejectedObservation {
                    let gap = vehicle.observedAt.timeIntervalSince(pending.observedAt)
                    reacquired = gap > 0 && gap <= 45 && pending.coordinate.distance(to: vehicle.rawCoordinate) <= 40 + gap * 28
                }
                if !reacquired {
                    var retained = old
                    retained.trackingIssue = .rejected
                    retained.rejectedObservation = RejectedObservation(coordinate: vehicle.rawCoordinate, observedAt: vehicle.observedAt)
                    return retained // Do not stamp an untrusted fix as a new accepted position.
                }
            }
        }
        let journey = metadata.journey(routeID: vehicle.routeID, direction: vehicle.direction)
        if let line = metadata.line(vehicle.routeID) {
            let from = old.flatMap { $0.roadMatch ?? ($0.aligned ? line.match($0.coordinate, heading: nil) : nil) }
            let context = interval <= 60 && !reacquired ? from : nil
            let direction = journey?.direction ?? old?.travelDirection ?? 0
            let travelLimit = interval.isFinite ? 60 + interval * 28 : nil
            if let match = line.match(vehicle.rawCoordinate, heading: vehicle.speed >= 5 && vehicle.hasHeading ? vehicle.heading : nil,
                previous: context, maximumTravel: travelLimit, travelDirection: direction, alongRange: journey?.range) {
                vehicle.coordinate = match.coordinate; vehicle.roadMatch = match; vehicle.aligned = true
                vehicle.travelDirection = direction
                if let old, let from = context, interval > 0 {
                    let delta = match.along - from.along
                    if journey == nil, abs(delta) >= 8 { vehicle.travelDirection = delta > 0 ? 1 : -1 }
                    if old.speed < 2, vehicle.speed < 2, old.coordinate.distance(to: match.coordinate) < 9 {
                        // Keep a stationary anchor while accepting the genuine timestamp and status.
                        vehicle.coordinate = old.coordinate; vehicle.roadMatch = from
                    } else if abs(delta) <= max(100, old.coordinate.distance(to: match.coordinate) * 3) {
                        vehicle.path = line.slice(from: from, to: match)
                    }
                }
            }
        }
        if vehicle.path.isEmpty { vehicle.path = [vehicle.coordinate] }
        return vehicle
    }

    /// A skipped packet must not make a selected physical bus disappear. Never retain an
    /// explicitly ended vehicle, or disguise the original observation time as a fresh fix.
    public static func retainMissing(previous: [BusVehicle], current: [BusVehicle], ended: Set<String>, now: Date) -> [BusVehicle] {
        let present = Set(current.map(\.id))
        return previous.compactMap { old in
            guard !present.contains(old.id), !ended.contains(old.id),
                  (-60...90).contains(now.timeIntervalSince(old.observedAt)) else { return nil }
            var retained = old
            retained.trackingIssue = .missing
            return retained
        }
    }
}
