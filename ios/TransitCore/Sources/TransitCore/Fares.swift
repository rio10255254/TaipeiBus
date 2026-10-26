import Foundation

/// Official fares (MOTC TDX, bundled): the adult metro fare between stations and the adult electronic
/// ticket fare of each bus route, with its fare buffer zones. A trip's fare adds up its rides; metro
/// rides one after another are one journey through the gates, and a direct metro↔bus transfer takes off
/// the transfer discount. YouBike is not included.
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

    /// What an adult electronic ticket saves on each direct metro↔bus transfer within the hour (Taipei
    /// Metro: 「捷運與公車雙向轉乘優惠」, 普通卡 NT$8). A YouBike or light-rail ride between breaks it.
    public static let transferDiscount = 8

    /// The fare of a whole trip's rides, or nil when none of them has a known fare. `cycledAfter` holds the
    /// rides followed by a YouBike ride, after which the next ride is not a direct transfer.
    public func estimate(_ rides: [TransitRide], metadata: TransitMetadata, cycledAfter: Set<Int> = []) -> Estimate? {
        guard !rides.isEmpty else { return nil }
        enum Kind { case metro, bus, other }
        // Metro rides in a row are one journey through the gates: one fare unit.
        var units: [(kind: Kind, fare: Int?, located: Bool, first: Int, last: Int)] = []
        var index = 0
        while index < rides.count {
            let ride = rides[index]
            if ride.route.mode == .metro {
                var last = index
                while last + 1 < rides.count, rides[last + 1].route.mode == .metro, !cycledAfter.contains(last) { last += 1 }
                var fare = metroFare(from: ride.boarding.stationID, to: rides[last].alighting.stationID)
                if fare == nil {
                    let legs = rides[index...last].map { metroFare(from: $0.boarding.stationID, to: $0.alighting.stationID) }
                    let known = legs.compactMap { $0 }
                    fare = known.isEmpty ? nil : known.reduce(0, +)
                    units.append((.metro, fare, known.count == legs.count, index, last))
                } else {
                    units.append((.metro, fare, true, index, last))
                }
                index = last + 1
            } else if ride.route.mode == .bus, let fare = busFare(ride, metadata: metadata) {
                units.append((.bus, fare.price, fare.located, index, index)); index += 1
            } else {
                units.append((ride.route.mode == .bus ? .bus : .other, nil, false, index, index)); index += 1
            }
        }
        var total = 0, complete = true, known = false
        for (position, unit) in units.enumerated() {
            guard var fare = unit.fare else { complete = false; continue }
            if position > 0 {
                let previous = units[position - 1]
                let direct = !cycledAfter.contains(previous.last)
                if direct, (previous.kind == .metro && unit.kind == .bus) || (previous.kind == .bus && unit.kind == .metro) {
                    fare = max(0, fare - Self.transferDiscount)
                }
            }
            total += fare; known = true; complete = complete && unit.located
        }
        return known ? Estimate(total: total, complete: complete) : nil
    }
}
