import Foundation

/// Where a train placed only by platform sightings is expected to be: the last station it was
/// seen entering and when it should leave, projected on official running and dwell times.
public struct MetroTrainPlan: Codable, Equatable, Sendable {
    /// Pattern index of the last sighted station.
    public let stationIndex: Int
    public let arrivedAt: Date
    public let departure: Date
    public let lastSeen: Date
    /// Where the train was already drawn when this plan replaced an older one (station index plus
    /// progress). The train waits there rather than moving backwards until the plan catches up.
    public var floor: Double? = nil
    public var floorAt: Date? = nil
    /// Position as a single number along the pattern: station index plus progress to the next.
    public static func position(_ state: MetroTrainState) -> Double {
        Double(state.previousIndex) + (state.atPlatform ? 0 : state.progress)
    }
}

/// A train's live state, the same shape for an official report and a sighting-based plan.
public struct MetroTrainState: Equatable, Sendable {
    /// Pattern index of the station behind the train (or the platform it stands at).
    public let previousIndex: Int
    /// Pattern index of the next station the train will stop at.
    public let nextIndex: Int
    /// 0 at the previous station, 1 at the next one.
    public let progress: Double
    public let secondsToNext: Double
    public let atPlatform: Bool
    /// Waiting for a new sighting instead of advancing on a guess.
    public let holding: Bool
}

public enum MetroTrainTimeline {
    /// At most this many stations are passed on running times alone before the train waits
    /// for its next sighting. The open feed lists most trains at nearly every station.
    public static let coastStations = 2
    /// A held train that is not seen again is dropped instead of drawn somewhere it is not.
    public static let holdSeconds: Double = 150
    public static let originLayover: Double = 8 * 60
    /// A train stays listed while it is at the platform; across ten minutes of live data the next
    /// station's first listing came a median 25 s plus the running time after the last listing.
    public static let departAfterLastListing: Double = 25
    public static func dwell(_ pattern: MetroPattern, _ index: Int) -> Double {
        pattern.dwellSeconds.indices.contains(index) && pattern.dwellSeconds[index] > 0 ? pattern.dwellSeconds[index] : 25
    }
    public static func run(_ pattern: MetroPattern, _ index: Int) -> Double {
        pattern.seconds.indices.contains(index) && pattern.seconds[index] > 0 ? pattern.seconds[index] : 90
    }

    public static func state(_ plan: MetroTrainPlan, pattern: MetroPattern, at date: Date) -> MetroTrainState? {
        guard let state = rawState(plan, pattern: pattern, at: date) else { return nil }
        guard let floor = plan.floor, MetroTrainPlan.position(state) < floor - 0.0001 else { return state }
        // A correction never runs the train backwards. Standing at a platform it simply waits
        // there; between stations it slows down to reach the next station when the plan does.
        let index = min(pattern.stationIDs.count - 1, max(0, Int(floor)))
        let start = floor - Double(index)
        let next = min(pattern.stationIDs.count - 1, index + 1)
        guard start > 0, next > index, let remaining = secondsUntil(next, state: state, pattern: pattern) else {
            return MetroTrainState(previousIndex: index, nextIndex: next, progress: 0,
                                   secondsToNext: secondsUntil(next, state: state, pattern: pattern) ?? state.secondsToNext,
                                   atPlatform: true, holding: false)
        }
        let elapsed = max(0, date.timeIntervalSince(plan.floorAt ?? date))
        let progress = start + (1 - start) * (elapsed + remaining > 0 ? elapsed / (elapsed + remaining) : 1)
        return MetroTrainState(previousIndex: index, nextIndex: next, progress: min(1, progress), secondsToNext: remaining,
                               atPlatform: false, holding: false)
    }
    static func rawState(_ plan: MetroTrainPlan, pattern: MetroPattern, at date: Date) -> MetroTrainState? {
        let last = pattern.stationIDs.count - 1
        guard pattern.stationIDs.indices.contains(plan.stationIndex), date.timeIntervalSince(plan.lastSeen) <= MetroPlatformFeed.memory else { return nil }
        var index = plan.stationIndex, leave = plan.departure
        if index == 0 {
            // At its origin a train lays over for an unknown time: it waits there until seen leaving.
            guard date.timeIntervalSince(plan.lastSeen) <= originLayover else { return nil }
            return MetroTrainState(previousIndex: 0, nextIndex: min(last, 1), progress: 0, secondsToNext: 0, atPlatform: true, holding: true)
        }
        if index == last {
            guard date.timeIntervalSince(plan.lastSeen) <= 90 else { return nil }
            return MetroTrainState(previousIndex: last, nextIndex: last, progress: 0, secondsToNext: 0, atPlatform: true, holding: false)
        }
        while true {
            if date < leave {
                return MetroTrainState(previousIndex: index, nextIndex: index + 1, progress: 0,
                    secondsToNext: leave.timeIntervalSince(date) + run(pattern, index), atPlatform: true, holding: false)
            }
            let arrive = leave.addingTimeInterval(run(pattern, index))
            if date < arrive {
                let duration = run(pattern, index)
                return MetroTrainState(previousIndex: index, nextIndex: index + 1,
                    progress: max(0, min(1, 1 - arrive.timeIntervalSince(date) / duration)),
                    secondsToNext: arrive.timeIntervalSince(date), atPlatform: false, holding: false)
            }
            index += 1
            if index == last || index - plan.stationIndex >= coastStations {
                guard date.timeIntervalSince(arrive) <= (index == last ? 90 : holdSeconds) else { return nil }
                return MetroTrainState(previousIndex: index, nextIndex: min(last, index + 1), progress: 0,
                    secondsToNext: 0, atPlatform: true, holding: index != last)
            }
            leave = arrive.addingTimeInterval(dwell(pattern, index))
        }
    }

