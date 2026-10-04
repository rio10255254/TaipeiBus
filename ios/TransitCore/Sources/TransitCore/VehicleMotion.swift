import Foundation

public struct VehiclePose: Sendable {
    public let id: String
    public let coordinate: Coordinate
    public let heading: Double
    public let stale: Bool
    /// Distance along received road geometry, used for wheel rotation rather than a wall clock.
    public let traveledDistance: Double
    /// GPS time represented by this point on the buffered, received trajectory.
    public let observedAt: Date
}

/// Animates only between received observations on an official route. No future extrapolation.
public struct VehicleMotion {
    private struct State {
        var vehicle: BusVehicle
        let path: RouteLine
        let bounds: GeoBounds
        let startedAt: TimeInterval
        let duration: TimeInterval
        let startHeading: Double
        let startDistance: Double
        let startSlope: Double
        let endSlope: Double
        let shortPathHeading: Double?
        let startObservedAt: Date

        init(vehicle: BusVehicle, path: RouteLine, startedAt: TimeInterval, duration: TimeInterval,
             startHeading: Double, startDistance: Double, startSlope: Double, endSlope: Double,
             startObservedAt: Date) {
            self.vehicle = vehicle; self.path = path; self.bounds = GeoBounds(path.coordinates)
            self.startedAt = startedAt; self.duration = duration
            self.startHeading = startHeading; self.startDistance = startDistance
            self.startSlope = startSlope; self.endSlope = endSlope
            self.startObservedAt = startObservedAt
            if path.length > 0.2, path.length <= 5.5 {
                let first = path.sample(fraction: 0).0, last = path.sample(fraction: 1).0
                shortPathHeading = first.distance(to: last) > 0.05 ? first.bearing(to: last) : nil
            } else { shortPathHeading = nil }
        }
        var endsAt: TimeInterval { startedAt + duration }
        var endVelocity: Double { duration > 0 ? endSlope * path.length / duration : 0 }

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
    private struct Track {
        var vehicle: BusVehicle
        var legs: [State]
        let bounds: GeoBounds
        init(vehicle: BusVehicle, legs: [State]) {
            self.vehicle = vehicle; self.legs = legs
            self.bounds = legs.reduce(GeoBounds([vehicle.coordinate])) { $0.union($1.bounds) }
        }
    }
    private var states: [String: Track] = [:]
    private static let maximumBuffer: TimeInterval = 20
    public init() {}

    public mutating func ingest(_ vehicles: [BusVehicle], time: TimeInterval, now: Date) {
        var next: [String: Track] = [:]
        for vehicle in vehicles {
            let old = states[vehicle.id]
            let sameJourney = old?.vehicle.routeID == vehicle.routeID && old?.vehicle.direction == vehicle.direction
            if let old, sameJourney, vehicle.observedAt <= old.vehicle.observedAt {
                var retained = old
                if vehicle.observedAt == old.vehicle.observedAt { retained.vehicle = vehicle }
                next[vehicle.id] = retained
                continue
            }
            var points = [vehicle.coordinate]
            var pending: [State] = []
            var startedAt = time
            var startHeading = vehicle.heading
            var startDistance = 0.0
            var initialVelocity = 0.0
            var duration = 0.0
            var startObservedAt = vehicle.observedAt
            var incomingPath = vehicle.path
            if let old, sameJourney, incomingPath.count < 2, (!vehicle.aligned || !old.vehicle.aligned),
               old.vehicle.trackingIssue == nil, vehicle.trackingIssue == nil {
                let interval = vehicle.observedAt.timeIntervalSince(old.vehicle.observedAt)
                let distance = old.vehicle.coordinate.distance(to: vehicle.coordinate)
                if (0...90).contains(interval), distance >= 0.8, distance <= max(100, interval * 25) {
                    // When road geometry is unavailable, interpolate only the two accepted GPS points.
                    incomingPath = [old.vehicle.coordinate, vehicle.coordinate]
                }
            }
            if let old, sameJourney, old.vehicle.isFresh(at: now), vehicle.isFresh(at: now),
               let first = incomingPath.first, incomingPath.count >= 2,
               first.distance(to: old.vehicle.coordinate) < 2 {
                let oldPose = pose(track: old, time: time, now: now)
                pending = old.legs.filter { $0.endsAt > time }
                points = incomingPath
                startObservedAt = old.vehicle.observedAt
                duration = min(Self.maximumBuffer, max(1, vehicle.observedAt.timeIntervalSince(old.vehicle.observedAt)))
                if let prior = pending.last {
                    startedAt = prior.endsAt
                    let endpoint = pose(state: prior, time: prior.endsAt, stale: false)
                    startHeading = endpoint.heading
                    startDistance = prior.startDistance + prior.path.length
                    initialVelocity = prior.endVelocity
                } else {
                    startHeading = oldPose.heading
                    startDistance = oldPose.traveledDistance
                    initialVelocity = old.vehicle.hasSpeed ? old.vehicle.speed / 3.6 : 0
                }
                // Keep an in-flight GPS leg untouched. Early packets queue the next leg instead of
                // repeatedly stretching or accelerating the remainder of the previous road segment.
                if startedAt + duration - time > Self.maximumBuffer {
                    points = [oldPose.coordinate]
                    for (index, leg) in pending.enumerated() {
                        let along = index == 0 ? leg.progress(time: time).fraction * leg.path.length : 0
                        points += leg.path.coordinates.enumerated().compactMap { pointIndex, point in
                            leg.path.cumulative[pointIndex] > along + 0.01 ? point : nil
                        }
                    }
                    points += incomingPath.dropFirst()
                    pending.removeAll(); startedAt = time; duration = Self.maximumBuffer
                    startHeading = oldPose.heading; startDistance = oldPose.traveledDistance
                    startObservedAt = oldPose.observedAt
                    if let active = old.legs.first(where: { $0.endsAt > time }) {
                        initialVelocity = active.progress(time: time).velocity
                    }
                }
            } else if let old, sameJourney, old.vehicle.coordinate.distance(to: vehicle.coordinate) < 0.8 {
                // A new stopped fix at the same endpoint must not teleport the still-playing bus there.
                let oldPose = pose(track: old, time: time, now: now)
                startHeading = oldPose.heading
                startDistance = oldPose.traveledDistance
                pending = old.legs.filter { $0.endsAt > time }
                if let prior = pending.last {
                    startedAt = prior.endsAt
                    startHeading = pose(state: prior, time: prior.endsAt, stale: false).heading
                    startDistance = prior.startDistance + prior.path.length
                }
            }
            let path = RouteLine(coordinates: points)
            if path.length < 0.2 { duration = 0 }
            let averageVelocity = duration > 0 ? path.length / duration : 0
            var startSlope = averageVelocity > 0 ? min(2.2, initialVelocity / averageVelocity) : 0
            let moving = !vehicle.hasSpeed || vehicle.speed >= 2
            let endVelocity = moving ? min(averageVelocity * 1.5,
                averageVelocity * 0.7 + (vehicle.hasSpeed ? vehicle.speed / 3.6 : averageVelocity) * 0.3) : 0
            var endSlope = averageVelocity > 0 ? endVelocity / averageVelocity : 0
            let sum = startSlope + endSlope
            if sum > 3 { startSlope *= 3 / sum; endSlope *= 3 / sum }
            pending.append(State(vehicle: vehicle, path: path, startedAt: startedAt, duration: duration,
                                 startHeading: startHeading, startDistance: startDistance,
                                 startSlope: startSlope, endSlope: endSlope, startObservedAt: startObservedAt))
            next[vehicle.id] = Track(vehicle: vehicle, legs: pending)
        }
        states = next
    }

