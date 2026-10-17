import Foundation

/// A bicycle connects the rider to transit. Longer or repeated rentals remain
/// inspectable alternatives, rather than displacing a practical transit journey.
public enum TransitBikePolicy {
    public static let maximumFeederMeters = 2_000.0
    public static let maximumFeederRideSeconds = 600.0
    /// Candidate distances are conservative detours. Keep some room until real
    /// cycling directions replace them; only verified legs decide recommendation.
    public static let maximumFeederSearchMeters = 2_500.0
    public static func feederPreferences(_ source: LiveSettings.Planning) -> LiveSettings.Planning {
        var value = source
        value.bikeMaximumRideMeters = min(value.bikeMaximumRideMeters,maximumFeederSearchMeters)
        return value
    }
    public static func isLocalFeeder(_ connection: BikeConnection) -> Bool {
        connection.rideMeters.isFinite && connection.rideSeconds.isFinite &&
            connection.rideMeters <= maximumFeederMeters && connection.rideSeconds <= maximumFeederRideSeconds
    }
    public static func isFeederCandidate(_ connection: BikeConnection) -> Bool {
        connection.rideMeters.isFinite && connection.rideSeconds.isFinite &&
            connection.rideMeters <= 3_000 && connection.rideSeconds <= 900
    }
    public static func isTransitLed(transitSeconds: Double, rideSeconds: [Double], rideMeters: [Double]) -> Bool {
        if rideSeconds.isEmpty { return true }
        guard rideSeconds.count == 1, rideSeconds.count == rideMeters.count,
              transitSeconds.isFinite, transitSeconds > 0,
              rideSeconds.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= maximumFeederRideSeconds }),
              rideMeters.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= maximumFeederMeters }) else { return false }
        return rideSeconds.reduce(0,+) <= max(300,transitSeconds)
    }
}

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
    public let transitLed: Bool
    public init(id: String, group: String, elapsed: Double, walking: Double, waiting: Double,
                transfers: Int, rentals: Int, unknownWaits: Int, supplyRisk: Double = 0,
                preferences: LiveSettings.Planning = .init(), transitLed: Bool = true) {
        self.id = id; self.group = group; self.elapsed = elapsed; self.walking = walking
        self.transfers = transfers; self.rentals = rentals; self.unknownWaits = unknownWaits; self.supplyRisk = supplyRisk
        self.transitLed = transitLed
        score = JourneyPreferenceCost.score(elapsed: elapsed, walking: walking, waiting: waiting,
            transfers: transfers, rentals: rentals, unknownWaits: unknownWaits, supplyRisk: supplyRisk, preferences: preferences)
    }
}

public enum JourneyChoiceRanking {
    public static func reason(for choice: JourneyChoice, comparedTo other: JourneyChoice) -> String? {
        let extra = choice.elapsed - other.elapsed
        if choice.transfers < other.transfers {
            if extra > 90, extra <= 300 {
                if AppLanguage.current == .english, other.transfers-choice.transfers == 1 {
                    return AppText.text("多花 %@ 分，少一次轉乘", Int(ceil(extra/60)))
                }
                return AppText.text("多花 %@ 分，少轉乘 %@ 次", Int(ceil(extra / 60)), other.transfers - choice.transfers)
            }
            if AppLanguage.current == .english, other.transfers-choice.transfers == 1 { return AppText.text("少一次轉乘") }
            return AppText.text("少轉乘 %@ 次", other.transfers - choice.transfers)
        }
        if choice.rentals == 1, other.rentals > 1 { return AppText.text("只需借還一次") }
        if choice.rentals == 0, other.rentals > 0 { return AppText.text("不用借還車") }
        let foot = other.walking - choice.walking
        if foot >= 120 { return AppText.text("少走 %@ 分", Int((foot / 60).rounded())) }
        if extra <= -120 { return AppText.text("快約 %@ 分", Int((-extra / 60).rounded())) }
        return nil
    }
    /// Preserve meaningful time/effort/reliability tradeoffs across every travel mode.
    public static func recommended(_ choices: [JourneyChoice]) -> [String] {
        let ordered = choices.filter { $0.score.isFinite && $0.elapsed.isFinite && $0.elapsed >= 0 }.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.elapsed != $1.elapsed { return $0.elapsed < $1.elapsed }
            return $0.id < $1.id
        }
        guard let best = ordered.first(where: \.transitLed) ?? ordered.first else { return [] }
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
        if fastest.transitLed, fastest.elapsed < best.elapsed - 60 { append(fastest) }
        let transit = reasonable.filter(\.transitLed)
        append(transit.min { $0.walking < $1.walking })
        append(transit.min { $0.transfers < $1.transfers })
        append(transit.min { $0.rentals < $1.rentals })
        for choice in transit { append(choice) }
        if !fastest.transitLed, fastest.elapsed < best.elapsed - 60 { append(fastest) }
        for choice in reasonable where !choice.transitLed { append(choice) }
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
        buffers(rides: trip.rides, walking: walking, transferDistances: trip.transferDistances, ridingSpreads: ridingSpreads)
    }
    public static func buffers(rides: [TransitRide], walking: [Double], transferDistances: [Double], ridingSpreads: [Double] = []) -> [Double] {
        rides.indices.map { index in
            let previous = index > 0 ? rides[index - 1] : nil
            let ride = rides[index]
            let internalWalk = index > 0 && previous?.route.mode != .bus && ride.route.mode != .bus &&
                transferDistances.indices.contains(index - 1) && transferDistances[index - 1] < 1
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
        labels = cycling ? 6 : 4
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
