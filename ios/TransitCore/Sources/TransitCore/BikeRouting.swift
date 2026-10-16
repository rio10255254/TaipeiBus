import Foundation

/// A proposed YouBike connection: walk to a station that has bikes, ride, and leave the bike
/// where there is somewhere to return it. Distances are straight-line planning estimates;
/// the app replaces them with verified pedestrian routes before showing a trip.
public struct BikeConnection: Sendable, Equatable {
    public let pickup: BikeStation
    public let dropoff: BikeStation
    /// What the two stations reported when this connection was planned.
    public let bikes: Int
    public let docks: Int
    public let accessMeters: Double
    public let rideMeters: Double
    public let egressMeters: Double
    public let accessSeconds: Double
    public let rideSeconds: Double
    public let egressSeconds: Double
    public let handlingSeconds: Double
    public var totalSeconds: Double { accessSeconds + handlingSeconds + rideSeconds + egressSeconds }
    public init(pickup: BikeStation, dropoff: BikeStation, bikes: Int, docks: Int,
                accessMeters: Double, rideMeters: Double, egressMeters: Double,
                accessSeconds: Double, rideSeconds: Double, egressSeconds: Double, handlingSeconds: Double) {
        self.pickup = pickup; self.dropoff = dropoff; self.bikes = bikes; self.docks = docks
        self.accessMeters = accessMeters; self.rideMeters = rideMeters; self.egressMeters = egressMeters
        self.accessSeconds = accessSeconds; self.rideSeconds = rideSeconds; self.egressSeconds = egressSeconds
        self.handlingSeconds = handlingSeconds
    }
}

/// Walking and cycling both take the street, not the straight line between two points.
public enum BikeRouting {
    public static let walkingDetour = 1.25
    public static let walkingSpeed = 1.2
    public static let cyclingDetour = 1.35

    public static func walkingSeconds(_ meters: Double) -> Double { meters * walkingDetour / walkingSpeed }

    /// The best pair of stations for riding from `from` to `to`, or nil when cycling is not a
    /// sensible way to cover this leg. Counts must be current: without them the rider could be
    /// sent to an empty station, so no connection is proposed at all.
    public static func connection(from: Coordinate, to: Coordinate, network: BikeNetwork,
                                  availability: BikeAvailability?, preferences: LiveSettings.Planning = .init(),
                                  at date: Date = Date()) -> BikeConnection? {
        connections(from: from, to: to, network: network, availability: availability,
            preferences: preferences, at: date, limit: 1).first
    }

    /// Keep distinct station pairs until the app can compare their real streets.
    public static func connections(from: Coordinate, to: Coordinate, network: BikeNetwork,
                                   availability: BikeAvailability?, preferences: LiveSettings.Planning = .init(),
                                   at date: Date = Date(), limit: Int = 3) -> [BikeConnection] {
        guard preferences.bikeRouting, let availability, !network.stations.isEmpty,
              from.isInServiceArea, to.isInServiceArea, limit > 0 else { return [] }
        let direct = from.distance(to: to)
        guard direct >= preferences.bikeMinimumRideMeters else { return [] }
        func usable(_ station: BikeStation, renting: Bool) -> Int? {
            guard let dock = availability.dock(station.id, at: date), dock.active else { return nil }
            let count = renting ? dock.rentable : dock.returnable
            let needed = renting ? preferences.bikeMinimumBikes : preferences.bikeMinimumDocks
            return Double(count) >= needed ? count : nil
        }
        let pickups = network.stations(near: from, radius: preferences.bikeAccessMeters, limit: network.stations.count)
            .compactMap { station in usable(station, renting: true).map { (station: station, count: $0) } }.prefix(8)
        guard !pickups.isEmpty else { return [] }
        let dropoffs = network.stations(near: to, radius: preferences.bikeAccessMeters, limit: network.stations.count)
            .compactMap { station in usable(station, renting: false).map { (station: station, count: $0) } }.prefix(8)
        guard !dropoffs.isEmpty else { return [] }
        var candidates: [BikeConnection] = []
        for pickup in pickups {
            let access = from.distance(to: pickup.station.coordinate)
            for dropoff in dropoffs where dropoff.station.id != pickup.station.id {
                let straight = pickup.station.coordinate.distance(to: dropoff.station.coordinate)
                guard straight >= preferences.bikeMinimumRideMeters, straight <= preferences.bikeMaximumRideMeters else { continue }
                let egress = dropoff.station.coordinate.distance(to: to)
                // Two detours around the direct line are a walk with extra steps, not a shortcut.
                guard access + straight + egress <= direct * 1.6 + 600 else { continue }
                let ride = straight * cyclingDetour
                let candidate = BikeConnection(pickup: pickup.station, dropoff: dropoff.station,
                    bikes: pickup.count, docks: dropoff.count, accessMeters: access, rideMeters: ride, egressMeters: egress,
                    accessSeconds: walkingSeconds(access), rideSeconds: ride / preferences.bikeSpeed,
                    egressSeconds: walkingSeconds(egress), handlingSeconds: preferences.bikeHandlingSeconds)
                candidates.append(candidate)
            }
        }
        return Array(candidates.sorted {
            let a = $0.totalSeconds + supplyPenalty($0, availability: availability, at: date)
            let b = $1.totalSeconds + supplyPenalty($1, availability: availability, at: date)
            if a != b { return a < b }
            if $0.bikes != $1.bikes { return $0.bikes > $1.bikes }
            return pairID($0) < pairID($1)
        }.prefix(min(8, limit)))
    }

