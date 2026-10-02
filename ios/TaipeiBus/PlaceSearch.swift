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
    static let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25.07, longitude: 121.54),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4))

    override init() {
        super.init()
        completer.delegate = self
        completer.region = Self.region
        completer.resultTypes = [.address, .pointOfInterest, .query]
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
        completer.queryFragment = query
        if query.isEmpty { completer.cancel(); searching = false }
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = Array(completer.results.sorted {
            (StationSearch.rank(name: $0.title, query: query) ?? 5) < (StationSearch.rank(name: $1.title, query: query) ?? 5)
        }.prefix(12)); searching = false
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
        for query in completion == nil ? StationSearch.placeQueries(text) : [text] {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            let request = completion.map { MKLocalSearch.Request(completion: $0) } ?? MKLocalSearch.Request()
            if completion == nil { request.naturalLanguageQuery = query }
            request.region = Self.region
            request.resultTypes = [.address, .pointOfInterest]
            let operation = MKLocalSearch(request: request); search = operation
            do {
                let response = try await operation.start()
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                for item in response.mapItems {
                    let coordinate = Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
                    guard coordinate.isInServiceArea else { continue }
                    let place = TravelPlace(name: item.name ?? text, address: item.placemark.title ?? "", coordinate: coordinate)
                    if !matches.contains(where: { $0.name == place.name && $0.coordinate.distance(to: place.coordinate) < 30 }) { matches.append(place) }
                }
            } catch {
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                lastError = error
            }
            if !matches.isEmpty { break }
        }
        if matches.isEmpty, let lastError { throw lastError }
        matches.sort { (StationSearch.rank(name: $0.name, query: text) ?? 5) < (StationSearch.rank(name: $1.name, query: text) ?? 5) }
        places = Array(matches.prefix(12))
        return places
    }
    func cancel() {
        generation = UUID(); search?.cancel(); completer.cancel(); searching = false
        query = ""; suggestions = []; places = []; error = nil
    }
}

