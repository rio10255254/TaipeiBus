import Foundation

public struct BusRoute: Identifiable, Sendable {
    public let id: String
    public let parentID: String
    public let name: String
    public let variantName: String
    public let departure: String
    public let destination: String
    public var englishName: String = ""
    public var englishVariantName: String = ""
    public var englishDeparture: String = ""
    public var englishDestination: String = ""
    public var aliasName: String = ""
    public var serviceWindows: [String: [BusServiceWindow]] = [:]
    public var servicePlans: [String: BusServicePlan] = [:]
    public var displayName: String { variantName.isEmpty ? name : variantName }
    public var localizedName: String { AppLanguage.current == .english && !englishName.isEmpty ? englishName : name }
    public var localizedDisplayName: String {
        AppLanguage.current == .english ? (englishVariantName.isEmpty ? localizedName : englishVariantName) : displayName
    }
    public func localizedDestination(direction: String) -> String {
        let english = direction == "0" ? englishDestination : direction == "1" ? englishDeparture : ""
        return AppLanguage.current == .english && !english.isEmpty ? english : AppText.text(destination(direction: direction))
    }
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
    public var englishName: String = ""
    public var localizedName: String { AppLanguage.current == .english && !englishName.isEmpty ? englishName : name }
    public var bilingualName: String { localizedName == name ? name : localizedName + "\n" + name }
}

public struct Station: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let coordinate: Coordinate
    public let address: String
    public let bearing: String
    public var stopIDs: [String]
    public var searchNames: [String] = []
    public var englishName: String = ""
    public var localizedName: String { AppLanguage.current == .english && !englishName.isEmpty ? englishName : name }
    public var bilingualName: String { localizedName == name ? name : localizedName + "\n" + name }
    public var localizedBearing: String { AppText.text(bearingLabel) }
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
    public var heading: Double
    public let speed: Double
    public var observedAt: Date
    public let status: String
    public let lowFloor: Bool
    public let provider: String?
    public var englishRouteName: String = ""
    public var englishDestination: String = ""
    public var localizedRouteName: String { AppLanguage.current == .english && !englishRouteName.isEmpty ? englishRouteName : routeName }
    public var localizedDestination: String { AppLanguage.current == .english && !englishDestination.isEmpty ? englishDestination : AppText.text(destination) }
    public var englishProvider: String? = nil
    public var localizedProvider: String? { AppLanguage.current == .english ? englishProvider ?? provider : provider }
    public var aligned: Bool = false
    public var path: [Coordinate] = []
    public var roadMatch: LineMatch?
    public var travelDirection: Int = 0
    public var hasHeading = true
    public var hasSpeed = true
    public var trackingIssue: TrackingIssue?
    public var rejectedObservation: RejectedObservation?

    public func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(observedAt)
        return (-60...120).contains(age)
    }
    public func hasReliablePosition(at date: Date) -> Bool { isFresh(at: date) && trackingIssue == nil }
    public var speedLabel: String { hasSpeed ? "\(Int(speed)) km/h" : AppText.text("速度未提供") }
    public func trackingLabel(at date: Date) -> String? {
        if !isFresh(at: date) { return AppText.text("定位已延遲") }
        switch trackingIssue {
        case .missing: return AppText.text("訊號暫缺，保留最後位置")
        case .rejected: return AppText.text("定位跳動，等待確認")
        case nil: return aligned ? nil : AppText.text("原始 GPS · 軌跡未確認")
        }
    }
    public var statusLabel: String {
        AppText.text(["0": "營運中", "1": "事故", "2": "車輛故障", "3": "交通壅塞",
         "4": "緊急狀況", "5": "加油中"][status] ?? "狀態未提供")
    }
}

public enum TrackingIssue: Sendable { case missing, rejected }
public struct RejectedObservation: Sendable {
    public let coordinate: Coordinate
    public let observedAt: Date
}

public struct StopReference: Sendable {
    public let stopID: String
    public let sequence: Int
}

public struct TransitMetadata: Sendable {
    public var officialTravelTimes = OfficialTravelTimes()
    public let revision = UUID()
    public var routes: [String: BusRoute] = [:]
    public var parents: [String: BusRoute] = [:]
    public var stops: [String: BusStop] = [:]
    public var stations: [String: Station] = [:]
    public var paths: [String: [StopReference]] = [:]
    public var providers: [String: String] = [:]
    public var englishProviders: [String: String] = [:]
    public var lines: [String: RouteLine] = [:]
    public var directionalLines: [String: RouteLine] = [:]
    public var journeys: [String: RouteJourney] = [:]
    public var routeCatalog = RouteCatalog()
    public var stationSearch = StationSearchIndex()