    /// Seconds until the train stops at `stationIndex`, nil once it has left it. A train standing
    /// at that platform returns 0.
    public static func secondsUntil(_ stationIndex: Int, plan: MetroTrainPlan, pattern: MetroPattern, at date: Date) -> Double? {
        state(plan, pattern: pattern, at: date).flatMap { secondsUntil(stationIndex, state: $0, pattern: pattern) }
    }
    public static func secondsUntil(_ stationIndex: Int, state: MetroTrainState, pattern: MetroPattern) -> Double? {
        // Holding is a lost observation, not evidence that the train reached this station.
        guard !state.holding else { return nil }
        if state.atPlatform, state.previousIndex == stationIndex { return 0 }
        guard stationIndex > state.previousIndex, stationIndex < pattern.stationIDs.count else { return nil }
        var total: Double, from: Int
        if state.holding || state.nextIndex == state.previousIndex {
            // Standing at a platform with no departure time yet: it still has to dwell and leave.
            total = dwell(pattern, state.previousIndex) + run(pattern, state.previousIndex); from = state.previousIndex + 1
        } else {
            total = state.secondsToNext; from = state.nextIndex
        }
        for index in from..<stationIndex { total += dwell(pattern, index) + run(pattern, index) }
        return total
    }
}

/// Turns anonymous "train entering station" sightings into trains that keep an identity: a new
/// sighting continues the train that should have reached that station by then. The identity is
/// the app's own, never an operator train number, and is labelled as an estimate.
public struct MetroTrainTracker: Sendable {
    public struct Track: Equatable, Sendable {
        public let id: String
        public let patternID: String
        public let direction: String
        public var plan: MetroTrainPlan
        public var sightings: Int
    }
    public private(set) var tracks: [Track] = []
    /// Recently lost trains can be picked up again under the same identity.
    private var lost: [Track] = []
    private var processed: [String: Date] = [:]
    private var counter = 0
    public init() {}

    private static func key(_ event: MetroPlatformEvent) -> String {
        "\(event.patternID)|\(event.direction)|\(event.stationID)|\(event.providerTimestamp ?? String(Int(event.observedAt.timeIntervalSince1970)))"
    }

