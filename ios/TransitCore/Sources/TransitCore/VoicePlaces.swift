import Foundation

/// The official names of places riders say by voice, from the Tourism Administration's open data
/// (attractions, restaurants, hotels), with where each is (release/collect-voice-places.py). Misheard names are
/// corrected against them by sound, and the ones near the rider are given to the recogniser to expect.
public struct VoicePlaces: Sendable {
    public struct Place: Sendable, Equatable {
        public let name: String
        public let coordinate: Coordinate
        /// spot, food or hotel.
        public let kind: String
    }
    public let places: [Place]

    public static let shared: VoicePlaces = {
        guard let url = Bundle.module.url(forResource: "voice-places", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return VoicePlaces(places: []) }
        return VoicePlaces(data: data)
    }()

    init(places: [Place]) { self.places = places }

    /// `{"places": [["國立故宮博物院", 25.10, 121.55, "spot"], ...]}`; rows that do not fit are left out.
    public init(data: Data) {
        let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["places"] as? [[Any]] ?? []
        places = rows.compactMap { row in
            guard row.count >= 3, let name = row[0] as? String, !name.isEmpty, name.count <= 12,
                  let latitude = (row[1] as? NSNumber)?.doubleValue, let longitude = (row[2] as? NSNumber)?.doubleValue else { return nil }
            return Place(name: name, coordinate: Coordinate(latitude: latitude, longitude: longitude),
                         kind: row.count > 3 ? (row[3] as? String ?? "spot") : "spot")
        }
    }

    /// Scenic spots, the names riders say from anywhere in the city.
    public var spots: [String] { places.filter { $0.kind == "spot" }.map(\.name) }

    /// The places within `meters` of a point, nearest first.
    public func near(_ point: Coordinate?, within meters: Double = 2500, limit: Int = 20) -> [String] {
        guard let point, limit > 0 else { return [] }
        return places.lazy.map { ($0.name, $0.coordinate.distance(to: point)) }.filter { $0.1 <= meters }
            .sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
    }
}
