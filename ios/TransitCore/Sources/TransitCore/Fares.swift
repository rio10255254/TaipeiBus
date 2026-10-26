import Foundation

/// The rider's ticket type on an EasyCard or iPASS: which official fare each ride charges and how much a
/// metro↔bus transfer takes off. Raw values are the class names in the bundled fare table.
public enum FareClass: String, CaseIterable, Codable, Identifiable, Sendable {
    case adult, student, child, elderly, disabled
    public var id: String { rawValue }

    /// The ticket's Chinese name, as riders and the voice assistant say it: 「學生票」.
    public var ticketName: String {
        switch self {
        case .adult: "全票"
        case .student: "學生票"
        case .child: "孩童票"
        case .elderly: "敬老票"
        case .disabled: "愛心票"
        }
    }

    /// The ticket's name in the app's language.
    public var title: String {
        switch self {
        case .adult: AppText.text("全票")
        case .student: AppText.text("學生票")
        case .child: AppText.text("孩童票")
        case .elderly: AppText.text("敬老票")
        case .disabled: AppText.text("愛心票")
        }
    }

    /// What each direct metro↔bus transfer within the hour saves (Taipei Metro: 「捷運與公車雙向轉乘優惠」,
    /// 普通卡 NT$8, 學生卡 NT$6, 優待卡 NT$4 for children, seniors and riders with disabilities).
    public var transferDiscount: Int {
        switch self {
        case .adult: 8
        case .student: 6
        case .child, .elderly, .disabled: 4
        }
    }

    /// The class whose metro fares this rider pays: Taipei Metro has no student fare, so students pay adult.
    var metroClass: FareClass { self == .student ? .adult : self }
}

/// Official fares (MOTC TDX, bundled): the metro fare between stations and the electronic ticket fare of
/// each bus route, per rider class, with the bus fare buffer zones. A trip's fare adds up its rides; metro
/// rides one after another are one journey through the gates, and a direct metro↔bus transfer takes off
/// the class's transfer discount. A TPASS 基北北桃 monthly pass covers both metro operators and the city
/// buses in the table. YouBike is not included.
public struct FareTable: Sendable {
    struct Metro: Decodable, Sendable {
        let stations: [String]
        /// Each class's index into `matrices`; classes with identical fares share one matrix.
        let classes: [String: Int]
        let matrices: [[[Int?]]]
    }
    struct Bus: Decodable, Sendable { let name: String; let fare: Int; let free: Bool; let zones: [[String]] }
    private struct File: Decodable { let updated: String; let metro: [String: Metro]; let busFares: [[String: Int]]; let bus: [String: Bus] }

    let metro: [String: Metro]
    let bus: [String: Bus]
    /// One section's fare per class, shared by the routes that charge the same.
    let busFares: [[String: Int]]
    private let positions: [String: [String: Int]]
    /// The day the official tables were last updated.
    public let updated: String

    /// The metro operators and, through the bus table, the city buses a TPASS 基北北桃 pass covers.
    static let passOperators: Set<String> = ["TRTC", "NTMC"]

    public static let shared: FareTable = {
        guard let url = Bundle.module.url(forResource: "fares", withExtension: "json"),
              let data = try? Data(contentsOf: url), let table = try? FareTable(data: data) else { return FareTable() }
        return table
    }()

    init() { metro = [:]; bus = [:]; busFares = []; positions = [:]; updated = "" }
    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        metro = file.metro; bus = file.bus; busFares = file.busFares; updated = file.updated
        positions = file.metro.mapValues { table in
            Dictionary(table.stations.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// A trip's fare and whether every ride of it is known.
    public struct Estimate: Equatable, Sendable {
        public let total: Int
        public let complete: Bool
    }

    /// A class's metro fare between two stations ("metro:TRTC:BL15"), when one operator's table has both
    /// and that class's fare (New Taipei Metro publishes no child fare).
    public func metroFare(from: String, to: String, fareClass: FareClass = .adult) -> Int? {
        let a = from.split(separator: ":"), b = to.split(separator: ":")
        guard a.count == 3, b.count == 3, a[1] == b[1], let table = metro[String(a[1])],
              let matrix = table.classes[fareClass.metroClass.rawValue], table.matrices.indices.contains(matrix),
              let i = positions[String(a[1])]?[String(a[2])], let j = positions[String(b[1])]?[String(b[2])] else { return nil }
        return table.matrices[matrix][i][j]
    }

    /// A bus ride's fare: one section, and one more for each fare buffer zone ridden right through. Nil
    /// when the route has no official fare; `located` is false when a zone's stops were not found.
    public func busFare(_ ride: TransitRide, metadata: TransitMetadata, fareClass: FareClass = .adult) -> (price: Int, located: Bool)? {
        guard let route = bus[ride.route.parentID] ?? bus[ride.route.id], busFares.indices.contains(route.fare),
              let price = busFares[route.fare][fareClass.rawValue] else { return nil }
        if route.free { return (0, true) }
        let zones = route.zones.filter { $0.count == 5 && $0[0] == ride.direction }
        guard !zones.isEmpty else { return (price, true) }
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
        return (price * sections, located)
    }

    /// Whether a TPASS 基北北桃 pass covers a metro ride: Taipei Metro and New Taipei Metro, fare table or not.
    func passCovers(metro ride: TransitRide) -> Bool {
        let parts = ride.boarding.stationID.split(separator: ":")
        return parts.count == 3 && Self.passOperators.contains(String(parts[1]))
    }

    /// The fare of a whole trip's rides for a rider class, or nil when none of them has a known fare.
    /// `cycledAfter` holds the rides followed by a YouBike ride, after which the next ride is not a direct
    /// transfer. With `pass` (TPASS 基北北桃), covered rides cost nothing and other rides stay unknown.
    public func estimate(_ rides: [TransitRide], metadata: TransitMetadata, cycledAfter: Set<Int> = [],
                         fareClass: FareClass = .adult, pass: Bool = false) -> Estimate? {
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
                if pass, rides[index...last].allSatisfy(passCovers(metro:)) {
                    units.append((.metro, 0, true, index, last)); index = last + 1; continue
                }
                var fare = metroFare(from: ride.boarding.stationID, to: rides[last].alighting.stationID, fareClass: fareClass)
                if fare == nil {
                    let legs = rides[index...last].map { metroFare(from: $0.boarding.stationID, to: $0.alighting.stationID, fareClass: fareClass) }
                    let known = legs.compactMap { $0 }
                    fare = known.isEmpty ? nil : known.reduce(0, +)
                    units.append((.metro, fare, known.count == legs.count, index, last))
                } else {
                    units.append((.metro, fare, true, index, last))
                }
                index = last + 1
            } else if ride.route.mode == .bus, let fare = busFare(ride, metadata: metadata, fareClass: fareClass) {
                // Every route in the table is a Taipei or New Taipei city bus, which the pass covers.
                units.append(pass ? (.bus, 0, true, index, index) : (.bus, fare.price, fare.located, index, index)); index += 1
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
                    fare = max(0, fare - fareClass.transferDiscount)
                }
            }
            total += fare; known = true; complete = complete && unit.located
        }
        return known ? Estimate(total: total, complete: complete) : nil
    }
}
