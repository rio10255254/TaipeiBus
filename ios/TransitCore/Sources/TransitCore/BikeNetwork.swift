import Foundation

/// A YouBike 2.0 docking station. Only the parts that do not change are bundled with the
/// app; bikes and free docks arrive from the live feed as `BikeDock`.
public struct BikeStation: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let englishName: String
    public let district: String
    public let englishDistrict: String
    public let address: String
    public let englishAddress: String
    public let coordinate: Coordinate
    /// Published dock count at this station.
    public let capacity: Int
    public init(id: String, name: String, englishName: String = "", district: String = "", englishDistrict: String = "",
                address: String = "", englishAddress: String = "", coordinate: Coordinate, capacity: Int = 0) {
        self.id = id; self.name = name; self.englishName = englishName
        self.district = district; self.englishDistrict = englishDistrict
        self.address = address; self.englishAddress = englishAddress
        self.coordinate = coordinate; self.capacity = capacity
    }
    public var localizedName: String { AppLanguage.current == .english && !englishName.isEmpty ? englishName : name }
    public var localizedDistrict: String { AppLanguage.current == .english && !englishDistrict.isEmpty ? englishDistrict : district }
    public var localizedAddress: String { AppLanguage.current == .english && !englishAddress.isEmpty ? englishAddress : address }
}

/// The bundled YouBike station list of Taipei and New Taipei, with a cell index for nearby lookups.
public struct BikeNetwork: Codable, Sendable {
    public let schema: Int
    public let generatedAt: String
    public let source: String
    public let stations: [BikeStation]
    /// Rebuilt after decoding; never part of the file.
    private var cells: [String: [Int]] = [:]
    private var positions: [String: Int] = [:]
    private enum CodingKeys: String, CodingKey { case schema, generatedAt, source, stations }

    public init(schema: Int = 1, generatedAt: String = "", source: String = "", stations: [BikeStation] = []) {
        self.schema = schema; self.generatedAt = generatedAt; self.source = source; self.stations = stations
        buildIndex()
    }
    public static let empty = BikeNetwork()

    /// A bounded, public file. Anything unexpected keeps the app on its last good list.
    public init(data: Data) throws {
        guard data.count <= 8 * 1_024 * 1_024 else { throw FeedError.invalid("YouBike 站點") }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard schema == 1, (1...6_000).contains(stations.count),
              Set(stations.map(\.id)).count == stations.count,
              stations.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && (0...200).contains($0.capacity) && $0.coordinate.isInServiceArea })
        else { throw FeedError.invalid("YouBike 站點") }
        buildIndex()
    }

    private static let cellSize = 0.003
    private static func cell(_ coordinate: Coordinate) -> (x: Int, y: Int) {
        (Int(floor(coordinate.longitude / cellSize)), Int(floor(coordinate.latitude / cellSize)))
    }
    private mutating func buildIndex() {
        var cells: [String: [Int]] = [:], positions: [String: Int] = [:]
        for (index, station) in stations.enumerated() {
            let (x, y) = Self.cell(station.coordinate)
            cells["\(x):\(y)", default: []].append(index)
            positions[station.id] = index
        }
        self.cells = cells; self.positions = positions
    }

    public func station(_ id: String) -> BikeStation? { positions[id].map { stations[$0] } }

    /// Stations within a straight-line radius, closest first. Walking distance is longer;
    /// this answers "which docks are around here", not "how far is the walk".
    public func stations(near point: Coordinate, radius: Double = 400, limit: Int = 6) -> [BikeStation] {
        guard !stations.isEmpty, radius > 0, limit > 0, point.isInServiceArea else { return [] }
        let (x, y) = Self.cell(point)
        let span = max(1, Int(ceil(radius / 300)))
        var found: [(station: BikeStation, distance: Double)] = []
        for dx in -span...span {
            for dy in -span...span {
                for index in cells["\(x + dx):\(y + dy)"] ?? [] {
                    let distance = stations[index].coordinate.distance(to: point)
                    if distance <= radius { found.append((stations[index], distance)) }
                }
            }
        }
        found.sort { $0.distance == $1.distance ? $0.station.id < $1.station.id : $0.distance < $1.distance }
        return found.prefix(limit).map(\.station)
    }
}
