import Foundation

public struct VehiclePose: Sendable {
    public let id: String
    public let coordinate: Coordinate
    public let heading: Double
    public let stale: Bool
    /// Distance along received road geometry, used for wheel rotation rather than a wall clock.
    public let traveledDistance: Double
}

/// Animates only between received observations on an official route. No future extrapolation.
public struct VehicleMotion {
    private struct State {
        let vehicle: BusVehicle
        let path: RouteLine
        let startedAt: TimeInterval
        let duration: TimeInterval
        let startHeading: Double
        let startDistance: Double
        let startSlope: Double
        let endSlope: Double

        func progress(time: TimeInterval, stale: Bool = false) -> (fraction: Double, velocity: Double) {
            guard duration > 0, !stale else { return (1, 0) }
            let t = min(1, max(0, (time - startedAt) / duration))
            // A monotone Hermite curve eases leaving and reaching a stop without leaving the known path.
            let t2 = t * t, t3 = t2 * t
            let fraction = (-2 * t3 + 3 * t2) + (t3 - 2 * t2 + t) * startSlope + (t3 - t2) * endSlope
            let derivative = (-6 * t2 + 6 * t) + (3 * t2 - 4 * t + 1) * startSlope + (3 * t2 - 2 * t) * endSlope
            return (min(1, max(0, fraction)), t >= 1 ? 0 : max(0, derivative * path.length / duration))
        }
    }
    private var states: [String: State] = [:]
    public init() {}

    public mutating func ingest(_ vehicles: [BusVehicle], time: TimeInterval, now: Date) {
        var next: [String: State] = [:]
        for vehicle in vehicles {
            let old = states[vehicle.id]
            let sameJourney = old?.vehicle.routeID == vehicle.routeID && old?.vehicle.direction == vehicle.direction
            if let old, sameJourney, vehicle.observedAt <= old.vehicle.observedAt {
                next[vehicle.id] = old
                continue
            }
            var points = [vehicle.coordinate]
            var startHeading = vehicle.heading
            var startDistance = 0.0
            var initialVelocity = 0.0
            var duration = 0.0
            if let old, sameJourney, old.vehicle.isFresh(at: now), vehicle.isFresh(at: now),
               let first = vehicle.path.first, vehicle.path.count >= 2,
               first.distance(to: old.vehicle.coordinate) < 2 {
                let progress = old.progress(time: time)
                let oldPose = pose(state: old, time: time, now: now)
                // Keep every remaining old corner before joining the next official GPS segment.
                points = [oldPose.coordinate]
                let along = progress.fraction * old.path.length
                points += old.path.coordinates.enumerated().compactMap { index, point in
                    old.path.cumulative[index] > along + 0.01 ? point : nil
                }
                points += vehicle.path.dropFirst()
                startHeading = oldPose.heading
                startDistance = oldPose.traveledDistance
                initialVelocity = progress.velocity
                if old.duration == 0 || time >= old.startedAt + old.duration {
                    initialVelocity = old.vehicle.speed / 3.6
                }
                duration = min(20, max(2, vehicle.observedAt.timeIntervalSince(old.vehicle.observedAt)))
            } else if let old, sameJourney, old.vehicle.coordinate.distance(to: vehicle.coordinate) < 0.8 {
                // GPS headings at a stationary stop are noisy; keep the actual rendered orientation.
                let oldPose = pose(state: old, time: time, now: now)
                startHeading = oldPose.heading
                startDistance = oldPose.traveledDistance
            }
            let path = RouteLine(coordinates: points)
            if path.length < 0.2 { duration = 0 }
            let averageVelocity = duration > 0 ? path.length / duration : 0
            var startSlope = averageVelocity > 0 ? min(2.2, initialVelocity / averageVelocity) : 0
            var endSlope = averageVelocity > 0 && vehicle.speed >= 2 ? min(1.8, max(0.3, vehicle.speed / 3.6 / averageVelocity)) : 0
            let sum = startSlope + endSlope
            if sum > 3 { startSlope *= 3 / sum; endSlope *= 3 / sum }
            next[vehicle.id] = State(vehicle: vehicle, path: path, startedAt: time, duration: duration,
                                    startHeading: startHeading, startDistance: startDistance,
                                    startSlope: startSlope, endSlope: endSlope)
        }
        states = next
    }

    public func pose(id: String, time: TimeInterval, now: Date) -> VehiclePose? {
        guard let state = states[id] else { return nil }
        return pose(state: state, time: time, now: now)
    }

    private func pose(state: State, time: TimeInterval, now: Date) -> VehiclePose {
        let stale = !state.vehicle.isFresh(at: now)
        let progress = state.progress(time: time, stale: stale)
        let along = progress.fraction * state.path.length
        let (coordinate, tangent) = state.path.sample(fraction: progress.fraction)
        var heading = state.startHeading
        if state.path.length > 0.2 {
            // A bus-length tangent turns the body smoothly, while its center stays on the road polyline.
            let before = state.path.sample(fraction: max(0, along - 5.5) / state.path.length).0
            let after = state.path.sample(fraction: min(state.path.length, along + 5.5) / state.path.length).0
            heading = before.distance(to: after) > 0.05 ? before.bearing(to: after) : tangent
            let entry = min(1, max(0, (time - state.startedAt) / 0.7))
            heading = Self.blendHeading(state.startHeading, heading, fraction: entry * entry * (3 - 2 * entry))
        }
        return VehiclePose(id: state.vehicle.id, coordinate: coordinate, heading: heading, stale: stale,
                           traveledDistance: state.startDistance + along)
    }

    private static func blendHeading(_ from: Double, _ to: Double, fraction: Double) -> Double {
        let delta = (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
        return (from + delta * fraction + 360).truncatingRemainder(dividingBy: 360)
    }

    public func poses(time: TimeInterval, now: Date) -> [VehiclePose] {
        states.keys.compactMap { pose(id: $0, time: time, now: now) }
    }

    public func isAnimating(time: TimeInterval, now: Date) -> Bool {
        states.values.contains { $0.duration > 0 && time < $0.startedAt + $0.duration && $0.vehicle.isFresh(at: now) }
    }
}
