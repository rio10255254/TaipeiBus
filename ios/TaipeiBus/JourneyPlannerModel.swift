import SwiftUI
import MapKit
import TransitCore

/// A YouBike connection inside one journey leg: walk to a station that has bikes, ride to a
/// station that has somewhere to return it, walk on from there. The riding portion uses
/// Apple cycling directions and their travel time, separately from the two pedestrian legs.
struct BikeLeg: Sendable {
    var pickup: BikeStation
    var dropoff: BikeStation
    /// What each station reported when the trip was planned.
    var bikes: Int
    var docks: Int
    var handlingSeconds: Double
    var toPickup: [Coordinate] = []
    var toPickupMeters: Double = 0
    var toPickupSeconds: Double = 0
    var ride: [Coordinate] = []
    var rideMeters: Double = 0
    var rideSeconds: Double = 0
    var fromDropoff: [Coordinate] = []
    var fromDropoffMeters: Double = 0
    var fromDropoffSeconds: Double = 0
    var walkingSeconds: Double { toPickupSeconds + fromDropoffSeconds }
    var walkingMeters: Double { toPickupMeters + fromDropoffMeters }
    var cyclingSeconds: Double { rideSeconds + handlingSeconds }
    var totalSeconds: Double { walkingSeconds + cyclingSeconds }
    var totalMeters: Double { walkingMeters + rideMeters }
    var coordinates: [Coordinate] { toPickup + ride + fromDropoff }
    /// Which part of the leg the rider is in, from how far along the leg they are.
    enum Phase { case toPickup, riding, fromDropoff }
    func phase(remainingMeters: Double) -> Phase {
        if remainingMeters > rideMeters + fromDropoffMeters { return .toPickup }
        return remainingMeters > fromDropoffMeters ? .riding : .fromDropoff
    }
}

/// Built from a planned connection; the street geometry is filled in when the leg is verified.
extension BikeLeg {
    init(_ connection: BikeConnection) {
        self.init(pickup: connection.pickup, dropoff: connection.dropoff, bikes: connection.bikes,
                  docks: connection.docks, handlingSeconds: connection.handlingSeconds,
                  toPickupMeters: connection.accessMeters, toPickupSeconds: connection.accessSeconds,
                  rideMeters: connection.rideMeters, rideSeconds: connection.rideSeconds,
                  fromDropoffMeters: connection.egressMeters, fromDropoffSeconds: connection.egressSeconds)
    }
}

struct WalkingLeg: Sendable {
    let from: Coordinate
    let to: Coordinate
    var coordinates: [Coordinate] = []
    var distance: Double?
    var duration: TimeInterval?
    var instructions: [String] = []
    var road: RouteLine?
    var stationSeconds: Double = 0
    var stationInstruction: String? = nil
    var internalTransfer = false
    var minimumDuration: Double = 0
    var streetDuration: Double? = nil
    /// Set when this leg is ridden rather than walked.
    var bike: BikeLeg? = nil
    var verified: Bool { duration != nil }
    var cyclingSeconds: Double { bike?.cyclingSeconds ?? 0 }
    /// Only the parts of this leg that are walked; a cycling leg keeps its ridden path apart.
    var footPaths: [[Coordinate]] {
        if let bike { return [bike.toPickup, bike.fromDropoff].filter { $0.count >= 2 } }
        return coordinates.count >= 2 ? [coordinates] : []
    }
    var timeLabel: String {
        if let bike, verified { return AppText.text("YouBike %@ 分", Int(ceil(bike.totalSeconds / 60))) }
        if bike != nil { return AppText.text("YouBike 路線待確認") }
        return duration.map { $0 < 30 ? AppText.text("就在附近") : AppText.text("步行 %@ 分", Int(ceil($0 / 60))) } ?? AppText.text("步行路線待確認")
    }
}

struct JourneyOption: Identifiable, Sendable {
    let id: String
    let trip: TransitTrip?
    var walks: [WalkingLeg]
    var walkIssue: String?
    var rides: [TransitRide] { trip?.rides ?? [] }
    var walkingOnly: Bool { trip == nil && walks.allSatisfy { $0.bike == nil } }
    /// A trip made entirely by YouBike, with no bus or train.
    var bikeOnly: Bool { trip == nil && walks.contains { $0.bike != nil } }
    var cycles: Bool { walks.contains { $0.bike != nil } }
    var cyclingSeconds: Double { walks.reduce(0) { $0 + $1.cyclingSeconds } }
    /// The station this trip rents a bike from, while one is still to be rented.
    var bikeLegIndex: Int? { walks.firstIndex { $0.bike != nil } }
    var verified: Bool { walks.allSatisfy(\.verified) }
    var walkingTimeLabel: String {
        guard verified else { return AppText.text("步行路線待確認") }
        let minutes = Int(ceil(walks.compactMap(\.duration).reduce(0, +) / 60))
        return AppText.text("步行 %@ 分", max(1, minutes))
    }
    var coordinates: [Coordinate] {
        rides.flatMap(\.coordinates) + walks.flatMap(\.coordinates) + walks.flatMap { [$0.from, $0.to] }
    }
}

enum JourneyStep: Equatable {
    case walk(Int), ride(Int)
}