    public init() {}
    public func route(_ id: String) -> BusRoute? { routes[id] ?? parents[id] }
    public func line(_ id: String, direction: String? = nil) -> RouteLine? {
        let parent = route(id)?.parentID ?? id
        if let direction {
            // Some single-direction subroutes publish their sole shape as GoBack=0 for both trip directions.
            // Their exact subroute shape still takes precedence over a parent fallback.
            return directionalLines["sub:\(id):\(direction)"] ?? lines["sub:\(id)"] ??
                directionalLines["route:\(parent):\(direction)"] ?? lines["route:\(parent)"]
        }
        return lines["sub:\(id)"] ?? lines["route:\(parent)"]
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
    public func journey(routeID: String, direction: String) -> RouteJourney? { journeys["\(routeID):\(direction)"] }
    public mutating func rebuildJourneys() {
        journeys = [:]
        for route in routes.values {
            for direction in ["0", "1"] {
                guard let line = line(route.id, direction: direction) else { continue }
                if let journey = RouteJourney.build(stops: orderedStops(routeID: route.id, direction: direction),
                    line: line, stations: stations) { journeys["\(route.id):\(direction)"] = journey }
            }
        }
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
        guard let value = seconds["\(routeID):\(stopID)"] else { return nil }
        if value < 0 { return value }
        // The published estimate belongs to the source timestamp, not the latest HTTP request.
        let elapsed = max(0, Int(date.timeIntervalSince(updatedAt).rounded(.down)))
        return max(0, value - elapsed)
    }
    public static func label(_ seconds: Int?) -> String {
        guard let seconds else { return AppText.text("暫無預估") }
        if seconds < 0 {
            return AppText.text([-1: "尚未發車", -2: "交管不停靠", -3: "末班已過", -4: "今日未營運"][seconds] ?? "暫無預估")
        }
        return seconds <= 60 ? AppText.text("1 分鐘內") : AppText.text("%@ 分鐘", max(1, seconds / 60))
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
public struct VehicleApproach: Identifiable, Sendable {
    public var id: String { vehicle.id }
    public let vehicle: BusVehicle
    public let alongDistance: Double?
    public let directDistance: Double
}

public struct StationArrival: Identifiable, Sendable {
    public var id: String { "\(stop.routeID):\(stop.direction)" }
    public let stop: BusStop
    public let route: BusRoute?
    public let estimateSeconds: Int?
    public let approaches: [VehicleApproach]
    public var nearbyVehicles: [BusVehicle] { approaches.map(\.vehicle) }

    public static func rows(station: Station, metadata: TransitMetadata,
                            snapshot: TransitSnapshot, now: Date) -> [StationArrival] {
        var seen = Set<String>()
        return station.stopIDs.compactMap { id -> StationArrival? in
            guard let stop = metadata.stops[id], seen.insert("\(stop.routeID):\(stop.direction)").inserted else { return nil }
            let buses = snapshot.vehicles.compactMap { bus -> VehicleApproach? in
                guard bus.parentRouteID == stop.routeID, bus.direction == stop.direction,
                      bus.hasReliablePosition(at: now) else { return nil }
                let path = metadata.paths[bus.routeID]
                guard path == nil || path!.isEmpty || path!.contains(where: { $0.stopID == id }) else { return nil }
                let progress = metadata.journey(routeID: bus.routeID, direction: bus.direction)?.progress(stopID: id, vehicle: bus, at: now)
                if let progress, progress.distance < -20 { return nil }
                return VehicleApproach(vehicle: bus, alongDistance: progress.map { max(0, $0.distance) },
                                       directDistance: bus.rawCoordinate.distance(to: station.coordinate))
            }.sorted {
                if ($0.alongDistance != nil) != ($1.alongDistance != nil) { return $0.alongDistance != nil }
                return ($0.alongDistance ?? $0.directDistance) < ($1.alongDistance ?? $1.directDistance)
            }
            return StationArrival(stop: stop, route: metadata.parents[stop.routeID],
                                  estimateSeconds: snapshot.estimates.value(routeID: stop.routeID, stopID: id, at: now),
                                  approaches: Array(buses.prefix(2)))
        }.sorted {
            let a = $0.estimateSeconds.flatMap { $0 >= 0 ? $0 : nil } ?? Int.max
            let b = $1.estimateSeconds.flatMap { $0 >= 0 ? $0 : nil } ?? Int.max
            return a == b ? $0.id < $1.id : a < b
        }
    }
}
