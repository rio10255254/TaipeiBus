import SwiftUI
import MapKit
import TransitCore

struct WalkingLeg: Sendable {
    let from: Coordinate
    let to: Coordinate
    var coordinates: [Coordinate] = []
    var distance: Double?
    var duration: TimeInterval?
    var instructions: [String] = []
    var road: RouteLine?
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
        return "步行 \(max(1, minutes)) 分"
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
    func options(metadata: TransitMetadata, from: Coordinate, to: Coordinate, preferences: LiveSettings.Planning,
                 estimates: EstimateFeed) -> [TransitTrip] {
        let signature = metadata.revision.uuidString
        if planner == nil || key != signature || Date().timeIntervalSince(builtAt) > 86_400 {
            planner = TripPlanner(metadata: metadata); key = signature; builtAt = Date()
        }
        return planner!.plan(from: from, to: to, maximumWalk: preferences.expandedWalkMeters, limit: 36,
                             preferences: preferences, estimates: estimates, preservePlatforms: true)

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
    private var preferences = LiveSettings.Planning()
    private var lastMetadata: TransitMetadata?
    private var selectionConfirmed = false
    private var forecast = VehicleArrivalForecast()
    private var verifiedPool: [JourneyOption] = []
    private var walkingCache: [String: WalkingLeg] = [:]
    @Published private(set) var optionLabels: [String: String] = [:]
    @Published private(set) var alternativeTransitSeconds: Double?
    private var alternativeTransitUpdatedAt = Date.distantPast
    var freshAlternativeTransitSeconds: Double? {
        Date().timeIntervalSince(alternativeTransitUpdatedAt) <= 120 ? alternativeTransitSeconds : nil
    }
    private var alternativeTask: Task<Void, Never>?


    init() {
        if let data = UserDefaults.standard.data(forKey: "journeyRecentPlaces"),
           let places = try? JSONDecoder().decode([TravelPlace].self, from: data) { recentPlaces = places }
    }
    var selected: JourneyOption? { options.first { $0.id == selectedID } }
    func duration(_ option: JourneyOption, at date: Date) -> JourneyDuration? {
        guard option.verified, option.walkIssue == nil else { return nil }
        let riding = option.rides.map { ride in
            lastMetadata.map { forecast.ridingSeconds(ride, metadata: $0, at: date) } ?? option.trip?.rideSeconds[option.rides.firstIndex(where: { $0.id == ride.id }) ?? 0] ?? 0
        }
        if let trip = option.trip {
            let assessment = TripRanking.assessment(trip, estimates: latestSnapshot.estimates, at: date,
                preferences: preferences, walkingDurations: option.walks.map(\.duration), ridingDurations: riding)
            return JourneyDuration(assessment: assessment, riding: riding)
        }
        return JourneyDuration(riding: [], walking: option.walks.compactMap(\.duration), arrivals: [], at: date)
    }
    private func publishRecommendations() {
        let date = Date()
        let valid = verifiedPool.filter { $0.verified && $0.walkIssue == nil }
        let trips = valid.compactMap(\.trip)
        let walks = Dictionary(uniqueKeysWithValues: valid.map { ($0.id, $0.walks.map(\.duration)) })
        let rides = Dictionary(uniqueKeysWithValues: valid.filter { !$0.walkingOnly }.map { option in
            (option.id, option.rides.map { ride in lastMetadata.map { forecast.ridingSeconds(ride, metadata: $0, at: date) } ?? 0 })
        })
        let ranked = TripRanking.recommended(trips, estimates: latestSnapshot.estimates, at: date,
            preferences: preferences, limit: 3, walkingDurations: walks, ridingDurations: rides)
        var result = ranked.compactMap { trip in valid.first { $0.id == trip.id } }
        if let foot = valid.first(where: \.walkingOnly), let walking = duration(foot, at: date),
           result.first.flatMap({ duration($0, at: date)?.totalSeconds }).map({ walking.totalSeconds <= $0 + 60 }) ?? true {
            result.insert(foot, at: 0)
        }
        result = Array(result.prefix(3))
        let recommended = result.first.flatMap { duration($0, at: date) }
        var labels: [String: String] = [:]
        for (index, option) in result.enumerated() {
            if index == 0 { labels[option.id] = option.walkingOnly ? "步行即可" : "推薦"; continue }
            if let timing = duration(option, at: date), let recommended {
                if timing.totalSeconds < recommended.totalSeconds - 60 { labels[option.id] = "較快" }
                else if timing.walkingSeconds < recommended.walkingSeconds - 120 { labels[option.id] = "少走路" }
                else { labels[option.id] = option.rides.count == 1 ? "直達" : "少轉乘" }
            }
        }
        let oldIDs = options.map(\.id)
        options = result; optionLabels = labels
        if !selectionConfirmed { selectedID = result.first?.id }
        if oldIDs != result.map(\.id) { mapRevision += 1 }
    }
    private func startAlternativeTransit(from: Coordinate, to: Coordinate, token: UUID) {
        alternativeTask?.cancel()
        alternativeTask = Task { [weak self] in
            guard let self else { return }
            let request = MKDirections.Request()
            request.source = TravelPlace(name: "出發地", address: "", coordinate: from).mapItem
            request.destination = TravelPlace(name: "目的地", address: "", coordinate: to).mapItem
            request.transportType = .transit; request.departureDate = Date()
            let requestedAt = Date()
            let operation = MKDirections(request: request); directions.append(operation)
            defer { directions.removeAll { $0 === operation } }
            if let response = try? await operation.calculateETA(), !Task.isCancelled, token == generation,
               response.transportType == .transit, response.expectedTravelTime.isFinite, response.expectedTravelTime > 0 {
                alternativeTransitSeconds = max(response.expectedTravelTime, response.expectedArrivalDate.timeIntervalSince(requestedAt))
                alternativeTransitUpdatedAt = Date()
            }
        }
    }
    var steps: [JourneyStep] {
        guard let option = selected else { return [] }
        if option.walkingOnly { return [.walk(0)] }
        return option.rides.indices.flatMap { [JourneyStep.walk($0), .ride($0)] } + [.walk(option.walks.count - 1)]
    }
    var currentStep: JourneyStep? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }
    /// Waiting is the default state; the rider confirms boarding rather than the GPS guessing it.
    var boardingRideIndex: Int? {
        guard let option = selected, !option.rides.isEmpty else { return nil }
        if !started { return 0 }
        if case .walk(let index) = currentStep, option.rides.indices.contains(index) { return index }
        return nil
    }
    var activeRide: TransitRide? {
        guard let option = selected else { return nil }
        if let index = boardingRideIndex { return option.rides[index] }
        if case .ride(let index) = currentStep { return option.rides[index] }
        return nil
    }
    func updateSnapshot(_ snapshot: TransitSnapshot, forecast: VehicleArrivalForecast = .init()) {
        latestSnapshot = snapshot; self.forecast = forecast
        // Live times continue updating inside each row. Once walking verification
        // finishes, leave those rows in place while the rider reads and compares.
        // Replacing them on a GPS refresh can change the option beneath a finger.
    }
    func updateSettings(_ settings: LiveSettings) { preferences = settings.planning }
    var arrived: Bool { started && stepIndex >= steps.count }
    var mapCoordinates: [Coordinate] {
        guard let option = selected else { return [] }
        if arrived { return destination.map { [$0.coordinate] } ?? [] }
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
        lastMetadata = metadata; selectionConfirmed = false
        cancelRequests()
        verifiedPool = []; optionLabels = [:]; alternativeTransitSeconds = nil
        options = []; selectedID = nil; started = false; stepIndex = 0; message = nil; mapRevision += 1
        guard let origin, let destination else {
            message = "選擇出發地，才能找附近可搭的站牌。"; return
        }
        guard origin.coordinate.isInServiceArea, destination.coordinate.isInServiceArea else {
            message = "此地超出公車規劃範圍"; return
        }
        guard !metadata.routes.isEmpty else { message = "路線資料載入後即可規劃。"; return }
        planning = true
        let token = generation
        let preferences = self.preferences
        task = Task { [weak self] in
            guard let self else { return }
            let trips = await network.options(metadata: metadata, from: origin.coordinate, to: destination.coordinate,
                                              preferences: preferences, estimates: latestSnapshot.estimates)
            guard !Task.isCancelled, token == generation else { return }
            verifiedPool = []; optionLabels = [:]
            let date = Date()
            let ordered = TripRanking.recommended(trips, estimates: latestSnapshot.estimates, at: date,
                preferences: preferences, limit: 36, diverse: false)
            func option(_ trip: TransitTrip) -> JourneyOption {
                var walks = [WalkingLeg(from: origin.coordinate, to: trip.rides[0].boarding.coordinate)]
                for index in trip.rides.indices.dropFirst() {
                    walks.append(WalkingLeg(from: trip.rides[index - 1].alighting.coordinate, to: trip.rides[index].boarding.coordinate))
                }
                walks.append(WalkingLeg(from: trip.rides.last!.alighting.coordinate, to: destination.coordinate))
                return JourneyOption(id: trip.id, trip: trip, walks: walks)
            }
            // Verify several families plus their alternative platforms, not just the three eventual rows.
            var selected: [TransitTrip] = []
            var families = Set<String>()
            for trip in ordered where families.insert(trip.familyID).inserted {
                selected.append(trip); if selected.count >= 6 { break }
            }
            for trip in ordered where !selected.contains(where: { $0.id == trip.id }) {
                selected.append(trip); if selected.count >= 18 { break }
            }
            var pending = selected.map(option)
            if origin.coordinate.distance(to: destination.coordinate) <= max(preferences.walkingOnlyMeters, 1_500) {
                pending.insert(JourneyOption(id: "walking", trip: nil,
                    walks: [WalkingLeg(from: origin.coordinate, to: destination.coordinate)]), at: 0)
            }
            options = Array(pending.prefix(3)); selectedID = nil; planning = false; checkingWalks = true
            startAlternativeTransit(from: origin.coordinate, to: destination.coordinate, token: token)
            guard !pending.isEmpty else { message = "附近沒有合適公車"; checkingWalks = false; return }
            // Two pedestrian requests at a time, with shared leg cache and cancellation.
            for start in stride(from: 0, to: pending.count, by: 2) {
                let batch = Array(pending[start..<min(pending.count, start + 2)])
                await withTaskGroup(of: JourneyOption?.self) { group in
                    for choice in batch {
                        group.addTask { [weak self] in try? await self?.enrich(choice) }
                    }
                    for await result in group {
                        guard token == self.generation, !Task.isCancelled, let result else { continue }
                        if result.verified && result.walkIssue == nil { self.verifiedPool.append(result) }
                    }
                }
                guard token == generation, !Task.isCancelled else { return }
                publishRecommendations()
            }
            guard token == generation else { return }
            checkingWalks = false
            publishRecommendations()
            if verifiedPool.isEmpty { message = "步行接駁暫時無法確認，請稍後重試或查看其他交通方式。"; options = []; selectedID = nil }
            mapRevision += 1

        }
    }
    func select(_ option: JourneyOption) {
        guard option.verified, option.walkIssue == nil, unavailableBoarding(option) == nil else { return }
        selectionConfirmed = true
        // The recommended option can already be verified while alternatives are
        // still loading. Confirming it must stop that work from selecting another.
        if selectedID == option.id, option.verified { cancelRequests(); return }
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
        if hasLongWalk { result.walkIssue = "步行接駁過長" }
        if !result.verified { result.walkIssue = "步行接駁待確認" }
        return result
    }
    private func walk(_ leg: WalkingLeg) async throws -> WalkingLeg {
        let cacheKey = "\(leg.from.latitude):\(leg.from.longitude):\(leg.to.latitude):\(leg.to.longitude)"
        if let cached = walkingCache[cacheKey] { return cached }
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
                result.road = RouteLine(coordinates: result.coordinates)
            }
        } catch {
            try Task.checkCancellation()
            // No straight-line walking polyline or fabricated time when Apple cannot confirm a route.
        }
        if result.verified { walkingCache[cacheKey] = result }
        return result
    }
    func begin() {
        guard let option = selected, option.verified, option.walkIssue == nil else { return }
        guard unavailableBoarding(option) == nil else { return }
        started = true; stepIndex = 0; mapRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func advance() {
        guard started, stepIndex < steps.count else { return }
        stepIndex += 1; mapRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func boardCurrentRide() {
        guard let index = boardingRideIndex,
              let target = steps.firstIndex(of: .ride(index)) else { return }
        started = true; stepIndex = target; mapRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func returnToWaiting() {
        guard case .ride(let index) = currentStep,
              let target = steps.firstIndex(of: .walk(index)) else { return }
        started = index > 0; stepIndex = target; mapRevision += 1
    }
    func finish() {
        cancelRequests(); started = false; destination = nil; options = []; selectedID = nil; message = nil; stepIndex = 0; mapRevision += 1
    }
    func navigateWalk(_ index: Int) {
        guard let option = selected, option.walks.indices.contains(index) else { return }
        let leg = option.walks[index]
        let title = index < option.rides.count ? option.rides[index].boarding.name : destination?.name ?? "目的地"
        let target = TravelPlace(name: title, address: "", coordinate: leg.to).mapItem
        let source = index == 0 && usingLocation ? MKMapItem.forCurrentLocation() :
            TravelPlace(name: index == 0 ? origin?.name ?? "出發地" : "下車站", address: "", coordinate: leg.from).mapItem
        MKMapItem.openMaps(with: [source, target], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
    func openAppleTransit() {
        guard let destination else { return }
        let source = origin?.mapItem ?? MKMapItem.forCurrentLocation()
        MKMapItem.openMaps(with: [source, destination.mapItem], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
    }
    func unavailableBoarding(_ option: JourneyOption) -> (route: String, status: Int)? {
        for ride in option.rides {
            if let eta = latestSnapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: Date()),
               [-2, -3, -4].contains(eta) { return (ride.route.name, eta) }
        }
        return nil
    }
    private func cancelRequests() {
        task?.cancel(); task = nil; alternativeTask?.cancel(); alternativeTask = nil; directions.forEach { $0.cancel() }; directions = []
        generation = UUID(); planning = false; checkingWalks = false
    }

#if DEBUG
    func prepareBoardingPreview(_ trip: TransitTrip) {
        cancelRequests()
        guard let first = trip.rides.first, let last = trip.rides.last else { return }
        origin = TravelPlace(name: first.boarding.name, address: "", coordinate: first.boarding.coordinate)
        destination = TravelPlace(name: last.alighting.name, address: "", coordinate: last.alighting.coordinate)
        usingLocation = false; started = false; stepIndex = 0
        var walks = [WalkingLeg(from: first.boarding.coordinate, to: first.boarding.coordinate, distance: 0, duration: 0)]
        for index in trip.rides.indices.dropFirst() {
            let from = trip.rides[index - 1].alighting.coordinate, to = trip.rides[index].boarding.coordinate
            let distance = from.distance(to: to)
            walks.append(WalkingLeg(from: from, to: to, distance: distance, duration: distance / 1.2))
        }
        walks.append(WalkingLeg(from: last.alighting.coordinate, to: last.alighting.coordinate, distance: 0, duration: 0))
        options = [JourneyOption(id: trip.id, trip: trip, walks: walks)]
        selectedID = trip.id; message = nil; mapRevision += 1
    }
#endif
}