private actor TripNetwork {
    private var planner: MultimodalPlanner?
    private var key = ""
    private var builtAt = Date.distantPast
    func options(metadata: TransitMetadata, from: Coordinate, to: Coordinate, preferences: LiveSettings.Planning,
                 estimates: EstimateFeed) -> [TransitTrip] {
        let signature = metadata.revision.uuidString
        if planner == nil || key != signature || Date().timeIntervalSince(builtAt) > 86_400 {
            planner = MultimodalPlanner(metadata: metadata); key = signature; builtAt = Date()
        }
        return planner!.plan(from: from, to: to, maximumWalk: preferences.expandedWalkMeters, limit: 36,
                             preferences: preferences, estimates: estimates)

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
    @Published private(set) var comparisonChanged = false
    @Published private(set) var alternativeTransitSeconds: Double?
    private var alternativeTransitUpdatedAt = Date.distantPast
    var freshAlternativeTransitSeconds: Double? {
        Date().timeIntervalSince(alternativeTransitUpdatedAt) <= 120 ? alternativeTransitSeconds : nil
    }
    private var alternativeTask: Task<Void, Never>?
    @Published private(set) var walkingProgress: WalkingProgress?
    @Published private(set) var walkingLegIndex: Int?
    @Published private(set) var walkingRecalculating = false
    @Published private(set) var walkingRouteUnavailable = false
    @Published private(set) var walkingRevision = 0
    @Published private(set) var walkingRouteRevision = 0
    private var walkingTask: Task<Void, Never>?
    private var walkingRequest: MKDirections?
    private var walkingGeneration = UUID()
    private var lastWalkingRequestAt = Date.distantPast

    func endWalkingGuidance() {
        walkingTask?.cancel(); walkingTask = nil; walkingRequest?.cancel(); walkingRequest = nil
        walkingGeneration = UUID(); walkingLegIndex = nil; walkingProgress = nil
        walkingRecalculating = false; walkingRouteUnavailable = false; lastWalkingRequestAt = .distantPast
        walkingRevision += 1
    }

    func updateWalking(index: Int, coordinate: Coordinate, accuracy: Double, timestamp: Date, now: Date) {
        guard let option = selected, option.walks.indices.contains(index) else { return }
        let leg = option.walks[index]
        guard !leg.internalTransfer else { return }
        let first = walkingLegIndex != index
        if first {
            endWalkingGuidance(); walkingLegIndex = index
            walkingProgress = WalkingProgress(coordinates: leg.coordinates, distance: leg.distance ?? 0, seconds: leg.streetDuration ?? leg.duration ?? 0)
        }
        guard var progress = walkingProgress else { return }
        let firstReliable = progress.lastFix == nil
        let advanced = progress.update(coordinate: coordinate, accuracy: accuracy, timestamp: timestamp, now: now)
        walkingProgress = progress
        if advanced { walkingRouteUnavailable = false; walkingRevision += 1 }
        // A cycling leg is three pieces of route, not one walk: rerouting it from here would
        // quietly turn the ride into a long walk. Its progress still updates.
        guard leg.bike == nil else { return }
        let fresh = accuracy >= 0 && accuracy <= 35 && abs(now.timeIntervalSince(timestamp)) <= 15
        let startChanged = (first || firstReliable) && coordinate.distance(to: leg.from) > 35 && progress.match == nil
        guard fresh, (startChanged || progress.needsReroute), !walkingRecalculating,
              now.timeIntervalSince(lastWalkingRequestAt) >= 20 else { return }
        walkingRecalculating = true; walkingRouteUnavailable = false; lastWalkingRequestAt = now
        let token = walkingGeneration, optionID = option.id
        walkingTask = Task { [weak self] in
            guard let self else { return }
            do {
                var refreshed = try await walk(WalkingLeg(from: coordinate, to: leg.to), guidance: true)
                guard !Task.isCancelled, walkingGeneration == token, selectedID == optionID,
                      walkingLegIndex == index, let slot = options.firstIndex(where: { $0.id == optionID }) else { return }
                walkingRecalculating = false
                guard refreshed.verified else { walkingRouteUnavailable = true; return }
                refreshed.streetDuration = refreshed.duration
                refreshed.stationSeconds = leg.stationSeconds; refreshed.stationInstruction = leg.stationInstruction
                let stationAllowance = max(0,(leg.duration ?? 0) - (leg.streetDuration ?? leg.duration ?? 0))
                refreshed.duration = (refreshed.duration ?? 0) + stationAllowance
                options[slot].walks[index] = refreshed
                walkingProgress = WalkingProgress(coordinates: refreshed.coordinates, distance: refreshed.distance ?? 0, seconds: refreshed.streetDuration ?? refreshed.duration ?? 0)
                walkingRevision += 1; walkingRouteRevision += 1
            } catch {
                if walkingGeneration == token, !Task.isCancelled { walkingRecalculating = false; walkingRouteUnavailable = true }
            }
        }
    }

    /// Which part of a cycling leg the rider is in now, from how far along the leg they are.
    func cyclingPhase(at index: Int) -> BikeLeg.Phase? {
        guard let option = selected, option.walks.indices.contains(index), let bike = option.walks[index].bike else { return nil }
        guard walkingLegIndex == index, let progress = walkingProgress, progress.locationConfirmed else { return .toPickup }
        return bike.phase(remainingMeters: progress.remainingDistance)
    }
    /// What to do right now on a cycling leg: fetch the bike, ride it, or walk on after docking.
    func cyclingInstruction(at index: Int) -> String? {
        guard let option = selected, option.walks.indices.contains(index), let bike = option.walks[index].bike,
              let phase = cyclingPhase(at: index) else { return nil }
        switch phase {
        case .toPickup: return AppText.text("走到 %@ 借 YouBike", bike.pickup.localizedName)
        case .riding: return AppText.text("騎到 %@ 還車", bike.dropoff.localizedName)
        case .fromDropoff:
            let target = option.rides.indices.contains(index) ? option.rides[index].boarding.localizedName
                : destination?.localizedName ?? AppText.text("目的地")
            return AppText.text("已還車，步行到 %@", target)
        }
    }
    func walkingCoordinates(at index: Int) -> [Coordinate] {
        if walkingLegIndex == index, let walkingProgress { return walkingProgress.remainingCoordinates }
        return selected?.walks.indices.contains(index) == true ? selected!.walks[index].coordinates : []
    }

    func walkingStatus(at index: Int) -> String? {
        guard walkingLegIndex == index else { return nil }
        if walkingRecalculating { return AppText.text("重新規劃步行中") }
        if walkingRouteUnavailable { return AppText.text("步行路線暫時無法更新") }
        guard let progress = walkingProgress, progress.locationConfirmed,
              let date = progress.lastFix, Date().timeIntervalSince(date) <= 20 else { return AppText.text("正在確認步行位置") }
        if progress.remainingDistance < 12 { return AppText.text("就在附近") }
        return AppText.text("步行剩餘 %@ · %@ 分", distanceLabel(progress.remainingDistance), max(1, Int(ceil(progress.remainingSeconds / 60))))
    }


    init() {
        if let data = UserDefaults.standard.data(forKey: "journeyRecentPlaces"),
           let places = try? JSONDecoder().decode([TravelPlace].self, from: data) { recentPlaces = places }
    }
    var selected: JourneyOption? { options.first { $0.id == selectedID } }
    /// Every station an offered trip would rent a bike from.
    var plannedPickupStations: [BikeStation] {
        options.compactMap { option in option.bikeLegIndex.flatMap { option.walks[$0].bike?.pickup } }
    }
    /// True while the chosen trip rides a YouBike, or while one is still among the choices,
    /// so counts stay fresh exactly as long as they are needed.
    var cyclingInPlan: Bool { selected.map(\.cycles) ?? options.contains(where: \.cycles) }
    /// The ridden part of each leg on the map, drawn apart from the walked parts.
    var bikeCoordinates: [[Coordinate]] {
        guard let option = selected else { return [] }
        let legs: [WalkingLeg]
        if started, case .walk(let index) = currentStep, option.walks.indices.contains(index) { legs = [option.walks[index]] }
        else if started { legs = [] }
        else { legs = option.walks }
        return legs.compactMap { $0.bike }.map(\.ride).filter { $0.count >= 2 }
    }
    func ridingEstimates(_ option: JourneyOption, at date: Date) -> [RidingTimeEstimate] {
        if let trip = option.trip, let metadata = lastMetadata {
            return forecast.plannedRidingEstimates(trip, metadata: metadata, estimates: latestSnapshot.estimates,
                walkingDurations: option.walks.map(\.duration), preferences: preferences, at: date)
        }
        return option.rides.enumerated().map { index, _ in
            RidingTimeEstimate(seconds: option.trip?.rideSeconds[index] ?? 0, evidence: .typical, observedVehicles: 0)
        }
    }
    func duration(_ option: JourneyOption, at date: Date) -> JourneyDuration? {
        guard option.verified, option.walkIssue == nil else { return nil }
        let estimates = ridingEstimates(option, at: date)
        let riding = estimates.map(\.seconds)
        if let trip = option.trip {
            let assessment = TripRanking.assessment(trip, estimates: latestSnapshot.estimates, at: date,
                preferences: preferences, walkingDurations: option.walks.map(\.duration), ridingDurations: riding,
                ridingSpreads: estimates.map(\.spreadSeconds))
            var duration = JourneyDuration(assessment: assessment, riding: riding)
            duration.cyclingSeconds = option.cyclingSeconds
            duration.ridingEvidence = estimates.contains { $0.evidence == .typical } ? .typical :
                estimates.contains { $0.evidence == .recentTraffic } ? .recentTraffic :
                estimates.contains { $0.evidence == .officialProfile } ? .officialProfile : estimates.contains { $0.evidence == .railProfile } ? .railProfile : .stationHistory
            return duration
        }
        var duration = JourneyDuration(riding: [], walking: option.walks.compactMap(\.duration), arrivals: [], at: date)
        duration.cyclingSeconds = option.cyclingSeconds
        return duration
    }
    private func recommendations(at date: Date) -> [JourneyOption] {
        let valid = verifiedPool.filter { $0.verified && $0.walkIssue == nil }
        let trips = valid.compactMap(\.trip)
        let walks = Dictionary(uniqueKeysWithValues: valid.map { ($0.id, $0.walks.map(\.duration)) })
        let rides = Dictionary(uniqueKeysWithValues: valid.filter { !$0.walkingOnly }.map { option in
            (option.id, ridingEstimates(option, at: date).map(\.seconds))
        })
        let ranked = TripRanking.recommended(trips, estimates: latestSnapshot.estimates, at: date,
            preferences: preferences, limit: 3, walkingDurations: walks, ridingDurations: rides)
        var result = ranked.compactMap { trip in valid.first { $0.id == trip.id } }
        // Riding the whole way has to clearly beat the bus it would replace, but only modestly
        // beat a walk: nobody is waiting for a walk. Either comparison can earn it a place, and
        // with no transit at all it is simply the way to get there.
        if let cycling = valid.first(where: \.bikeOnly), let riding = duration(cycling, at: date) {
            let transit = result.first.flatMap { duration($0, at: date)?.totalSeconds }
            let walking = valid.first(where: \.walkingOnly).flatMap { duration($0, at: date)?.totalSeconds }
            let beatsTransit = transit.map { riding.totalSeconds <= $0 - preferences.bikeMinimumGainSeconds } ?? true
            let beatsWalking = walking.map { riding.totalSeconds <= $0 - preferences.bikeWalkGainSeconds } ?? false
            if beatsTransit { result.insert(cycling, at: 0) }
            else if beatsWalking {
                // Eligibility is not a recommendation: keep genuinely faster transit first.
                let position = result.firstIndex { (duration($0, at: date)?.totalSeconds ?? .infinity) > riding.totalSeconds } ?? result.count
                result.insert(cycling, at: max(1, position))
            }
        }
        if let foot = valid.first(where: \.walkingOnly), let walking = duration(foot, at: date),
           result.first.flatMap({ duration($0, at: date)?.totalSeconds }).map({ walking.totalSeconds <= $0 + 60 }) ?? true {
            result.insert(foot, at: 0)
        }
        result = Array(result.prefix(3))
        return result
    }
    private func labels(for result: [JourneyOption], recommendedOption: JourneyOption?, at date: Date) -> [String: String] {
        let recommended = recommendedOption.flatMap { duration($0, at: date) }
        var labels: [String: String] = [:]
        for option in result {
            if option.id == recommendedOption?.id {
                labels[option.id] = option.bikeOnly ? "騎 YouBike" : option.walkingOnly ? "步行即可" : "推薦"
                continue
            }
            if option.bikeOnly { labels[option.id] = "騎 YouBike"; continue }
            if option.cycles { labels[option.id] = "YouBike 接駁"; continue }
            if let timing = duration(option, at: date), let recommended {
                if timing.totalSeconds < recommended.totalSeconds - 60 { labels[option.id] = "較快" }
                else if timing.walkingSeconds < recommended.walkingSeconds - 120 { labels[option.id] = "少走路" }
                else if option.rides.count == 1 { labels[option.id] = "直達" }
                else { labels[option.id] = option.rides.count < (recommendedOption?.rides.count ?? 0) ? "少轉乘" : "轉乘" }
            }
        }
        return labels
    }
    private func publishRecommendations() {
        let date = Date()
        let ranked = recommendations(at: date)
        // Previewing a result must not cancel discovery of later alternatives. Keep
        // the inspected route available even if it falls outside the new top three.
        var result = ranked
        if selectionConfirmed, let inspected = selected, !result.contains(where: { $0.id == inspected.id }) {
            result.append(inspected)
        }
        if selectionConfirmed {
            let order = Dictionary(uniqueKeysWithValues: options.enumerated().map { ($0.element.id, $0.offset) })
            result.sort { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
        }
        let previousSelection = selectedID
        options = result; optionLabels = labels(for: result, recommendedOption: ranked.first, at: date)
        comparisonChanged = selectionConfirmed && result.map(\.id) != ranked.map(\.id)
        if !selectionConfirmed { selectedID = result.first?.id }
        if previousSelection != selectedID { mapRevision += 1 }
    }
    func refreshRecommendations() {
        guard !started else { return }
        if !checkingWalks, !verifiedPool.isEmpty {
            selectionConfirmed = false; publishRecommendations()
        } else if let metadata = lastMetadata { plan(metadata: metadata) }
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
        if !started, !planning, !checkingWalks, !verifiedPool.isEmpty {
            let date = Date()
            let fresh = recommendations(at: date)
            comparisonChanged = fresh.map(\.id) != options.map(\.id)
            let updatedLabels = labels(for: options, recommendedOption: fresh.first, at: date)
            if updatedLabels != optionLabels { optionLabels = updatedLabels }
        }
    }
    func updateSettings(_ settings: LiveSettings) { preferences = settings.planning }
    private var bikeNetwork = BikeNetwork.empty
    private var bikeAvailability: BikeAvailability?
    private func entrance(_ stop: BusStop, toward point: Coordinate, metadata: TransitMetadata) -> Coordinate {
        metadata.metro.nearestExit(stationID: stop.stationID, to: point)?.coordinate ?? stop.coordinate
    }
    private var pickupTask: Task<Void, Never>?
    private var pickupGeneration = UUID()
    @Published var changingBikeStation = false
    @Published var bikeStationUpdateMessage: String?
    func updateBikes(network: BikeNetwork, availability: BikeAvailability?) {
        bikeNetwork = network; bikeAvailability = availability
    }
    /// A YouBike station this trip is counting on that can no longer be counted on, with the
    /// nearest station that can take its place. Checked only while that end is still ahead.
    enum BikeAlert: Equatable {
        case noBikes(BikeStation, replacement: BikeStation?)
        case noDocks(BikeStation, replacement: BikeStation?)
        var station: BikeStation {
            switch self { case .noBikes(let station, _), .noDocks(let station, _): return station }
        }
        var replacement: BikeStation? {
            switch self { case .noBikes(_, let station), .noDocks(_, let station): return station }
        }
        /// True when the rider still has to find a bike, false when they have to return one.
        var renting: Bool { if case .noBikes = self { return true }; return false }
    }
    var bikeAlert: BikeAlert? {
        guard let option = selected, let index = option.bikeLegIndex, let bike = option.walks[index].bike else { return nil }
        let legStep = steps.firstIndex(of: .walk(index))
        let passed = started && (legStep ?? .max) < stepIndex
        guard !passed else { return nil }
        let phase = started && legStep == stepIndex ? cyclingPhase(at: index) : .toPickup
        guard phase != .fromDropoff else { return nil }
        let date = Date()
        func replacement(_ station: BikeStation, renting: Bool) -> BikeStation? {
            BikeRouting.replacement(for: station, network: bikeNetwork, availability: bikeAvailability,
                                    renting: renting, preferences: preferences, at: date)
        }
        if phase == .toPickup, !BikeRouting.stillUsable(bike.pickup, availability: bikeAvailability, renting: true, preferences: preferences, at: date) {
            return .noBikes(bike.pickup, replacement: replacement(bike.pickup, renting: true))
        }
        if !BikeRouting.stillUsable(bike.dropoff, availability: bikeAvailability, renting: false, preferences: preferences, at: date) {
            return .noDocks(bike.dropoff, replacement: replacement(bike.dropoff, renting: false))
        }
        return nil
    }
    /// Moves one end of the cycling leg to another station and re-checks the streets for it,
    /// keeping the rest of the trip as it is.
    func moveBikeStation(to station: BikeStation, renting: Bool) {
        guard let option = selected, let index = option.bikeLegIndex, var bike = option.walks[index].bike,
              options.contains(where: { $0.id == option.id }) else { return }
        if renting { bike.pickup = station; bike.bikes = bikeAvailability?.dock(station.id)?.rentable ?? 0 }
        else { bike.dropoff = station; bike.docks = bikeAvailability?.dock(station.id)?.returnable ?? 0 }
        var leg = option.walks[index]
        // Keep the confirmed trip visible until the replacement has a complete route.
        leg.bike = bike
        let id = option.id, token = generation
        pickupTask?.cancel()
        let request = UUID(); pickupGeneration = request
        let step = stepIndex
        changingBikeStation = true; bikeStationUpdateMessage = nil
        pickupTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.pickupGeneration == request { self.changingBikeStation = false } }
            let updated = try? await self.cycle(leg)
            guard !Task.isCancelled, token == self.generation, request == self.pickupGeneration,
                  self.selectedID == id, self.stepIndex == step,
                  let slot = self.options.firstIndex(where: { $0.id == id }) else { return }
            guard let updated, updated.verified,
                  BikeRouting.stillUsable(station, availability: self.bikeAvailability, renting: renting,
                                         preferences: self.preferences) else {
                self.bikeStationUpdateMessage = "保留原行程，請稍後再試"
                return
            }
            self.options[slot].walks[index] = updated
            if let verified = self.verifiedPool.firstIndex(where: { $0.id == id }) {
                self.verifiedPool[verified].walks[index] = updated
            }
            self.endWalkingGuidance()
            self.walkingRevision += 1; self.walkingRouteRevision += 1; self.mapRevision += 1
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }
    /// The ride a saved trip would start with now, for the Home Screen widget. Walks are the
    /// planning estimates; nothing here touches the trip on screen.
    enum FirstLeg { case ride(TransitRide, walk: Double), walk }
    func firstRide(metadata: TransitMetadata, from: Coordinate, to: Coordinate,
                   preferences: LiveSettings.Planning) async -> FirstLeg? {
        let estimates = latestSnapshot.estimates, forecast = self.forecast
        let trips = await network.options(metadata: metadata, from: from, to: to, preferences: preferences, estimates: estimates)
        let date = Date()
        let riding = Dictionary(uniqueKeysWithValues: trips.map { trip in
            (trip.id, forecast.plannedRidingEstimates(trip, metadata: metadata, estimates: estimates,
                walkingDurations: [], preferences: preferences, at: date).map(\.seconds))
        })
        guard let best = TripRanking.recommended(trips, estimates: estimates, at: date, preferences: preferences,
                                                 limit: 1, ridingDurations: riding).first,
              let ride = best.rides.first else { return trips.isEmpty && from.distance(to: to) <= 1500 ? .walk : nil }
        return .ride(ride, walk: best.planningWalkSeconds.first ?? 0)
    }
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
        verifiedPool = []; optionLabels = [:]; alternativeTransitSeconds = nil; comparisonChanged = false
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
            let initialRiding = Dictionary(uniqueKeysWithValues: trips.map { trip in
                (trip.id, forecast.plannedRidingEstimates(trip, metadata: metadata, estimates: latestSnapshot.estimates,
                    walkingDurations: [], preferences: preferences, at: date).map(\.seconds))
            })
            let ordered = TripRanking.recommended(trips, estimates: latestSnapshot.estimates, at: date,
                preferences: preferences, limit: 36, ridingDurations: initialRiding, diverse: false)
            func option(_ trip: TransitTrip) -> JourneyOption {
                func entrance(_ stop: BusStop, toward point: Coordinate) -> Coordinate {
                    metadata.metro.nearestExit(stationID: stop.stationID, to: point)?.coordinate ?? stop.coordinate
                }
                let first = trip.rides[0], last = trip.rides.last!
                let firstExit = metadata.metro.nearestExit(stationID: first.boarding.stationID, to: origin.coordinate)
                var walks = [WalkingLeg(from: origin.coordinate, to: entrance(first.boarding, toward: origin.coordinate),
                    stationSeconds: first.boardingAccessSeconds, stationInstruction: firstExit.map { AppText.text("從 %@ 進站", AppLanguage.current == .english ? $0.englishName : $0.name) })]
                for index in trip.rides.indices.dropFirst() {
                    let a = trip.rides[index - 1].alighting, b = trip.rides[index].boarding
                    let transfer = metadata.metro.transfers.first { $0.from == a.stationID && $0.to == b.stationID }
                    let internalTransfer = a.mode != .bus && b.mode != .bus && (a.stationID == b.stationID || transfer?.external == false)
                    let officialSeconds = trip.transferSeconds.indices.contains(index - 1) ? trip.transferSeconds[index - 1] : 0
                    if internalTransfer {
                        walks.append(WalkingLeg(from: a.coordinate, to: b.coordinate, distance: 0, duration: officialSeconds,
                            instructions: [AppText.text("站內轉乘")], internalTransfer: true))
                    } else {
                        walks.append(WalkingLeg(from: entrance(a, toward: b.coordinate), to: entrance(b, toward: a.coordinate),
                            stationSeconds: trip.rides[index - 1].alightingAccessSeconds + trip.rides[index].boardingAccessSeconds,
                            stationInstruction: b.mode != .bus ? AppText.text("進站至月台") : nil,
                            minimumDuration: transfer?.seconds ?? 0))
                    }
                }
                let lastExit = metadata.metro.nearestExit(stationID: last.alighting.stationID, to: destination.coordinate)
                walks.append(WalkingLeg(from: entrance(last.alighting, toward: destination.coordinate), to: destination.coordinate,
                    stationSeconds: last.alightingAccessSeconds, stationInstruction: lastExit.map { AppText.text("從 %@ 出站", AppLanguage.current == .english ? $0.englishName : $0.name) }))
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
            // YouBike alternatives. Nothing is proposed without current counts at both ends: a
            // station with no bikes, or with nowhere to return one, is not a plan. Each one is
            // an alternative to the same rides, so only the better of the two is ever offered.
            if preferences.bikeRouting, bikeAvailability != nil, !bikeNetwork.stations.isEmpty {
                var cycling: [JourneyOption] = []
                for trip in selected.prefix(6) {
                    guard let first = trip.rides.first, let last = trip.rides.last else { continue }
                    let boarding = entrance(first.boarding, toward: origin.coordinate, metadata: metadata)
                    let toBoarding = origin.coordinate.distance(to: boarding)
                    if toBoarding >= 350,
                       let connection = BikeRouting.connection(from: origin.coordinate, to: boarding, network: bikeNetwork,
                           availability: bikeAvailability, preferences: preferences, at: date),
                       BikeRouting.worthRiding(connection, insteadOfWalking: toBoarding, preferences: preferences) {
                        var choice = option(trip.asVariant("youbike-access"))
                        choice.walks[0].bike = BikeLeg(connection)
                        cycling.append(choice)
                    }
                    let alighting = entrance(last.alighting, toward: destination.coordinate, metadata: metadata)
                    let fromAlighting = alighting.distance(to: destination.coordinate)
                    if fromAlighting >= 350,
                       let connection = BikeRouting.connection(from: alighting, to: destination.coordinate, network: bikeNetwork,
                           availability: bikeAvailability, preferences: preferences, at: date),
                       BikeRouting.worthRiding(connection, insteadOfWalking: fromAlighting, preferences: preferences) {
                        var choice = option(trip.asVariant("youbike-finish"))
                        choice.walks[choice.walks.count - 1].bike = BikeLeg(connection)
                        cycling.append(choice)
                    }
                    if cycling.count >= 3 { break }
                }
                // A station a short ride away can open a far better trip than anything within
                // walking distance. That costs a second search, so it runs only for longer
                // trips where what the walk-based search found is not already quick.
                let bestElapsed = ordered.first.map {
                    TripRanking.assessment($0, estimates: latestSnapshot.estimates, at: date, preferences: preferences).elapsedSeconds
                }
                if bestElapsed ?? .infinity > 1_500,
                   let gateway = BikeRouting.gateway(from: origin.coordinate, to: destination.coordinate,
                       network: bikeNetwork, availability: bikeAvailability, preferences: preferences, at: date) {
                    let remote = await network.options(metadata: metadata, from: gateway.coordinate, to: destination.coordinate,
                                                       preferences: preferences, estimates: latestSnapshot.estimates)
                    guard !Task.isCancelled, token == generation else { return }
                    for trip in TripRanking.recommended(remote, estimates: latestSnapshot.estimates, at: date,
                                                        preferences: preferences, limit: 2) {
                        guard let first = trip.rides.first else { continue }
                        let boarding = entrance(first.boarding, toward: gateway.coordinate, metadata: metadata)
                        guard origin.coordinate.distance(to: boarding) >= 1_000,
                              let connection = BikeRouting.connection(from: origin.coordinate, to: boarding, network: bikeNetwork,
                                  availability: bikeAvailability, preferences: preferences, at: date) else { continue }
                        var choice = option(trip.asVariant("youbike-start"))
                        choice.walks[0].bike = BikeLeg(connection)
                        cycling.append(choice)
                        break
                    }
                }
                pending.append(contentsOf: cycling)
                if let whole = BikeRouting.connection(from: origin.coordinate, to: destination.coordinate,
                        network: bikeNetwork, availability: bikeAvailability, preferences: preferences, at: date) {
                    var leg = WalkingLeg(from: origin.coordinate, to: destination.coordinate)
                    leg.bike = BikeLeg(whole)
                    pending.insert(JourneyOption(id: "youbike", trip: nil, walks: [leg]), at: 0)
                }
            }
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
        guard selectedID != option.id else { return }
        endWalkingGuidance()
        selectedID = option.id; started = false; stepIndex = 0; mapRevision += 1
    }
    private func enrich(_ option: JourneyOption) async throws -> JourneyOption {
        var result = option
        for index in option.walks.indices {
            try Task.checkCancellation()
            if option.walks[index].internalTransfer { continue }
            if option.walks[index].bike != nil {
                result.walks[index] = try await cycle(option.walks[index])
                continue
            }
            result.walks[index] = try await walk(option.walks[index])
            result.walks[index].streetDuration = result.walks[index].duration
            result.walks[index].stationSeconds = option.walks[index].stationSeconds
            result.walks[index].stationInstruction = option.walks[index].stationInstruction
            if let seconds = result.walks[index].duration { result.walks[index].duration = max(option.walks[index].minimumDuration, seconds + option.walks[index].stationSeconds) }
        }
        let hasLongWalk = result.walks.enumerated().contains { index, leg in
            // On a cycling leg only the two walks count; the ride itself is meant to be long.
            if let bike = leg.bike { return max(bike.toPickupMeters, bike.fromDropoffMeters) > 900 }
            let transfer = index > 0 && index < result.walks.count - 1
            return (leg.distance ?? 0) > (transfer ? 600 : 1_800)
        }
        if hasLongWalk { result.walkIssue = result.cycles ? "接駁步行過長" : "步行接駁過長" }
        if !result.verified { result.walkIssue = result.cycles ? "YouBike 路線待確認" : "步行接駁待確認" }
        return result
    }
    /// Verifies a cycling leg: the walk to the station, the streets the bike will take, and the
    /// walk on from where it is returned. Never substitute pedestrian directions for cycling.
    private func cycle(_ leg: WalkingLeg) async throws -> WalkingLeg {
#if DEBUG
        if let testCycle { return try await testCycle(leg) }
#endif
        guard var bike = leg.bike else { return leg }
        var result = leg
        let access = try await walk(WalkingLeg(from: leg.from, to: bike.pickup.coordinate))
        let street = try await walk(WalkingLeg(from: bike.pickup.coordinate, to: bike.dropoff.coordinate), transport: .cycling)
        let egress = try await walk(WalkingLeg(from: bike.dropoff.coordinate, to: leg.to))
        guard let accessSeconds = access.duration, let egressSeconds = egress.duration,
              let rideMeters = street.distance, let rideSeconds = street.duration, rideMeters > 0, rideSeconds > 0 else {
            result.duration = nil; return result
        }
        bike.toPickup = access.coordinates
        bike.toPickupMeters = access.distance ?? leg.from.distance(to: bike.pickup.coordinate)
        bike.toPickupSeconds = accessSeconds
        bike.ride = street.coordinates
        bike.rideMeters = rideMeters
        bike.rideSeconds = rideSeconds
        bike.fromDropoff = egress.coordinates
        bike.fromDropoffMeters = egress.distance ?? bike.dropoff.coordinate.distance(to: leg.to)
        bike.fromDropoffSeconds = egressSeconds
        result.bike = bike
        result.coordinates = bike.coordinates
        result.road = RouteLine(coordinates: result.coordinates)
        result.distance = bike.totalMeters
        result.streetDuration = bike.totalSeconds
        result.duration = bike.totalSeconds + leg.stationSeconds
        result.instructions = access.instructions + street.instructions + egress.instructions
        return result
    }
    private func walk(_ leg: WalkingLeg, guidance: Bool = false, transport: MKDirectionsTransportType = .walking) async throws -> WalkingLeg {
        let cacheKey = "\(transport.rawValue):\(leg.from.latitude):\(leg.from.longitude):\(leg.to.latitude):\(leg.to.longitude):\(AppLanguage.current.rawValue)"
        if let cached = walkingCache[cacheKey] { return cached }
        var result = leg
        if leg.from.distance(to: leg.to) < 1 {
            result.distance = 0; result.duration = 0; result.coordinates = [leg.from, leg.to]; result.road = RouteLine(coordinates: result.coordinates); return result
        }
        let request = MKDirections.Request()
        request.source = TravelPlace(name: "起點", address: "", coordinate: leg.from).mapItem
        request.destination = TravelPlace(name: "終點", address: "", coordinate: leg.to).mapItem
        request.transportType = transport
        request.requestsAlternateRoutes = true
        let operation = MKDirections(request: request); directions.append(operation)
        if guidance { walkingRequest = operation }
        defer { directions.removeAll { $0 === operation }; if walkingRequest === operation { walkingRequest = nil } }
        do {
            let response = try await operation.calculate()
            try Task.checkCancellation()
            // MapKit currently labels cycling responses/steps as automobile even when their
            // geometry, notices and ETA are bicycle-specific (verified against driving and
            // walking queries on the same station pair). The single-mode request is the source
            // of truth; never change a cycling request into a walking or driving fallback.
            if let path = response.routes.filter({ route in transport == .cycling || route.transportType == transport })
                .compactMap({ PedestrianPath.leg($0, from: leg.from, to: leg.to) })
                .min(by: { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }) { result = path }
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
        cancelRequests()
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
        started = true; stepIndex = target; mapRevision += 1
    }
    func finish() {
        cancelRequests(); started = false; destination = nil; options = []; selectedID = nil; message = nil; stepIndex = 0; mapRevision += 1
        verifiedPool = []; comparisonChanged = false; optionLabels = [:]
    }
    func openAppleTransit() {
        guard let destination else { return }
        let source = origin?.mapItem ?? MKMapItem.forCurrentLocation()
        MKMapItem.openMaps(with: [source, destination.mapItem], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
    }
    func unavailableBoarding(_ option: JourneyOption) -> (route: String, status: Int)? {
        for ride in option.rides {
            if let eta = latestSnapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: Date()),
               [-2, -3, -4].contains(eta) { return (ride.route.localizedName, eta) }
        }
        return nil
    }
    private func cancelRequests() {
        endWalkingGuidance()
        pickupTask?.cancel(); pickupTask = nil; pickupGeneration = UUID()
        changingBikeStation = false; bikeStationUpdateMessage = nil
        task?.cancel(); task = nil; alternativeTask?.cancel(); alternativeTask = nil; directions.forEach { $0.cancel() }; directions = []
        generation = UUID(); planning = false; checkingWalks = false
    }

#if DEBUG
    var testCycle: ((WalkingLeg) async throws -> WalkingLeg)?
    func verifyCyclingLegForTest(_ leg: WalkingLeg) async throws -> WalkingLeg { try await cycle(leg) }
    /// Controlled inputs; tests still exercise production ranking and navigation methods.
    func auditLoadChoices(_ choices: [JourneyOption], from start: TravelPlace, to end: TravelPlace) {
        cancelRequests(); origin = start; destination = end; usingLocation = false
        started = false; stepIndex = 0; selectionConfirmed = false
        verifiedPool = choices; options = choices
        publishRecommendations()
    }
    func auditVerifyAdditionalChoices(_ choices: [JourneyOption], delay: Double = 0.15) {
        checkingWalks = true
        let token = generation
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.verifiedPool.append(contentsOf: choices)
            self.checkingWalks = false
            self.publishRecommendations()
        }
    }

    /// Deterministic UI scenarios use actual planner routes and explicitly simulated walking.
    func prepareRouteChoicesPreview(_ trips: [TransitTrip], from start: TravelPlace, to end: TravelPlace) {
        cancelRequests(); origin = start; destination = end; usingLocation = false
        started = false; stepIndex = 0; selectionConfirmed = true
        options = trips.map { trip in
            var walks: [WalkingLeg] = []
            for index in 0...trip.rides.count {
                let from = index == 0 ? start.coordinate : trip.rides[index - 1].alighting.coordinate
                let to = index == trip.rides.count ? end.coordinate : trip.rides[index].boarding.coordinate
                let distance = trip.walkingDistances[index], duration = trip.planningWalkSeconds[index]
                var leg = WalkingLeg(from:from,to:to,coordinates:[from,to],distance:distance,duration:duration)
                leg.road = RouteLine(coordinates:leg.coordinates); walks.append(leg)
            }
            return JourneyOption(id:trip.id,trip:trip,walks:walks)
        }
        selectedID = options.first?.id; optionLabels = [:]; message = nil; mapRevision += 1
    }

    /// Deterministic cycling scenario: real stations and a real trip, with simulated street
    /// geometry, so the cycling interface can be checked without Apple's routing. Availability
    /// must already be injected with `updateBikes`.
    func prepareCyclingPreview(trip: TransitTrip?, from start: TravelPlace, to end: TravelPlace) {
        cancelRequests(); origin = start; destination = end; usingLocation = false
        started = false; stepIndex = 0; selectionConfirmed = true
        func cycling(_ connection: BikeConnection, from: Coordinate, to: Coordinate) -> WalkingLeg {
            var bike = BikeLeg(connection)
            bike.toPickup = [from, connection.pickup.coordinate]
            bike.ride = [connection.pickup.coordinate, connection.dropoff.coordinate]
            bike.fromDropoff = [connection.dropoff.coordinate, to]
            var leg = WalkingLeg(from: from, to: to, coordinates: bike.coordinates,
                                 distance: bike.totalMeters, duration: bike.totalSeconds)
            leg.road = RouteLine(coordinates: leg.coordinates)
            leg.streetDuration = bike.totalSeconds
            leg.bike = bike
            return leg
        }
        func walking(_ from: Coordinate, _ to: Coordinate) -> WalkingLeg {
            let meters = from.distance(to: to)
            var leg = WalkingLeg(from: from, to: to, coordinates: [from, to], distance: meters,
                                 duration: BikeRouting.walkingSeconds(meters))
            leg.road = RouteLine(coordinates: leg.coordinates)
            leg.streetDuration = leg.duration
            return leg
        }
        var result: [JourneyOption] = []
        if let whole = BikeRouting.connection(from: start.coordinate, to: end.coordinate, network: bikeNetwork,
                                              availability: bikeAvailability, preferences: preferences) {
            result.append(JourneyOption(id: "youbike", trip: nil,
                walks: [cycling(whole, from: start.coordinate, to: end.coordinate)]))
        }
        if let trip, let first = trip.rides.first, let last = trip.rides.last,
           let access = BikeRouting.connection(from: start.coordinate, to: first.boarding.coordinate,
                                               network: bikeNetwork, availability: bikeAvailability, preferences: preferences) {
            let variant = trip.asVariant("youbike-access")
            var walks = [cycling(access, from: start.coordinate, to: first.boarding.coordinate)]
            for index in trip.rides.indices.dropFirst() {
                walks.append(walking(trip.rides[index - 1].alighting.coordinate, trip.rides[index].boarding.coordinate))
            }
            walks.append(walking(last.alighting.coordinate, end.coordinate))
            result.append(JourneyOption(id: variant.id, trip: variant, walks: walks))
        }
        guard !result.isEmpty else { return }
        options = result; verifiedPool = result
        selectedID = result.first?.id
        optionLabels = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.bikeOnly ? "騎 YouBike" : "YouBike 接駁") })
        message = nil; mapRevision += 1
    }

    func prepareWalkingPreview() async {
        cancelRequests(); usingLocation = true
        let start = Coordinate.taipei, end = Coordinate(latitude: 25.0410, longitude: 121.5663)
        origin = TravelPlace(name: "目前位置", address: "", coordinate: start)
        destination = TravelPlace(name: "市政府附近", address: "", coordinate: end, englishName: "Near City Hall")
        do {
            let leg = try await walk(WalkingLeg(from: start, to: end))
            guard leg.verified else { return }
            let option = JourneyOption(id: "walking-interface-check", trip: nil, walks: [leg])
            options = [option]; selectedID = option.id; started = true; stepIndex = 0; mapRevision += 1
        } catch { return }
    }

    func prepareBoardingPreview(_ trip: TransitTrip, started: Bool = true) {
        cancelRequests()
        guard let first = trip.rides.first, let last = trip.rides.last else { return }
        origin = TravelPlace(name: first.boarding.name, address: "", coordinate: first.boarding.coordinate, englishName: first.boarding.englishName)
        destination = TravelPlace(name: last.alighting.name, address: "", coordinate: last.alighting.coordinate, englishName: last.alighting.englishName)
        usingLocation = false; self.started = started; stepIndex = 0
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
