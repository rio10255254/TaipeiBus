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

    /// Read this often a month on Wikipedia, a place people go to is a sight: a department store, a temple.
    static let famousViews = 300.0
    /// Places people go to. Schools and offices are read about by those who study or work there.
    private static let visited: Set<String> = Set(sights.keys).union(venues.keys)
        .union(["park", "garden", "grocery", "shop", "place_of_worship", "cinema", "library", "lodging"])

    private init(_ tier: Tier, _ weight: Double, notable: Bool, views: Double, from zoom: Double) {
        self.tier = tier; minimumZoom = zoom
        // Better known places go first within their kind, never ahead of a kind that comes first;
        // never below 0, which PlaceLabelBudget treats as invalid.
        score = Double(tier.rawValue) * 1000 + weight * 100 + (notable ? 49 - min(49, 12 * log10(1 + views)) : 99)
    }

    /// nil for places the map does not draw: kinds without an icon, and metro stations, which the
    /// app draws itself from the official network.
    public init?(_ place: MapPlace, known: KnownPlaces = .shared) {
        let kind = place.kind, subclass = place.subclass
        // Checked first: a dense city tile holds thousands of bus stops and offices.
        guard Self.drawn.contains(kind), kind != "railway" || subclass != "subway" else { return nil }
        let match = known.match(place.names["name:zh"] ?? place.names["name"] ?? "", near: place.coordinate)
        let views = match?.views ?? 0
        // Listed or read about, or a real English name: the best signs in the tile that people know the place.
        let notable = match != nil || (place.names["name:en"] ?? "").unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
        // A listed temple, park or market, or a well-read department store, is a sight whatever its kind.
        if match?.listing == "spot" && Self.food[kind] == nil || views >= Self.famousViews && Self.visited.contains(kind) {
            self.init(.sight, 0, notable: true, views: views, from: 14); return
        }
        switch (kind, subclass) {
        case ("attraction", "viewpoint"): self.init(.sight, 3, notable: notable, views: views, from: 15.5)
        case ("hospital", "hospital"), ("college", _), ("railway", _):
            self.init(.sight, Self.landmarks[kind]!, notable: notable, views: views, from: notable ? 14 : 15)
        case ("hospital", _), ("art_gallery", "artwork"), ("art_gallery", "art"): self.init(.minor, 0, notable: notable, views: views, from: 16.5)
        case ("lodging", let type) where !["hotel", "hostel", "motel", "guest_house"].contains(type):
            self.init(.minor, 0, notable: notable, views: views, from: 16.5)
        case ("grocery", let type) where !["supermarket", "department_store", "marketplace"].contains(type):
            self.init(.minor, 0, notable: notable, views: views, from: 16.5)
        default:
            if let weight = Self.sights[kind] { self.init(.sight, weight, notable: notable, views: views, from: notable ? 14 : 15) }
            else if let weight = Self.venues[kind] {
                if notable { self.init(.sight, weight, notable: true, views: views, from: 15) }
                else { self.init(.minor, 0, notable: false, views: views, from: 16.5) }
            }
            else if let weight = Self.food[kind] { self.init(.food, weight, notable: notable, views: views, from: notable ? 15 : 15.5) }
            else if let weight = Self.everyday[kind] { self.init(.everyday, weight, notable: notable, views: views, from: 15.5) }
            else { self.init(.minor, 0, notable: notable, views: views, from: 16.5) }
        }
    }
    /// Every kind with a map icon (NativeBusMap poiCategories).
    private static let drawn = Set([sights, venues, landmarks, food, everyday].flatMap(\.keys)).union(minor)
}

/// A place people read about: its Wikidata names and how often its Wikipedia articles are read
/// (QRank; famous-places.json, from release/collect-famous-places.py).
public struct FamousPlace: Sendable, Equatable {
    public let name: String
    public let coordinate: Coordinate
    /// Average monthly views over a year, across Wikimedia projects.
    public let views: Double

    public static let bundled: [FamousPlace] = {
        guard let url = Bundle.module.url(forResource: "famous-places", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }()
    /// `{"places": [["台北101", 25.03361, 121.56472, 11297], ...]}`; rows that do not fit are left out.
    public static func decode(_ data: Data) -> [FamousPlace] {
        let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["places"] as? [[Any]] ?? []
        return rows.compactMap { row in
            guard row.count >= 4, let name = row[0] as? String, !name.isEmpty,
                  let latitude = (row[1] as? NSNumber)?.doubleValue, let longitude = (row[2] as? NSNumber)?.doubleValue,
                  let views = (row[3] as? NSNumber)?.doubleValue, views.isFinite, views > 0 else { return nil }
            return FamousPlace(name: name, coordinate: Coordinate(latitude: latitude, longitude: longitude), views: views)
        }
    }
}

/// What open data says about a place of this name nearby: the Tourism Administration's attractions,
/// restaurants and hotels (VoicePlaces), and how often its Wikipedia articles are read. Many temples and
/// churches share a name, so only an entry within 500 m counts.
public struct KnownPlaces: Sendable {
    public struct Match: Sendable, Equatable {
        /// spot, food or hotel when the Tourism Administration lists it.
        public var listing: String?
        /// Monthly Wikipedia views; 0 without an article.
        public var views: Double
    }
    public static let shared = KnownPlaces(VoicePlaces.shared.places, famous: FamousPlace.bundled)
    private struct Entry: Sendable { let coordinate: Coordinate; let listing: String?; let views: Double }
    private let byName: [String: [Entry]]
    public init(_ places: [VoicePlaces.Place], famous: [FamousPlace] = []) {
        var byName: [String: [Entry]] = [:]
        for place in places { byName[Self.key(place.name), default: []].append(Entry(coordinate: place.coordinate, listing: place.kind, views: 0)) }
        for place in famous { byName[Self.key(place.name), default: []].append(Entry(coordinate: place.coordinate, listing: nil, views: place.views)) }
        byName.removeValue(forKey: "")
        self.byName = byName
    }
    public func match(_ name: String, near coordinate: Coordinate) -> Match? {
        guard let entries = byName[Self.key(name)] else { return nil }
        var match: Match?
        for entry in entries where entry.coordinate.distance(to: coordinate) <= 500 {
            match = Match(listing: match?.listing ?? entry.listing, views: max(match?.views ?? 0, entry.views))
        }
        return match
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