    public mutating func ingest(_ events: [MetroPlatformEvent], network: MetroNetwork, at date: Date) {
        processed = processed.filter { date.timeIntervalSince($0.value) <= MetroPlatformFeed.memory }
        let fresh = events.filter { processed[Self.key($0)] == nil && date.timeIntervalSince($0.observedAt) <= MetroPlatformFeed.memory }
            .sorted { $0.observedAt < $1.observedAt }
        for event in fresh {
            guard processed[Self.key(event)] == nil else { continue }
            processed[Self.key(event)] = event.observedAt
            guard let pattern = network.pattern(event.patternID, direction: event.direction),
                  let index = pattern.stationIDs.firstIndex(of: event.stationID) else { continue }
            if let slot = bestMatch(event, index: index, pattern: pattern, in: tracks, at: date) {
                tracks[slot] = updated(tracks[slot], event: event, index: index, pattern: pattern, at: date)
            } else if let slot = bestMatch(event, index: index, pattern: pattern, in: lost, revive: true, at: date) {
                tracks.append(updated(lost.remove(at: slot), event: event, index: index, pattern: pattern, at: date, revived: true))
            } else {
                counter += 1
                let arrived = event.observedAt
                tracks.append(Track(id: "est-\(pattern.lineID)-\(event.direction)-\(counter)", patternID: event.patternID,
                    direction: event.direction, plan: MetroTrainPlan(stationIndex: index, arrivedAt: arrived,
                    departure: Self.departure(arrived: arrived, lastSeen: arrived, pattern: pattern, index: index), lastSeen: arrived), sightings: 1))
            }
        }
        prune(network: network, at: date)
    }

    public mutating func prune(network: MetroNetwork, at date: Date) {
        var alive: [Track] = []
        for track in tracks {
            if let pattern = network.pattern(track.patternID, direction: track.direction),
               MetroTrainTimeline.state(track.plan, pattern: pattern, at: date) != nil { alive.append(track) } else { lost.append(track) }
        }
        tracks = alive
        lost = Array(lost.filter { date.timeIntervalSince($0.plan.lastSeen) <= 12 * 60 }.suffix(200))
    }

    static func departure(arrived: Date, lastSeen: Date, pattern: MetroPattern, index: Int) -> Date {
        max(arrived.addingTimeInterval(MetroTrainTimeline.dwell(pattern, index)),
            lastSeen.addingTimeInterval(MetroTrainTimeline.departAfterLastListing))
    }

    private func updated(_ track: Track, event: MetroPlatformEvent, index: Int, pattern: MetroPattern, at date: Date, revived: Bool = false) -> Track {
        var track = track
        let plan = track.plan
        var next: MetroTrainPlan
        if index == plan.stationIndex {
            // Still listed at the platform, so it has not left yet.
            let seen = max(plan.lastSeen, event.observedAt)
            next = MetroTrainPlan(stationIndex: index, arrivedAt: plan.arrivedAt,
                departure: max(plan.departure, Self.departure(arrived: plan.arrivedAt, lastSeen: seen, pattern: pattern, index: index)), lastSeen: seen)
        } else {
            next = MetroTrainPlan(stationIndex: index, arrivedAt: event.observedAt,
                departure: Self.departure(arrived: event.observedAt, lastSeen: event.observedAt, pattern: pattern, index: index), lastSeen: event.observedAt)
        }
        // Where the train is drawn now stays the minimum, so it never visibly backs up.
        if !revived, let shown = MetroTrainTimeline.state(plan, pattern: pattern, at: date),
           let fresh = MetroTrainTimeline.rawState(next, pattern: pattern, at: date),
           MetroTrainPlan.position(fresh) < MetroTrainPlan.position(shown) {
            next.floor = MetroTrainPlan.position(shown); next.floorAt = date
        }
        track.plan = next
        track.sightings += 1
        return track
    }