    public func pose(id: String, time: TimeInterval, now: Date) -> VehiclePose? {
        guard let state = states[id] else { return nil }
        return pose(track: state, time: time, now: now)
    }
    public func observation(id: String) -> BusVehicle? { states[id]?.vehicle }

    private func pose(track: Track, time: TimeInterval, now: Date) -> VehiclePose {
        let stale = !track.vehicle.isFresh(at: now)
        let leg = stale ? track.legs.last! : track.legs.first(where: { $0.endsAt > time }) ?? track.legs.last!
        let result = pose(state: leg, time: time, stale: stale)
        return VehiclePose(id: result.id, coordinate: result.coordinate, heading: result.heading,
            stale: stale || track.vehicle.trackingIssue != nil, traveledDistance: result.traveledDistance,
            observedAt: result.observedAt)
    }

    private func pose(state: State, time: TimeInterval, stale: Bool) -> VehiclePose {
        let progress = state.progress(time: time, stale: stale)
        let along = progress.fraction * state.path.length
        let (coordinate, tangent) = state.path.sample(fraction: progress.fraction)
        var heading = state.startHeading
        if state.path.length > 0.2 {
            if let fixed = state.shortPathHeading { heading = fixed }
            else {
                // A bus-length tangent turns the body smoothly, while its center stays on the road polyline.
                let before = state.path.sample(fraction: max(0, along - 5.5) / state.path.length).0
                let after = state.path.sample(fraction: min(state.path.length, along + 5.5) / state.path.length).0
                heading = before.distance(to: after) > 0.05 ? before.bearing(to: after) : tangent
            }
            let entry = min(1, max(0, (time - state.startedAt) / 0.7))
            heading = Self.blendHeading(state.startHeading, heading, fraction: entry * entry * (3 - 2 * entry))
        }
        return VehiclePose(id: state.vehicle.id, coordinate: coordinate, heading: heading,
                           stale: stale || state.vehicle.trackingIssue != nil,
                           traveledDistance: state.startDistance + along,
                           observedAt: state.startObservedAt.addingTimeInterval(
                            state.vehicle.observedAt.timeIntervalSince(state.startObservedAt) * progress.fraction))
    }

    private static func blendHeading(_ from: Double, _ to: Double, fraction: Double) -> Double {
        let delta = (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
        return (from + delta * fraction + 360).truncatingRemainder(dividingBy: 360)
    }

    public func poses(time: TimeInterval, now: Date) -> [VehiclePose] {
        states.values.map { pose(track: $0, time: time, now: now) }
    }

    public func poses(time: TimeInterval, now: Date, in bounds: GeoBounds, including selectedID: String?) -> [VehiclePose] {
        states.values.compactMap { track in
            guard track.vehicle.id == selectedID || track.bounds.intersects(bounds) else { return nil }
            return pose(track: track, time: time, now: now)
        }
    }

    /// Accessibility changes can end an in-flight transition without waiting for a new GPS timestamp.
    public mutating func finishAnimations(time: TimeInterval, now: Date) {
        states = states.mapValues { state in
            let end = pose(track: state, time: max(time, state.legs.last!.endsAt), now: now)
            let leg = State(vehicle: state.vehicle, path: RouteLine(coordinates: [state.vehicle.coordinate]),
                         startedAt: time, duration: 0, startHeading: end.heading,
                         startDistance: end.traveledDistance, startSlope: 0, endSlope: 0,
                         startObservedAt: state.vehicle.observedAt)
            return Track(vehicle: state.vehicle, legs: [leg])
        }
    }

    public func isAnimating(time: TimeInterval, now: Date) -> Bool {
        states.values.contains { $0.legs.last!.endsAt > time && $0.vehicle.isFresh(at: now) }
    }
}
