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
    var ridingMinutes: Int { max(1, Int(ceil(rideSeconds / 60))) }
    var totalSeconds: Double { walkingSeconds + cyclingSeconds }
    var totalMeters: Double { walkingMeters + rideMeters }
    var connection: BikeConnection {
        BikeConnection(pickup: pickup, dropoff: dropoff, bikes: bikes, docks: docks,
            accessMeters: toPickupMeters, rideMeters: rideMeters, egressMeters: fromDropoffMeters,
            accessSeconds: toPickupSeconds, rideSeconds: rideSeconds, egressSeconds: fromDropoffSeconds, handlingSeconds: handlingSeconds)
    }
    var coordinates: [Coordinate] { toPickup + ride + fromDropoff }
    func remaining(meters: Double) -> (total: Double, cycling: Double, handling: Double) {
        guard meters.isFinite else { return (totalSeconds, cyclingSeconds, handlingSeconds) }
        let distance = min(totalMeters, max(0, meters))
        if distance > rideMeters + fromDropoffMeters {
            let foot = toPickupSeconds * min(1, (distance - rideMeters - fromDropoffMeters) / max(1, toPickupMeters))
            return (foot + cyclingSeconds + fromDropoffSeconds, cyclingSeconds, handlingSeconds)
        }
        if distance > fromDropoffMeters {
            let ridden = rideSeconds * min(1, (distance - fromDropoffMeters) / max(1, rideMeters))
            let docking = handlingSeconds / 2
            return (ridden + docking + fromDropoffSeconds, ridden + docking, docking)
        }
        return (fromDropoffSeconds * min(1, distance / max(1, fromDropoffMeters)), 0, 0)
    }
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
    var plannedStartAfter: Double = 0
    var temporaryStreetFailure = false
    var verified: Bool { duration != nil }
    var cyclingSeconds: Double { bike?.cyclingSeconds ?? 0 }
    /// Only the parts of this leg that are walked; a cycling leg keeps its ridden path apart.
    var footPaths: [[Coordinate]] {
        if let bike { return [bike.toPickup, bike.fromDropoff].filter { $0.count >= 2 } }
        return coordinates.count >= 2 ? [coordinates] : []
    }
    var timeLabel: String {
        if let bike, verified { return AppText.text("騎車 %@ 分", bike.ridingMinutes) }
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
                 estimates: EstimateFeed, bikeNetwork: BikeNetwork = .empty, bikeAvailability: BikeAvailability? = nil) -> [TransitTrip] {
        let signature = metadata.revision.uuidString
        if planner == nil || key != signature || Date().timeIntervalSince(builtAt) > 86_400 {
            planner = MultimodalPlanner(metadata: metadata); key = signature; builtAt = Date()
        }
        let budget = JourneySearchBudget(distance: from.distance(to: to), cycling: preferences.bikeRouting && bikeAvailability != nil)
        return planner!.plan(from: from, to: to, maximumWalk: preferences.expandedWalkMeters, limit: budget.candidates,
                             preferences: preferences, estimates: estimates, bikeNetwork: bikeNetwork, bikeAvailability: bikeAvailability)

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
    private var walkingCache: [String: (leg: WalkingLeg, date: Date)] = [:]
    // Briefly share unavailable endpoints across combinations, while allowing a
    // transient failure to recover. A new explicit search always tries them again.
    private var unavailableStreets: [String: (leg: WalkingLeg, date: Date)] = [:]
    private var walkingRequests: [String: (id: UUID, task: Task<WalkingLeg, Error>)] = [:]
    private var hadTemporaryStreetFailure = false
    @Published private(set) var optionLabels: [String: String] = [:]
    @Published private(set) var comparisonChanged = false
    @Published private(set) var alternativeTransitSeconds: Double?
    private var alternativeTransitUpdatedAt = Date.distantPast
    var freshAlternativeTransitSeconds: Double? {
        Date().timeIntervalSince(alternativeTransitUpdatedAt) <= 120 ? alternativeTransitSeconds : nil
    }
    private var alternativeTask: Task<Void, Never>?
    private var evaluatingRemainingJourney = false
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
        if let option = selected, option.walks.indices.contains(index), let bike = option.walks[index].bike {
            if bike.phase(remainingMeters: progress.remainingDistance) == .riding {
                let meters = max(0, progress.remainingDistance - bike.fromDropoffMeters)
                let seconds = bike.rideSeconds * min(1, meters / max(1, bike.rideMeters))
                return AppText.text("騎乘剩餘 %@ · %@ 分", distanceLabel(meters), max(1, Int(ceil(seconds / 60))))
            }
            let remaining = bike.remaining(meters: progress.remainingDistance)
            let meters = bike.phase(remainingMeters: progress.remainingDistance) == .toPickup
                ? max(0, progress.remainingDistance - bike.rideMeters - bike.fromDropoffMeters) : progress.remainingDistance
            let seconds = bike.phase(remainingMeters: progress.remainingDistance) == .toPickup
                ? max(0, remaining.total - remaining.cycling - bike.fromDropoffSeconds) : remaining.total
            return AppText.text("步行剩餘 %@ · %@ 分", distanceLabel(meters), max(1, Int(ceil(seconds / 60))))
        }
        return AppText.text("步行剩餘 %@ · %@ 分", distanceLabel(progress.remainingDistance), max(1, Int(ceil(progress.remainingSeconds / 60))))
    }


    init() {
        if let data = UserDefaults.standard.data(forKey: "journeyRecentPlaces"),
           let places = try? JSONDecoder().decode([TravelPlace].self, from: data) { recentPlaces = places }
    }
    var selected: JourneyOption? { options.first { $0.id == selectedID } }
    /// Keep the compact carousel readable while the full list retains other useful tradeoffs.
    var featuredOptions: [JourneyOption] {
        var result = Array(options.prefix(5))
        if let selected, !result.contains(where: { $0.id == selected.id }) {
            if result.count == 5 { result.removeLast() }
            result.append(selected)
        }
        return result
    }
    /// Every station an offered trip would rent a bike from.
    var plannedPickupStations: [BikeStation] {
        var seen = Set<String>()
        return options.flatMap { $0.walks.compactMap { $0.bike?.pickup } }.filter { seen.insert($0.id).inserted }
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
        if let trip = contextualTrip(option, at: date), let metadata = lastMetadata {
            return forecast.plannedRidingEstimates(trip, metadata: metadata, estimates: latestSnapshot.estimates,
                walkingDurations: option.walks.map(\.duration), preferences: preferences, at: date)
        }
        return option.rides.enumerated().map { index, _ in
            RidingTimeEstimate(seconds: option.trip?.rideSeconds[index] ?? 0, evidence: .typical, observedVehicles: 0)
        }
    }
    private func contextualTrip(_ option: JourneyOption, at date: Date, riding: [Double]? = nil) -> TransitTrip? {
        guard let trip = option.trip else { return nil }
        guard option.walks.count == trip.rides.count + 1 else { return trip }
        return trip.replacingRides(contextualRides(trip.rides,
            walking: option.walks.enumerated().map { $0.element.duration ?? trip.planningWalkSeconds[$0.offset] },
            riding: riding ?? trip.rideSeconds, transferDistances: trip.transferDistances, at: date))
    }
    func contextualRides(_ source: [TransitRide], walking: [Double], riding: [Double],
                         transferDistances: [Double], at date: Date, onboardFirst: Bool = false) -> [TransitRide] {
        guard let metadata = lastMetadata, walking.count == source.count + 1, riding.count == source.count else { return source }
        var rides = source, cursor = 0.0
        for index in rides.indices {
            if onboardFirst && index == 0 { cursor += riding[index]; continue }
            cursor += walking[index]
            if rides[index].route.mode != .bus {
                rides[index].railService = metadata.metro.combinedService(routeID: rides[index].route.id, direction: rides[index].direction,
                    from: rides[index].boarding.stationID, to: rides[index].alighting.stationID, at: date.addingTimeInterval(cursor))
            }
            var arrivals = rides.map { latestSnapshot.estimates.value(routeID: $0.route.parentID, stopID: $0.boarding.id, at: date) }
            if onboardFirst { arrivals[0] = 0 }
            let timing = TripRanking.assess(riding: riding, walking: walking, arrivals: arrivals, preferences: preferences,
                minimumServiceWaits: rides.map { $0.route.minimumServiceWait(direction: $0.direction, at: date, fullRouteSeconds: $0.fullRouteSeconds) },
                services: rides.map { $0.railService ?? $0.route.servicePlans[$0.direction]?.service(at: date) },
                boardingOffsets: rides.map(\.boardingOffsetSeconds), at: date,
                boardingBuffers: ConnectionTiming.buffers(rides: rides, walking: walking, transferDistances: transferDistances))
            cursor += timing.waits[index].seconds + riding[index]
        }
        return rides
    }
    func duration(_ option: JourneyOption, at date: Date) -> JourneyDuration? {
        guard option.verified, option.walkIssue == nil else { return nil }
        let estimates = ridingEstimates(option, at: date)
        let riding = estimates.map(\.seconds)
        if let trip = contextualTrip(option, at: date, riding: riding) {
            let assessment = TripRanking.assessment(trip, estimates: latestSnapshot.estimates, at: date,
                preferences: preferences, walkingDurations: option.walks.map(\.duration), ridingDurations: riding,
                ridingSpreads: estimates.map(\.spreadSeconds))
            var duration = JourneyDuration(assessment: assessment, riding: riding)
            duration.cyclingSeconds = option.cyclingSeconds
            duration.cyclingHandlingSeconds = option.walks.compactMap(\.bike).reduce(0) { $0 + $1.handlingSeconds }
            duration.ridingEvidence = estimates.contains { $0.evidence == .typical } ? .typical :
                estimates.contains { $0.evidence == .recentTraffic } ? .recentTraffic :
                estimates.contains { $0.evidence == .officialProfile } ? .officialProfile : estimates.contains { $0.evidence == .railProfile } ? .railProfile : .stationHistory
            return duration
        }
        var duration = JourneyDuration(riding: [], walking: option.walks.compactMap(\.duration), arrivals: [], at: date)
        duration.cyclingSeconds = option.cyclingSeconds
        duration.cyclingHandlingSeconds = option.walks.compactMap(\.bike).reduce(0) { $0 + $1.handlingSeconds }
        return duration
    }
    private func connectionStarts(_ option: JourneyOption, at date: Date) -> [Double] {
        guard let trip = option.trip else { return [0] }
        guard option.walks.count == trip.rides.count + 1 else { return Array(repeating: 0, count: option.walks.count) }
        let rides = ridingEstimates(option, at: date).map(\.seconds)
        let assessment = TripRanking.assessment(trip, estimates: latestSnapshot.estimates, at: date,
            preferences: preferences, walkingDurations: option.walks.map(\.duration), ridingDurations: rides)
        var cursor = 0.0, starts: [Double] = []
        for index in option.walks.indices {
            starts.append(cursor)
            cursor += option.walks[index].duration ?? trip.planningWalkSeconds[index]
            if rides.indices.contains(index) { cursor += assessment.waits[index].seconds + rides[index] }
        }
        return starts
    }
    private func supplyRisk(_ option: JourneyOption, at date: Date) -> Double {
        guard option.cycles else { return 0 }
        let starts = connectionStarts(option, at: date)
        return option.walks.enumerated().reduce(0) { result, item in
            guard let bike = item.element.bike else { return result }
            return result + BikeRouting.supplyPenalty(bike.connection, availability: bikeAvailability,
                pickupAfter: starts.indices.contains(item.offset) ? starts[item.offset] : 0, at: date)
        }
    }
    func canUse(_ option: JourneyOption) -> Bool {
        guard option.verified, option.walkIssue == nil, unavailableBoarding(option) == nil else { return false }
        return option.walks.compactMap(\.bike).allSatisfy {
            BikeRouting.confirmed($0.pickup, availability: bikeAvailability, renting: true, minimum: 1) &&
            BikeRouting.confirmed($0.dropoff, availability: bikeAvailability, renting: false, minimum: 1)
        }
    }
    func canContinueSelected() -> Bool {
        guard let option = selected, started, let step = currentStep else { return false }
        let first: Int
        switch step { case .walk(let i): first = i; case .ride(let i): first = i + 1 }
        for ride in option.rides.dropFirst(first) {
            if let status = latestSnapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: Date()),
               [-2, -3, -4].contains(status) { return false }
        }
        for (index, leg) in option.walks.enumerated() where index >= first {
            guard let bike = leg.bike else { continue }
            let phase = index == first ? cyclingPhase(at: index) : .toPickup
            if phase == .fromDropoff { continue }
            if phase != .riding && !BikeRouting.confirmed(bike.pickup, availability: bikeAvailability, renting: true, minimum: 1) { return false }
            if !BikeRouting.confirmed(bike.dropoff, availability: bikeAvailability, renting: false, minimum: 1) { return false }
        }
        return true
    }
    func preferenceScore(_ option: JourneyOption, at date: Date) -> Double {
        guard let timing = duration(option, at: date) else { return .infinity }
        return JourneyPreferenceCost.score(elapsed: timing.totalSeconds,
            walking: max(0, timing.walkingSeconds - option.cyclingSeconds), waiting: timing.waitingSeconds,
            transfers: max(0, option.rides.count - 1), rentals: option.walks.filter { $0.bike != nil }.count,
            unknownWaits: timing.unknownWaits, supplyRisk: supplyRisk(option, at: date), preferences: preferences)
    }
    private func recommendations(at date: Date) -> [JourneyOption] {
        let valid = verifiedPool.filter { $0.verified && $0.walkIssue == nil && unavailableBoarding($0) == nil }
        var metrics: [JourneyChoice] = []
        for option in valid {
            guard let timing = duration(option, at: date) else { continue }
            let legs = option.walks.indices.filter { option.walks[$0].bike != nil }.map(String.init).joined(separator: "-")
            let group = (option.trip?.familyID ?? (option.cycles ? "cycling" : "walking")) + "|bikes:" + legs
            metrics.append(JourneyChoice(id: option.id, group: group, elapsed: timing.totalSeconds,
                walking: max(0, timing.walkingSeconds - option.cyclingSeconds), waiting: timing.waitingSeconds,
                transfers: max(0, option.rides.count - 1), rentals: option.walks.filter { $0.bike != nil }.count,
                unknownWaits: timing.unknownWaits, supplyRisk: supplyRisk(option, at: date), preferences: preferences))
        }
        let byID = Dictionary(uniqueKeysWithValues: valid.map { ($0.id, $0) })
        return JourneyChoiceRanking.recommended(metrics).compactMap { byID[$0] }
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
            if recommendedOption?.cycles == true { labels[option.id] = "免騎車"; continue }
            if let timing = duration(option, at: date), let recommended {
                if timing.totalSeconds < recommended.totalSeconds - 60 { labels[option.id] = "較快" }
                else if timing.walkingSeconds - timing.cyclingSeconds < recommended.walkingSeconds - recommended.cyclingSeconds - 120 { labels[option.id] = "少走路" }
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
        let previousSelection = selectedID
        options = result; optionLabels = labels(for: result, recommendedOption: ranked.first, at: date)
        // The recommendation is always first. Keep the inspected page selected by ID,
        // rather than freezing the entire list in its old arrival order.
        comparisonChanged = selectionConfirmed && selectedID != ranked.first?.id
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
            if let response = try? await DirectionsRequestGate.shared.calculateETA(operation, priority: .alternatives), !Task.isCancelled, token == generation,
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
        // Refresh the order without changing an inspected route or its map camera.
        if !started, !planning, !checkingWalks, !verifiedPool.isEmpty {
            let date = Date()
            let fresh = recommendations(at: date)
            var orderedIDs = fresh.map(\.id)
            if selectionConfirmed, let selectedID, !orderedIDs.contains(selectedID) { orderedIDs.append(selectedID) }
            let updatedLabels = labels(for: options, recommendedOption: fresh.first, at: date)
            if orderedIDs != options.map(\.id) || updatedLabels != optionLabels { publishRecommendations() }
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
        if !started, !verifiedPool.isEmpty { publishRecommendations() }
        discoverBikeConnections()
    }
    private var bikeRefinementTask: Task<Void, Never>?
    private var attemptedBikeConnections = Set<String>()
    private var connectionBases: [String: JourneyOption] = [:]
    private var integratedSearchHasSupply = false
    private var lastIntegratedBikeSearch = Date.distantPast
    private var lastIntegratedSupplyAt = Date.distantPast
    private var stationRefinements: [String: Date] = [:]
    private func bikeChoiceKey(_ option: JourneyOption) -> String {
        option.id + "|" + option.walks.enumerated().compactMap { index, leg in
            leg.bike.map { "\(index):\($0.pickup.id):\($0.dropoff.id)" }
        }.joined(separator: "|")
    }
    /// Offer the first checked connection promptly, then verify several station pairs for
    /// the leading choices. Every alternative is ranked as a whole journey, including
    /// which departure its changed access/transfer can actually catch.
    private func refineLeadingStations(token: UUID) async {
        let leading = recommendations(at: Date()).filter(\.cycles).prefix(2)
        for original in leading {
            guard !Task.isCancelled, token == generation, !started else { return }
            let key = bikeChoiceKey(original)
            if let date = stationRefinements[key], Date().timeIntervalSince(date) < 180 { continue }
            stationRefinements[key] = Date()
            var variants = [original]
            for index in original.walks.indices where original.walks[index].bike != nil {
                let leg = original.walks[index]
                let pairs = BikeRouting.connections(from: leg.from, to: leg.to, network: bikeNetwork,
                    availability: bikeAvailability, preferences: preferences, limit: 3)
                var checked: [WalkingLeg] = [leg]
                for pair in pairs where BikeRouting.pairID(pair) != leg.bike.map({ BikeRouting.pairID($0.connection) }) {
                    guard !Task.isCancelled, token == generation, !started else { return }
                    if let result = try? await verifyPair(leg, connection: pair), result.verified { checked.append(result) }
                }
                var expanded: [JourneyOption] = []
                for variant in variants { for checkedLeg in checked {
                    var walks = variant.walks; walks[index] = checkedLeg
                    let connections = Dictionary(uniqueKeysWithValues: walks.enumerated().compactMap { index, leg in
                        leg.bike.map { (index, $0.connection) }
                    })
                    let trip = variant.trip?.withBikeConnections(connections)
                    let id = trip?.id ?? "youbike:" + connections.keys.sorted().map { BikeRouting.pairID(connections[$0]!) }.joined(separator: "|")
                    expanded.append(JourneyOption(id: id, trip: trip, walks: walks))
                } }
                let unique = Dictionary(expanded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                guard !Task.isCancelled, token == generation, !started else { return }
                for option in unique.values where supplyRisk(option, at: Date()).isFinite {
                    verifiedPool.removeAll { $0.id == option.id }; verifiedPool.append(option)
                }
                publishRecommendations()
                let offered = Set(recommendations(at: Date()).map(\.id))
                variants = Array(unique.values.filter { offered.contains($0.id) }.prefix(3))
                if variants.isEmpty { variants = [original] }
            }
        }
    }
    /// Pull freshly possible bike choices between verification batches. A feed arriving
    /// mid-search must not wait for every ordinary boarding platform to finish first.
    private func takeBikeConnections(limit: Int) -> [JourneyOption] {
        guard preferences.bikeRouting, attemptedBikeConnections.count < limit else { return [] }
        var choices = integratedSearchHasSupply ? [] : bikeConnections(for: Array(connectionBases.values), at: Date())
        if let origin, let destination,
           let whole = BikeRouting.connection(from: origin.coordinate, to: destination.coordinate,
               network: bikeNetwork, availability: bikeAvailability, preferences: preferences) {
            var leg = WalkingLeg(from: origin.coordinate, to: destination.coordinate); leg.bike = BikeLeg(whole)
            let choice = JourneyOption(id: "youbike", trip: nil, walks: [leg])
            if !attemptedBikeConnections.contains(bikeChoiceKey(choice)) { choices.append(choice) }
        }
        let reserved = Array(choices.prefix(limit - attemptedBikeConnections.count))
        attemptedBikeConnections.formUnion(reserved.map(bikeChoiceKey))
        return reserved
    }
    /// One ordinary route and one cycling alternative share each batch. Later walking
    /// platforms cannot monopolize the queue; at most two routes are verified at once.
    private func verifyConnections(_ ordinary: [JourneyOption], cycling initial: [JourneyOption] = [], limit: Int = 12, token: UUID) async {
        var walking = ordinary, cycling = initial
        while !Task.isCancelled, token == generation {
            cycling.append(contentsOf: takeBikeConnections(limit: limit))
            var batch: [JourneyOption] = []
            if !walking.isEmpty { batch.append(walking.removeFirst()) }
            if !cycling.isEmpty { batch.append(cycling.removeFirst()) }
            while batch.count < 2, !walking.isEmpty { batch.append(walking.removeFirst()) }
            while batch.count < 2, !cycling.isEmpty { batch.append(cycling.removeFirst()) }
            guard !batch.isEmpty else { return }
            await withTaskGroup(of: JourneyOption?.self) { group in
                for choice in batch { group.addTask { [weak self] in try? await self?.enrich(choice) } }
                for await result in group {
                    guard token == self.generation, !Task.isCancelled, let result else { continue }
                    if result.trip?.variant.isEmpty == true { self.connectionBases[result.id] = result }
                    if result.verified, result.walkIssue == nil {
                        self.verifiedPool.removeAll { $0.id == result.id }
                        self.verifiedPool.append(result); self.message = nil
                        // Publish as soon as either half is ready, not after the slower half.
                        self.publishRecommendations()
                    }
                }
            }
        }
    }
    /// Compare single and combined access, transfer and egress connections. An indoor
    /// platform change is never turned into a street bike ride. Verification remains bounded.
    private func bikeConnections(for choices: [JourneyOption], at date: Date) -> [JourneyOption] {
        var candidates: [(choice: JourneyOption, score: Double, gain: Double)] = []
        var seen = Set<String>()
        for base in choices where !base.cycles {
            guard let trip = base.trip else { continue }
            let originalDurations = trip.planningWalkSeconds.enumerated().map { i, seconds in base.walks.indices.contains(i) ? base.walks[i].duration ?? seconds : seconds }
            let original = TripRanking.assessment(trip, estimates: latestSnapshot.estimates, at: date,
                preferences: preferences, walkingDurations: originalDurations.map { Optional($0) })
            var links: [(index: Int, connection: BikeConnection, gain: Double)] = []
            for index in base.walks.indices where !base.walks[index].internalTransfer {
                let leg = base.walks[index]
                guard let connection = BikeRouting.connection(from: leg.from, to: leg.to, network: bikeNetwork,
                    availability: bikeAvailability, preferences: preferences, at: date) else { continue }
                let walk = leg.duration.map { max(0, $0 - leg.stationSeconds) } ?? BikeRouting.walkingSeconds(leg.from.distance(to: leg.to))
                let gain = walk - connection.totalSeconds
                guard gain > 0 else { continue }
                links.append((index, connection, gain))
            }
            guard !links.isEmpty else { continue }
            // At most five street connections for four transit rides, so the subsets are
            // cheap to enumerate; road queries are reserved for the best distinct choices.
            for mask in 1..<(1 << min(links.count, 5)) {
                let chosen = links.indices.filter { mask & (1 << $0) != 0 }
                let indices = chosen.map { links[$0].index }
                let name: String
                if indices == [0] { name = "youbike-access" }
                else if indices == [base.walks.count - 1] { name = "youbike-finish" }
                else { name = "youbike-legs-" + indices.map(String.init).joined(separator: "-") }
                let variant = trip.asVariant(name)
                guard seen.insert(variant.id).inserted else { continue }
                var walks = base.walks
                var predicted = originalDurations
                var cycling = 0.0, gain = 0.0
                for slot in chosen {
                    let item = links[slot], leg = base.walks[item.index]
                    var replacement = WalkingLeg(from: leg.from, to: leg.to,
                        stationSeconds: leg.stationSeconds, stationInstruction: leg.stationInstruction)
                    replacement.bike = BikeLeg(item.connection); walks[item.index] = replacement
                    predicted[item.index] = item.connection.totalSeconds + leg.stationSeconds
                    cycling += item.connection.rideSeconds + item.connection.handlingSeconds; gain += item.gain
                }
                let assessment = TripRanking.assessment(variant, estimates: latestSnapshot.estimates, at: date,
                    preferences: preferences, walkingDurations: predicted.map { Optional($0) }, cyclingSeconds: cycling,
                    rentalCount: chosen.count)
                // A short local saving can catch a departure that walking would miss.
                guard !assessment.unavailable,
                      gain >= preferences.bikeWalkGainSeconds || assessment.elapsedSeconds <= original.elapsedSeconds - preferences.bikeWalkGainSeconds else { continue }
                let choice = JourneyOption(id: variant.id, trip: variant, walks: walks)
                guard !attemptedBikeConnections.contains(bikeChoiceKey(choice)) else { continue }
                candidates.append((choice, assessment.score, gain))
            }
        }
        candidates.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.gain == $1.gain ? $0.choice.id < $1.choice.id : $0.gain > $1.gain
        }
        // Preserve two alternatives per transit chain until their actual streets are checked.
        var families: [String: Int] = [:], result: [JourneyOption] = []
        for item in candidates {
            let family = item.choice.trip!.familyID
            guard families[family, default: 0] < 2 else { continue }
            families[family, default: 0] += 1; result.append(item.choice)
            if result.count == 8 { break }
        }
        return result
    }
    private var searchedBikeGateways = false
    /// Search independently reachable rail corridors at each end, instead of assuming
    /// that the closest dock towards the destination opens the best transit route.
    private func bikeGatewayProbes(at date: Date) -> [(Coordinate, Coordinate)] {
        guard !searchedBikeGateways, preferences.bikeRouting, bikeAvailability != nil,
              let origin, let destination, let metadata = lastMetadata,
              origin.coordinate.distance(to: destination.coordinate) >= 2_000 else { return [] }
        func gateways(_ point: Coordinate, other: Coordinate, access: Bool) -> [Coordinate] {
            var candidates: [(coordinate: Coordinate, corridor: String, score: Double)] = []
            for station in metadata.metro.stations {
                let entrance = metadata.metro.nearestExit(stationID: station.id, to: point)?.coordinate ?? station.coordinate
                let distance = point.distance(to: entrance)
                guard distance > preferences.expandedWalkMeters, distance <= min(3_000, preferences.bikeMaximumRideMeters) else { continue }
                let from = access ? point : entrance, to = access ? entrance : point
                guard let connection = BikeRouting.connection(from: from, to: to, network: bikeNetwork,
                    availability: bikeAvailability, preferences: preferences, at: date) else { continue }
                let corridor = metadata.metro.lines.first { station.code.hasPrefix($0.code) }?.id ?? station.id
                candidates.append((entrance, corridor, connection.totalSeconds + entrance.distance(to: other) / 8))
            }
            candidates.sort { $0.score == $1.score ? $0.corridor < $1.corridor : $0.score < $1.score }
            var lines = Set<String>(), result: [Coordinate] = []
            for candidate in candidates where lines.insert(candidate.corridor).inserted {
                result.append(candidate.coordinate); if result.count == 2 { break }
            }
            // Preserve the bus-only gateway when no rail corridor is reachable by bike.
            if result.isEmpty, access,
               let station = BikeRouting.gateway(from: point, to: other, network: bikeNetwork,
                   availability: bikeAvailability, preferences: preferences, at: date),
               BikeRouting.connection(from: point, to: station.coordinate, network: bikeNetwork,
                   availability: bikeAvailability, preferences: preferences, at: date) != nil {
                result.append(station.coordinate)
            }
            return result
        }
        let starts = gateways(origin.coordinate, other: destination.coordinate, access: true)
        let ends = gateways(destination.coordinate, other: origin.coordinate, access: false)
        var probes = starts.map { ($0, destination.coordinate) } + ends.map { (origin.coordinate, $0) }
        for start in starts { for end in ends { probes.append((start, end)) } }
        var seen = Set<String>()
        return probes.filter { from, to in seen.insert("\(from.latitude):\(from.longitude):\(to.latitude):\(to.longitude)").inserted }
    }
    /// Late counts and new bike-reachable corridors are verified without clearing the
    /// inspected route. An explicitly started journey cancels all remaining work.
    private func discoverBikeConnections() {
        guard !started, !planning, !checkingWalks, bikeRefinementTask == nil else { return }
        let shouldSearch = bikeAvailability != nil && lastMetadata != nil && origin != nil && destination != nil &&
            (!integratedSearchHasSupply || (bikeAvailability?.receivedAt ?? .distantPast) > lastIntegratedSupplyAt ||
                Date().timeIntervalSince(lastIntegratedBikeSearch) >= 60)
        let candidates = takeBikeConnections(limit: 12)
        guard !candidates.isEmpty || shouldSearch else { return }
        checkingWalks = true; message = nil
        let token = generation
        bikeRefinementTask = Task { [weak self] in
            guard let self else { return }
            await self.verifyConnections([], cycling: candidates, token: token)
            if shouldSearch, let metadata = self.lastMetadata, let origin = self.origin, let destination = self.destination {
                self.lastIntegratedBikeSearch = Date()
                let supply = self.bikeAvailability
                self.lastIntegratedSupplyAt = supply?.receivedAt ?? .distantPast
                let routes = await self.network.options(metadata: metadata, from: origin.coordinate, to: destination.coordinate,
                    preferences: self.preferences, estimates: self.latestSnapshot.estimates,
                    bikeNetwork: self.bikeNetwork, bikeAvailability: supply)
                guard !Task.isCancelled, token == self.generation else { return }
                self.integratedSearchHasSupply = true
                let budget = JourneySearchBudget(distance: origin.coordinate.distance(to: destination.coordinate), cycling: true)
                let known = Set(self.verifiedPool.map(\.id))
                let pending = routes.filter { !known.contains($0.id) }.prefix(budget.verification).map {
                    self.option($0, metadata: metadata, origin: origin, destination: destination)
                }
                for choice in pending where self.connectionBases[choice.id] == nil { self.connectionBases[choice.id] = choice }
                let cycling = pending.filter(\.cycles)
                self.attemptedBikeConnections.formUnion(cycling.map(self.bikeChoiceKey))
                await self.verifyConnections(pending.filter { !$0.cycles }, cycling: cycling,
                    limit: budget.verification, token: token)
            } else {
                await self.verifyConnections([], limit: 24, token: token)
            }
            guard !Task.isCancelled, token == self.generation else { return }
            await self.refineLeadingStations(token: token)
            guard !Task.isCancelled, token == self.generation else { return }
            self.checkingWalks = false; self.bikeRefinementTask = nil
            self.publishRecommendations()
        }
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
    /// A trip may rent again after transit. Past rental stations must not hide or replace
    /// the upcoming connection's stations, or interrupt a completed rental.
    var upcomingBikeLegIndex: Int? {
        guard let option = selected else { return nil }
        return option.walks.indices.first { option.walks[$0].bike != nil && (!started || $0 * 2 >= stepIndex) }
    }
    var bikeAlert: BikeAlert? {
        guard let option = selected, let index = upcomingBikeLegIndex, let bike = option.walks[index].bike else { return nil }
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
        guard let option = selected, let index = upcomingBikeLegIndex, var bike = option.walks[index].bike,
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
            let updated = try? await self.cycle(leg, compareStations: false)
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
    private func option(_ trip: TransitTrip, metadata: TransitMetadata, origin: TravelPlace, destination: TravelPlace) -> JourneyOption {
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
        for (index, connection) in trip.bikeConnections where walks.indices.contains(index) && !walks[index].internalTransfer {
            walks[index].bike = BikeLeg(connection)
        }
        let aligned = trip.withEndpointDistances(access: walks[0].from.distance(to: walks[0].to),
            egress: walks.last!.from.distance(to: walks.last!.to))
        return JourneyOption(id: aligned.id, trip: aligned, walks: walks)
    }
    func plan(metadata: TransitMetadata) {
        lastMetadata = metadata; selectionConfirmed = false
        cancelRequests()
        hadTemporaryStreetFailure = false
        JourneyDiagnostics.shared.record("plan_start")
        verifiedPool = []; optionLabels = [:]; alternativeTransitSeconds = nil; comparisonChanged = false
        attemptedBikeConnections = []; connectionBases = [:]; searchedBikeGateways = false
        integratedSearchHasSupply = false; lastIntegratedBikeSearch = .distantPast; lastIntegratedSupplyAt = .distantPast
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
        let supply = bikeAvailability, bikes = bikeNetwork
        let budget = JourneySearchBudget(distance: origin.coordinate.distance(to: destination.coordinate), cycling: supply != nil)
        task = Task { [weak self] in
            guard let self else { return }
            let trips = await network.options(metadata: metadata, from: origin.coordinate, to: destination.coordinate,
                                              preferences: preferences, estimates: latestSnapshot.estimates,
                                              bikeNetwork: bikes, bikeAvailability: supply)
            guard !Task.isCancelled, token == generation else { return }
            integratedSearchHasSupply = supply != nil; lastIntegratedBikeSearch = Date(); lastIntegratedSupplyAt = supply?.receivedAt ?? .distantPast
            verifiedPool = []; optionLabels = [:]
            let date = Date()
            let observations = latestSnapshot.estimates, currentForecast = forecast
            let ordered = await Task.detached(priority: .userInitiated) {
                let initialRiding = Dictionary(uniqueKeysWithValues: trips.map { trip in
                    (trip.id, currentForecast.plannedRidingEstimates(trip, metadata: metadata, estimates: observations,
                        walkingDurations: [], preferences: preferences, at: date).map(\.seconds))
                })
                return TripRanking.recommended(trips, estimates: observations, at: date,
                    preferences: preferences, limit: budget.candidates, ridingDurations: initialRiding, diverse: false)
            }.value
            guard !Task.isCancelled, token == generation else { return }
            // Verify several families plus their alternative platforms, not just the three eventual rows.
            var selected: [TransitTrip] = []
            var families = Set<String>()
            for trip in ordered where families.insert(trip.familyID + "|" + trip.bikeConnections.keys.sorted().map(String.init).joined(separator: "-")).inserted {
                selected.append(trip); if selected.count >= min(12, budget.verification) { break }
            }
            for trip in ordered where !selected.contains(where: { $0.id == trip.id }) {
                selected.append(trip); if selected.count >= budget.verification { break }
            }
            var pending = selected.map { option($0, metadata: metadata, origin: origin, destination: destination) }
            connectionBases = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
            if origin.coordinate.distance(to: destination.coordinate) <= max(preferences.walkingOnlyMeters, 2_000) {
                pending.insert(JourneyOption(id: "walking", trip: nil,
                    walks: [WalkingLeg(from: origin.coordinate, to: destination.coordinate)]), at: 0)
            }
            options = Array(pending.prefix(3)); selectedID = nil; planning = false; checkingWalks = true
            startAlternativeTransit(from: origin.coordinate, to: destination.coordinate, token: token)
            guard !pending.isEmpty else {
                message = "附近沒有合適公車"; checkingWalks = false; discoverBikeConnections(); return
            }
            let cycling = pending.filter(\.cycles)
            attemptedBikeConnections.formUnion(cycling.map(bikeChoiceKey))
            await verifyConnections(pending.filter { !$0.cycles }, cycling: cycling, limit: budget.verification, token: token)
            guard token == generation, !Task.isCancelled else { return }
            // A provider interruption is not a proof that every street connection
            // is absent. Retain confirmed legs and retry a small leading set once.
            if verifiedPool.isEmpty, hadTemporaryStreetFailure {
                JourneyDiagnostics.shared.record("plan_recover_temporary_service")
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
                guard token == generation, !Task.isCancelled else { return }
                await verifyConnections(Array(pending.filter { !$0.cycles }.prefix(3)),
                    cycling:Array(cycling.prefix(1)),limit:budget.verification,token:token)
                guard token == generation, !Task.isCancelled else { return }
            }
            await refineLeadingStations(token: token)
            guard token == generation, !Task.isCancelled else { return }
            checkingWalks = false
            publishRecommendations()
            if verifiedPool.isEmpty { message = "步行接駁暫時無法確認，請稍後重試或查看其他交通方式。"; options = []; selectedID = nil }
            JourneyDiagnostics.shared.record("plan_end checked=\(verifiedPool.count) offered=\(options.count) temporary_service=\(hadTemporaryStreetFailure)")
            discoverBikeConnections()

        }
    }
    func select(_ option: JourneyOption) {
        // A row can still receive its tap while a fresh recommendation removes it
        // from the compact list. Resolve the checked choice and retain it before
        // changing selection; never leave selectedID pointing at an absent option.
        guard let current = verifiedPool.first(where: { $0.id == option.id }) ?? options.first(where: { $0.id == option.id }),
              current.verified, current.walkIssue == nil, unavailableBoarding(current) == nil else { return }
        if !options.contains(where: { $0.id == current.id }) { options.append(current) }
        selectionConfirmed = true
        comparisonChanged = current.id != options.first?.id
        guard selectedID != current.id else { return }
        endWalkingGuidance()
        selectedID = current.id; started = false; stepIndex = 0; mapRevision += 1
    }
    private func enrich(_ option: JourneyOption, compareStations: Bool = false) async throws -> JourneyOption {
        var result = option
        for index in option.walks.indices {
            try Task.checkCancellation()
            if option.walks[index].internalTransfer { continue }
            if option.walks[index].bike != nil {
                var leg = option.walks[index]
                let starts = connectionStarts(result, at: Date())
                leg.plannedStartAfter = starts.indices.contains(index) ? starts[index] : 0
                result.walks[index] = try await cycle(leg, compareStations: compareStations)
                if !result.walks[index].verified { break }
                continue
            }
            result.walks[index] = try await walk(option.walks[index])
            result.walks[index].streetDuration = result.walks[index].duration
            result.walks[index].stationSeconds = option.walks[index].stationSeconds
            result.walks[index].stationInstruction = option.walks[index].stationInstruction
            if let seconds = result.walks[index].duration { result.walks[index].duration = max(option.walks[index].minimumDuration, seconds + option.walks[index].stationSeconds) }
            if !result.walks[index].verified { break }
        }
        let hasLongWalk = result.walks.enumerated().contains { index, leg in
            // On a cycling leg only the two walks count; the ride itself is meant to be long.
            if let bike = leg.bike { return max(bike.toPickupMeters, bike.fromDropoffMeters) > 900 }
            let transfer = index > 0 && index < result.walks.count - 1
            return (leg.distance ?? 0) > (option.walkingOnly ? 3_500 : transfer ? 600 : 1_800)
        }
        if hasLongWalk { result.walkIssue = result.cycles ? "接駁步行過長" : "步行接駁過長" }
        if !result.verified { result.walkIssue = result.cycles ? "YouBike 路線待確認" : "步行接駁待確認" }
        if hasLongWalk || !result.verified {
            JourneyDiagnostics.shared.record("choice_rejected long_walk=\(hasLongWalk) verified=\(result.verified) legs=\(result.walks.count)")
        }
        return result
    }
    /// Verifies a cycling leg: the walk to the station, the streets the bike will take, and the
    /// walk on from where it is returned. Never substitute pedestrian directions for cycling.
    private func cycle(_ leg: WalkingLeg, compareStations: Bool = true) async throws -> WalkingLeg {
#if DEBUG
        if let testCycle { return try await testCycle(leg) }
#endif
        guard let original = leg.bike else { return leg }
        var pairs = [original.connection]
        if compareStations {
            pairs += BikeRouting.connections(from: leg.from, to: leg.to, network: bikeNetwork,
                availability: bikeAvailability, preferences: preferences, limit: 3)
        }
        var seen = Set<String>(), best: WalkingLeg?, bestCost = Double.infinity
        for pair in pairs where seen.insert(BikeRouting.pairID(pair)).inserted {
            try Task.checkCancellation()
            // A direct test of the provider can omit live supply. Offered journeys cannot.
            if !bikeNetwork.stations.isEmpty &&
                (!BikeRouting.confirmed(pair.pickup, availability: bikeAvailability, renting: true) ||
                 !BikeRouting.confirmed(pair.dropoff, availability: bikeAvailability, renting: false)) { continue }
            guard let result = try? await verifyPair(leg, connection: pair), result.verified, let bike = result.bike else { continue }
            let risk = bikeNetwork.stations.isEmpty ? 0 : BikeRouting.supplyPenalty(bike.connection,
                availability: bikeAvailability, pickupAfter: leg.plannedStartAfter)
            let cost = (result.duration ?? .infinity) + bike.walkingSeconds * max(0, preferences.walkingWeight - 1 + 0.35) + risk
            if cost < bestCost { best = result; bestCost = cost }
        }
        if let best { return best }
        var unresolved = leg; unresolved.duration = nil; return unresolved
    }
    private func verifyPair(_ leg: WalkingLeg, connection: BikeConnection) async throws -> WalkingLeg {
        var bike = BikeLeg(connection), result = leg
        let access = try await walk(WalkingLeg(from: leg.from, to: bike.pickup.coordinate))
        let street = try await walk(WalkingLeg(from: bike.pickup.coordinate, to: bike.dropoff.coordinate), transport: .cycling)
        let egress = try await walk(WalkingLeg(from: bike.dropoff.coordinate, to: leg.to))
        guard let accessSeconds = access.duration, let egressSeconds = egress.duration,
              let rideMeters = street.distance, let rideSeconds = street.duration, rideMeters > 0, rideSeconds > 0 else {
            result.duration = nil; return result
        }
        bike.toPickup = access.coordinates; bike.toPickupMeters = access.distance ?? leg.from.distance(to: bike.pickup.coordinate)
        bike.toPickupSeconds = accessSeconds; bike.ride = street.coordinates
        bike.rideMeters = rideMeters; bike.rideSeconds = rideSeconds
        bike.fromDropoff = egress.coordinates; bike.fromDropoffMeters = egress.distance ?? bike.dropoff.coordinate.distance(to: leg.to)
        bike.fromDropoffSeconds = egressSeconds
        result.bike = bike; result.coordinates = bike.coordinates
        result.road = RouteLine(coordinates: result.coordinates); result.distance = bike.totalMeters
        result.streetDuration = bike.totalSeconds; result.duration = bike.totalSeconds + leg.stationSeconds
        result.instructions = access.instructions + street.instructions + egress.instructions
        return result
    }
    private func walk(_ leg: WalkingLeg, guidance: Bool = false, transport: MKDirectionsTransportType = .walking) async throws -> WalkingLeg {
        let cacheKey = "\(transport.rawValue):\(leg.from.latitude):\(leg.from.longitude):\(leg.to.latitude):\(leg.to.longitude):\(AppLanguage.current.rawValue)"
        if guidance { return try await calculateStreet(leg, guidance: true, transport: transport) }
        if let cached = walkingCache[cacheKey], Date().timeIntervalSince(cached.date) < 900 { return cached.leg }
        if !changingBikeStation, let unavailable = unavailableStreets[cacheKey], Date().timeIntervalSince(unavailable.date) < 15 { return unavailable.leg }
        // A deliberate dock change has its own navigation reserve; it must not
        // inherit a background comparison that was deferred or briefly unavailable.
        if !changingBikeStation, let request = walkingRequests[cacheKey] { return try await request.task.value }
        let id = UUID()
        let task = Task { try await self.calculateStreet(leg, guidance: false, transport: transport) }
        walkingRequests[cacheKey] = (id, task)
        defer { if walkingRequests[cacheKey]?.id == id { walkingRequests[cacheKey] = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        if result.verified {
            if walkingCache.count >= 512, let oldest = walkingCache.min(by: { $0.value.date < $1.value.date }) { walkingCache[oldest.key] = nil }
            walkingCache[cacheKey] = (result, Date())
        } else if !result.temporaryStreetFailure { unavailableStreets[cacheKey] = (result, Date()) }
        return result
    }
    private func calculateStreet(_ leg: WalkingLeg, guidance: Bool, transport: MKDirectionsTransportType) async throws -> WalkingLeg {
        let token = generation
#if DEBUG
        if let testStreet {
            do { return try await testStreet(leg,transport) }
            catch { return try streetFailure(leg,error:error,token:token) }
        }
#endif
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
            let ready = options.contains { canUse($0) }
            let priority: DirectionsRequestGate.Priority = guidance || changingBikeStation ? .navigation :
                evaluatingRemainingJourney || ready ? .alternatives : .firstChoice
            let response = try await DirectionsRequestGate.shared.calculate(operation, priority: priority)
            try Task.checkCancellation()
            for route in response.routes where route.polyline.pointCount > 0 {
                let first = route.polyline.points()[0].coordinate
                let last = route.polyline.points()[route.polyline.pointCount-1].coordinate
                let startGap = leg.from.distance(to:.init(latitude:first.latitude,longitude:first.longitude))
                let endGap = leg.to.distance(to:.init(latitude:last.latitude,longitude:last.longitude))
                let accepted = (transport == .cycling || route.transportType == transport) &&
                    PedestrianPath.leg(route,from:leg.from,to:leg.to,transport:transport) != nil
                JourneyDiagnostics.shared.record("street_response requested=\(transport.rawValue) returned=\(route.transportType.rawValue) points=\(route.polyline.pointCount) start_gap_m=\(startGap.isFinite ? Int(startGap.rounded()) : -1) end_gap_m=\(endGap.isFinite ? Int(endGap.rounded()) : -1) accepted=\(accepted)")
            }
            if response.routes.isEmpty { JourneyDiagnostics.shared.record("street_no_routes mode=\(transport.rawValue)") }
#if DEBUG
            if auditStreetDiagnostics {
                for route in response.routes where route.polyline.pointCount > 0 {
                    let first = route.polyline.points()[0].coordinate
                    let last = route.polyline.points()[max(0, route.polyline.pointCount - 1)].coordinate
                    let startGap = leg.from.distance(to: Coordinate(latitude: first.latitude, longitude: first.longitude))
                    let endGap = leg.to.distance(to: Coordinate(latitude: last.latitude, longitude: last.longitude))
                    print("STREET_RESPONSE mode=\(transport.rawValue) kind=\(route.transportType.rawValue) meters=\(route.distance) seconds=\(route.expectedTravelTime) startGap=\(startGap) endGap=\(endGap) anchored=\(PedestrianPath.leg(route, from: leg.from, to: leg.to, transport:transport) != nil)")
                }
            }
#endif
            // MapKit currently labels cycling responses/steps as automobile even when their
            // geometry, notices and ETA are bicycle-specific (verified against driving and
            // walking queries on the same station pair). The single-mode request is the source
            // of truth; never change a cycling request into a walking or driving fallback.
            if let path = response.routes.filter({ route in transport == .cycling || route.transportType == transport })
                .compactMap({ PedestrianPath.leg($0, from: leg.from, to: leg.to, transport:transport) })
                .min(by: { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }) { result = path }
        } catch {
#if DEBUG
            if auditStreetDiagnostics { print("STREET_ERROR mode=\(transport.rawValue) error=\(error)") }
#endif
            return try streetFailure(leg,error:error,token:token)
        }
        return result
    }
    private func streetFailure(_ leg: WalkingLeg, error: Error, token: UUID) throws -> WalkingLeg {
        try Task.checkCancellation()
        if error is CancellationError || error is DirectionsRequestGate.Deferred { throw error }
        let value = error as NSError
        let temporary = DirectionsRequestGate.isTemporary(error)
        JourneyDiagnostics.shared.record("street_error domain=\(value.domain) code=\(value.code) temporary=\(temporary)")
        if token == generation, temporary { hadTemporaryStreetFailure = true }
        var unresolved = leg; unresolved.temporaryStreetFailure = temporary
        // A failed request supplies no verified path or travel time.
        unresolved.duration = nil; unresolved.distance = nil; unresolved.coordinates = []; unresolved.road = nil
        return unresolved
    }
    func begin() {
        guard let option = selected, canUse(option) else { return }
        cancelRequests()
        started = true; stepIndex = 0; mapRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    /// A separate planner may evaluate the remaining journey without changing the active
    /// planner's selection, map, walking progress or boarded vehicle.
    func resolveRemaining(metadata: TransitMetadata, from start: TravelPlace, to end: TravelPlace,
                          settings: LiveSettings, snapshot: TransitSnapshot, forecast: VehicleArrivalForecast,
                          bikes: BikeNetwork, availability: BikeAvailability?, cacheFrom: JourneyPlannerModel,
                          maximumWait: Double = 18) async -> JourneyOption? {
        cancelRequests(); origin = start; destination = end; usingLocation = false
        preferences = settings.planning; latestSnapshot = snapshot; self.forecast = forecast
        bikeNetwork = bikes; bikeAvailability = availability
        walkingCache.merge(cacheFrom.walkingCache) { a, b in a.date > b.date ? a : b }
        evaluatingRemainingJourney = true
        plan(metadata: metadata)
        defer { cancelRequests(); evaluatingRemainingJourney = false }
        let began = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled {
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if let selected, canUse(selected), (!planning && !checkingWalks || elapsed >= 8) { return selected }
            if elapsed >= maximumWait { return selected.flatMap { canUse($0) ? $0 : nil } }
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return nil }
        }
        return nil
    }
    @discardableResult
    func adoptRemaining(_ option: JourneyOption, from start: TravelPlace) -> Bool {
        guard started, case .walk = currentStep, canUse(option),
              option.walks.count == option.rides.count + 1 else { return false }
        if case .walk(let index) = currentStep, selected?.walks.indices.contains(index) == true,
           selected?.walks[index].bike != nil {
            guard walkingLegIndex == index, let progress = walkingProgress, progress.locationConfirmed,
                  let fix = progress.lastFix, Date().timeIntervalSince(fix) < 20,
                  cyclingPhase(at: index) == .toPickup else { return false }
        }
        cancelRequests(); origin = start; usingLocation = true
        verifiedPool = [option]; connectionBases = [:]; attemptedBikeConnections = []; stationRefinements = [:]
        options = [option]; selectedID = option.id; selectionConfirmed = true
        optionLabels = [:]; comparisonChanged = false; message = nil
        started = true; stepIndex = 0; mapRevision += 1
        return true
    }
    func advance() {
        guard started, stepIndex < steps.count else { return }
        stepIndex += 1; mapRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func boardCurrentRide() {
        guard let index = boardingRideIndex,
              let target = steps.firstIndex(of: .ride(index)) else { return }
        cancelRequests()
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
        verifiedPool = []; connectionBases = [:]; attemptedBikeConnections = []; searchedBikeGateways = false; comparisonChanged = false; optionLabels = [:]
        integratedSearchHasSupply = false; lastIntegratedBikeSearch = .distantPast; lastIntegratedSupplyAt = .distantPast; stationRefinements = [:]
    }
    func openAppleTransit() {
        guard let destination else { return }
        let source = origin?.mapItem ?? MKMapItem.forCurrentLocation()
        MKMapItem.openMaps(with: [source, destination.mapItem], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
    }
    func unavailableBoarding(_ option: JourneyOption, at date: Date = Date()) -> (route: String, status: Int)? {
        for ride in option.rides {
            if let eta = latestSnapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: date),
               [-2, -3, -4].contains(eta) { return (ride.route.localizedName, eta) }
        }
        // Street verification may move the arrival at a platform past its last train.
        // Recheck every rail line at that platform's clock, rather than query time.
        if let metadata = lastMetadata {
            let estimates = ridingEstimates(option, at: date), riding = estimates.map(\.seconds)
            guard let trip = contextualTrip(option, at: date, riding: riding) else { return nil }
            let timing = TripRanking.assessment(trip, estimates: latestSnapshot.estimates, at: date,
                preferences: preferences, walkingDurations: option.walks.map(\.duration),
                ridingDurations: riding, ridingSpreads: estimates.map(\.spreadSeconds))
            var cursor = 0.0
            for index in trip.rides.indices {
                let ride = trip.rides[index]
                cursor += option.walks.indices.contains(index) ? option.walks[index].duration ?? trip.planningWalkSeconds[index] : trip.planningWalkSeconds[index]
                cursor += timing.waits[index].seconds
                if ride.route.mode != .bus, timing.waits[index].evidence != .official,
                   metadata.metro.pattern(ride.route.id, direction: ride.direction) != nil,
                   !metadata.metro.isOperating(routeID: ride.route.id, direction: ride.direction,
                       stationID: ride.boarding.stationID, at: date.addingTimeInterval(cursor)) {
                    return (ride.route.localizedName, -3)
                }
                cursor += riding[index]
            }
        }
        return nil
    }
    private func cancelRequests() {
        endWalkingGuidance()
        pickupTask?.cancel(); pickupTask = nil; pickupGeneration = UUID()
        changingBikeStation = false; bikeStationUpdateMessage = nil
        bikeRefinementTask?.cancel(); bikeRefinementTask = nil
        walkingRequests.values.forEach { $0.task.cancel() }; walkingRequests = [:]
        unavailableStreets = [:]
        task?.cancel(); task = nil; alternativeTask?.cancel(); alternativeTask = nil; directions.forEach { $0.cancel() }; directions = []
        generation = UUID(); planning = false; checkingWalks = false
    }

#if DEBUG
    var auditStreetDiagnostics = false
    var testCycle: ((WalkingLeg) async throws -> WalkingLeg)?
    var testStreet: ((WalkingLeg, MKDirectionsTransportType) async throws -> WalkingLeg)?
    func auditAgeStreetCache(_ seconds: Double) {
        walkingCache = walkingCache.mapValues { ($0.leg,$0.date.addingTimeInterval(-seconds)) }
    }
    func auditRefineStations() async { await refineLeadingStations(token: generation) }
    func auditMetadata(_ metadata: TransitMetadata) { lastMetadata = metadata }
    func auditStreet(_ leg: WalkingLeg, cycling: Bool = false) async throws -> WalkingLeg {
        try await walk(leg, transport: cycling ? .cycling : .walking)
    }
    func auditVerifyConnections(_ choices: [JourneyOption]) async {
        connectionBases = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0) })
        checkingWalks = true
        let token = generation
        await verifyConnections(choices, token: token)
        guard token == generation, !Task.isCancelled else { return }
        checkingWalks = false; publishRecommendations()
    }
    func auditVerifyAdditionalCorridors(_ choices: [JourneyOption]) async {
        for choice in choices where connectionBases[choice.id] == nil { connectionBases[choice.id] = choice }
        checkingWalks = true
        let token = generation
        await verifyConnections([], limit: 24, token: token)
        guard token == generation, !Task.isCancelled else { return }
        checkingWalks = false; publishRecommendations()
    }
    func verifyCyclingLegForTest(_ leg: WalkingLeg) async throws -> WalkingLeg { try await cycle(leg, compareStations: false) }
    /// Controlled inputs; tests still exercise production ranking and navigation methods.
    func auditLoadChoices(_ choices: [JourneyOption], from start: TravelPlace, to end: TravelPlace) {
        cancelRequests(); origin = start; destination = end; usingLocation = false
        started = false; stepIndex = 0; selectionConfirmed = false
        verifiedPool = choices; options = choices
        connectionBases = Dictionary(uniqueKeysWithValues: choices.filter { !$0.cycles }.map { ($0.id, $0) })
        publishRecommendations()
    }
    func auditEnrich(_ option: JourneyOption, metadata: TransitMetadata) async throws -> JourneyOption {
        lastMetadata = metadata
        return try await enrich(option)
    }
    func auditBikeConnections(_ choices: [JourneyOption], at date: Date = Date()) -> [JourneyOption] {
        bikeConnections(for: choices, at: date)
    }
    func auditBikeGatewayProbes(metadata: TransitMetadata, from: Coordinate, to: Coordinate) -> [(Coordinate, Coordinate)] {
        lastMetadata = metadata
        origin = TravelPlace(name:"出發",address:"",coordinate:from)
        destination = TravelPlace(name:"目的地",address:"",coordinate:to)
        return bikeGatewayProbes(at: Date())
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
    func prepareCyclingPreview(trip: TransitTrip?, from start: TravelPlace, to end: TravelPlace, bothEnds: Bool = false) {
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
            if bothEnds, let egress = BikeRouting.connection(from: last.alighting.coordinate, to: end.coordinate,
                network: bikeNetwork, availability: bikeAvailability, preferences: preferences) {
                let combined = trip.asVariant("youbike-legs-0-\(walks.count - 1)")
                walks[walks.count - 1] = cycling(egress, from: last.alighting.coordinate, to: end.coordinate)
                result.insert(JourneyOption(id:combined.id,trip:combined,walks:walks),at:0)
            }
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
