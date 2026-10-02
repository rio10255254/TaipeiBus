import SwiftUI
import MapKit
import TransitCore

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
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    private let completer = MKLocalSearchCompleter()
    private var search: MKLocalSearch?
    static let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25.07, longitude: 121.54),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.4))

    override init() {
        super.init()
        completer.delegate = self
        completer.region = Self.region
        completer.resultTypes = [.address, .pointOfInterest]
    }
    func update(_ text: String) {
        error = nil
        suggestions = []
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searching = !query.isEmpty
        completer.queryFragment = query
        if query.isEmpty { completer.cancel(); searching = false }
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = Array(completer.results.prefix(8)); searching = false
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        searching = false; suggestions = []; self.error = "地點搜尋暫時無法連線，可改選下方站牌。"
    }
    func resolve(text: String, completion: MKLocalSearchCompletion? = nil) async throws -> TravelPlace? {
        search?.cancel()
        let request = completion.map { MKLocalSearch.Request(completion: $0) } ?? MKLocalSearch.Request()
        if completion == nil { request.naturalLanguageQuery = text }
        request.region = Self.region
        request.resultTypes = [.address, .pointOfInterest]
        let operation = MKLocalSearch(request: request); search = operation
        let response = try await operation.start()
        try Task.checkCancellation()
        guard let item = response.mapItems.first(where: {
            Coordinate(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude).isInServiceArea
        }) else { return nil }
        return TravelPlace(name: item.name ?? text, address: item.placemark.title ?? "",
            coordinate: Coordinate(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude))
    }
    func cancel() { search?.cancel(); completer.cancel(); searching = false }
}

struct WalkingLeg: Sendable {
    let from: Coordinate
    let to: Coordinate
    var coordinates: [Coordinate] = []
    var distance: Double?
    var duration: TimeInterval?
    var instructions: [String] = []
    var verified: Bool { duration != nil }
    var timeLabel: String {
        duration.map { $0 < 30 ? "就在附近" : "步行 \(Int(ceil($0 / 60))) 分" } ?? "步行路線待確認"
    }
}

struct JourneyOption: Identifiable, Sendable {
    let id: String
    let trip: TransitTrip?
    var walks: [WalkingLeg]
    var walkIssue: String?
    var rides: [TransitRide] { trip?.rides ?? [] }
    var walkingOnly: Bool { trip == nil }
    var verified: Bool { walks.allSatisfy(\.verified) }
    var walkingTimeLabel: String {
        guard verified else { return "步行路線待確認" }
        let minutes = Int(ceil(walks.compactMap(\.duration).reduce(0, +) / 60))
        return "步行共 \(max(1, minutes)) 分"
    }
    var coordinates: [Coordinate] {
        rides.flatMap(\.coordinates) + walks.flatMap(\.coordinates) + walks.flatMap { [$0.from, $0.to] }
    }
}

enum JourneyStep: Equatable {
    case walk(Int), ride(Int)
}

private actor TripNetwork {
    private var planner: TripPlanner?
    private var key = ""
    private var builtAt = Date.distantPast
    func options(metadata: TransitMetadata, from: Coordinate, to: Coordinate) -> [TransitTrip] {
        let signature = metadata.routes.keys.sorted().joined(separator: ",") + ":\(metadata.stops.count):\(metadata.paths.count)"
        if planner == nil || key != signature || Date().timeIntervalSince(builtAt) > 86_400 {
            planner = TripPlanner(metadata: metadata); key = signature; builtAt = Date()
        }
        let nearby = planner!.plan(from: from, to: to, maximumWalk: 800)
        return nearby.isEmpty ? planner!.plan(from: from, to: to, maximumWalk: 1_200) : nearby
    }
}

@MainActor
final class JourneyPlannerModel: ObservableObject {
    @Published private(set) var origin: TravelPlace?
    @Published private(set) var destination: TravelPlace?
    @Published private(set) var usingLocation = true
    @Published private(set) var options: [JourneyOption] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var planning = false
    @Published private(set) var checkingWalks = false
    @Published private(set) var message: String?
    @Published private(set) var started = false
    @Published private(set) var stepIndex = 0
    @Published private(set) var mapRevision = 0
    @Published private(set) var recentPlaces: [TravelPlace] = []
    private let network = TripNetwork()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var directions: [MKDirections] = []
    private var latestSnapshot = TransitSnapshot()

