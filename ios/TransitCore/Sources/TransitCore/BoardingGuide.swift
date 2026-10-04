import Foundation

public struct BoardingGuide: Sendable {
    public let ride: TransitRide
    public let station: Station?
    public let estimateSeconds: Int?
    public let estimateUpdatedAt: Date?
    public let approaches: [VehicleApproach]
    public let emptyPositionLabel: String

    public init(ride: TransitRide, metadata: TransitMetadata, snapshot: TransitSnapshot, at date: Date) {
        self.ride = ride
        station = metadata.stations[ride.boarding.stationID]
        estimateSeconds = snapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: date)
        estimateUpdatedAt = estimateSeconds == nil ? nil : snapshot.estimates.updatedAt
        approaches = [-2, -3, -4].contains(estimateSeconds ?? 0) ? [] :
            Self.vehicles(ride: ride, metadata: metadata, snapshot: snapshot, at: date, approachingOnly: true)
        if [-2, -3, -4].contains(estimateSeconds ?? 0) { emptyPositionLabel = "目前未發車" }
        else if !Self.vehicles(ride: ride, metadata: metadata, snapshot: snapshot, at: date, approachingOnly: false).isEmpty,
                approaches.isEmpty { emptyPositionLabel = "前車已過站 · 等待後續車輛" }
        else if estimateSeconds != nil { emptyPositionLabel = "到站預估可用 · GPS 暫缺" }
        else { emptyPositionLabel = snapshot.vehicleError == nil ? "此方向暫無車輛回報" : "車輛定位更新中" }
    }

    public var arrivalLabel: String {
        guard let seconds = estimateSeconds else { return "目前沒有到站預估" }
        if seconds < 0 { return EstimateFeed.label(seconds) }
        return seconds <= 60 ? "即將到上車站" : "約 \(max(1, seconds / 60)) 分鐘到上車站"
    }

    public var arrivalShortLabel: String {
        guard let seconds = estimateSeconds else { return "—" }
        if seconds < 0 { return EstimateFeed.label(seconds) }
        return seconds <= 60 ? "即將到站" : "\(max(1, seconds / 60)) 分"
    }

    public static func vehicles(ride: TransitRide, metadata: TransitMetadata, snapshot: TransitSnapshot,
                                at date: Date, approachingOnly: Bool) -> [VehicleApproach] {
        let routeIDs = metadata.routeIDs(serving: ride)
        return snapshot.vehicles.compactMap { bus -> VehicleApproach? in
            guard routeIDs.contains(bus.routeID), bus.direction == ride.direction,
                  bus.hasReliablePosition(at: date), ["0", "3"].contains(bus.status) else { return nil }
            let progress = metadata.journey(routeID: bus.routeID, direction: bus.direction)?
                .progress(stopID: ride.boarding.id, vehicle: bus, at: date)
            if approachingOnly, let progress, progress.distance < -20 { return nil }
            return VehicleApproach(vehicle: bus, alongDistance: progress.map { max(0, $0.distance) },
                                   directDistance: bus.rawCoordinate.distance(to: ride.boarding.coordinate))
        }.sorted {
            if ($0.alongDistance != nil) != ($1.alongDistance != nil) { return $0.alongDistance != nil }
            let a = $0.alongDistance ?? $0.directDistance, b = $1.alongDistance ?? $1.directDistance
            return a == b ? $0.id < $1.id : a < b
        }
    }
}

public extension TransitMetadata {
    /// Co-operated variants can carry the same ride only when every stop between
    /// boarding and alighting matches, in order. A common route name is insufficient.
    func routeIDs(serving ride: TransitRide) -> Set<String> {
        let required = ride.stops.map(\.id)
        func serves(_ id: String) -> Bool {
            let stops = orderedStops(routeID: id, direction: ride.direction).map(\.id)
            guard let start = stops.firstIndex(of: ride.boarding.id), start + required.count <= stops.count else { return false }
            return Array(stops[start..<(start + required.count)]) == required
        }
        var ids = Set(variants(routeID: ride.route.id).filter { serves($0.id) }.map(\.id))
        ids.insert(ride.route.id)
        if serves(ride.route.parentID) { ids.insert(ride.route.parentID) }
        return ids
    }
    func canServe(_ ride: TransitRide, vehicle: BusVehicle) -> Bool {
        vehicle.direction == ride.direction && routeIDs(serving: ride).contains(vehicle.routeID)
    }
}
