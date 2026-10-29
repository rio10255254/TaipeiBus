import Foundation

/// One feed the app reads: a city's buses or its YouBike stations. A source has its own id space;
/// `idPrefix` keeps it apart from the others once several are loaded (REGION_DESIGN.md §3.3).
public struct TransitSource: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case bus, bike }
    public let id: String
    public let name: String
    public let kind: Kind
    /// A bus source's folder of feed files, or a bike source's single file.
    public let feed: URL
    /// Taipei's and New Taipei's ids are stored unprefixed: they come from one information centre with
    /// one numbering, so saved stops and commutes need no migration. A source relayed from elsewhere gets one.
    public let idPrefix: String
    /// How often a feed is worth asking for, when it is rewritten less often than the app's usual pace
    /// (New Taipei's YouBike file, about every five minutes); 0 keeps the usual pace.
    public let refreshSeconds: Double
    /// A bus source's pace for rides without official station-to-station times, as measured against its
    /// buses (RideTiming); nil keeps ForecastTuning's.
    public struct RidePace: Sendable, Equatable {
        public let metersPerSecond: Double
        public let stopSeconds: Double
        public init(metersPerSecond: Double, stopSeconds: Double) { self.metersPerSecond = metersPerSecond; self.stopSeconds = stopSeconds }
    }
    public let ridePace: RidePace?
    public init(id: String, name: String, kind: Kind, feed: URL, idPrefix: String = "", refreshSeconds: Double = 0, ridePace: RidePace? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.feed = feed; self.idPrefix = idPrefix; self.refreshSeconds = refreshSeconds
        self.ridePace = ridePace
    }
}

/// An area the app serves and loads together, such as 雙北 or 基隆, with the sources it needs.
public struct ServiceRegion: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let englishName: String
    /// Where the map and searches start without a usable location.
    public let center: Coordinate
    /// A union of boxes, enough to follow a county's outline.
    public let bounds: [GeoBounds]
    public let sources: [String]
    public init(id: String, name: String, englishName: String, center: Coordinate, bounds: [GeoBounds], sources: [String]) {
        self.id = id; self.name = name; self.englishName = englishName; self.center = center; self.bounds = bounds; self.sources = sources
    }
    public func contains(_ point: Coordinate) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite && bounds.contains { $0.contains(point) }
    }
}

/// The regions and sources the app knows, from Regions/regions.json. The release collectors read the
/// same file, so the area the app serves and the area its bundled data covers cannot drift apart.
public struct RegionCatalog: Sendable {
    public let regions: [ServiceRegion]
    public let sources: [String: TransitSource]
    /// The region the bundled data covers; the default when no other applies.
    public let home: ServiceRegion

    public static let shared: RegionCatalog = bundled ?? builtIn

