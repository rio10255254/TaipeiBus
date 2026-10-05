import Foundation

/// The buses approaching one physical stop, separate from the route's whole fleet.
/// Source route ETAs never identify a plate, so ordering uses verified road progress.
public struct RouteBoardingVehicles: Sendable {
    public enum OtherReason: String, Sendable { case passed, differentPattern, positionUnknown, notRunning }
    public struct Other: Identifiable, Sendable {
        public var id: String { vehicle.id }
        public let vehicle: BusVehicle
        public let reason: OtherReason
    }
    public let approaching: [VehicleApproach]
    public let other: [Other]
    public init(stop: BusStop, vehicles: [BusVehicle], metadata: TransitMetadata, at date: Date) {
        var incoming: [VehicleApproach] = [], remaining: [Other] = []
        for bus in vehicles where bus.direction == stop.direction {
            guard bus.hasReliablePosition(at: date) else {
                remaining.append(Other(vehicle: bus, reason: .positionUnknown)); continue
            }
            guard ["0", "3"].contains(bus.status) else {
                remaining.append(Other(vehicle: bus, reason: .notRunning)); continue
            }
            let stops = metadata.orderedStops(routeID: bus.routeID, direction: bus.direction)
            guard stops.contains(where: { $0.id == stop.id }) else {
                remaining.append(Other(vehicle: bus, reason: .differentPattern)); continue
            }
            guard let progress = metadata.journey(routeID: bus.routeID, direction: bus.direction)?
                .progress(stopID: stop.id, vehicle: bus, at: date) else {
                remaining.append(Other(vehicle: bus, reason: .positionUnknown)); continue
            }
            guard progress.distance >= -20 else {
                remaining.append(Other(vehicle: bus, reason: .passed)); continue
            }
            incoming.append(VehicleApproach(vehicle: bus, alongDistance: max(0, progress.distance),
                directDistance: bus.rawCoordinate.distance(to: stop.coordinate)))
        }
        approaching = incoming.sorted {
            let a = $0.alongDistance ?? .infinity, b = $1.alongDistance ?? .infinity
            return a == b ? $0.id < $1.id : a < b
        }
        other = remaining.sorted { $0.vehicle.plate < $1.vehicle.plate }
    }
}
