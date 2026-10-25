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

struct WalkingEntrance: Sendable {
    let from: Coordinate
    let to: Coordinate
    let instruction: String?
}
struct WalkingLeg: Sendable {
    var from: Coordinate
    var to: Coordinate
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
    var entranceAlternatives: [WalkingEntrance] = []
    var verified: Bool { duration != nil }
    var cyclingSeconds: Double { bike?.cyclingSeconds ?? 0 }
    var stationAllowance: Double {
        let total = max(0, duration ?? 0)
        if internalTransfer { return total }
        return min(total, max(0, total - (streetDuration ?? max(0, total - stationSeconds))))
    }
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
                 estimates: EstimateFeed, at date: Date = Date(), bikeNetwork: BikeNetwork = .empty, bikeAvailability: BikeAvailability? = nil,
                 onPreliminary: (@Sendable ([TransitTrip]) -> Void)? = nil) -> [TransitTrip] {
        guard !Task.isCancelled else { return [] }
        let signature = metadata.revision.uuidString
        if planner == nil || key != signature || Date().timeIntervalSince(builtAt) > 86_400 {
            planner = MultimodalPlanner(metadata: metadata); key = signature; builtAt = Date()
        }
        let budget = JourneySearchBudget(distance: from.distance(to: to), cycling: preferences.bikeRouting && bikeAvailability != nil)
        guard !Task.isCancelled else { return [] }
        return planner!.plan(from: from, to: to, maximumWalk: preferences.expandedWalkMeters, limit: budget.candidates,
                             preferences: preferences, estimates: estimates, at: date, bikeNetwork: bikeNetwork, bikeAvailability: bikeAvailability,
                             onPreliminary: onPreliminary)

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
    /// A verified pool can still rank to no usable options (for example after
    /// service ends). Never leave the completed route sheet blank in that case.
    var emptyOptionsMessage: String? {
        guard destination != nil, options.isEmpty, !planning, !checkingWalks else { return nil }
        return message ?? "這趟行程暫無可用方案，可更換出發地或查看其他交通方式。"
    }
    @Published private(set) var message: String?
    @Published private(set) var started = false
    @Published private(set) var stepIndex = 0
    /// A complete navigation transition, delivered after all of its state has changed.
    var onNavigationChange: (() -> Void)?
    @Published private(set) var mapRevision = 0
    @Published private(set) var recentPlaces: [TravelPlace] = []
    private let network = TripNetwork()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var directions: [MKDirections] = []
    private var receivedSnapshot = TransitSnapshot()
    private let scheduledSnapshot = TransitSnapshot()
    /// A trip planned for later has no observed bus to rely on; only timetables and headways count.
    private var latestSnapshot: TransitSnapshot { scheduledDeparture == nil ? receivedSnapshot : scheduledSnapshot }
    /// Set for 「明天下午三點出發」: the same planning, ranked on that day's timetables and headways.
    @Published private(set) var scheduledDeparture: Date?
    /// The time every timing in this plan is measured from.
    func clock(_ date: Date) -> Date { scheduledDeparture ?? date }
    /// 「三點前到台大」: the departure is moved until the recommended route arrives a few minutes early.
    @Published private(set) var arrivalDeadline: Date?
    func schedule(_ departure: Date?, arriveBy deadline: Date? = nil) {
        // Within a few minutes it is simply now, with live buses.
        arrivalDeadline = deadline.flatMap { $0.timeIntervalSinceNow > 10 * 60 ? $0 : nil }
        if let arrivalDeadline {
            // A first guess; alignToDeadline() corrects it from the routes found.
            let guess = arrivalDeadline.addingTimeInterval(-45 * 60)
            scheduledDeparture = max(Date().addingTimeInterval(6 * 60), Date(timeIntervalSince1970: floor(guess.timeIntervalSince1970 / 60) * 60))
        } else {
            scheduledDeparture = departure.flatMap { $0.timeIntervalSinceNow > 5 * 60 ? $0 : nil }
        }
        durationCache.removeAll(keepingCapacity: true)
    }
    /// Timetable waits jump at each departure, so a few corrections, each to the whole minute.
    private func alignToDeadline() {
        guard let deadline = arrivalDeadline, var departure = scheduledDeparture else { return }
        let earliest = Date().addingTimeInterval(6 * 60)
        for _ in 0..<5 {
            guard let best = recommendations(at: departure).first, let timing = duration(best, at: departure) else { return }
            let shift = deadline.addingTimeInterval(-5 * 60).timeIntervalSince(departure.addingTimeInterval(timing.totalSeconds))
            if abs(shift) < 90 { return }
            let next = max(earliest, Date(timeIntervalSince1970: floor((departure.timeIntervalSince1970 + shift) / 60) * 60))
            if next == departure { return }
            departure = next; scheduledDeparture = next; durationCache.removeAll(keepingCapacity: true)
        }
    }
    /// When the shown route is expected to arrive, from the planned departure.
    var expectedArrival: Date? {
        guard let option = selected ?? options.first, let timing = duration(option, at: Date()) else { return nil }
        return timing.referenceDate.addingTimeInterval(timing.totalSeconds)
    }
    private var preferences = LiveSettings.Planning()
    private var lastMetadata: TransitMetadata?
    private var selectionConfirmed = false
    /// The rider tapped this route. A card only retained because it appeared first may still
    /// give way to a clearly better route found later.
    private var selectionChosen = false
    /// A way of travelling the rider asked for in 用一句話規劃 (e.g. 騎單車): routes made only of
    /// it are listed first. Cleared when the trip is finished.
    var preferredMode = AssistantTravelMode.any
    /// 「不要搭公車」, 「只搭捷運」, 「避開紅線」: routes that break them are left out while others exist.
    var constraints = TripConstraints() { didSet { if constraints != oldValue { durationCache.removeAll(keepingCapacity: true) } } }
    /// No route kept the constraints, so the usual ones are shown with a note.
    @Published private(set) var constraintsUnmet = false
    /// A rider who asked to cycle gets a whole-trip YouBike route up to 20 km; otherwise rides stay
    /// within the usual limit (5 km), beyond which public transport is normally the better offer.
    /// Why no whole-trip YouBike route can be offered for a rider who asked to cycle, or nil when
    /// one is listed or may still appear (its streets are still being checked).
    func wholeTripBikeIssue(at date: Date = Date()) -> String? {
        guard preferredMode == .cycling, let origin, let destination, !options.contains(where: \.bikeOnly) else { return nil }
        guard let availability = bikeAvailability else { return AppText.text("YouBike 即時車位尚未載入。") }
        let limits = wholeTripBikePreferences
        let distance = origin.coordinate.distance(to: destination.coordinate)
        if distance > limits.bikeMaximumRideMeters {
            return AppText.text("距離超過 %@ 公里，不適合全程騎 YouBike。", "\(Int(limits.bikeMaximumRideMeters / 1000))")
        }
        if distance < limits.bikeMinimumRideMeters { return AppText.text("距離很近，走路就能到。") }
        func usable(_ point: Coordinate, renting: Bool) -> Bool {
            bikeNetwork.stations(near: point, radius: limits.bikeAccessMeters, limit: 40).contains { station in
                guard let dock = availability.dock(station.id, at: date), dock.active else { return false }
                return Double(renting ? dock.rentable : dock.returnable) >= (renting ? limits.bikeMinimumBikes : limits.bikeMinimumDocks)
            }
        }
        let meters = "\(Int(limits.bikeAccessMeters))"
        if !usable(origin.coordinate, renting: true) { return AppText.text("出發地 %@ 公尺內沒有可借的 YouBike。", meters) }
        if !usable(destination.coordinate, renting: false) { return AppText.text("目的地 %@ 公尺內沒有可還車的 YouBike 站。", meters) }
        return nil
    }
    private var wholeTripBikePreferences: LiveSettings.Planning {
        guard preferredMode == .cycling else { return preferences }
        var value = preferences
        value.bikeMaximumRideMeters = max(value.bikeMaximumRideMeters, 20_000)
        return value
    }
    private var forecast = VehicleArrivalForecast()
    private struct CachedDuration {
        let bucket: Int
        let walks: [Double?]
        let from: [Coordinate]
        let to: [Coordinate]
        let riding: [Double]
        let cycling: Double
        let station: Double
        let handling: Double
        let value: JourneyDuration
    }
    private var durationCache: [String: CachedDuration] = [:]
    private var verifiedPool: [JourneyOption] = []
    private var walkingCache: [String: (leg: WalkingLeg, date: Date)] = [:]
    // Briefly share unavailable endpoints across combinations, while allowing a
    // transient failure to recover. A new explicit search always tries them again.
    private var unavailableStreets: [String: (leg: WalkingLeg, date: Date)] = [:]
    private var walkingRequests: [String: (id: UUID, task: Task<WalkingLeg, Error>)] = [:]
    private var primaryStreetKeys = Set<String>()
    private var hadTemporaryStreetFailure = false
    private var planBegan = 0.0
    private var recordedFirstChoice = false
    @Published private(set) var optionLabels: [String: String] = [:]
    @Published private(set) var optionReasons: [String: String] = [:]
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
            walkingProgress = WalkingProgress(coordinates: leg.coordinates, distance: leg.distance ?? 0,
                seconds: leg.streetDuration ?? leg.duration ?? 0, learnsWalkingPace: leg.bike == nil)
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
        guard walkingLegIndex == index, let progress = walkingProgress, progress.hasConfirmedProgress else { return .toPickup }
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
        guard let progress = walkingProgress, progress.hasConfirmedProgress else { return AppText.text("正在確認步行位置") }
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

    /// The access walk and train-platform directions share the existing map;
    /// boarding still happens only after the rider explicitly confirms it.
    func accessInstruction(at index: Int, date: Date) -> String? {
        guard started, currentStep == .walk(index), let option = selected,
              option.walks.indices.contains(index), option.rides.indices.contains(index) else { return nil }
        let leg = option.walks[index], ride = option.rides[index]
        if leg.bike != nil { return cyclingInstruction(at: index) }
        if leg.internalTransfer { return leg.stationInstruction ?? AppText.text("前往 %@ 月台", ride.route.localizedName) }
        if (leg.distance ?? .infinity) <= 30, (leg.streetDuration ?? leg.duration ?? .infinity) <= 45 {
            return ride.route.mode == .bus ? nil : leg.stationInstruction
        }
        if walkingLegIndex == index, let progress = walkingProgress, progress.hasConfirmedProgress,
           progress.remainingDistance <= 30 {
            if ride.route.mode != .bus { return leg.stationInstruction ?? AppText.text("前往 %@ 月台", ride.route.localizedName) }
            return nil
        }
        return AppText.text("步行至 %@", ride.boarding.localizedName)
    }


    init() {
        if let data = UserDefaults.standard.data(forKey: "journeyRecentPlaces"),
           let places = try? JSONDecoder().decode([TravelPlace].self, from: data) { recentPlaces = places }
    }
    var selected: JourneyOption? { options.first { $0.id == selectedID } }
    func removeRecentPlace(_ id: String) {
        recentPlaces.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(recentPlaces) { UserDefaults.standard.set(data, forKey: "journeyRecentPlaces") }
    }
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
    func ridingEstimates(_ option: JourneyOption, at suppliedDate: Date) -> [RidingTimeEstimate] {
        let date = clock(suppliedDate)
        if let trip = contextualTrip(option, at: date), let metadata = lastMetadata {
            return forecast.plannedRidingEstimates(trip, metadata: metadata, estimates: latestSnapshot.estimates,
                walkingDurations: option.walks.map(\.duration), preferences: preferences, at: date,
                departures: boardingDepartures(trip.rides, at: date))
        }
        return option.rides.enumerated().map { index, _ in
            RidingTimeEstimate(seconds: option.trip?.rideSeconds[index] ?? 0, evidence: .typical, observedVehicles: 0)
        }
    }
    private func boardingDepartures(_ rides: [TransitRide], at date: Date) -> [[BoardingDeparture]] {
        guard let metadata = lastMetadata else { return [] }
        return rides.map { forecast.departures(for: $0, metadata: metadata, snapshot: latestSnapshot, at: date) }
    }
    private func contextualTrip(_ option: JourneyOption, at date: Date, riding: [Double]? = nil) -> TransitTrip? {
        guard let trip = option.trip else { return nil }
        guard option.walks.count == trip.rides.count + 1 else { return trip }
        return trip.replacingRides(contextualRides(trip.rides,
            walking: option.walks.enumerated().map { $0.element.duration ?? trip.planningWalkSeconds[$0.offset] },
            riding: riding ?? trip.rideSeconds, transferDistances: trip.transferDistances, at: date))
    }
    func contextualRides(_ source: [TransitRide], walking: [Double], riding: [Double],
                         transferDistances: [Double], at suppliedDate: Date, onboardFirst: Bool = false) -> [TransitRide] {
        let date = clock(suppliedDate)
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
                boardingBuffers: ConnectionTiming.buffers(rides: rides, walking: walking, transferDistances: transferDistances),
                departures: boardingDepartures(rides, at: date))
            cursor += timing.waits[index].seconds + riding[index]
        }
        return rides
    }
    func duration(_ option: JourneyOption, at suppliedDate: Date) -> JourneyDuration? {
        let date = clock(suppliedDate)
        guard option.verified, option.walkIssue == nil else { return nil }
        let bucket = Int(floor(date.timeIntervalSince1970 / 5))
        let walks = option.walks.map(\.duration), from = option.walks.map(\.from), to = option.walks.map(\.to)
        let station = option.walks.reduce(0) { $0 + $1.stationAllowance }
        let handling = option.walks.compactMap(\.bike).reduce(0) { $0 + $1.handlingSeconds }
        if let cached = durationCache[option.id], cached.bucket == bucket,
           cached.walks == walks, cached.from == from, cached.to == to,
           cached.riding == option.trip?.rideSeconds ?? [], cached.cycling == option.cyclingSeconds,
           cached.station == station, cached.handling == handling { return cached.value }
        guard let value = calculateDuration(option, at: date) else { return nil }
        if durationCache.count >= 100 { durationCache.removeAll(keepingCapacity: true) }
        durationCache[option.id] = CachedDuration(bucket: bucket, walks: walks, from: from, to: to,
            riding: option.trip?.rideSeconds ?? [], cycling: option.cyclingSeconds, station: station, handling: handling, value: value)
        return value
    }
    private func calculateDuration(_ option: JourneyOption, at date: Date) -> JourneyDuration? {
        guard option.verified, option.walkIssue == nil else { return nil }
        let estimates = ridingEstimates(option, at: date)
        let riding = estimates.map(\.seconds)
        if let trip = contextualTrip(option, at: date, riding: riding) {
            let assessment = TripRanking.assessment(trip, estimates: latestSnapshot.estimates, at: date,
                preferences: preferences, walkingDurations: option.walks.map(\.duration), ridingDurations: riding,
                ridingSpreads: estimates.map(\.spreadSeconds), departures: boardingDepartures(trip.rides, at: date))
            var duration = JourneyDuration(assessment: assessment, riding: riding)
            duration.cyclingSeconds = option.cyclingSeconds
            duration.cyclingHandlingSeconds = option.walks.compactMap(\.bike).reduce(0) { $0 + $1.handlingSeconds }
            duration.stationSeconds = option.walks.reduce(0) { $0 + $1.stationAllowance }
            duration.ridingEvidence = estimates.contains { $0.evidence == .typical } ? .typical :
                estimates.contains { $0.evidence == .recentTraffic } ? .recentTraffic :
                estimates.contains { $0.evidence == .officialProfile } ? .officialProfile : estimates.contains { $0.evidence == .railProfile } ? .railProfile : .stationHistory
            return duration
        }
        var duration = JourneyDuration(riding: [], walking: option.walks.compactMap(\.duration), arrivals: [], at: date)
        duration.cyclingSeconds = option.cyclingSeconds
        duration.cyclingHandlingSeconds = option.walks.compactMap(\.bike).reduce(0) { $0 + $1.handlingSeconds }
        duration.stationSeconds = option.walks.reduce(0) { $0 + $1.stationAllowance }
        return duration
    }
    private func connectionStarts(_ option: JourneyOption, at suppliedDate: Date) -> [Double] {
        let date = clock(suppliedDate)
        guard let trip = option.trip else { return [0] }
        guard option.walks.count == trip.rides.count + 1 else { return Array(repeating: 0, count: option.walks.count) }
        let rides = ridingEstimates(option, at: date).map(\.seconds)
        let assessment = TripRanking.assessment(trip, estimates: latestSnapshot.estimates, at: date,
            preferences: preferences, walkingDurations: option.walks.map(\.duration), ridingDurations: rides,
            departures: boardingDepartures(trip.rides, at: date))
        var cursor = 0.0, starts: [Double] = []
        for index in option.walks.indices {
            starts.append(cursor)
            cursor += option.walks[index].duration ?? trip.planningWalkSeconds[index]
            if rides.indices.contains(index) { cursor += assessment.waits[index].seconds + rides[index] }
        }
        return starts
    }
    private func supplyRisk(_ option: JourneyOption, at suppliedDate: Date) -> Double {
        let date = clock(suppliedDate)
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
    private func recommendations(at suppliedDate: Date) -> [JourneyOption] {
        let date = clock(JourneyDuration.previewDate(suppliedDate))
        let valid = verifiedPool.filter { $0.verified && $0.walkIssue == nil && unavailableBoarding($0) == nil }
        let hasTransit = valid.contains { !$0.rides.isEmpty }
        var metrics: [JourneyChoice] = []
        for option in valid {
            guard let timing = duration(option, at: date) else { continue }
            let legs = option.walks.indices.filter { option.walks[$0].bike != nil }.map(String.init).joined(separator: "-")
            let group = (option.trip?.familyID ?? (option.cycles ? "cycling" : "walking")) + "|bikes:" + legs
            metrics.append(JourneyChoice(id: option.id, group: group, elapsed: timing.totalSeconds,
                walking: max(0, timing.walkingSeconds - option.cyclingSeconds), waiting: timing.waitingSeconds,
                transfers: max(0, option.rides.count - 1), rentals: option.walks.filter { $0.bike != nil }.count,
                unknownWaits: timing.unknownWaits, supplyRisk: supplyRisk(option, at: date), preferences: preferences,
                transitLed: isTransitLed(option,timing:timing,hasTransit:hasTransit)))
        }
        let byID = Dictionary(uniqueKeysWithValues: valid.map { ($0.id, $0) })
        var ranked = JourneyChoiceRanking.recommended(metrics).compactMap { byID[$0] }
        if !constraints.isEmpty {
            let kept = ranked.filter(constraints.allows)
            let unmet = kept.isEmpty && !ranked.isEmpty && !planning && !checkingWalks
            if constraintsUnmet != unmet { constraintsUnmet = unmet }
            if !kept.isEmpty { ranked = kept }
        } else if constraintsUnmet { constraintsUnmet = false }
        let wanted: [JourneyOption]
        switch preferredMode {
        case .any: return ranked
        case .cycling: wanted = valid.filter(\.bikeOnly).filter(constraints.allows)
        case .walking: wanted = valid.filter(\.walkingOnly)
        }
        let fastest = wanted.sorted { (duration($0, at: date)?.totalSeconds ?? .infinity) < (duration($1, at: date)?.totalSeconds ?? .infinity) }
        let ids = Set(fastest.map(\.id))
        return fastest + ranked.filter { !ids.contains($0.id) }
    }
    private func isTransitLed(_ option: JourneyOption, timing: JourneyDuration, hasTransit: Bool = true) -> Bool {
        let bikes = option.walks.compactMap(\.bike)
        // With no transit leg available, a short local ride can still beat a long walk.
        if !hasTransit, option.bikeOnly, bikes.count == 1,
           TransitBikePolicy.isLocalFeeder(bikes[0].connection) { return true }
        return TransitBikePolicy.isTransitLed(transitSeconds:timing.ridingSeconds,
            rideSeconds:bikes.map(\.rideSeconds),rideMeters:bikes.map(\.rideMeters))
    }
    private func labels(for result: [JourneyOption], recommendedOption: JourneyOption?, at date: Date) -> [String: String] {
        let recommended = recommendedOption.flatMap { duration($0, at: date) }
        let durations = result.compactMap { duration($0, at: date) }
        let fastest = durations.map(\.totalSeconds).min() ?? .infinity
        let shortestWalk = durations.map { max(0, $0.walkingSeconds - $0.cyclingSeconds) }.min() ?? .infinity
        var labels: [String: String] = [:]
        for option in result {
            if option.cycles, let timing = duration(option,at:date), !isTransitLed(option,timing:timing,hasTransit:result.contains { !$0.rides.isEmpty }) {
                labels[option.id] = option.bikeOnly ? "騎 YouBike" : option.walks.filter({ $0.bike != nil }).count > 1 ? "多次借還" : "騎乘較多"
                continue
            }
            if option.id == recommendedOption?.id {
                labels[option.id] = option.bikeOnly ? "騎 YouBike" : option.walkingOnly ? "步行即可" : "推薦"
                continue
            }
            if option.bikeOnly { labels[option.id] = "騎 YouBike"; continue }
            if option.cycles { labels[option.id] = "YouBike 接駁"; continue }
            if recommendedOption?.cycles == true { labels[option.id] = "免騎車"; continue }
            if let timing = duration(option, at: date), let recommended {
                if timing.totalSeconds < recommended.totalSeconds - 60, timing.totalSeconds <= fastest + 30 { labels[option.id] = "較快" }
                else if timing.walkingSeconds - timing.cyclingSeconds < recommended.walkingSeconds - recommended.cyclingSeconds - 120,
                        timing.walkingSeconds - timing.cyclingSeconds <= shortestWalk + 30 { labels[option.id] = "少走路" }
                else if option.rides.count == 1 { labels[option.id] = "直達" }
                else { labels[option.id] = option.rides.count < (recommendedOption?.rides.count ?? 0) ? "少轉乘" : "轉乘" }
            }
        }
        return labels
    }
    private func publishRecommendations() {
        alignToDeadline()
        let date = JourneyDuration.previewDate(Date())
        let ranked = recommendations(at: date)
        // The first usable card is kept steady under the reader's finger, but not at any cost:
        // an 88-minute bus must not stay on top of a 39-minute route found seconds later.
        // Never while navigating: the active route is the rider's commitment.
        if !started, selectionConfirmed, !selectionChosen, let current = selected, let best = ranked.first, best.id != current.id,
           let shown = duration(current, at: date), let better = duration(best, at: date),
           JourneyRevisionPolicy.shouldOffer(current: shown.totalSeconds, alternative: better.totalSeconds, currentUsable: true) {
            selectionConfirmed = false
        }
        // Previewing a result must not cancel discovery of later alternatives. Keep
        // the inspected route available even if it falls outside the new top three.
        var result = ranked
        if selectionConfirmed, let inspected = selected, !result.contains(where: { $0.id == inspected.id }) {
            result.append(inspected)
        }
        let previousSelection = selectedID
        options = result; optionLabels = labels(for: result, recommendedOption: ranked.first, at: date)
        let comparisons = result.compactMap { option -> JourneyChoice? in
            guard let timing = duration(option, at: date) else { return nil }
            return JourneyChoice(id: option.id, group: "", elapsed: timing.totalSeconds,
                walking: max(0,timing.walkingSeconds-option.cyclingSeconds), waiting: timing.waitingSeconds,
                transfers: max(0,option.rides.count-1), rentals: option.walks.filter { $0.bike != nil }.count,
                unknownWaits: timing.unknownWaits)
        }
        optionReasons = Dictionary(uniqueKeysWithValues: comparisons.compactMap { choice in
            guard let other = comparisons.first(where: { $0.id != choice.id }),
                  let reason = JourneyChoiceRanking.reason(for: choice, comparedTo: other) else { return nil }
            return (choice.id, reason)
        })
        // The recommendation is always first. Keep the inspected page selected by ID,
        // rather than freezing the entire list in its old arrival order.
        comparisonChanged = selectionConfirmed && selectedID != ranked.first?.id
        if !selectionConfirmed { selectedID = result.first?.id }
        if previousSelection != selectedID { mapRevision += 1 }
    }
    func refreshRecommendations() {
        guard !started else { return }
        if !checkingWalks, !verifiedPool.isEmpty {
            selectionConfirmed = false; selectionChosen = false; publishRecommendations()
        } else if let metadata = lastMetadata { plan(metadata: metadata) }
    }
    private func startAlternativeTransit(from: Coordinate, to: Coordinate, token: UUID) {
        alternativeTask?.cancel()
        alternativeTask = Task { [weak self] in
            guard let self else { return }
            let request = MKDirections.Request()
            request.source = TravelPlace(name: "出發地", address: "", coordinate: from).mapItem
            request.destination = TravelPlace(name: "目的地", address: "", coordinate: to).mapItem
            let requestedAt = clock(Date())
            request.transportType = .transit; request.departureDate = requestedAt
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
        durationCache.removeAll(keepingCapacity: true)
        receivedSnapshot = snapshot; self.forecast = forecast
        // Refresh the order without changing an inspected route or its map camera.
        if !started, !planning, !checkingWalks, !verifiedPool.isEmpty {
            let date = JourneyDuration.previewDate(Date())
            let fresh = recommendations(at: date)
            var orderedIDs = fresh.map(\.id)
            if selectionConfirmed, let selectedID, !orderedIDs.contains(selectedID) { orderedIDs.append(selectedID) }
            let updatedLabels = labels(for: options, recommendedOption: fresh.first, at: date)
            if orderedIDs != options.map(\.id) || updatedLabels != optionLabels { publishRecommendations() }
        }
    }
    func updateSettings(_ settings: LiveSettings) {
        durationCache.removeAll(keepingCapacity: true); preferences = settings.planning
        if !started, !verifiedPool.isEmpty { publishRecommendations() }
    }
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
                let pairs = original.trip == nil
                    ? BikeRouting.connections(from:leg.from,to:leg.to,network:bikeNetwork,availability:bikeAvailability,preferences:preferences,limit:3)
                    : BikeRouting.feederConnections(from:leg.from,to:leg.to,network:bikeNetwork,availability:bikeAvailability,preferences:preferences,limit:3)
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
        guard preferences.bikeRouting else { return [] }
        // A rider who asked to cycle always gets the whole-trip ride checked, even after transit
        // feeder rides have used the comparison budget; it used to never be tried on long trips.
        var priority: [JourneyOption] = []
        if preferredMode == .cycling, let whole = wholeTripBikeChoice(),
           attemptedBikeConnections.insert(bikeChoiceKey(whole)).inserted { priority = [whole] }
        guard attemptedBikeConnections.count < limit else { return priority }
        var choices = integratedSearchHasSupply ? [] : bikeConnections(for: Array(connectionBases.values), at: Date())
        if let whole = wholeTripBikeChoice(), !attemptedBikeConnections.contains(bikeChoiceKey(whole)) { choices.append(whole) }
        let reserved = Array(choices.prefix(limit - attemptedBikeConnections.count))
        attemptedBikeConnections.formUnion(reserved.map(bikeChoiceKey))
        return priority + reserved
    }
    /// Riding YouBike all the way, when stations with bikes and docks are near both ends.
    private func wholeTripBikeChoice() -> JourneyOption? {
        guard preferences.bikeRouting, let origin, let destination,
              let whole = BikeRouting.connection(from: origin.coordinate, to: destination.coordinate,
                  network: bikeNetwork, availability: bikeAvailability, preferences: wholeTripBikePreferences) else { return nil }
        var leg = WalkingLeg(from: origin.coordinate, to: destination.coordinate); leg.bike = BikeLeg(whole)
        return JourneyOption(id: "youbike", trip: nil, walks: [leg])
    }
    /// One ordinary route and one cycling alternative share each batch. Later walking
    /// platforms cannot monopolize the queue; at most two routes are verified at once.
    private func verifyConnections(_ ordinary: [JourneyOption], cycling initial: [JourneyOption] = [], limit: Int = 12,
                                   discoverBikes: Bool = true, token: UUID) async {
        var walking = ordinary, cycling = initial
        while !Task.isCancelled, token == generation {
            if discoverBikes { cycling.append(contentsOf: takeBikeConnections(limit: limit)) }
            var batch: [JourneyOption] = []
            let batchLimit = verifiedPool.isEmpty ? 1 : 2
            if !walking.isEmpty { batch.append(walking.removeFirst()) }
            if batch.count < batchLimit, !cycling.isEmpty { batch.append(cycling.removeFirst()) }
            while batch.count < batchLimit, !walking.isEmpty { batch.append(walking.removeFirst()) }
            while batch.count < batchLimit, !cycling.isEmpty { batch.append(cycling.removeFirst()) }
            guard !batch.isEmpty else { return }
            var serviceInterrupted = false
            await withTaskGroup(of: JourneyOption?.self) { group in
                for choice in batch { group.addTask { [weak self] in try? await self?.enrich(choice) } }
                for await result in group {
                    guard token == self.generation, !Task.isCancelled, let result else { continue }
                    if result.walks.contains(where: \.temporaryStreetFailure) { serviceInterrupted = true }
                    if result.trip?.variant.isEmpty == true { self.connectionBases[result.id] = result }
                    if result.verified, result.walkIssue == nil {
                        if !self.recordedFirstChoice {
                            self.recordedFirstChoice = true
                            JourneyDiagnostics.shared.record("first_choice_ms=\(Int((ProcessInfo.processInfo.systemUptime-self.planBegan)*1000))")
                        }
                        self.verifiedPool.removeAll { $0.id == result.id }
                        self.verifiedPool.append(result); self.message = nil
                        // Publish as soon as either half is ready, not after the slower half.
                        self.publishRecommendations()
                    }
                }
            }
            // An outage is shared by the provider, not unique to a platform.
            // Stop the batch and let the bounded recovery pass handle it instead
            // of immediately sending the same failing access leg for every option.
            if serviceInterrupted { return }
        }
    }
    /// Compare single and combined access, transfer and egress connections. An indoor
    /// platform change is never turned into a street bike ride. Verification remains bounded.
    private func bikeConnections(for choices: [JourneyOption], at suppliedDate: Date) -> [JourneyOption] {
        let date = clock(suppliedDate)
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
                guard let connection = BikeRouting.feederConnections(from: leg.from, to: leg.to, network: bikeNetwork,
                    availability: bikeAvailability, preferences: preferences, at: date, limit:1).first else { continue }
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
    private func bikeGatewayProbes(at suppliedDate: Date) -> [(Coordinate, Coordinate)] {
        let date = clock(suppliedDate)
        guard !searchedBikeGateways, preferences.bikeRouting, bikeAvailability != nil,
              let origin, let destination, let metadata = lastMetadata,
              origin.coordinate.distance(to: destination.coordinate) >= 2_000 else { return [] }
        func gateways(_ point: Coordinate, other: Coordinate, access: Bool) -> [Coordinate] {
            var candidates: [(coordinate: Coordinate, corridor: String, score: Double)] = []
            for station in metadata.metro.stations {
                let entrance = metadata.metro.nearestExit(stationID: station.id, to: point)?.coordinate ?? station.coordinate
                let distance = point.distance(to: entrance)
                guard distance > preferences.expandedWalkMeters, distance <= min(TransitBikePolicy.maximumFeederMeters, preferences.bikeMaximumRideMeters) else { continue }
                let from = access ? point : entrance, to = access ? entrance : point
                guard let connection = BikeRouting.feederConnections(from: from, to: to, network: bikeNetwork,
                    availability: bikeAvailability, preferences: preferences, at: date,limit:1).first else { continue }
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
                   availability: bikeAvailability, preferences: TransitBikePolicy.feederPreferences(preferences), at: date),
               !BikeRouting.feederConnections(from: point, to: station.coordinate, network: bikeNetwork,
                   availability: bikeAvailability, preferences: preferences, at: date,limit:1).isEmpty {
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
                    preferences: self.preferences, estimates: self.latestSnapshot.estimates, at: self.clock(Date()),
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
            Haptics.stage()
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
    func option(_ trip: TransitTrip, metadata: TransitMetadata, origin: TravelPlace, destination: TravelPlace) -> JourneyOption {
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
        func exits(_ stop: BusStop, toward point: Coordinate) -> [(Coordinate, String?)] {
            let values = metadata.metro.station(stop.stationID)?.exits.sorted {
                $0.coordinate.distance(to: point) < $1.coordinate.distance(to: point)
            } ?? []
            return values.isEmpty ? [(stop.coordinate, nil)] : values.prefix(3).map {
                ($0.coordinate, AppLanguage.current == .english ? $0.englishName : $0.name)
            }
        }
        // Compare real public entrances, rather than assuming the straight-line
        // closest door is also the shortest walk around the block.
        for index in walks.indices where !walks[index].internalTransfer {
            let starts: [(Coordinate, String?)] = index == 0 ? [(origin.coordinate, nil)] :
                exits(trip.rides[index - 1].alighting, toward: walks[index].to)
            let ends: [(Coordinate, String?)] = index == trip.rides.count ? [(destination.coordinate, nil)] :
                exits(trip.rides[index].boarding, toward: walks[index].from)
            var alternatives: [WalkingEntrance] = []
            for a in starts { for b in ends {
                guard a.0.distance(to: walks[index].from) > 1 || b.0.distance(to: walks[index].to) > 1 else { continue }
                let instruction = b.1.map { AppText.text("從 %@ 進站", $0) } ?? a.1.map { AppText.text("從 %@ 出站", $0) }
                alternatives.append(.init(from: a.0, to: b.0, instruction: instruction))
            } }
            walks[index].entranceAlternatives = Array(alternatives.sorted {
                $0.from.distance(to: $0.to) < $1.from.distance(to: $1.to)
            }.prefix(2))
        }
        for (index, connection) in trip.bikeConnections where walks.indices.contains(index) && !walks[index].internalTransfer {
            walks[index].bike = BikeLeg(connection)
        }
        let aligned = trip.withEndpointDistances(access: walks[0].from.distance(to: walks[0].to),
            egress: walks.last!.from.distance(to: walks.last!.to))
        return JourneyOption(id: aligned.id, trip: aligned, walks: walks)
    }
    func plan(metadata: TransitMetadata) {
        defer { onNavigationChange?() }
        durationCache.removeAll(keepingCapacity: true)
        lastMetadata = metadata; selectionConfirmed = false; selectionChosen = false
        cancelRequests()
        hadTemporaryStreetFailure = false
        JourneyDiagnostics.shared.record("plan_start")
        planBegan = ProcessInfo.processInfo.systemUptime; recordedFirstChoice = false; optionReasons = [:]
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
            guard let self, !Task.isCancelled, token == generation else { return }
            let observation = latestSnapshot.estimates, departure = clock(Date())
            let stream = AsyncStream<([TransitTrip], Bool)> { continuation in
                let search = Task { [network] in
                    let trips = await network.options(metadata: metadata, from: origin.coordinate, to: destination.coordinate,
                        preferences: preferences, estimates: observation, at: departure, bikeNetwork: bikes, bikeAvailability: supply,
                        onPreliminary: { continuation.yield(($0, false)) })
                    if !Task.isCancelled { continuation.yield((trips, true)) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in search.cancel() }
            }
            var recoveryCandidates: [JourneyOption] = []
            for await (trips, complete) in stream {
            guard !Task.isCancelled, token == generation else { return }
            integratedSearchHasSupply = supply != nil; lastIntegratedBikeSearch = Date(); lastIntegratedSupplyAt = supply?.receivedAt ?? .distantPast
            let date = clock(Date())
            let observations = latestSnapshot.estimates, currentForecast = forecast
            let currentSnapshot = latestSnapshot
            let ordered = await Task.detached(priority: .userInitiated) {
                let departures = Dictionary(uniqueKeysWithValues: trips.map { trip in
                    (trip.id, trip.rides.map { currentForecast.departures(for: $0, metadata: metadata, snapshot: currentSnapshot, at: date) })
                })
                let initialRiding = Dictionary(uniqueKeysWithValues: trips.map { trip in
                    (trip.id, currentForecast.plannedRidingEstimates(trip, metadata: metadata, estimates: observations,
                        walkingDurations: [], preferences: preferences, at: date, departures: departures[trip.id] ?? []).map(\.seconds))
                })
                return TripRanking.recommended(trips, estimates: observations, at: date,
                    preferences: preferences, limit: budget.candidates, ridingDurations: initialRiding, diverse: false,
                    departureOptions: departures)
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
            if !complete { selected = Array(selected.filter { $0.bikeConnections.isEmpty }.prefix(1)) }
            if selected.isEmpty, !complete { selected = Array(ordered.filter { $0.bikeConnections.count <= 1 }.prefix(1)) }
            var pending = selected.filter { trip in !verifiedPool.contains { $0.id == trip.id } }
                .map { option($0, metadata: metadata, origin: origin, destination: destination) }
            connectionBases.merge(Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })) { _, new in new }
            if complete, !verifiedPool.contains(where: { $0.walkingOnly }), origin.coordinate.distance(to: destination.coordinate) <= max(preferences.walkingOnlyMeters, 2_000) {
                pending.insert(JourneyOption(id: "walking", trip: nil,
                    walks: [WalkingLeg(from: origin.coordinate, to: destination.coordinate)]), at: 0)
            }
            if complete, preferredMode == .cycling, !verifiedPool.contains(where: \.bikeOnly),
               let whole = wholeTripBikeChoice(), attemptedBikeConnections.insert(bikeChoiceKey(whole)).inserted {
                pending.insert(whole, at: 0)
            }
            if options.isEmpty { options = Array(pending.prefix(3)); selectedID = nil }
            planning = false; checkingWalks = true
            recoveryCandidates.append(contentsOf: pending)
            if pending.isEmpty || hadTemporaryStreetFailure { continue }
            let cycling = pending.filter(\.cycles)
            attemptedBikeConnections.formUnion(cycling.map(bikeChoiceKey))
            if complete {
                // A quickly checked provisional bus must not spend the comparison
                // reserve before a much better rail or rail+cycling trip is checked.
                let contenders = primaryContenders(pending)
                contenders.forEach(reserveStreets)
                let ids = Set(contenders.map(\.id))
                await verifyConnections(contenders.filter { !$0.cycles }, cycling: contenders.filter(\.cycles),
                    limit: budget.verification, discoverBikes: false, token: token)
                guard token == generation, !Task.isCancelled else { return }
                if !hadTemporaryStreetFailure {
                    let remaining = pending.filter { !ids.contains($0.id) }
                    await verifyConnections(remaining.filter { !$0.cycles }, cycling: remaining.filter(\.cycles),
                        limit: budget.verification, token: token)
                }
            } else {
                await verifyConnections(pending.filter { !$0.cycles }, cycling: cycling,
                    limit: budget.verification, discoverBikes: false, token: token)
            }
            guard token == generation, !Task.isCancelled else { return }
            }
            guard token == generation, !Task.isCancelled else { return }
            planning = false
            var recoveryIDs = Set<String>()
            let pending = recoveryCandidates.filter { recoveryIDs.insert($0.id).inserted }
            let cycling = pending.filter(\.cycles)
            startAlternativeTransit(from: origin.coordinate, to: destination.coordinate, token: token)
            // A provider interruption is not a proof that every street connection
            // is absent. Retain confirmed legs and retry a small leading set once.
            if hadTemporaryStreetFailure {
                JourneyDiagnostics.shared.record("plan_recover_temporary_service")
                do { try await Task.sleep(for:.seconds(2)) } catch { return }
                guard token == generation, !Task.isCancelled else { return }
                let recovery = primaryContenders(pending.filter { candidate in !verifiedPool.contains { $0.id == candidate.id } })
                recovery.forEach(reserveStreets)
                await verifyConnections(recovery.filter { !$0.cycles }, cycling:recovery.filter(\.cycles),
                    limit:budget.verification,discoverBikes:false,token:token)
                guard token == generation, !Task.isCancelled else { return }
            }
            await refineLeadingEntrances(token: token)
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
        defer { onNavigationChange?() }
        // A row can still receive its tap while a fresh recommendation removes it
        // from the compact list. Resolve the checked choice and retain it before
        // changing selection; never leave selectedID pointing at an absent option.
        guard let current = verifiedPool.first(where: { $0.id == option.id }) ?? options.first(where: { $0.id == option.id }),
              current.verified, current.walkIssue == nil, unavailableBoarding(current) == nil else { return }
        if !options.contains(where: { $0.id == current.id }) { options.append(current) }
        selectionConfirmed = true; selectionChosen = true
        comparisonChanged = current.id != options.first?.id
        guard selectedID != current.id else { return }
        endWalkingGuidance()
        selectedID = current.id; started = false; stepIndex = 0; mapRevision += 1
    }
    /// Once a usable card has appeared, later results may improve the list but cannot
    /// replace its Go button or map underneath the reader's finger.
    func retainVisiblePreview() {
        guard !started, let selected, selected.verified, selected.walkIssue == nil else { return }
        selectionConfirmed = true
    }
    private func enrich(_ option: JourneyOption, compareStations: Bool = false) async throws -> JourneyOption {
        var result = option
        var checked: [Int: WalkingLeg] = [:]
        // Reserve both street slots for the leading choice's two ends. A second
        // option no longer delays its first usable door-to-door result.
        if !option.cycles, verifiedPool.isEmpty {
            try await withThrowingTaskGroup(of: (Int, WalkingLeg).self) { group in
                for index in option.walks.indices.filter({ !option.walks[$0].internalTransfer }).prefix(2) {
                    group.addTask { [self] in (index, try await checkedWalk(option.walks[index])) }
                }
                for try await (index, leg) in group { checked[index] = leg }
            }
        }
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
            if let leg = checked[index] { result.walks[index] = leg }
            else { result.walks[index] = try await checkedWalk(option.walks[index]) }
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
    func checkedWalk(_ leg: WalkingLeg) async throws -> WalkingLeg {
        func finish(_ path: WalkingLeg, requested: WalkingLeg) -> WalkingLeg {
            var result = path
            result.stationSeconds = requested.stationSeconds; result.stationInstruction = requested.stationInstruction
            result.minimumDuration = requested.minimumDuration; result.entranceAlternatives = requested.entranceAlternatives
            result.streetDuration = path.duration
            if let seconds = path.duration { result.duration = max(requested.minimumDuration, seconds + requested.stationSeconds) }
            return result
        }
        let initial = finish(try await walk(leg), requested: leg)
        guard !initial.verified, !initial.temporaryStreetFailure else { return initial }
        for entry in leg.entranceAlternatives {
            try Task.checkCancellation()
            var candidate = leg; candidate.from = entry.from; candidate.to = entry.to
            candidate.stationInstruction = entry.instruction; candidate.entranceAlternatives = []
            let result = finish(try await walk(candidate), requested: candidate)
            if result.verified || result.temporaryStreetFailure { return result }
        }
        return initial
    }
    private func refineLeadingEntrances(token: UUID) async {
        var remaining = 2
        for original in recommendations(at: Date()).prefix(2) {
            var candidate = original
            for index in original.walks.indices where original.walks[index].bike == nil {
                let leg = candidate.walks[index]
                for entry in leg.entranceAlternatives {
                    guard remaining > 0, !Task.isCancelled, token == generation, !started, !selectionConfirmed else { return }
                    remaining -= 1
                    var alternate = leg; alternate.from = entry.from; alternate.to = entry.to
                    alternate.stationInstruction = entry.instruction; alternate.entranceAlternatives = []
                    guard let checked = try? await checkedWalk(alternate), !checked.temporaryStreetFailure else { return }
                    if checked.verified, (checked.duration ?? .infinity) + 15 < (candidate.walks[index].duration ?? .infinity) {
                        candidate.walks[index] = checked
                    }
                }
            }
            guard token == generation, !Task.isCancelled, !started, !selectionConfirmed else { return }
            if candidate.walks.map(\.to) != original.walks.map(\.to) || candidate.walks.map(\.from) != original.walks.map(\.from) {
                verifiedPool.removeAll { $0.id == candidate.id }; verifiedPool.append(candidate)
                publishRecommendations(); if selectedID == candidate.id { mapRevision += 1 }
            }
        }
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
        var interrupted = false
        for pair in pairs where seen.insert(BikeRouting.pairID(pair)).inserted {
            try Task.checkCancellation()
            // A direct test of the provider can omit live supply. Offered journeys cannot.
            if !bikeNetwork.stations.isEmpty &&
                (!BikeRouting.confirmed(pair.pickup, availability: bikeAvailability, renting: true) ||
                 !BikeRouting.confirmed(pair.dropoff, availability: bikeAvailability, renting: false)) { continue }
            guard let result = try? await verifyPair(leg, connection: pair) else { continue }
            if result.temporaryStreetFailure { interrupted = true; break }
            guard result.verified, let bike = result.bike else { continue }
            let risk = bikeNetwork.stations.isEmpty ? 0 : BikeRouting.supplyPenalty(bike.connection,
                availability: bikeAvailability, pickupAfter: leg.plannedStartAfter)
            let cost = (result.duration ?? .infinity) + bike.walkingSeconds * max(0, preferences.walkingWeight - 1 + 0.35) + risk
            if cost < bestCost { best = result; bestCost = cost }
        }
        if let best { return best }
        var unresolved = leg; unresolved.duration = nil; unresolved.temporaryStreetFailure = interrupted; return unresolved
    }
    private func verifyPair(_ leg: WalkingLeg, connection: BikeConnection) async throws -> WalkingLeg {
        var bike = BikeLeg(connection), result = leg
        let access = try await walk(WalkingLeg(from: leg.from, to: bike.pickup.coordinate))
        guard access.verified else { result.duration = nil; result.temporaryStreetFailure = access.temporaryStreetFailure; return result }
        let street = try await walk(WalkingLeg(from: bike.pickup.coordinate, to: bike.dropoff.coordinate), transport: .cycling)
        guard street.verified else { result.duration = nil; result.temporaryStreetFailure = street.temporaryStreetFailure; return result }
        let egress = try await walk(WalkingLeg(from: bike.dropoff.coordinate, to: leg.to))
        guard egress.verified else { result.duration = nil; result.temporaryStreetFailure = egress.temporaryStreetFailure; return result }
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
    /// Comparison remains integrated in one menu. These distinct contenders only
    /// decide which real streets to check first, before optional platform variants.
    private func primaryContenders(_ choices: [JourneyOption]) -> [JourneyOption] {
        let rail = choices.filter { $0.rides.contains { $0.route.mode != .bus } }
        var ids = Set<String>(), result: [JourneyOption] = []
        for choice in [choices.first, rail.first(where: { !$0.cycles }), rail.first(where: \.cycles),
                       choices.first(where: { !$0.rides.isEmpty && $0.rides.allSatisfy { $0.route.mode == .bus } })] {
            if let choice, ids.insert(choice.id).inserted { result.append(choice) }
            if result.count == 3 { break }
        }
        return result
    }
    private func streetKey(_ leg: WalkingLeg, transport: MKDirectionsTransportType) -> String {
        "\(transport.rawValue):\(leg.from.latitude):\(leg.from.longitude):\(leg.to.latitude):\(leg.to.longitude):\(AppLanguage.current.rawValue)"
    }
    private func reserveStreets(_ choice: JourneyOption) {
        guard !evaluatingRemainingJourney else { return }
        func reserve(_ from: Coordinate, _ to: Coordinate, _ mode: MKDirectionsTransportType = .walking) {
            primaryStreetKeys.insert(streetKey(WalkingLeg(from:from,to:to),transport:mode))
        }
        for leg in choice.walks where !leg.internalTransfer {
            if let bike = leg.bike {
                reserve(leg.from,bike.pickup.coordinate)
                reserve(bike.pickup.coordinate,bike.dropoff.coordinate,.cycling)
                reserve(bike.dropoff.coordinate,leg.to)
            } else {
                reserve(leg.from,leg.to)
                for entrance in leg.entranceAlternatives { reserve(entrance.from,entrance.to) }
            }
        }
    }
    private func walk(_ leg: WalkingLeg, guidance: Bool = false, transport: MKDirectionsTransportType = .walking) async throws -> WalkingLeg {
        let cacheKey = streetKey(leg, transport: transport)
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
            let primary = !evaluatingRemainingJourney && primaryStreetKeys.contains(streetKey(leg, transport: transport))
            let priority: DirectionsRequestGate.Priority = guidance || changingBikeStation ? .navigation :
                primary ? .firstChoice : evaluatingRemainingJourney || ready ? .alternatives : .firstChoice
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
        guard scheduledDeparture == nil, let option = selected, canUse(option) else { return }
        defer { onNavigationChange?() }
        cancelRequests()
        started = true; stepIndex = 0; mapRevision += 1
        Haptics.stage()
    }
    /// A separate planner may evaluate the remaining journey without changing the active
    /// planner's selection, map, walking progress or boarded vehicle.
    func resolveRemaining(metadata: TransitMetadata, from start: TravelPlace, to end: TravelPlace,
                          settings: LiveSettings, snapshot: TransitSnapshot, forecast: VehicleArrivalForecast,
                          bikes: BikeNetwork, availability: BikeAvailability?, cacheFrom: JourneyPlannerModel,
                          maximumWait: Double = 18) async -> JourneyOption? {
        cancelRequests(); origin = start; destination = end; usingLocation = false
        preferences = settings.planning; receivedSnapshot = snapshot; self.forecast = forecast
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
        defer { onNavigationChange?() }
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
        defer { onNavigationChange?() }
        stepIndex += 1; mapRevision += 1
        if arrived { Haptics.arrived() } else { Haptics.stage() }
    }
    func boardCurrentRide() {
        guard let index = boardingRideIndex,
              let target = steps.firstIndex(of: .ride(index)) else { return }
        defer { onNavigationChange?() }
        cancelRequests()
        started = true; stepIndex = target; mapRevision += 1
        Haptics.stage()
    }
    func returnToWaiting() {
        guard case .ride(let index) = currentStep,
              let target = steps.firstIndex(of: .walk(index)) else { return }
        defer { onNavigationChange?() }
        started = true; stepIndex = target; mapRevision += 1
    }
    func finish() {
        defer { onNavigationChange?() }
        cancelRequests(); started = false; destination = nil; options = []; selectedID = nil; message = nil; stepIndex = 0; mapRevision += 1
        preferredMode = .any; scheduledDeparture = nil; arrivalDeadline = nil; constraints = TripConstraints(); constraintsUnmet = false
        verifiedPool = []; connectionBases = [:]; attemptedBikeConnections = []; searchedBikeGateways = false; comparisonChanged = false; optionLabels = [:]
        integratedSearchHasSupply = false; lastIntegratedBikeSearch = .distantPast; lastIntegratedSupplyAt = .distantPast; stationRefinements = [:]
    }
    func openAppleTransit() {
        guard let destination else { return }
        let source = origin?.mapItem ?? MKMapItem.forCurrentLocation()
        MKMapItem.openMaps(with: [source, destination.mapItem], launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
    }
    func unavailableBoarding(_ option: JourneyOption, at suppliedDate: Date = Date()) -> (route: String, status: Int)? {
        let date = clock(suppliedDate)
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
        primaryStreetKeys = []
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
    func auditRefineEntrances() async { await refineLeadingEntrances(token: generation) }
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
    /// A late verification result arriving after Go, without the generation guard of a search.
    func auditLoadAdditionalChoicesWhileNavigating(_ choices: [JourneyOption]) {
        verifiedPool.append(contentsOf: choices); publishRecommendations()
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
        if ProcessInfo.processInfo.arguments.contains("--preview-access-walk") {
            let board = first.boarding.coordinate
            let start = Coordinate(latitude:board.latitude-0.003,longitude:board.longitude)
            walks[0] = WalkingLeg(from:start,to:board,coordinates:[start,board],distance:start.distance(to:board),duration:300)
            origin = TravelPlace(name:"目前位置",address:"",coordinate:start,englishName:"Current location")
        }
        options = [JourneyOption(id: trip.id, trip: trip, walks: walks)]
        selectedID = trip.id; message = nil; mapRevision += 1
    }
#endif
}

extension TripConstraints {
    func allows(_ option: JourneyOption) -> Bool {
        if avoidBike, option.cycles { return false }
        for ride in option.rides {
            if avoidBus, ride.route.mode == .bus { return false }
            if avoidMetro, ride.route.mode != .bus { return false }
            if avoidRoutes.contains(where: { Self.route(ride.route.name, isCalled: $0) }) { return false }
        }
        return true
    }
}
