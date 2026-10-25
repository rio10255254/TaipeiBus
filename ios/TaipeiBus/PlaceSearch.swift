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
    var englishName: String? = nil
    var localizedName: String { AppLanguage.current == .english ? englishName.flatMap { $0.isEmpty ? nil : $0 } ?? AppText.text(name) : name }
    var mapItem: MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate.locationCoordinate))
        item.name = localizedName
        return item
    }
}

/// 「西門町的網咖」「公館附近的咖啡廳」「附近的藥局」: a kind of place around an area, not one place's
/// name. Searching the whole phrase found nothing named that (a phone offered a hotel and a market),
/// so the area is found first and the kind is searched around it.
struct NearbyQuery: Equatable {
    let area: String
    let what: String
    /// After 「的」 only these mean a kind of place (「台大的機械館」 is still one building).
    static let kinds = ["網咖", "網吧", "咖啡廳", "咖啡店", "咖啡", "餐廳", "便利商店", "超商", "超市", "藥局", "藥妝店",
        "醫院", "診所", "書店", "公園", "加油站", "停車場", "健身房", "電影院", "夜市", "早餐店", "銀行", "郵局", "提款機",
        "ATM", "百貨公司", "麥當勞", "星巴克", "拉麵", "火鍋", "燒肉", "酒吧", "KTV", "飯店", "旅館", "甜點店", "飲料店",
        "手搖飲", "小吃", "牛肉麵", "廁所", "洗手間", "自助洗衣", "髮廊", "寵物店", "文具店", "電器行", "眼鏡行"]
    init?(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["附近的", "周邊的", "周圍的", "旁邊的", "一帶的", "附近", "周邊", "周圍", "一帶"] {
            guard let range = clean.range(of: marker) else { continue }
            let area = clean[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let what = clean[range.upperBound...].trimmingCharacters(in: .whitespaces)
            // 「西門町附近」 alone is a place; a long remainder is a sentence, not a kind.
            guard !what.isEmpty, what.count <= 8, area.count <= 20 else { return nil }
            self.area = area; self.what = what
            return
        }
        guard let range = clean.range(of: "的", options: .backwards) else { return nil }
        let area = clean[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let what = clean[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !area.isEmpty, area.count <= 20, Self.kinds.contains(where: { what == $0 || (what.hasSuffix($0) && what.count <= 6) }) else { return nil }
        self.area = area; self.what = what
    }
}

@MainActor
final class PlaceSearch: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []
    @Published private(set) var places: [TravelPlace] = []
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    private var completer: MKLocalSearchCompleter?
    private var search: MKLocalSearch?
    private var debounceTask: Task<Void, Never>?
    private var query = ""
    private var generation = UUID()
    private var searchRegion = PlaceSearch.region
    private var preferredPosition = Coordinate.taipei
    private var vocabulary = SearchVocabulary()
    private var settings = LiveSettings.Search()
    private var rulesRevision = -1
    private var stationHints: [Station] = []
    private var completionCache: [String: (Date, [MKLocalSearchCompletion])] = [:]
    private var placeCache: [String: (Date, [TravelPlace])] = [:]
    static let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25.07, longitude: 121.54),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4))

    func setRules(vocabulary: SearchVocabulary, settings: LiveSettings.Search, revision: Int) {
        guard revision != rulesRevision else { return }
        self.vocabulary = vocabulary; self.settings = settings; rulesRevision = revision
        completionCache.removeAll(); placeCache.removeAll()
        update(query, force: true)
    }
    func setStationHints(_ hints: [Station]) {
        let old = stationHints.first?.name
        stationHints = hints
        if old != hints.first?.name, !query.isEmpty, StationSearch.isTransitQuery(query) {
            update(query, force: true, keepHints: true)
        }
    }
    private var cacheKey: String {
        "\(AppLanguage.current.rawValue):\(rulesRevision):\(StationSearch.normalize(StationSearch.cleanQuery(query))):\(Int(preferredPosition.latitude * 100)):\(Int(preferredPosition.longitude * 100))"
    }
    private func queries(for text: String) -> [String] {
        var queries = StationSearch.placeQueries(text, vocabulary: vocabulary)
        if StationSearch.isTransitQuery(text), let hint = stationHints.first(where: { $0.name.hasPrefix("捷運") || $0.searchNames.contains(where: { $0.hasPrefix("MRT") }) }) {
            let name = hint.localizedName.components(separatedBy: CharacterSet(charactersIn: "(（")).first ?? hint.name
            queries.insert(name, at: 0)
        }
        var seen = Set<String>()
        return queries.filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }
    func update(_ text: String) { update(text, force: false) }
    private func update(_ text: String, force: Bool, keepHints: Bool = false) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != query || force else { return }
        debounceTask?.cancel(); completer?.cancel(); completer = nil
        search?.cancel(); search = nil; generation = UUID()
        query = value; error = nil; suggestions = []; places = []
        if !keepHints { stationHints = [] }
        guard !value.isEmpty else { searching = false; return }
        let key = cacheKey
        if let cached = completionCache[key], Date().timeIntervalSince(cached.0) < 600 {
            suggestions = cached.1; searching = false; return
        }
        searching = true
        let token = generation
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .milliseconds(settings.debounceMilliseconds)) } catch { return }
            guard token == generation else { return }
            let operation = MKLocalSearchCompleter()
            operation.delegate = self; operation.region = searchRegion
            operation.resultTypes = [.address, .pointOfInterest]
            completer = operation
            operation.queryFragment = queries(for: value).first ?? value
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            if token == generation { searching = false }
        }
    }
    func completerDidUpdateResults(_ operation: MKLocalSearchCompleter) {
        guard operation === completer else { return }
        let matchers = ([query] + queries(for: query)).map { PlaceMatcher(query: $0, vocabulary: vocabulary) }
        let scored = operation.results.compactMap { completion -> (MKLocalSearchCompletion, Int)? in
            guard let rank = matchers.compactMap({ $0.rank(name: completion.title, address: completion.subtitle) }).min() else { return nil }
            return (completion, rank)
        }.sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 < $1.1 }
        let strong = scored.contains { $0.1 <= 1 }
        var unique: [MKLocalSearchCompletion] = []
        for (completion, rank) in scored {
            if strong && rank > 2 { continue }
            if unique.contains(where: {
                StationSearch.normalize($0.subtitle) == StationSearch.normalize(completion.subtitle) &&
                (StationSearch.rank(name: $0.title, query: completion.title, vocabulary: vocabulary) ?? 9) <= 1
            }) { continue }
            unique.append(completion)
        }
        suggestions = Array(unique.prefix(settings.resultLimit)); searching = false
        completionCache[cacheKey] = (Date(), suggestions)
        if completionCache.count > 24 { completionCache.removeValue(forKey: completionCache.min { $0.value.0 < $1.value.0 }!.key) }
    }
    func setContext(_ coordinate: Coordinate?) {
        let point = coordinate?.isInServiceArea == true ? coordinate! : .taipei
        let moved = preferredPosition.distance(to: point) > 1_500
        preferredPosition = point
        searchRegion = MKCoordinateRegion(center: point.locationCoordinate, span: Self.region.span)
        completer?.region = searchRegion
        if moved && !query.isEmpty { update(query, force: true) }
    }
    func completer(_ operation: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard operation === completer else { return }
        searching = false; suggestions = []
        self.error = "地點搜尋暫時無法連線，可改選下方站牌。"
    }
    func resolve(text: String, completion: MKLocalSearchCompletion? = nil) async throws -> TravelPlace? {
        try await find(text: text, completion: completion).first
    }
    /// `queryLimit` and `timeout` bound one lookup; the journey assistant uses a smaller budget
    /// because the on-device model waits for every search it makes.
    func find(text: String, completion: MKLocalSearchCompletion? = nil, queryLimit: Int = 3, timeout: Double = 6) async throws -> [TravelPlace] {
        // The whole phrase only finds unrelated places (a hotel, a market), so it is not searched.
        if completion == nil, let nearby = NearbyQuery(text) { return try await find(nearby, timeout: timeout) }
        debounceTask?.cancel(); completer?.cancel(); completer = nil
        search?.cancel()
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        generation = UUID(); let token = generation
        searching = true
        defer { if token == generation { searching = false } }
        let key = cacheKey + ":" + (completion?.title ?? "") + ":" + (completion?.subtitle ?? "")
        if let cached = placeCache[key], Date().timeIntervalSince(cached.0) < 600 {
            places = cached.1; return cached.1
        }
        var matches: [TravelPlace] = []
        /// Apple's own results that our name matching did not recognise, kept as a last resort.
        var unmatched: [TravelPlace] = []
        var lastError: Error?
        let clean = StationSearch.cleanQuery(text)
        let addressQuery = StationSearch.isAddressQuery(clean)
        let category: MKPointOfInterestCategory? = ["咖啡": .cafe, "咖啡店": .cafe, "餐廳": .restaurant,
            "醫院": .hospital, "公園": .park, "捷運站": .publicTransport, "加油站": .gasStation][StationSearch.normalize(clean)]
        let transitQuery = StationSearch.isTransitQuery(clean)
        let searchQueries = completion == nil ? Array(queries(for: text).prefix(max(1, queryLimit))) : [text]
        let matchers = ([text] + searchQueries).map { PlaceMatcher(query: $0, vocabulary: vocabulary) }
        for (index, query) in searchQueries.enumerated() {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            let request = completion.map { MKLocalSearch.Request(completion: $0) } ?? MKLocalSearch.Request()
            if completion == nil { request.naturalLanguageQuery = query }
            request.region = searchRegion
            request.resultTypes = completion != nil || addressQuery ? [.address, .pointOfInterest] : [.pointOfInterest]
            if let category { request.pointOfInterestFilter = MKPointOfInterestFilter(including: [category]) }
            else if transitQuery && index == 0 { request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport]) }
            let operation = MKLocalSearch(request: request); search = operation
            let deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                operation.cancel()
            }
            do {
                let response = try await operation.start()
                deadline.cancel()
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                for item in response.mapItems {
                    let coordinate = Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
                    guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
                          (-85...85).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude),
                          abs(coordinate.latitude) + abs(coordinate.longitude) > 0.001 else { continue }
                    let place = TravelPlace(name: item.name ?? text, address: item.placemark.title ?? "", coordinate: coordinate,
                        isTransitPlace: item.pointOfInterestCategory == .publicTransport)
                    let relevant = matchers.contains { $0.rank(name: place.name, address: place.address) != nil }
                    guard completion != nil || relevant || (category != nil && item.pointOfInterestCategory == category) else {
                        if !unmatched.contains(where: { $0.coordinate.distance(to: place.coordinate) < 30 }) { unmatched.append(place) }
                        continue
                    }
                    if !matches.contains(where: { StationSearch.normalize($0.name) == StationSearch.normalize(place.name) && $0.coordinate.distance(to: place.coordinate) < 30 }) { matches.append(place) }
                }
            } catch {
                deadline.cancel()
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                lastError = error
            }
            if completion != nil || category != nil || matches.contains(where: { place in matchers.contains { ($0.rank(name: place.name, address: place.address) ?? 9) <= 1 } }) { break }
        }
        // An address written another way, or a building Apple names differently (台大機械館 / 機械工程學系館):
        // rather than nothing, offer what Apple Maps found, after anything that matched by name.
        if matches.isEmpty || addressQuery {
            matches += unmatched.filter { $0.coordinate.isInServiceArea }.prefix(addressQuery ? 3 : 2)
        }
        if matches.isEmpty, let lastError { throw lastError }
        let scored = matches.map { place in (place, matchers.compactMap { $0.rank(name: place.name, address: place.address) }.min() ?? 9) }
        matches = scored.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if !transitQuery, !addressQuery, $0.0.isTransitPlace != $1.0.isTransitPlace { return $0.0.isTransitPlace != true }
            let a = $0.0.coordinate.distance(to: preferredPosition), b = $1.0.coordinate.distance(to: preferredPosition)
            return a == b ? $0.0.name < $1.0.name : a < b
        }.map { $0.0 }
        places = Array(matches.prefix(settings.resultLimit))
        if !places.isEmpty { placeCache[key] = (Date(), places) }
        if placeCache.count > 24 { placeCache.removeValue(forKey: placeCache.min { $0.value.0 < $1.value.0 }!.key) }
        return places
    }
    /// Places of a kind around an area (or around the rider when no area is said), nearest first.
    /// Empty when the area cannot be found.
    private func find(_ nearby: NearbyQuery, timeout: Double) async throws -> [TravelPlace] {
        var center = preferredPosition
        if !nearby.area.isEmpty {
            do {
                guard let area = try await find(text: nearby.area, queryLimit: 2, timeout: timeout).first(where: { $0.coordinate.isInServiceArea }) else { return [] }
                center = area.coordinate
            } catch is CancellationError { throw CancellationError() } catch { return [] }
        }
        debounceTask?.cancel(); completer?.cancel(); completer = nil; search?.cancel()
        generation = UUID(); let token = generation
        searching = true
        defer { if token == generation { searching = false } }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = nearby.what
        request.region = MKCoordinateRegion(center: center.locationCoordinate, latitudinalMeters: 2400, longitudinalMeters: 2400)
        request.resultTypes = [.pointOfInterest]
        let operation = MKLocalSearch(request: request); search = operation
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            operation.cancel()
        }
        defer { deadline.cancel() }
        guard let response = try? await operation.start() else {
            try Task.checkCancellation()
            return []
        }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        var found: [TravelPlace] = []
        for item in response.mapItems {
            let coordinate = Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
            // Apple widens a sparse search to the whole city; only what is really around the area counts.
            guard coordinate.isInServiceArea, coordinate.distance(to: center) <= 1_500,
                  !found.contains(where: { $0.coordinate.distance(to: coordinate) < 30 }) else { continue }
            found.append(TravelPlace(name: item.name ?? nearby.what, address: item.placemark.title ?? "", coordinate: coordinate,
                                     isTransitPlace: item.pointOfInterestCategory == .publicTransport))
        }
        places = Array(found.sorted { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) }.prefix(max(settings.resultLimit, 5)))
        return places
    }
    func cancel() {
        generation = UUID(); debounceTask?.cancel(); search?.cancel(); completer?.cancel(); completer = nil
        searching = false; query = ""; suggestions = []; places = []; stationHints = []; error = nil
    }
}