    /// The bundled Regions/regions.json, or nil if it cannot be read.
    static var bundled: RegionCatalog? {
        guard let url = Bundle.module.url(forResource: "regions", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? RegionCatalog(data: data)
    }

    /// Used only if the bundled file cannot be read, so a damaged resource never takes the whole app
    /// out of service: Taipei's buses and bikes in the area the app first served, which the bundled
    /// file always covers (RegionCatalogTests).
    static let builtIn = RegionCatalog(
        regions: [ServiceRegion(id: "taipei", name: "台北", englishName: "Taipei", center: Coordinate(latitude: 25.0377, longitude: 121.56),
                                bounds: [GeoBounds(south: 24.90, west: 121.27, north: 25.25, east: 121.72)], sources: ["tpe", "bike-tpe"])],
        sources: [TransitSource(id: "tpe", name: "臺北市公車", kind: .bus, feed: URL(string: "https://tcgbusfs.blob.core.windows.net/blobbus/")!),
                  TransitSource(id: "bike-tpe", name: "臺北市 YouBike 2.0", kind: .bike,
                                feed: URL(string: "https://tcgbusfs.blob.core.windows.net/dotapp/youbike/v2/youbike_immediate.json")!)],
        home: "taipei")!

    init?(regions: [ServiceRegion], sources: [TransitSource], home: String) {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The home region always has buses: the app reads them before anything else.
        guard let region = regions.first(where: { $0.id == home }), region.sources.contains(where: { byID[$0]?.kind == .bus }),
              regions.allSatisfy({ !$0.bounds.isEmpty && $0.sources.allSatisfy { byID[$0] != nil } }) else { return nil }
        self.regions = regions; self.sources = byID; self.home = region
    }

    /// `{"home": "taipei", "regions": [{"id", "name", "englishName", "center": [lat, lon],
    /// "bounds": [[south, west, north, east]], "sources": ["tpe"]}], "sources": [{"id", "name", "kind",
    /// "feed", "idPrefix", "refreshSeconds", "ridePace": {"metersPerSecond", "stopSeconds"}}]}`. Feeds must be https; a region naming an unknown source is rejected.
    public init(data: Data) throws {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let home = document["home"] as? String,
              let regionRows = document["regions"] as? [[String: Any]], let sourceRows = document["sources"] as? [[String: Any]]
        else { throw FeedError.invalid("Regions") }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        let sources = try sourceRows.map { row -> TransitSource in
            guard let id = row["id"] as? String, !id.isEmpty, let name = row["name"] as? String,
                  let kind = (row["kind"] as? String).flatMap(TransitSource.Kind.init(rawValue:)),
                  let feed = (row["feed"] as? String).flatMap(URL.init(string:)), feed.scheme == "https" else { throw FeedError.invalid("Region source") }
            let refresh = number(row["refreshSeconds"]) ?? 0
            guard refresh.isFinite, (0...3_600).contains(refresh) else { throw FeedError.invalid("Region source") }
            var pace: TransitSource.RidePace?
            if let value = row["ridePace"] {
                guard let fields = value as? [String: Any], let speed = number(fields["metersPerSecond"]), let stop = number(fields["stopSeconds"]),
                      (2...20).contains(speed), (0...120).contains(stop) else { throw FeedError.invalid("Region ride pace") }
                pace = TransitSource.RidePace(metersPerSecond: speed, stopSeconds: stop)
            }
            return TransitSource(id: id, name: name, kind: kind, feed: feed, idPrefix: row["idPrefix"] as? String ?? "",
                                 refreshSeconds: refresh, ridePace: pace)
        }
        let regions = try regionRows.map { row -> ServiceRegion in
            guard let id = row["id"] as? String, !id.isEmpty, let name = row["name"] as? String,
                  let center = row["center"] as? [Any], center.count == 2, let latitude = number(center[0]), let longitude = number(center[1]),
                  let boxes = row["bounds"] as? [[Any]], let sourceIDs = row["sources"] as? [String] else { throw FeedError.invalid("Region") }
            let bounds = try boxes.map { box -> GeoBounds in
                let values = box.compactMap(number)
                guard values.count == 4, values.allSatisfy(\.isFinite), values[0] < values[2], values[1] < values[3] else { throw FeedError.invalid("Region bounds") }
                return GeoBounds(south: values[0], west: values[1], north: values[2], east: values[3])
            }
            return ServiceRegion(id: id, name: name, englishName: row["englishName"] as? String ?? name,
                                 center: Coordinate(latitude: latitude, longitude: longitude), bounds: bounds, sources: sourceIDs)
        }
        guard let catalog = RegionCatalog(regions: regions, sources: sources, home: home) else { throw FeedError.invalid("Regions") }
        self = catalog
    }

    public func region(at point: Coordinate) -> ServiceRegion? { regions.first { $0.contains(point) } }
    public func contains(_ point: Coordinate) -> Bool { regions.contains { $0.contains(point) } }
    /// The first source of a kind a region lists; the home region's when none is given.
    public func source(_ kind: TransitSource.Kind, in region: ServiceRegion? = nil) -> TransitSource? {
        self.sources(kind, in: region).first
    }
    /// Every source of a kind a region lists, in its order; the first is the one the app cannot work without.
    public func sources(_ kind: TransitSource.Kind, in region: ServiceRegion? = nil) -> [TransitSource] {
        (region ?? home).sources.compactMap { sources[$0] }.filter { $0.kind == kind }
    }
}

extension Coordinate {
    /// Inside a region the app serves.
    public var isInServiceArea: Bool { RegionCatalog.shared.contains(self) }
    /// Where to start without a usable location: the home region's center.
    public static var serviceCenter: Coordinate { RegionCatalog.shared.home.center }
}
