import Foundation

/// A comparison model, not a timetable or a promised arrival time.
public struct TripAssessment: Sendable {
    public let score: Double
    public let elapsedSeconds: Double
    public let walkingSeconds: Double
    public let waitingSeconds: Double
    public let missedFirstArrival: Bool
    public let uncertainWaits: Int
    public let unavailable: Bool
    public let waits: [BoardingWait]
    public let lowerSeconds: Double
    public let upperSeconds: Double
    /// Arrival range including how much each ride itself may run early or late. The
    /// waiting bounds above stay separate so that waits are not widened by ride time.
    public let earliestSeconds: Double
    public let latestSeconds: Double
    public let referenceDate: Date
    public var unknownWaits: Int { waits.filter { $0.evidence == .unknown }.count }
    public var travelSeconds: Double { elapsedSeconds - waitingSeconds }
}

public enum TripRanking {
    /// A convenience preference only, never added to the displayed travel or arrival time.
    /// A second rental is another decision and another station to depend on.
    public static let rentalConvenienceSeconds = 120.0
    /// Missing headways must carry a waiting cost instead of making a connection free.
    /// These fallback seconds are used for comparison only and never shown as official ETAs.
    public static func assess(riding: [Double], walking: [Double], arrivals: [Int?],
                              preferences: LiveSettings.Planning = .init(), minimumServiceWaits: [Double] = [],
                              services: [BusDayService?] = [], boardingOffsets: [Double] = [],
                              ridingSpreads: [Double] = [],
                              at date: Date = Date(), serviceTimeOfDay: Double? = nil, cyclingSeconds: Double = 0,
                              rentalCount: Int = 0, boardingBuffers: [Double] = [], supplyRisk: Double = 0,
                              departures: [[BoardingDeparture]] = []) -> TripAssessment {
        precondition(walking.count == riding.count + 1 && arrivals.count == riding.count)
        let walks = walking.map { max(0, $0) }
        var elapsed = 0.0, lower = 0.0, upper = 0.0, waiting = 0.0, unknown = 0, missed = false, spread = 0.0
        var waits: [BoardingWait] = []
        let timeOfDay = serviceTimeOfDay ?? BusServiceWindow.secondsOfDay(at: date)
        let unavailable = arrivals.contains { value in value.map { [-2, -3, -4].contains($0) } ?? false }
        for index in riding.indices {
            elapsed += walks[index]
            lower += walks[index]; upper += walks[index]
            let arrival = arrivals[index]
            let buffer = boardingBuffers.indices.contains(index) ? max(0, boardingBuffers[index]) :
                ConnectionTiming.buffer(first: index == 0, walking: walks[index])
            let ready = index > 0 && upper - lower > 120 ? upper : elapsed
            let result = BoardingTime.wait(official: arrival, readyAt: ready, buffer: buffer,
                service: services.indices.contains(index) ? services[index] : nil,
                secondsOfDay: timeOfDay,
                boardingOffset: boardingOffsets.indices.contains(index) ? boardingOffsets[index] : 0,
                minimumServiceWait: minimumServiceWaits.indices.contains(index) ? minimumServiceWaits[index] : 0,
                departures: departures.indices.contains(index) ? departures[index] : [])
            if index == 0 && result.missedNext { missed = true }
            if result.isEstimated { unknown += 1 }
            let before = elapsed, beforeLower = lower, beforeUpper = upper
            let wait = max(0, result.seconds + ready - before)
            let ride = max(0, riding[index])
            let rideSpread = ridingSpreads.indices.contains(index) ? max(0, ridingSpreads[index]) : 0
            // A reachable official departure is anchored to query time. Earlier
            // uncertainty changes how long we wait, not that departure's clock.
            if let departure = result.departureSeconds {
                elapsed = departure + ride
                lower = ready + result.lowerSeconds + ride; upper = ready + result.upperSeconds + ride
                // Catching that departure absorbs how early or late the earlier rides ran.
                spread = rideSpread
            } else if result.evidence == .timetable || result.missedNext {
                spread += rideSpread
                elapsed = ready + result.seconds + ride
                lower = ready + result.lowerSeconds + ride
                upper = ready + result.upperSeconds + ride
            } else {
                spread += rideSpread
                elapsed = ready + result.seconds + ride
                lower = beforeLower + result.lowerSeconds + ride
                upper = ready + result.upperSeconds + ride
            }
            waits.append(BoardingWait(seconds: wait,
                lowerSeconds: max(0, lower - ride - beforeUpper),
                upperSeconds: max(0, upper - ride - beforeLower),
                evidence: result.evidence, missedNext: result.missedNext, departureSeconds: result.departureSeconds))
            waiting += wait
        }
        elapsed += walks.last ?? 0
        lower += walks.last ?? 0; upper += walks.last ?? 0
        let walkingSeconds = walks.reduce(0, +)
        let cycled = cyclingSeconds.isFinite ? min(walkingSeconds, max(0, cyclingSeconds)) : 0
        let score = JourneyPreferenceCost.score(elapsed: elapsed, walking: walkingSeconds - cycled, waiting: waiting,
            transfers: max(0, riding.count - 1), rentals: rentalCount,
            unknownWaits: waits.filter { $0.evidence == .unknown }.count, supplyRisk: supplyRisk, preferences: preferences)
        return TripAssessment(score: unavailable ? .infinity : score, elapsedSeconds: elapsed,
            walkingSeconds: walkingSeconds, waitingSeconds: waiting, missedFirstArrival: missed,
            uncertainWaits: unknown, unavailable: unavailable, waits: waits,
            lowerSeconds: min(lower, elapsed), upperSeconds: max(upper, elapsed),
            earliestSeconds: max(0, min(lower, elapsed) - spread), latestSeconds: max(upper, elapsed) + spread, referenceDate: date)
    }

