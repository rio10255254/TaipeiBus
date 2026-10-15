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
    /// Missing headways must carry a waiting cost instead of making a connection free.
    /// These fallback seconds are used for comparison only and never shown as official ETAs.
    public static func assess(riding: [Double], walking: [Double], arrivals: [Int?],
                              preferences: LiveSettings.Planning = .init(), minimumServiceWaits: [Double] = [],
                              services: [BusDayService?] = [], boardingOffsets: [Double] = [],
                              ridingSpreads: [Double] = [],
                              at date: Date = Date(), serviceTimeOfDay: Double? = nil) -> TripAssessment {
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
            let buffer = index == 0 ? (walks[index] >= 30 ? 60.0 : 0) : 90.0
            let ready = index > 0 && upper - lower > 120 ? upper : elapsed
            let result = BoardingTime.wait(official: arrival, readyAt: ready, buffer: buffer,
                service: services.indices.contains(index) ? services[index] : nil,
                secondsOfDay: timeOfDay,
                boardingOffset: boardingOffsets.indices.contains(index) ? boardingOffsets[index] : 0,
                minimumServiceWait: minimumServiceWaits.indices.contains(index) ? minimumServiceWaits[index] : 0)
            if index == 0 && result.missedNext { missed = true }
            if result.isEstimated { unknown += 1 }
            let before = elapsed, beforeLower = lower, beforeUpper = upper
            let wait = max(0, result.seconds + ready - before)
            let ride = max(0, riding[index])
            let rideSpread = ridingSpreads.indices.contains(index) ? max(0, ridingSpreads[index]) : 0
            // A reachable official departure is anchored to query time. Earlier
            // uncertainty changes how long we wait, not that departure's clock.
            if result.evidence == .official, let arrival {
                elapsed = Double(arrival) + ride; lower = elapsed; upper = elapsed
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
                evidence: result.evidence, missedNext: result.missedNext))
            waiting += wait
        }
        elapsed += walks.last ?? 0
        lower += walks.last ?? 0; upper += walks.last ?? 0
        let walkingSeconds = walks.reduce(0, +)
        let score = elapsed + walkingSeconds * (preferences.walkingWeight - 1 + 0.35) +
            waiting * (preferences.waitingWeight - 1) +
            Double(max(0, riding.count - 1)) * min(300, preferences.transferPenaltySeconds) +
            Double(waits.filter { $0.evidence == .unknown }.count) * 180
        return TripAssessment(score: unavailable ? .infinity : score, elapsedSeconds: elapsed,
            walkingSeconds: walkingSeconds, waitingSeconds: waiting, missedFirstArrival: missed,
            uncertainWaits: unknown, unavailable: unavailable, waits: waits,
            lowerSeconds: min(lower, elapsed), upperSeconds: max(upper, elapsed),
            earliestSeconds: max(0, min(lower, elapsed) - spread), latestSeconds: max(upper, elapsed) + spread, referenceDate: date)
    }

    public static func assessment(_ trip: TransitTrip, estimates: EstimateFeed, at date: Date,
                                  preferences: LiveSettings.Planning = .init(),
                                  walkingDurations: [Double?]? = nil, ridingDurations: [Double]? = nil,
                                  ridingSpreads: [Double]? = nil) -> TripAssessment {
        let walking = trip.planningWalkSeconds.enumerated().map { index, seconds -> Double in
            if let durations = walkingDurations, durations.indices.contains(index), let seconds = durations[index] { return seconds }
            return seconds
        }
        return assess(riding: ridingDurations ?? trip.rideSeconds, walking: walking,
            arrivals: trip.rides.map { estimates.value(routeID: $0.route.parentID, stopID: $0.boarding.id, at: date) },
            preferences: preferences, minimumServiceWaits: trip.rides.map {
                $0.route.minimumServiceWait(direction: $0.direction, at: date, fullRouteSeconds: $0.fullRouteSeconds)
            }, services: trip.rides.map { $0.railService ?? $0.route.servicePlans[$0.direction]?.service(at: date) },
            boardingOffsets: trip.rides.map(\.boardingOffsetSeconds),
            ridingSpreads: ridingSpreads ?? zip(trip.rides, ridingDurations ?? trip.rideSeconds).map { ride, seconds in
                seconds * (ride.route.mode == .bus ? RidingTimeEstimate.Evidence.officialProfile : .railProfile).spreadFraction
            }, at: date)
    }

    /// Keep a reasonable direct alternative alongside meaningful time/walking trade-offs.
    public static func recommended(_ trips: [TransitTrip], estimates: EstimateFeed, at date: Date,
                                   preferences: LiveSettings.Planning = .init(), limit: Int = 3,
                                   walkingDurations: [String: [Double?]] = [:],
                                   ridingDurations: [String: [Double]] = [:], diverse: Bool = true,
                                   cyclingDurations: [String: Double] = [:]) -> [TransitTrip] {
        guard limit > 0 else { return [] }
        let scores = Dictionary(uniqueKeysWithValues: trips.map { trip in
            (trip.id, assessment(trip, estimates: estimates, at: date, preferences: preferences,
                walkingDurations: walkingDurations[trip.id], ridingDurations: ridingDurations[trip.id]))
        })
        // Connector durations include cycling so departure feasibility and arrival clocks
        // remain correct. Only the preference cost and walking comparison exclude riding.
        func cycling(_ id: String) -> Double {
            let seconds = cyclingDurations[id] ?? 0
            return seconds.isFinite ? min(scores[id]!.walkingSeconds, max(0, seconds)) : 0
        }
        func walking(_ id: String) -> Double { scores[id]!.walkingSeconds - cycling(id) }
        func rankingScore(_ id: String) -> Double {
            scores[id]!.score - cycling(id) * (preferences.walkingWeight - 1 + 0.35)
        }
        let ordered = trips.filter { scores[$0.id]?.unavailable == false }.sorted {
            let a = rankingScore($0.id), b = rankingScore($1.id)
            if a != b { return a < b }
            if $0.transfers != $1.transfers { return $0.transfers < $1.transfers }
            return $0.id < $1.id
        }
        guard diverse, limit <= 4, !ordered.isEmpty else { return Array(ordered.prefix(limit)) }
        // Keep useful trade-offs, then collapse the same bus chain only after walking is verified.
        let frontier = ordered.filter { candidate in
            let a = scores[candidate.id]!
            return !ordered.contains { other in
                guard other.id != candidate.id else { return false }
                let b = scores[other.id]!
                let fewerTransfers = other.transfers < candidate.transfers
                return b.elapsedSeconds <= a.elapsedSeconds + (fewerTransfers ? 60 : 0) &&
                    walking(other.id) <= walking(candidate.id) + (fewerTransfers ? 30 : 0) &&
                    other.transfers <= candidate.transfers && b.unknownWaits <= a.unknownWaits &&
                    (b.elapsedSeconds < a.elapsedSeconds - 30 || walking(other.id) < walking(candidate.id) - 30 || other.transfers < candidate.transfers)
            }
        }
        let best = frontier.first ?? ordered[0]
        let fastest = (frontier.isEmpty ? ordered : frontier).min { scores[$0.id]!.elapsedSeconds < scores[$1.id]!.elapsedSeconds }!
        var result = [best]
        func append(_ candidate: TransitTrip?) {
            guard let candidate, result.count < limit,
                  !result.contains(where: { $0.id == candidate.id || $0.familyID == candidate.familyID }) else { return }
            result.append(candidate)
        }
        if scores[fastest.id]!.elapsedSeconds < scores[best.id]!.elapsedSeconds - 60 { append(fastest) }
        let reasonable = frontier.filter { scores[$0.id]!.elapsedSeconds <= scores[fastest.id]!.elapsedSeconds + 900 }
        append(reasonable.min { walking($0.id) < walking($1.id) })
        append(reasonable.first { $0.transfers == 0 })
        for trip in frontier { append(trip) }
        return result
    }
}