    /// The train expected at this station at this time: same service, at or behind the station,
    /// and arriving within a tolerance that grows with the distance travelled unseen.
    private func bestMatch(_ event: MetroPlatformEvent, index: Int, pattern: MetroPattern, in list: [Track], revive: Bool = false, at date: Date) -> Int? {
        var best: (slot: Int, score: Double)?
        for (slot, track) in list.enumerated() where track.patternID == event.patternID && track.direction == event.direction {
            let plan = track.plan
            // A train already drawn well past this station is a different train.
            if !revive, let shown = MetroTrainTimeline.state(plan, pattern: pattern, at: date),
               MetroTrainPlan.position(shown) > Double(index) + 1.2 { continue }
            var score: Double
            if index == plan.stationIndex {
                let gap = event.observedAt.timeIntervalSince(plan.lastSeen)
                guard gap > -30, gap <= 90 else { continue }
                score = abs(gap) * 0.25
            } else {
                guard index > plan.stationIndex, index - plan.stationIndex <= (revive ? 8 : 5),
                      event.observedAt > plan.lastSeen else { continue }
                var travel = 0.0
                for hop in plan.stationIndex..<index {
                    travel += MetroTrainTimeline.run(pattern, hop) + (hop > plan.stationIndex ? MetroTrainTimeline.dwell(pattern, hop) : 0)
                }
                let error = event.observedAt.timeIntervalSince(plan.departure.addingTimeInterval(travel))
                // A train seen at its origin leaves whenever its layover ends.
                let late = plan.stationIndex == 0 ? MetroTrainTimeline.originLayover : max(90, travel * 0.5) + 30
                guard error >= -max(45, travel * 0.3), error <= late else { continue }
                // A train cannot pass the one ahead of it on the same track.
                let blocked = list.contains { other in
                    other.id != track.id && other.patternID == track.patternID && other.direction == track.direction &&
                        other.plan.stationIndex > plan.stationIndex && other.plan.stationIndex < index
                }
                if blocked { continue }
                score = (plan.stationIndex == 0 ? max(0, -error) : abs(error)) + Double(index - plan.stationIndex) * 8
            }
            if best.map({ score < $0.score }) ?? true { best = (slot, score) }
        }
        return best?.slot
    }

    /// Reports in the same form an authorized feed would deliver, flagged as estimates.
    public func reports(network: MetroNetwork, at date: Date) -> [MetroTrainReport] {
        tracks.compactMap { track in
            guard let pattern = network.pattern(track.patternID, direction: track.direction),
                  let state = MetroTrainTimeline.state(track.plan, pattern: pattern, at: date),
                  let destination = pattern.stationIDs.last else { return nil }
            let waiting = state.holding || state.nextIndex == state.previousIndex
            return MetroTrainReport(id: track.id, operatorID: "TRTC", patternID: track.patternID, direction: track.direction,
                nextStationID: pattern.stationIDs[waiting ? state.previousIndex : state.nextIndex], destinationStationID: destination,
                remainingSeconds: waiting ? 0 : state.secondsToNext, observedAt: date, atPlatform: waiting, plan: track.plan)
        }
    }
}

/// Track geometry for sighting-based trains, shared by every train on a pattern.
public struct MetroPatternGeometry: Sendable {
    public let line: RouteLine
    public let stationAlong: [Double]
    public let profile: MetroHeightProfile?
    public init?(pattern: MetroPattern, profile: MetroHeightProfile? = nil) {
        self.profile = profile
        let line = RouteLine(coordinates: pattern.coordinates)
        guard line.length > 0 else { return nil }
        var along: [Double] = []
        var floor = 0.0
        for coordinate in pattern.stationCoordinates {
            guard let match = line.match(coordinate, heading: nil, alongRange: floor...line.length)
                    ?? line.candidates(coordinate, maximumDistance: 120).filter({ $0.along >= floor }).min(by: { $0.distance < $1.distance }) else { return nil }
            along.append(match.along); floor = match.along
        }
        self.line = line; stationAlong = along
    }
    /// Trains accelerate out of a station and brake into the next, rather than gliding at constant speed.
    public func along(_ state: MetroTrainState) -> Double {
        guard stationAlong.indices.contains(state.previousIndex), stationAlong.indices.contains(state.nextIndex) else { return 0 }
        let t = max(0, min(1, state.progress))
        let eased = 0.4 * t + 0.6 * t * t * (3 - 2 * t)
        let from = stationAlong[state.previousIndex], to = stationAlong[state.nextIndex]
        return from + (to - from) * eased
    }
    public func height(along: Double) -> Double { profile?.height(at: along) ?? 0 }
    public func sample(along: Double) -> (Coordinate, Double) {
        line.sample(fraction: max(0, min(line.length, along)) / line.length)
    }
}
