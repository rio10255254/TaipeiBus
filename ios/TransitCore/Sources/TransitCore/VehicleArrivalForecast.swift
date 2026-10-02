import Foundation

public enum VehicleArrivalEstimate: Equatable, Sendable {
    case nearStop
    case minutes(lower: Int, upper: Int)
    case unavailable

    public var label: String {
        switch self {
        case .nearStop: return "已在站牌附近"
        case .minutes(let lower, let upper): return lower == upper ? "約 \(lower) 分" : "約 \(lower)–\(upper) 分"
        case .unavailable: return "暫無法估算"
        }
    }
}

/// A deliberately broad travel-time estimate from received vehicle movement, never a vehicle binding of official ETA.
public struct VehicleArrivalForecast: Sendable {
    private struct Observation: Sendable {
        let route: String
        let direction: String
        let along: Double
        let sign: Int
        let date: Date
    }
    private var history: [String: [Observation]] = [:]
    public init() {}

    public mutating func ingest(_ vehicles: [BusVehicle], metadata: TransitMetadata, at date: Date) {
        var current: [String: [Observation]] = [:]
        for bus in vehicles where bus.hasReliablePosition(at: date) {
            guard bus.aligned, let match = bus.roadMatch,
                  let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction) else { continue }
            var samples = (history[bus.id] ?? []).filter {
                $0.route == bus.routeID && $0.direction == bus.direction && $0.sign == journey.direction &&
                (-60...150).contains(date.timeIntervalSince($0.date))
            }
            if samples.last.map({ bus.observedAt > $0.date }) ?? true {
                samples.append(Observation(route: bus.routeID, direction: bus.direction, along: match.along,
                                           sign: journey.direction, date: bus.observedAt))
            }
            current[bus.id] = Array(samples.suffix(6))
        }
        history = current
    }

    public func estimate(_ approach: VehicleApproach, ride: TransitRide, metadata: TransitMetadata,
                         at date: Date) -> VehicleArrivalEstimate {
        let bus = approach.vehicle
        guard bus.hasReliablePosition(at: date), bus.routeID == ride.route.id, bus.direction == ride.direction,
              let distance = approach.alongDistance, bus.aligned,
              let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction),
              let boarding = journey.progress(stopID: ride.boarding.id, vehicle: bus, at: date), boarding.distance >= -20 else {
            return .unavailable
        }
        if distance <= 40 { return .nearStop }
        var speeds: [Double] = []
        let samples = history[bus.id] ?? []
        for pair in zip(samples, samples.dropFirst()) {
            let interval = pair.1.date.timeIntervalSince(pair.0.date)
            let moved = (pair.1.along - pair.0.along) * Double(pair.1.sign)
            if (10...90).contains(interval), moved >= 15 {
                let speed = moved / interval
                if (0.8...22).contains(speed) { speeds.append(speed) }
            }
        }
        // A single stationary report is not a promise that the bus will depart.
        if speeds.isEmpty, bus.hasSpeed, (5...80).contains(bus.speed) { speeds = [bus.speed / 3.6] }
        guard !speeds.isEmpty else { return .unavailable }
        speeds.sort()
        let speed = speeds[speeds.count / 2]
        let intermediate = journey.upcoming(vehicle: bus, at: date)
            .filter { $0.distance > 40 && $0.distance < distance - 20 }.count
        let fast = min(22, speed * 1.3), slow = max(0.8, speed * 0.55)
        let lower = max(1, Int(ceil((distance / fast + Double(intermediate) * 15) / 60)))
        let upper = max(lower, Int(ceil((distance / slow + Double(intermediate) * 40 + 60) / 60)))
        return .minutes(lower: lower, upper: upper)
    }
}