    public static func assessment(_ trip: TransitTrip, estimates: EstimateFeed, at date: Date,
                                  preferences: LiveSettings.Planning = .init(),
                                  walkingDurations: [Double?]? = nil, ridingDurations: [Double]? = nil,
                                  ridingSpreads: [Double]? = nil, cyclingSeconds: Double? = nil,
                                  rentalCount: Int? = nil, supplyRisk: Double? = nil,
                                  departures: [[BoardingDeparture]] = []) -> TripAssessment {
        let walking = trip.planningWalkSeconds.enumerated().map { index, seconds -> Double in
            if let durations = walkingDurations, durations.indices.contains(index), let seconds = durations[index] { return seconds }
            return seconds
        }
        let spreads = ridingSpreads ?? zip(trip.rides, ridingDurations ?? trip.rideSeconds).map { ride, seconds in
            seconds * (ride.route.mode == .bus ? RidingTimeEstimate.Evidence.officialProfile : .railProfile).spreadFraction
        }
        return assess(riding: ridingDurations ?? trip.rideSeconds, walking: walking,
            arrivals: trip.rides.map { estimates.value(routeID: $0.route.parentID, stopID: $0.boarding.id, at: date) },
            preferences: preferences, minimumServiceWaits: trip.rides.map {
                $0.route.minimumServiceWait(direction: $0.direction, at: date, fullRouteSeconds: $0.fullRouteSeconds)
            }, services: trip.rides.map { $0.railService ?? $0.route.servicePlans[$0.direction]?.service(at: date) },
            boardingOffsets: trip.rides.map(\.boardingOffsetSeconds),
            ridingSpreads: spreads, at: date, cyclingSeconds: cyclingSeconds ?? trip.planningCyclingSeconds,
            rentalCount: rentalCount ?? trip.bikeConnections.count,
            boardingBuffers: ConnectionTiming.buffers(for: trip, walking: walking, ridingSpreads: spreads),
            supplyRisk: supplyRisk ?? trip.planningSupplyRisk, departures: departures)
    }

