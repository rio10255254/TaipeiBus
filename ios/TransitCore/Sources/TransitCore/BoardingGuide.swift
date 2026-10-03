import Foundation

public struct BoardingGuide: Sendable {
    public let ride: TransitRide
    public let station: Station?
    public let estimateSeconds: Int?
    public let estimateUpdatedAt: Date?
    public let approaches: [VehicleApproach]

    public init(ride: TransitRide, metadata: TransitMetadata, snapshot: TransitSnapshot, at date: Date) {
        self.ride = ride
        station = metadata.stations[ride.boarding.stationID]
        estimateSeconds = snapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: date)
        estimateUpdatedAt = estimateSeconds == nil ? nil : snapshot.estimates.updatedAt
        approaches = [-2, -3, -4].contains(estimateSeconds ?? 0) ? [] :
            Self.vehicles(ride: ride, metadata: metadata, snapshot: snapshot, at: date, approachingOnly: true)
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
        snapshot.vehicles.compactMap { bus -> VehicleApproach? in
            guard bus.routeID == ride.route.id, bus.direction == ride.direction,
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
