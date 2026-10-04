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
                              at date: Date = Date(), serviceTimeOfDay: Double? = nil) -> TripAssessment {
        precondition(walking.count == riding.count + 1 && arrivals.count == riding.count)
        let walks = walking.map { max(0, $0) }
        var elapsed = 0.0, lower = 0.0, upper = 0.0, waiting = 0.0, unknown = 0, missed = false
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
            waits.append(result)
            let wait = max(0, result.seconds + ready - elapsed)
            elapsed += wait + max(0, riding[index]); waiting += wait
            lower += result.lowerSeconds + max(0, riding[index])
            upper += result.upperSeconds + max(0, riding[index])
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
            lowerSeconds: min(lower, elapsed), upperSeconds: max(upper, elapsed), referenceDate: date)
    }

    public static func assessment(_ trip: TransitTrip, estimates: EstimateFeed, at date: Date,
                                  preferences: LiveSettings.Planning = .init(),
                                  walkingDurations: [Double?]? = nil, ridingDurations: [Double]? = nil) -> TripAssessment {
        let distances = [trip.accessDistance] + (trip.transfers > 0 ? [trip.transferDistance] : []) + [trip.egressDistance]
        let walking = distances.enumerated().map { index, distance -> Double in
            if let durations = walkingDurations, durations.indices.contains(index), let seconds = durations[index] { return seconds }
            return distance * 1.25 / 1.2
        }
        return assess(riding: ridingDurations ?? trip.rideSeconds, walking: walking,
            arrivals: trip.rides.map { estimates.value(routeID: $0.route.parentID, stopID: $0.boarding.id, at: date) },
            preferences: preferences, minimumServiceWaits: trip.rides.map {
                $0.route.minimumServiceWait(direction: $0.direction, at: date, fullRouteSeconds: $0.fullRouteSeconds)
            }, services: trip.rides.map { $0.route.servicePlans[$0.direction]?.service(at: date) },
            boardingOffsets: trip.rides.map(\.boardingOffsetSeconds), at: date)
    }

    /// Reserve one usable direct alternative, even when several transfers have lower scores.
    public static func recommended(_ trips: [TransitTrip], estimates: EstimateFeed, at date: Date,
                                   preferences: LiveSettings.Planning = .init(), limit: Int = 3,
                                   walkingDurations: [String: [Double?]] = [:],
                                   ridingDurations: [String: [Double]] = [:], diverse: Bool = true) -> [TransitTrip] {
        guard limit > 0 else { return [] }
        let scores = Dictionary(uniqueKeysWithValues: trips.map { trip in
            (trip.id, assessment(trip, estimates: estimates, at: date, preferences: preferences,
                walkingDurations: walkingDurations[trip.id], ridingDurations: ridingDurations[trip.id]))
        })
        let ordered = trips.filter { scores[$0.id]?.unavailable == false }.sorted {
            let a = scores[$0.id]!.score, b = scores[$1.id]!.score
            if a != b { return a < b }
            if $0.transfers != $1.transfers { return $0.transfers < $1.transfers }
            return $0.id < $1.id
        }
        guard diverse, limit <= 4, let best = ordered.first else { return Array(ordered.prefix(limit)) }
        // Keep useful trade-offs, then collapse the same bus chain only after walking is verified.
        let frontier = ordered.filter { candidate in
            let a = scores[candidate.id]!
            return !ordered.contains { other in
                guard other.id != candidate.id else { return false }
                let b = scores[other.id]!
                return b.elapsedSeconds <= a.elapsedSeconds && b.walkingSeconds <= a.walkingSeconds &&
                    other.transfers <= candidate.transfers && b.unknownWaits <= a.unknownWaits &&
                    (b.elapsedSeconds < a.elapsedSeconds - 30 || b.walkingSeconds < a.walkingSeconds - 30 || other.transfers < candidate.transfers)
            }
        }
        let fastest = ordered.min { scores[$0.id]!.elapsedSeconds < scores[$1.id]!.elapsedSeconds }!
        var result = [best]
        func append(_ candidate: TransitTrip?) {
            guard let candidate, result.count < limit,
                  !result.contains(where: { $0.id == candidate.id || $0.familyID == candidate.familyID }) else { return }
            result.append(candidate)
        }
        if scores[fastest.id]!.elapsedSeconds < scores[best.id]!.elapsedSeconds - 60 { append(fastest) }
        let reasonable = frontier.filter { scores[$0.id]!.elapsedSeconds <= scores[fastest.id]!.elapsedSeconds + 900 }
        append(reasonable.min { scores[$0.id]!.walkingSeconds < scores[$1.id]!.walkingSeconds })
        append(reasonable.first { $0.transfers == 0 })
        for trip in frontier { append(trip) }
        for trip in ordered { append(trip) }
        return result
    }
}