    /// Keep a reasonable direct alternative alongside meaningful time/walking trade-offs.
    public static func recommended(_ trips: [TransitTrip], estimates: EstimateFeed, at date: Date,
                                   preferences: LiveSettings.Planning = .init(), limit: Int = 3,
                                   walkingDurations: [String: [Double?]] = [:],
                                   ridingDurations: [String: [Double]] = [:], diverse: Bool = true,
                                   cyclingDurations: [String: Double] = [:], rentalCounts: [String: Int] = [:],
                                   choiceGroups: [String: String] = [:],
                                   departureOptions: [String: [[BoardingDeparture]]] = [:]) -> [TransitTrip] {
        guard limit > 0 else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: trips.map { ($0.id, $0) })
        let scores = Dictionary(uniqueKeysWithValues: trips.map { trip in
            (trip.id, assessment(trip, estimates: estimates, at: date, preferences: preferences,
                walkingDurations: walkingDurations[trip.id], ridingDurations: ridingDurations[trip.id],
                cyclingSeconds: cyclingDurations[trip.id],
                rentalCount: rentalCounts[trip.id] ?? (trip.bikeConnections.isEmpty ? ((cyclingDurations[trip.id] ?? 0) > 0 ? 1 : 0) : trip.bikeConnections.count),
                departures: departureOptions[trip.id] ?? []))
        })
        // Connector durations include cycling so departure feasibility and arrival clocks
        // remain correct. Only the preference cost and walking comparison exclude riding.
        func cycling(_ id: String) -> Double {
            let seconds = cyclingDurations[id] ?? byID[id]?.planningCyclingSeconds ?? 0
            return seconds.isFinite ? min(scores[id]!.walkingSeconds, max(0, seconds)) : 0
        }
        func walking(_ id: String) -> Double { scores[id]!.walkingSeconds - cycling(id) }
        let ordered = trips.filter { scores[$0.id]?.unavailable == false }.sorted {
            let a = scores[$0.id]!.score, b = scores[$1.id]!.score
            if a != b { return a < b }
            if $0.transfers != $1.transfers { return $0.transfers < $1.transfers }
            return $0.id < $1.id
        }
        guard diverse, !ordered.isEmpty else { return Array(ordered.prefix(limit)) }
        func rentals(_ id: String) -> Int {
            if let count = rentalCounts[id] { return max(0, count) }
            if let count = byID[id]?.bikeConnections.count, count > 0 { return count }
            return cycling(id) > 0 ? 1 : 0
        }
        func group(_ trip: TransitTrip) -> String { choiceGroups[trip.id] ?? trip.familyID }
        // Keep useful trade-offs, then collapse the same bus chain only after walking is verified.
        let frontier = ordered.filter { candidate in
            let a = scores[candidate.id]!
            return !ordered.contains { other in
                guard other.id != candidate.id else { return false }
                // Requiring a bike (or two rentals) is a real tradeoff, even if it saves time.
                guard rentals(other.id) <= rentals(candidate.id) else { return false }
                let b = scores[other.id]!
                let fewerTransfers = other.transfers < candidate.transfers
                return b.elapsedSeconds <= a.elapsedSeconds + (fewerTransfers ? 60 : 0) &&
                    walking(other.id) <= walking(candidate.id) + (fewerTransfers ? 30 : 0) &&
                    other.transfers <= candidate.transfers && b.unknownWaits <= a.unknownWaits &&
                    (b.elapsedSeconds < a.elapsedSeconds - 30 || walking(other.id) < walking(candidate.id) - 30 || other.transfers < candidate.transfers || rentals(other.id) < rentals(candidate.id))
            }
        }
        let best = frontier.first ?? ordered[0]
        let fastest = (frontier.isEmpty ? ordered : frontier).min { scores[$0.id]!.elapsedSeconds < scores[$1.id]!.elapsedSeconds }!
        var result = [best]
        func append(_ candidate: TransitTrip?) {
            guard let candidate, result.count < limit else { return }
            let duplicate = result.contains { other in
                if other.id == candidate.id { return true }
                guard group(other) == group(candidate) else { return false }
                // Native verified choices may board the same line at meaningfully different
                // stops. Merge only near-equivalent elapsed/walking times in that case.
                guard !choiceGroups.isEmpty else { return true }
                return abs(scores[other.id]!.elapsedSeconds - scores[candidate.id]!.elapsedSeconds) <= 60 &&
                    abs(walking(other.id) - walking(candidate.id)) <= 120
            }
            guard !duplicate else { return }
            result.append(candidate)
        }
        if scores[fastest.id]!.elapsedSeconds < scores[best.id]!.elapsedSeconds - 60 { append(fastest) }
        let reasonable = frontier.filter { scores[$0.id]!.elapsedSeconds <= scores[fastest.id]!.elapsedSeconds + 900 }
        append(reasonable.min { walking($0.id) < walking($1.id) })
        append(reasonable.first { $0.transfers == 0 })
        append(reasonable.min { rentals($0.id) < rentals($1.id) })
        for trip in reasonable { append(trip) }
        return result
    }
}
