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
}

public enum TripRanking {
    /// Missing headways must carry a waiting cost instead of making a connection free.
    /// These fallback seconds are used for comparison only and never shown as official ETAs.
    public static func assess(riding: [Double], walking: [Double], arrivals: [Int?],
                              preferences: LiveSettings.Planning = .init(), minimumServiceWaits: [Double] = []) -> TripAssessment {
        precondition(walking.count == riding.count + 1 && arrivals.count == riding.count)
        let walks = walking.map { max(0, $0) }
        var elapsed = 0.0, waiting = 0.0, unknown = 0, missed = false
        let unavailable = arrivals.contains { value in value.map { [-2, -3, -4].contains($0) } ?? false }
        for index in riding.indices {
            elapsed += walks[index]
            let arrival = arrivals[index]
            let wait: Double
            // A current estimate at a transfer stop only describes a usable connection
            // when it is still ahead of the passenger's estimated arrival at that stop.
            if let arrival, arrival >= 0, Double(arrival) + 30 >= elapsed {
                wait = max(0, Double(arrival) - elapsed)
            } else {
                if index == 0, let arrival, arrival >= 0 { missed = true }
                unknown += 1
                let serviceWait = (arrival == nil || arrival! < 0) && minimumServiceWaits.indices.contains(index) ? max(0, minimumServiceWaits[index] - elapsed) : 0
                wait = max(arrival == -1 ? 900 : 480, serviceWait)
            }
            elapsed += wait + max(0, riding[index]); waiting += wait
        }
        elapsed += walks.last ?? 0
        let walkingSeconds = walks.reduce(0, +)
        let score = elapsed + walkingSeconds * (preferences.walkingWeight - 1) +
            waiting * (preferences.waitingWeight - 1) +
            Double(max(0, riding.count - 1)) * preferences.transferPenaltySeconds + (missed ? 180 : 0)
        return TripAssessment(score: unavailable ? .infinity : score, elapsedSeconds: elapsed,
            walkingSeconds: walkingSeconds, waitingSeconds: waiting, missedFirstArrival: missed,
            uncertainWaits: unknown, unavailable: unavailable)
    }

    public static func assessment(_ trip: TransitTrip, estimates: EstimateFeed, at date: Date,
                                  preferences: LiveSettings.Planning = .init(),
                                  walkingDurations: [Double?]? = nil) -> TripAssessment {
        let distances = [trip.accessDistance] + (trip.transfers > 0 ? [trip.transferDistance] : []) + [trip.egressDistance]
        let walking = distances.enumerated().map { index, distance -> Double in
            if let durations = walkingDurations, durations.indices.contains(index), let seconds = durations[index] { return seconds }
            return distance * 1.25 / 1.2
        }
        return assess(riding: trip.rideSeconds, walking: walking,
            arrivals: trip.rides.map { estimates.value(routeID: $0.route.parentID, stopID: $0.boarding.id, at: date) },
            preferences: preferences, minimumServiceWaits: trip.rides.map {
                $0.route.minimumServiceWait(direction: $0.direction, secondsOfDay: BusServiceWindow.secondsOfDay(at: date), fullRouteSeconds: $0.fullRouteSeconds)
            })
    }

    /// Reserve one usable direct alternative, even when several transfers have lower scores.
    public static func recommended(_ trips: [TransitTrip], estimates: EstimateFeed, at date: Date,
                                   preferences: LiveSettings.Planning = .init(), limit: Int = 3,
                                   walkingDurations: [String: [Double?]] = [:]) -> [TransitTrip] {
        guard limit > 0 else { return [] }
        let scores = Dictionary(uniqueKeysWithValues: trips.map { trip in
            (trip.id, assessment(trip, estimates: estimates, at: date, preferences: preferences,
                walkingDurations: walkingDurations[trip.id]))
        })
        let ordered = trips.filter { scores[$0.id]?.unavailable == false }.sorted {
            let a = scores[$0.id]!.score, b = scores[$1.id]!.score
            if a != b { return a < b }
            if $0.transfers != $1.transfers { return $0.transfers < $1.transfers }
            return $0.id < $1.id
        }
        var result = Array(ordered.prefix(limit))
        if limit >= 2, let direct = ordered.first(where: { $0.transfers == 0 }), !result.contains(where: { $0.id == direct.id }) {
            result[result.count - 1] = direct
        }
        return result
    }
}