    public static func pairID(_ connection: BikeConnection) -> String { connection.pickup.id + ":" + connection.dropoff.id }

    public static func confirmed(_ station: BikeStation, availability: BikeAvailability?, renting: Bool,
                                 minimum: Int = 2, at date: Date = Date()) -> Bool {
        guard let dock = availability?.dock(station.id, at: date), dock.active else { return false }
        return (renting ? dock.rentable : dock.returnable) >= minimum
    }

    /// An availability preference, not a probability or extra travel time. Sparse or old
    /// reports matter more when the station will only be used later in the journey.
    public static func supplyPenalty(_ connection: BikeConnection, availability: BikeAvailability?,
                                     pickupAfter: Double = 0, dropoffAfter: Double = 0,
                                     at date: Date = Date()) -> Double {
        func cost(_ station: BikeStation, renting: Bool, after: Double) -> Double {
            guard let dock = availability?.dock(station.id, at: date), dock.active else { return .infinity }
            let count = renting ? dock.rentable : dock.returnable
            guard count >= 2 else { return .infinity }
            let low: Double = count <= 2 ? 120 : count <= 5 ? 60 : 0
            let later = count <= 5 ? min(180, max(0, after - 300) / 5) : 0
            let age = min(180, max(0, date.timeIntervalSince(dock.observedAt) - 120) / 3)
            return low + later + age
        }
        return cost(connection.pickup, renting: true, after: pickupAfter) +
            cost(connection.dropoff, renting: false, after: max(pickupAfter + connection.totalSeconds, dropoffAfter))
    }

    /// Cycling replaces a walk only when it saves real time. What counts as real depends on
    /// what it replaces: a walk of ten minutes is worth cutting by two, while a bus someone is
    /// already waiting for is not worth abandoning for the same two.
    public static func worthRiding(_ connection: BikeConnection?, insteadOfWalking meters: Double,
                                   preferences: LiveSettings.Planning = .init(),
                                   gainSeconds: Double? = nil) -> Bool {
        guard let connection else { return false }
        return walkingSeconds(meters) - connection.totalSeconds >= (gainSeconds ?? preferences.bikeWalkGainSeconds)
    }

    /// A station worth riding to before boarding anything: too far to walk to, close enough to
    /// ride, a real step towards the destination, and with docks free to leave the bike in.
    /// Searching from there can find services no stop within walking distance offers.
    public static func gateway(from: Coordinate, to: Coordinate, network: BikeNetwork,
                               availability: BikeAvailability?, preferences: LiveSettings.Planning = .init(),
                               at date: Date = Date()) -> BikeStation? {
        guard preferences.bikeRouting, let availability, from.isInServiceArea, to.isInServiceArea else { return nil }
        let direct = from.distance(to: to)
        guard direct >= 2_000 else { return nil }
        return network.stations(near: from, radius: min(preferences.bikeMaximumRideMeters, 3_000), limit: 150)
            .filter { station in
                guard from.distance(to: station.coordinate) >= 1_200,
                      direct - station.coordinate.distance(to: to) >= 800 else { return false }
                guard let dock = availability.dock(station.id, at: date), dock.active,
                      Double(dock.returnable) >= preferences.bikeMinimumDocks else { return false }
                return true
            }
            .min { $0.coordinate.distance(to: to) < $1.coordinate.distance(to: to) }
    }

    /// Whether a station the rider is walking towards can still be counted on.
    public static func stillUsable(_ station: BikeStation, availability: BikeAvailability?, renting: Bool,
                                   preferences: LiveSettings.Planning = .init(), at date: Date = Date()) -> Bool {
        guard let dock = availability?.dock(station.id, at: date) else { return true }
        guard dock.active else { return false }
        // One bike or one free dock left is not yet a failure, but it is no longer a plan:
        // the rider is told, and offered the nearest station that still holds a few.
        return renting ? dock.rentable >= 1 : dock.returnable >= 1
    }

    /// The nearest station that can replace one that ran out, for a rider already on the way.
    public static func replacement(for station: BikeStation, network: BikeNetwork, availability: BikeAvailability?,
                                   renting: Bool, preferences: LiveSettings.Planning = .init(),
                                   at date: Date = Date()) -> BikeStation? {
        guard let availability else { return nil }
        return network.stations(near: station.coordinate, radius: 500, limit: 10).first { other in
            guard other.id != station.id, let dock = availability.dock(other.id, at: date), dock.active else { return false }
            let count = renting ? dock.rentable : dock.returnable
            return Double(count) >= (renting ? preferences.bikeMinimumBikes : preferences.bikeMinimumDocks)
        }
    }
}
