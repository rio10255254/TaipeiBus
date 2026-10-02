import SwiftUI
import MapKit
import TransitCore

extension Coordinate {
    var locationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct TravelPlace: Identifiable, Codable, Sendable {
    var id: String { "\(coordinate.latitude):\(coordinate.longitude):\(name)" }
    let name: String
    let address: String
    let coordinate: Coordinate
    var isTransitPlace: Bool? = nil
    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate.locationCoordinate))
        item.name = name
        return item
    }
}

@MainActor
final class PlaceSearch: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    @Published private(set) var places: [TravelPlace] = []
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    private let completer = MKLocalSearchCompleter()
    private var search: MKLocalSearch?
    private var query = ""
    private var generation = UUID()
    private var searchRegion = PlaceSearch.region
    private var preferredPosition = Coordinate.taipei
    static let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25.07, longitude: 121.54),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4))

    override init() {
        super.init()
        completer.delegate = self
        completer.region = Self.region
        completer.resultTypes = [.address, .pointOfInterest]
    }
    func update(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != self.query else { return }
        error = nil
        suggestions = []
        places = []
        search?.cancel(); generation = UUID()
        self.query = query
        searching = !query.isEmpty
        completer.queryFragment = StationSearch.placeQueries(query).first ?? query
        if query.isEmpty { completer.cancel(); searching = false }
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let ordered = completer.results.sorted {
            (StationSearch.placeRank(name: $0.title, address: $0.subtitle, query: query) ?? 9) <
                (StationSearch.placeRank(name: $1.title, address: $1.subtitle, query: query) ?? 9)
        }
        let hasStrongMatch = ordered.contains { (StationSearch.placeRank(name: $0.title, address: $0.subtitle, query: query) ?? 9) <= 1 }
        var unique: [MKLocalSearchCompletion] = []
        for completion in ordered {
            if hasStrongMatch, (StationSearch.placeRank(name: completion.title, address: completion.subtitle, query: query) ?? 9) > 2 { continue }
            if unique.contains(where: {
                StationSearch.normalize($0.subtitle) == StationSearch.normalize(completion.subtitle) &&
                (StationSearch.rank(name: $0.title, query: completion.title) ?? 9) <= 1
            }) { continue }
            unique.append(completion)
        }
        suggestions = Array(unique.prefix(12)); searching = false
    }
    func setContext(_ coordinate: Coordinate?) {
        preferredPosition = coordinate?.isInServiceArea == true ? coordinate! : .taipei
        searchRegion = MKCoordinateRegion(center: preferredPosition.locationCoordinate, span: Self.region.span)
        completer.region = searchRegion
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        searching = false; suggestions = []; self.error = "地點搜尋暫時無法連線，可改選下方站牌。"
    }
    func resolve(text: String, completion: MKLocalSearchCompletion? = nil) async throws -> TravelPlace? {
        let places = try await find(text: text, completion: completion)
        return places.first
    }

    func find(text: String, completion: MKLocalSearchCompletion? = nil) async throws -> [TravelPlace] {
        search?.cancel()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        generation = UUID(); let token = generation
        searching = true
        defer { if token == generation { searching = false } }
        var matches: [TravelPlace] = []
        var lastError: Error?
        let addressQuery = StationSearch.isAddressQuery(text)
        let category: MKPointOfInterestCategory? = ["咖啡": .cafe, "咖啡店": .cafe, "餐廳": .restaurant,
            "醫院": .hospital, "公園": .park, "捷運站": .publicTransport, "加油站": .gasStation][StationSearch.normalize(text)]
        let transitQuery = StationSearch.isTransitQuery(text)
        for query in completion == nil ? StationSearch.placeQueries(text) : [text] {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            let request = completion.map { MKLocalSearch.Request(completion: $0) } ?? MKLocalSearch.Request()
            if completion == nil { request.naturalLanguageQuery = query }
            request.region = searchRegion
            request.resultTypes = completion != nil || addressQuery ? [.address, .pointOfInterest] : [.pointOfInterest]
            if let category { request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category]) }
            else if transitQuery { request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport]) }
            let operation = MKLocalSearch(request: request); search = operation
            do {
                let response = try await operation.start()
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                for item in response.mapItems {
                    let coordinate = Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
                    guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                          (-85...85).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude),
                          abs(coordinate.latitude) + abs(coordinate.longitude) > 0.001 else { continue }
                    let place = TravelPlace(name: item.name ?? text, address: item.placemark.title ?? "", coordinate: coordinate,
                                            isTransitPlace: item.pointOfInterestCategory == .publicTransport)
                    let relevant = StationSearch.placeRank(name: place.name, address: place.address, query: text) != nil ||
                        StationSearch.placeRank(name: place.name, address: place.address, query: query) != nil
                    guard completion != nil || relevant || (category != nil && item.pointOfInterestCategory == category) else { continue }
                    if !matches.contains(where: { StationSearch.normalize($0.name) == StationSearch.normalize(place.name) && $0.coordinate.distance(to: place.coordinate) < 30 }) { matches.append(place) }
                }
            } catch {
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                lastError = error
            }
            if completion != nil || category != nil || matches.contains(where: {
                (StationSearch.placeRank(name: $0.name, address: $0.address, query: text) ?? 9) <= 1 ||
                (StationSearch.placeRank(name: $0.name, address: $0.address, query: query) ?? 9) <= 1
            }) { break }
        }
        if matches.isEmpty, let lastError { throw lastError }
        matches.sort {
            let a = StationSearch.placeRank(name: $0.name, address: $0.address, query: text) ?? 9
            let b = StationSearch.placeRank(name: $1.name, address: $1.address, query: text) ?? 9
            if a != b { return a < b }
            if !transitQuery, !addressQuery, $0.isTransitPlace != $1.isTransitPlace {
                return $0.isTransitPlace != true
            }
            return $0.coordinate.distance(to: preferredPosition) < $1.coordinate.distance(to: preferredPosition)
        }
        places = Array(matches.prefix(12))
        return places
    }
    func cancel() {
        generation = UUID(); search?.cancel(); completer.cancel(); searching = false
        query = ""; suggestions = []; places = []; error = nil
    }
}

