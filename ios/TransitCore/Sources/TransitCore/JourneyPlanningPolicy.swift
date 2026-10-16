import Foundation

/// One preference model for transit, direct cycling and walking. These costs never
/// become minutes on an arrival clock.
public enum JourneyPreferenceCost {
    public static func score(elapsed: Double, walking: Double, waiting: Double, transfers: Int,
                             rentals: Int, unknownWaits: Int, supplyRisk: Double = 0,
                             preferences: LiveSettings.Planning = .init()) -> Double {
        guard elapsed.isFinite, walking.isFinite, waiting.isFinite, supplyRisk.isFinite else { return .infinity }
        return max(0, elapsed) + max(0, walking) * max(0, preferences.walkingWeight - 1 + 0.35) +
            max(0, waiting) * (preferences.waitingWeight - 1) +
            Double(max(0, transfers)) * preferences.effectiveTransferPenaltySeconds +
            Double(max(0, rentals)) * TripRanking.rentalConvenienceSeconds +
            Double(max(0, unknownWaits)) * 180 + max(0, supplyRisk)
    }
}

public struct JourneyChoice: Sendable {
    public let id: String
    public let group: String
    public let elapsed: Double
    public let walking: Double
    public let transfers: Int
    public let rentals: Int
    public let unknownWaits: Int
    public let supplyRisk: Double
    public let score: Double
    public init(id: String, group: String, elapsed: Double, walking: Double, waiting: Double,
                transfers: Int, rentals: Int, unknownWaits: Int, supplyRisk: Double = 0,
                preferences: LiveSettings.Planning = .init()) {
        self.id = id; self.group = group; self.elapsed = elapsed; self.walking = walking
        self.transfers = transfers; self.rentals = rentals; self.unknownWaits = unknownWaits; self.supplyRisk = supplyRisk
        score = JourneyPreferenceCost.score(elapsed: elapsed, walking: walking, waiting: waiting,
            transfers: transfers, rentals: rentals, unknownWaits: unknownWaits, supplyRisk: supplyRisk, preferences: preferences)
    }
}

public enum JourneyChoiceRanking {
    /// Preserve meaningful time/effort/reliability tradeoffs across every travel mode.
    public static func recommended(_ choices: [JourneyChoice]) -> [String] {
        let ordered = choices.filter { $0.score.isFinite && $0.elapsed.isFinite && $0.elapsed >= 0 }.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.elapsed != $1.elapsed { return $0.elapsed < $1.elapsed }
            return $0.id < $1.id
        }
        guard let best = ordered.first else { return [] }
        let frontier = ordered.filter { a in
            !ordered.contains { b in
                b.id != a.id && b.elapsed <= a.elapsed && b.walking <= a.walking && b.transfers <= a.transfers &&
                b.rentals <= a.rentals && b.unknownWaits <= a.unknownWaits && b.supplyRisk <= a.supplyRisk &&
                (b.elapsed < a.elapsed - 30 || b.walking < a.walking - 30 || b.transfers < a.transfers ||
                 b.rentals < a.rentals || b.unknownWaits < a.unknownWaits || b.supplyRisk < a.supplyRisk - 30)
            }
        }
        let fastest = ordered.min { $0.elapsed < $1.elapsed }!
        let reasonable = frontier.filter { $0.elapsed <= fastest.elapsed + max(900, fastest.elapsed * 0.3) }
        var result: [JourneyChoice] = []
        func append(_ choice: JourneyChoice?) {
            guard let choice, !result.contains(where: {
                $0.id == choice.id || ($0.group == choice.group && abs($0.elapsed - choice.elapsed) <= 60 &&
                    abs($0.walking - choice.walking) <= 120 && $0.rentals == choice.rentals &&
                    $0.unknownWaits == choice.unknownWaits && abs($0.supplyRisk - choice.supplyRisk) <= 30)
            }) else { return }
            result.append(choice)
        }
        append(best)
        if fastest.elapsed < best.elapsed - 60 { append(fastest) }
        append(reasonable.min { $0.walking < $1.walking })
        append(reasonable.min { $0.transfers < $1.transfers })
        append(reasonable.min { $0.rentals < $1.rentals })
        for choice in reasonable { append(choice) }
        return result.map(\.id)
    }
}

public enum ConnectionTiming {
    /// Station access and the actual transfer walk are already in the route. Only the
    /// boarding margin goes here; it chooses a reachable departure without inventing time.
    public static func buffer(first: Bool, walking: Double, from: TransportMode? = nil,
                              to: TransportMode = .bus, internalTransfer: Bool = false,
                              samePlatform: Bool = false, previousSpread: Double = 0) -> Double {
        if first { return walking < 30 ? 0 : 60 }
        let base: Double = internalTransfer ? (samePlatform ? 30 : 60) : 90
        let uncertainty = previousSpread.isFinite ? min(90, max(0, previousSpread - 60) * 0.5) : 90
        return base + uncertainty
    }
    public static func buffers(for trip: TransitTrip, walking: [Double], ridingSpreads: [Double] = []) -> [Double] {
        trip.rides.indices.map { index in
            let previous = index > 0 ? trip.rides[index - 1] : nil
            let ride = trip.rides[index]
            let internalWalk = index > 0 && previous?.route.mode != .bus && ride.route.mode != .bus &&
                trip.transferDistances.indices.contains(index - 1) && trip.transferDistances[index - 1] < 1
            return buffer(first: index == 0, walking: walking.indices.contains(index) ? walking[index] : 0,
                from: previous?.route.mode, to: ride.route.mode, internalTransfer: internalWalk,
                samePlatform: previous?.alighting.stationID == ride.boarding.stationID,
                previousSpread: index > 0 && ridingSpreads.indices.contains(index - 1) ? ridingSpreads[index - 1] : 0)
        }
    }
}

public struct JourneySearchBudget: Sendable {
    public let candidates: Int
    public let verification: Int
    public let labels: Int
    public init(distance: Double, cycling: Bool) {
        candidates = distance > 10_000 ? 72 : distance > 3_000 || cycling ? 54 : 36
        verification = distance > 10_000 ? 30 : distance > 3_000 || cycling ? 24 : 18
        labels = cycling ? 8 : 6
    }
}

public enum JourneyRevisionPolicy {
    /// A useful improvement, not a stream of one-minute suggestions. An unusable rental
    /// can justify a replacement even when it cannot promise an earlier arrival.
    public static func shouldOffer(current: Double, alternative: Double, currentUsable: Bool) -> Bool {
        guard current.isFinite, alternative.isFinite, current >= 0, alternative > 0 else { return false }
        if !currentUsable { return alternative <= current + 900 }
        return current - alternative >= max(240, current * 0.12)
    }
}
