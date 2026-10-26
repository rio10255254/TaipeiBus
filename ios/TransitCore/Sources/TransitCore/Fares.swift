import Foundation

/// Official fares (MOTC TDX, bundled): the adult metro fare between stations and the adult electronic
/// ticket fare of each bus route, with its fare buffer zones. A trip's fare adds up its rides; metro
/// rides one after another are one journey through the gates. Transfer discounts and YouBike are not
/// included, so a trip's total is an upper estimate.
public struct FareTable: Sendable {
    struct Metro: Decodable, Sendable { let stations: [String]; let adult: [[Int?]] }
    struct Bus: Decodable, Sendable { let name: String; let price: Int; let free: Bool; let zones: [[String]] }
    private struct File: Decodable { let updated: String; let metro: [String: Metro]; let bus: [String: Bus] }

    let metro: [String: Metro]
    let bus: [String: Bus]
    private let positions: [String: [String: Int]]
    /// The day the official tables were last updated.
    public let updated: String

    public static let shared: FareTable = {
        guard let url = Bundle.module.url(forResource: "fares", withExtension: "json"),
              let data = try? Data(contentsOf: url), let table = try? FareTable(data: data) else { return FareTable() }
        return table
    }()

    init() { metro = [:]; bus = [:]; positions = [:]; updated = "" }
    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        metro = file.metro; bus = file.bus; updated = file.updated
        positions = file.metro.mapValues { table in
            Dictionary(table.stations.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// A trip's fare and whether every ride of it is known.
    public struct Estimate: Equatable, Sendable {
        public let total: Int
        public let complete: Bool
    }

    /// The adult metro fare between two stations ("metro:TRTC:BL15"), when one operator's table has both.
    public func metroFare(from: String, to: String) -> Int? {
        let a = from.split(separator: ":"), b = to.split(separator: ":")
        guard a.count == 3, b.count == 3, a[1] == b[1], let table = metro[String(a[1])],
              let i = positions[String(a[1])]?[String(a[2])], let j = positions[String(b[1])]?[String(b[2])] else { return nil }
        return table.adult[i][j]
    }

    /// A bus ride's fare: one section, and one more for each fare buffer zone ridden right through. Nil
    /// when the route has no official fare; `located` is false when a zone's stops were not found.
    public func busFare(_ ride: TransitRide, metadata: TransitMetadata) -> (price: Int, located: Bool)? {
        guard let route = bus[ride.route.parentID] ?? bus[ride.route.id] else { return nil }
        if route.free { return (0, true) }
        let zones = route.zones.filter { $0.count == 5 && $0[0] == ride.direction }
        guard !zones.isEmpty else { return (route.price, true) }
        let stops = metadata.orderedStops(routeID: ride.route.id, direction: ride.direction)
        func sequence(_ id: String, _ name: String) -> Int? {
            stops.first { $0.id == id }?.sequence ?? stops.first { StationSearch.normalize($0.name) == StationSearch.normalize(name) }?.sequence
        }
        let from = ride.boarding.sequence, to = ride.alighting.sequence
        var sections = 1, located = true
        for zone in zones {
            guard let a = sequence(zone[1], zone[2]), let b = sequence(zone[3], zone[4]) else { located = false; continue }
            if from < min(a, b), to > max(a, b) { sections += 1 }
        }
        return (route.price * sections, located)
    }

    /// The fare of a whole trip's rides, or nil when none of them has a known fare.
    public func estimate(_ rides: [TransitRide], metadata: TransitMetadata) -> Estimate? {
        guard !rides.isEmpty else { return nil }
        var total = 0, complete = true, known = false, index = 0
        while index < rides.count {
            let ride = rides[index]
            if ride.route.mode == .metro {
                // Metro rides in a row are one journey through the gates.
                var last = index
                while last + 1 < rides.count, rides[last + 1].route.mode == .metro { last += 1 }
                if let fare = metroFare(from: ride.boarding.stationID, to: rides[last].alighting.stationID) {
                    total += fare; known = true
                } else {
                    for leg in rides[index...last] {
                        if let fare = metroFare(from: leg.boarding.stationID, to: leg.alighting.stationID) { total += fare; known = true }
                        else { complete = false }
                    }
                }
                index = last + 1
                continue
            }
            if ride.route.mode == .bus, let fare = busFare(ride, metadata: metadata) {
                total += fare.price; known = true; complete = complete && fare.located
            } else {
                complete = false
            }
            index += 1
        }
        return known ? Estimate(total: total, complete: complete) : nil
    }
}
