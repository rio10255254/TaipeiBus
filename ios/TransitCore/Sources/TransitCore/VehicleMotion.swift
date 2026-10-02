import Foundation

public struct VehiclePose: Sendable {
    public let id: String
    public let coordinate: Coordinate
    public let heading: Double
    public let stale: Bool
}

/// Animates only between received observations on an official route. No future extrapolation.
public struct VehicleMotion {
    private struct State {
        let vehicle: BusVehicle
        let path: RouteLine
        let startedAt: TimeInterval
        let duration: TimeInterval
    }
    private var states: [String: State] = [:]
    public init() {}

    public mutating func ingest(_ vehicles: [BusVehicle], time: TimeInterval, now: Date) {
        var next: [String: State] = [:]
        for vehicle in vehicles {
            let old = states[vehicle.id]
            if let old, old.vehicle.routeID == vehicle.routeID, old.vehicle.direction == vehicle.direction,
               old.vehicle.observedAt == vehicle.observedAt {
                next[vehicle.id] = old
                continue
            }
            var points = vehicle.path
            let canAnimate = old != nil && old!.vehicle.routeID == vehicle.routeID &&
                old!.vehicle.direction == vehicle.direction && vehicle.isFresh(at: now) &&
                vehicle.observedAt > old!.vehicle.observedAt && points.count >= 2
            if !canAnimate { points = [vehicle.coordinate] }
            let duration = canAnimate ? min(12, max(1.8, vehicle.observedAt.timeIntervalSince(old!.vehicle.observedAt) * 0.8)) : 0
            next[vehicle.id] = State(vehicle: vehicle, path: RouteLine(coordinates: points), startedAt: time, duration: duration)
        }
        states = next
    }

    public func pose(id: String, time: TimeInterval, now: Date) -> VehiclePose? {
        guard let state = states[id] else { return nil }
        let stale = !state.vehicle.isFresh(at: now)
        let fraction = state.duration > 0 && !stale ? min(1, max(0, (time - state.startedAt) / state.duration)) : 1
        let (coordinate, segmentHeading) = state.path.sample(fraction: fraction)
        return VehiclePose(id: id, coordinate: coordinate,
                           heading: state.duration > 0 && fraction < 1 ? segmentHeading : state.vehicle.heading,
                           stale: stale)
    }

    public func poses(time: TimeInterval, now: Date) -> [VehiclePose] {
        states.keys.compactMap { pose(id: $0, time: time, now: now) }
    }

    public func isAnimating(time: TimeInterval, now: Date) -> Bool {
        states.values.contains { $0.duration > 0 && time < $0.startedAt + $0.duration && $0.vehicle.isFresh(at: now) }
    }
}