    init() {
        if let data = UserDefaults.standard.data(forKey: "journeyRecentPlaces"),
           let places = try? JSONDecoder().decode([TravelPlace].self, from: data) { recentPlaces = places }
    }
    var selected: JourneyOption? { options.first { $0.id == selectedID } }
    var steps: [JourneyStep] {
        guard let option = selected else { return [] }
        if option.walkingOnly { return [.walk(0)] }
        return option.rides.indices.flatMap { [JourneyStep.walk($0), .ride($0)] } + [.walk(option.walks.count - 1)]
    }
    var currentStep: JourneyStep? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }
    func updateSnapshot(_ snapshot: TransitSnapshot) { latestSnapshot = snapshot }
    var arrived: Bool { started && stepIndex >= steps.count }
    var mapCoordinates: [Coordinate] {
        guard let option = selected else { return [] }
        guard started, let currentStep else { return option.coordinates }
        switch currentStep {
        case .walk(let index):
            let leg = option.walks[index]
            return leg.coordinates.isEmpty ? [leg.from, leg.to] : leg.coordinates
        case .ride(let index):
            let ride = option.rides[index]
            return ride.coordinates.isEmpty ? ride.stops.map(\.coordinate) : ride.coordinates
        }
    }
    func useLocation(_ coordinate: Coordinate?, metadata: TransitMetadata) {
        usingLocation = true
        origin = coordinate.map { TravelPlace(name: "目前位置", address: "", coordinate: $0) }
        if destination != nil { plan(metadata: metadata) }
    }
    func locationArrived(_ coordinate: Coordinate, metadata: TransitMetadata) {
        guard usingLocation, !started, origin == nil else { return }
        useLocation(coordinate, metadata: metadata)
    }
    func setOrigin(_ place: TravelPlace, metadata: TransitMetadata) {
        origin = place; usingLocation = false
        if destination != nil { plan(metadata: metadata) }
    }
    func setDestination(_ place: TravelPlace, metadata: TransitMetadata, currentLocation: Coordinate?) {
        destination = place
        if usingLocation { origin = currentLocation.map { TravelPlace(name: "目前位置", address: "", coordinate: $0) } }
        recentPlaces = [place] + Array(recentPlaces.filter { $0.id != place.id }.prefix(5))
        if let data = try? JSONEncoder().encode(recentPlaces) { UserDefaults.standard.set(data, forKey: "journeyRecentPlaces") }
        plan(metadata: metadata)
    }
    func plan(metadata: TransitMetadata) {
        cancelRequests()
        options = []; selectedID = nil; started = false; stepIndex = 0; message = nil; mapRevision += 1
        guard let origin, let destination else {
            message = "選擇出發地，才能找附近可搭的站牌。"; return
        }
        guard origin.coordinate.isInServiceArea, destination.coordinate.isInServiceArea else {
            message = "公車規劃目前涵蓋台北市區與周邊。可改選出發地，或用 Apple 地圖規劃。"; return
        }
        guard !metadata.routes.isEmpty else { message = "路線資料載入後即可規劃。"; return }
        planning = true
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            let trips = await network.options(metadata: metadata, from: origin.coordinate, to: destination.coordinate)
            guard !Task.isCancelled, token == generation else { return }
            func availability(_ trip: TransitTrip) -> Int {
                guard let ride = trip.rides.first,
                      let eta = latestSnapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: Date()) else { return 1 }
                return eta >= 0 ? 0 : [-2, -3, -4].contains(eta) ? 2 : 1
            }
            let ordered = trips.sorted {
                let a = availability($0), b = availability($1)
                return a == b ? $0.score < $1.score : a < b
            }
            var choices = ordered.prefix(3).map { trip -> JourneyOption in
                var walks = [WalkingLeg(from: origin.coordinate, to: trip.rides[0].boarding.coordinate)]
                if trip.rides.count > 1 {
                    for i in 1..<trip.rides.count {
                        walks.append(WalkingLeg(from: trip.rides[i - 1].alighting.coordinate, to: trip.rides[i].boarding.coordinate))
                    }
                }
                walks.append(WalkingLeg(from: trip.rides.last!.alighting.coordinate, to: destination.coordinate))
                return JourneyOption(id: trip.id, trip: trip, walks: walks)
            }
            if origin.coordinate.distance(to: destination.coordinate) <= 900 {
                choices.insert(JourneyOption(id: "walking", trip: nil,
                    walks: [WalkingLeg(from: origin.coordinate, to: destination.coordinate)]), at: 0)
                choices = Array(choices.prefix(3))
            }
            options = choices; selectedID = choices.first?.id; planning = false; mapRevision += 1
            guard !choices.isEmpty else {
                message = "附近未找到直達或一次轉乘的公車。可改選出發地，或用 Apple 地圖查看其他轉乘。"; return
            }
            checkingWalks = true
            // Only calculate routes being presented to the user. Validate the recommended option first.
            for choice in choices {
                do {
                    let verified = try await enrich(choice)
                    guard token == generation, !Task.isCancelled else { return }
                    if let index = options.firstIndex(where: { $0.id == choice.id }) { options[index] = verified }
                    if verified.walkIssue == nil {
                        selectedID = verified.id; mapRevision += 1; break
                    }
                } catch { return }
            }
            guard token == generation else { return }
            checkingWalks = false; mapRevision += 1
        }
    }
    func select(_ option: JourneyOption) {
        guard selectedID != option.id || !option.verified else { return }
        cancelRequests(); selectedID = option.id; started = false; stepIndex = 0; mapRevision += 1
        guard !option.verified else { return }
        checkingWalks = true
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let verified = try await enrich(option)
                guard token == generation, !Task.isCancelled else { return }
                if let index = options.firstIndex(where: { $0.id == option.id }) { options[index] = verified }
                checkingWalks = false; mapRevision += 1
            } catch { if token == generation { checkingWalks = false } }
        }
    }
    private func enrich(_ option: JourneyOption) async throws -> JourneyOption {
        var result = option
        for index in option.walks.indices {
            try Task.checkCancellation()
            result.walks[index] = try await walk(option.walks[index])
        }
        let hasLongWalk = result.walks.enumerated().contains { index, leg in
            let transfer = index > 0 && index < result.walks.count - 1
            return (leg.distance ?? 0) > (transfer ? 600 : 1_800)
        }
        if hasLongWalk { result.walkIssue = "實際步行距離較長，建議選擇其他方案。" }
        return result
    }
    private func walk(_ leg: WalkingLeg) async throws -> WalkingLeg {
        var result = leg
        if leg.from.distance(to: leg.to) < 1 {
            result.distance = 0; result.duration = 0; return result
        }
        let request = MKDirections.Request()
        request.source = TravelPlace(name: "起點", address: "", coordinate: leg.from).mapItem
        request.destination = TravelPlace(name: "終點", address: "", coordinate: leg.to).mapItem
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        let operation = MKDirections(request: request); directions.append(operation)
        defer { directions.removeAll { $0 === operation } }
        do {
            let response = try await operation.calculate()
            try Task.checkCancellation()
            if let route = response.routes.first {
                var coordinates = Array(repeating: CLLocationCoordinate2D(), count: route.polyline.pointCount)
                route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: coordinates.count))
                result.coordinates = coordinates.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
                result.distance = route.distance; result.duration = route.expectedTravelTime
                result.instructions = route.steps.map(\.instructions).filter { !$0.isEmpty }
            }
        } catch {
            try Task.checkCancellation()
            // No straight-line walking polyline or fabricated time when Apple cannot confirm a route.
        }
        return result
    }
    func begin() {
        guard let option = selected, option.walkIssue == nil, !checkingWalks else { return }
        started = true; stepIndex = 0; mapRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func advance() {
        guard started, stepIndex < steps.count else { return }
        stepIndex += 1; mapRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func finish() {
        cancelRequests(); started = false; destination = nil; options = []; selectedID = nil; message = nil; stepIndex = 0; mapRevision += 1
    }
    func navigateWalk(_ index: Int) {
        guard let option = selected, option.walks.indices.contains(index) else { return }
        let leg = option.walks[index]
        let title = index < option.rides.count ? option.rides[index].boarding.name : destination?.name ?? "目的地"
        let target = TravelPlace(name: title, address: "", coordinate: leg.to).mapItem
        let source = TravelPlace(name: index == 0 ? origin?.name ?? "出發地" : "下車站", address: "", coordinate: leg.from).mapItem
        MKMapItem.openMaps(with: [source, target], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
    func openAppleTransit() {
        guard let destination else { return }
        let source = origin?.mapItem ?? MKMapItem.forCurrentLocation()
        MKMapItem.openMaps(with: [source, destination.mapItem], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
    }
    private func cancelRequests() {
        task?.cancel(); task = nil; directions.forEach { $0.cancel() }; directions = []
        generation = UUID(); planning = false; checkingWalks = false
    }
}
