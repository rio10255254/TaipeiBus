import Foundation

public struct BusRoute: Identifiable, Sendable {
    public let id: String
    public let parentID: String
    public let name: String
    public let variantName: String
    public let departure: String
    public let destination: String
    public func destination(direction: String) -> String {
        direction == "0" ? destination : direction == "1" ? departure : "方向未提供"
    }
}

public struct BusStop: Identifiable, Sendable {
    public let id: String
    public let routeID: String
    public let stationID: String
    public let name: String
    public let direction: String
    public var sequence: Int
    public let coordinate: Coordinate
}

public struct Station: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let coordinate: Coordinate
    public let address: String
    public let bearing: String
    public var stopIDs: [String]
    public var bearingLabel: String {
        ["N": "北向", "NE": "東北向", "E": "東向", "SE": "東南向",
         "S": "南向", "SW": "西南向", "W": "西向", "NW": "西北向"][bearing] ?? bearing
    }
}

public struct BusVehicle: Identifiable, Sendable {
    public let id: String
    public let plate: String
    public let routeID: String
    public let parentRouteID: String
    public let routeName: String
    public let direction: String
    public let destination: String
    public var coordinate: Coordinate
    public let rawCoordinate: Coordinate
    public let heading: Double
    public let speed: Double
    public let observedAt: Date
    public let status: String
    public let lowFloor: Bool
    public let provider: String?
    public var aligned: Bool = false
    public var path: [Coordinate] = []

    public func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(observedAt)
        return (-60...120).contains(age)
    }
    public var statusLabel: String {
        ["0": "營運中", "1": "事故", "2": "車輛故障", "3": "交通壅塞",
         "4": "緊急狀況", "5": "加油中"][status] ?? "狀態未提供"
    }
}

public struct StopReference: Sendable {
    public let stopID: String
    public let sequence: Int
}

public struct TransitMetadata: Sendable {
    public var routes: [String: BusRoute] = [:]
    public var parents: [String: BusRoute] = [:]
    public var stops: [String: BusStop] = [:]
    public var stations: [String: Station] = [:]
    public var paths: [String: [StopReference]] = [:]
    public var providers: [String: String] = [:]
    public var lines: [String: RouteLine] = [:]

    public init() {}
    public func route(_ id: String) -> BusRoute? { routes[id] ?? parents[id] }
    public func line(_ id: String) -> RouteLine? {
        lines["sub:\(id)"] ?? lines["route:\(route(id)?.parentID ?? id)"]
    }
    public func orderedStops(routeID: String, direction: String) -> [BusStop] {
        let parent = route(routeID)?.parentID ?? routeID
        let rows: [BusStop]
        if let path = paths[routeID], !path.isEmpty {
            rows = path.compactMap { reference in
                guard var stop = stops[reference.stopID] else { return nil }
                stop.sequence = reference.sequence
                return stop
            }
        } else { rows = stops.values.filter { $0.routeID == parent } }
        return rows.filter { $0.direction == direction }.sorted { $0.sequence < $1.sequence }
    }
}

public struct EstimateFeed: Sendable {
    public let seconds: [String: Int]
    public let updatedAt: Date?
    public var error: String?
    public init(seconds: [String: Int] = [:], updatedAt: Date? = nil, error: String? = nil) {
        self.seconds = seconds; self.updatedAt = updatedAt; self.error = error
    }

    public func value(routeID: String, stopID: String, at date: Date) -> Int? {
        guard error == nil, let updatedAt,
              (-60...120).contains(date.timeIntervalSince(updatedAt)) else { return nil }
        return seconds["\(routeID):\(stopID)"]
    }
    public static func label(_ seconds: Int?) -> String {
        guard let seconds else { return "暫無預估" }
        if seconds < 0 {
            return [-1: "尚未發車", -2: "交管不停靠", -3: "末班已過", -4: "今日未營運"][seconds] ?? "暫無預估"
        }
        return seconds <= 60 ? "1 分鐘內" : "\(Int(ceil(Double(seconds) / 60))) 分鐘"
    }
}

public struct TransitSnapshot: Sendable {
    public var vehicles: [BusVehicle]
    public var sourceUpdatedAt: Date?
    public var receivedAt: Date?
    public var vehicleError: String?
    public var estimates: EstimateFeed
    public var revision: Int
    public init(vehicles: [BusVehicle] = [], sourceUpdatedAt: Date? = nil,
                receivedAt: Date? = nil, vehicleError: String? = nil,
                estimates: EstimateFeed = EstimateFeed(), revision: Int = 0) {
        self.vehicles = vehicles; self.sourceUpdatedAt = sourceUpdatedAt; self.receivedAt = receivedAt
        self.vehicleError = vehicleError; self.estimates = estimates; self.revision = revision
    }
}

/// Official ETA is for a route at a stop. Nearby vehicle IDs are a separate GPS observation.
public struct StationArrival: Identifiable, Sendable {
    public var id: String { "\(stop.routeID):\(stop.direction)" }
    public let stop: BusStop
    public let route: BusRoute?
    public let estimateSeconds: Int?
    public let nearbyVehicles: [BusVehicle]

    public static func rows(station: Station, metadata: TransitMetadata,
                            snapshot: TransitSnapshot, now: Date) -> [StationArrival] {
        var seen = Set<String>()
        return station.stopIDs.compactMap { id -> StationArrival? in
            guard let stop = metadata.stops[id], seen.insert("\(stop.routeID):\(stop.direction)").inserted else { return nil }
            let buses = snapshot.vehicles.filter { bus in
                guard bus.parentRouteID == stop.routeID, bus.direction == stop.direction,
                      bus.isFresh(at: now) else { return false }
                let path = metadata.paths[bus.routeID]
                return path == nil || path!.isEmpty || path!.contains { $0.stopID == id }
            }.sorted { $0.rawCoordinate.distance(to: station.coordinate) < $1.rawCoordinate.distance(to: station.coordinate) }
            return StationArrival(stop: stop, route: metadata.parents[stop.routeID],
                                  estimateSeconds: snapshot.estimates.value(routeID: stop.routeID, stopID: id, at: now),
                                  nearbyVehicles: Array(buses.prefix(2)))
        }.sorted {
            let a = $0.estimateSeconds.flatMap { $0 >= 0 ? $0 : nil } ?? Int.max
            let b = $1.estimateSeconds.flatMap { $0 >= 0 ? $0 : nil } ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
}
