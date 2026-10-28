import Foundation

/// Which map places are shown first, and from which zoom. Riders look for sights and for somewhere
/// to eat or drink far more than for banks or clinics, so those come first. OpenMapTiles' `rank`
/// cannot say this: it only orders the places inside one label-grid cell by a fixed class list in
/// which hospitals (clinics included) and bus stops come first and restaurants and cafés last.
public struct MapPlacePriority: Sendable, Equatable {
    public enum Tier: Int, Sendable { case sight, food, everyday, minor }
    public let tier: Tier
    /// The lowest zoom the place is shown at; always one of `zoomSteps`.
    public let minimumZoom: Double
    /// Lower is shown first; tiers never overlap.
    public let score: Double

    /// Zooms at which more places become eligible.
    public static let zoomSteps: [Double] = [14, 15, 15.5, 16.5, 17.5]
    /// 0 below the first step, otherwise one more than the index of the highest step reached.
    public static func band(_ zoom: Double) -> Int {
        guard zoom.isFinite else { return 0 }
        return zoomSteps.lastIndex { zoom >= $0 }.map { $0 + 1 } ?? 0
    }

    private static let sights: [String: Double] = ["attraction": 0, "museum": 0, "zoo": 0, "monument": 0]
    /// Theatres and galleries include lecture halls and shops that sell art: a sight only when notable.
    private static let venues: [String: Double] = ["theatre": 1, "art_gallery": 1, "castle": 1]
    private static let landmarks: [String: Double] = ["college": 2, "hospital": 2, "railway": 2]
    private static let food: [String: Double] = ["restaurant": 0, "cafe": 0, "bar": 0, "beer": 0, "fast_food": 1,
                                                 "bakery": 2, "ice_cream": 2]
    private static let everyday: [String: Double] = ["park": 0, "garden": 0, "grocery": 1, "lodging": 2, "cinema": 2,
        "library": 2, "shop": 3, "clothing_store": 3, "books": 3, "school": 4, "town_hall": 4, "post": 4, "bank": 4,
        "pharmacy": 4, "place_of_worship": 4, "police": 5, "fire_station": 5]
    private static let minor: Set<String> = ["doctors", "dentist", "veterinary", "kindergarten", "playground",
                                             "alcohol_shop", "butcher", "jewelry", "mobile_phone", "music"]

    private init(_ tier: Tier, _ weight: Double, notable: Bool, from zoom: Double) {
        self.tier = tier; minimumZoom = zoom
        score = Double(tier.rawValue) * 1000 + weight * 100 + (notable ? 0 : 50)
    }

    /// nil for places the map does not draw: kinds without an icon, and metro stations, which the
    /// app draws itself from the official network.
    public init?(_ place: MapPlace, known: KnownPlaces = .shared) {
        let kind = place.kind, subclass = place.subclass
        // Checked first: a dense city tile holds thousands of bus stops and offices.
        guard Self.drawn.contains(kind), kind != "railway" || subclass != "subway" else { return nil }
        let listed = known.kind(of: place.names["name:zh"] ?? place.names["name"] ?? "", near: place.coordinate)
        // A real English name is the best sign in the tile that visitors know the place.
        let notable = listed != nil || (place.names["name:en"] ?? "").unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
        // A listed temple, park or market is a sight whatever its kind.
        if listed == "spot", Self.food[kind] == nil { self.init(.sight, 0, notable: true, from: 14); return }
        switch (kind, subclass) {
        case ("attraction", "viewpoint"): self.init(.sight, 3, notable: notable, from: 15.5)
        case ("hospital", "hospital"), ("college", _), ("railway", _):
            self.init(.sight, Self.landmarks[kind]!, notable: notable, from: notable ? 14 : 15)
        case ("hospital", _), ("art_gallery", "artwork"), ("art_gallery", "art"): self.init(.minor, 0, notable: notable, from: 16.5)
        case ("lodging", let type) where !["hotel", "hostel", "motel", "guest_house"].contains(type):
            self.init(.minor, 0, notable: notable, from: 16.5)
        case ("grocery", let type) where !["supermarket", "department_store", "marketplace"].contains(type):
            self.init(.minor, 0, notable: notable, from: 16.5)
        default:
            if let weight = Self.sights[kind] { self.init(.sight, weight, notable: notable, from: notable ? 14 : 15) }
            else if let weight = Self.venues[kind] {
                if notable { self.init(.sight, weight, notable: true, from: 15) } else { self.init(.minor, 0, notable: false, from: 16.5) }
            }
            else if let weight = Self.food[kind] { self.init(.food, weight, notable: notable, from: notable ? 15 : 15.5) }
            else if let weight = Self.everyday[kind] { self.init(.everyday, weight, notable: notable, from: 15.5) }
            else { self.init(.minor, 0, notable: notable, from: 16.5) }
        }
    }
    /// Every kind with a map icon (NativeBusMap poiCategories).
    private static let drawn = Set([sights, venues, landmarks, food, everyday].flatMap(\.keys)).union(minor)
}

/// The Tourism Administration's attractions, restaurants and hotels (VoicePlaces), looked up by
/// name and place: many temples and churches share a name, so only the listing nearby counts.
public struct KnownPlaces: Sendable {
    public static let shared = KnownPlaces(VoicePlaces.shared.places)
    private let byName: [String: [VoicePlaces.Place]]
    public init(_ places: [VoicePlaces.Place]) {
        byName = Dictionary(grouping: places) { Self.key($0.name) }
    }
    /// spot, food or hotel, for a listing of this name within 500 m.
    public func kind(of name: String, near coordinate: Coordinate) -> String? {
        let key = Self.key(name)
        guard !key.isEmpty, let listings = byName[key] else { return nil }
        return listings.first { $0.coordinate.distance(to: coordinate) <= 500 }?.kind
    }
    /// The name as the listing writes it: no bracketed branch or note, 台 rather than 臺, letters
    /// and digits only (release/collect-voice-places.py cleans listed names the same way).
    static func key(_ name: String) -> String {
        // By scalar: this runs for every drawn place of every tile.
        var depth = 0, result = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar {
            case "（", "(", "[", "【": depth += 1
            case "）", ")", "]", "】": depth = max(0, depth - 1)
            case "臺": if depth == 0 { result.append("台") }
            case "A"..."Z": if depth == 0 { result.append(Unicode.Scalar(scalar.value + 32)!) }
            default:
                if depth == 0, scalar.properties.isAlphabetic || scalar.properties.numericType != nil { result.append(scalar) }
            }
        }
        return String(result)
    }
}
