import Foundation

public enum MetroCountdown {
    public static func label(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        if seconds == 0 { return AppText.text("進站中") }
        if seconds < 60 { return AppText.text("%@ 秒",seconds) }
        return AppText.text("%@ 分 %@ 秒",seconds / 60,seconds % 60)
    }
}

/// The private operator feed is normalized on the server. No account keys are
/// distributed to phones, and station arrival events cannot invent train IDs.
public struct MetroTrainReport: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let operatorID: String
    public let patternID: String
    public let direction: String
    public let nextStationID: String
    public let destinationStationID: String
    public let remainingSeconds: Double
    public let observedAt: Date
    public let atPlatform: Bool
    /// Present only for a train placed by platform sightings rather than an operator report.
    public let plan: MetroTrainPlan?
    public var isEstimated: Bool { plan != nil }
    public init(id: String, operatorID: String, patternID: String, direction: String, nextStationID: String,
                destinationStationID: String, remainingSeconds: Double, observedAt: Date, atPlatform: Bool, plan: MetroTrainPlan? = nil) {
        self.id = id; self.operatorID = operatorID; self.patternID = patternID; self.direction = direction
        self.nextStationID = nextStationID; self.destinationStationID = destinationStationID
        self.remainingSeconds = remainingSeconds; self.observedAt = observedAt; self.atPlatform = atPlatform; self.plan = plan
    }
    /// The live state at `date`, for an operator report (valid for a minute) or a sighting plan.
    public func state(network: MetroNetwork, at date: Date) -> MetroTrainState? {
        guard let pattern = network.pattern(patternID, direction: direction) else { return nil }
        if let plan { return MetroTrainTimeline.state(plan, pattern: pattern, at: date) }
        let age = date.timeIntervalSince(observedAt)
        guard (-15...60).contains(age), let next = pattern.stationIDs.firstIndex(of: nextStationID) else { return nil }
        let remaining = max(0, remainingSeconds - max(0, age))
        if atPlatform || next == 0 {
            return MetroTrainState(previousIndex: next, nextIndex: next, progress: 0, secondsToNext: 0, atPlatform: true, holding: false)
        }
        let duration = MetroTrainTimeline.run(pattern, next - 1)
        return MetroTrainState(previousIndex: next - 1, nextIndex: next, progress: max(0, min(1, 1 - remaining / duration)),
            secondsToNext: remaining, atPlatform: false, holding: false)
    }
}
public struct MetroArrival: Codable, Equatable, Sendable {
    public let stationID: String
    public let patternID: String
    public let direction: String
    public let destinationStationID: String
    public let trainID: String?
    public let seconds: Int
    public let observedAt: Date
    public func remaining(at date: Date) -> Int? {
        let age = date.timeIntervalSince(observedAt)
        guard (-15...75).contains(age), seconds >= 0 else { return nil }
        // The operator timestamp is the countdown anchor, not download time.
        return max(0, seconds - Int(max(0, age)))
    }
}
public struct MetroRealtime: Codable, Equatable, Sendable {
    public let schema: Int
    public let source: String
    public let trains: [MetroTrainReport]
    public let arrivals: [MetroArrival]
    public init(data: Data, network: MetroNetwork, at date: Date) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw FeedError.invalid("Metro feed size") }
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = plain.date(from:text) ?? fractional.date(from:text) else { throw FeedError.invalid("Metro report timestamp") }
            return date
        }
        self = try decoder.decode(Self.self, from: data)
        guard schema == 1, source == "Taipei Metro authorized API", trains.count <= 300, arrivals.count <= 3000,
              Set(trains.map(\.id)).count == trains.count else { throw FeedError.invalid("Metro feed source") }
        for report in trains {
            guard !report.id.isEmpty, report.operatorID == "TRTC", report.plan == nil, report.remainingSeconds.isFinite,
                  (0...1800).contains(report.remainingSeconds),
                  let pattern = network.pattern(report.patternID, direction: report.direction),
                  let next = pattern.stationIDs.firstIndex(of:report.nextStationID),
                  let destination = pattern.stationIDs.firstIndex(of:report.destinationStationID), next <= destination else {
                throw FeedError.invalid("Metro train report")
            }
        }
        for arrival in arrivals {
            guard let pattern = network.pattern(arrival.patternID, direction: arrival.direction),
                  let board = pattern.stationIDs.firstIndex(of: arrival.stationID),
                  let destination = pattern.stationIDs.firstIndex(of: arrival.destinationStationID), destination >= board,
                  (0...7200).contains(arrival.seconds) else { throw FeedError.invalid("Metro arrival report") }
        }
    }
    public func nextArrival(ride: TransitRide, network: MetroNetwork, at date: Date) -> MetroArrival? {
        guard !ride.stops.isEmpty else { return nil }
        return arrivals.filter { a in
            guard a.stationID == ride.boarding.stationID, a.remaining(at: date) != nil else { return false }
            // A short-turn train must actually reach the requested alighting station.
            return network.canServe(ride, patternID: a.patternID, direction: a.direction, destinationStationID: a.destinationStationID)
        }.min { ($0.remaining(at: date) ?? .max) < ($1.remaining(at: date) ?? .max) }
    }
    public func applying(to estimates: EstimateFeed, network: MetroNetwork, at date: Date) -> EstimateFeed {
        let freshBus = estimates.error == nil && estimates.updatedAt.map { (-60...120).contains(date.timeIntervalSince($0)) } == true
        var seconds = freshBus ? estimates.seconds : [:]
        // Re-anchor existing bus estimates to now before mixing independent timestamps.
        for key in seconds.keys {
            if let value = seconds[key], value >= 0, let updated = estimates.updatedAt {
                seconds[key] = max(0, value - Int(max(0, date.timeIntervalSince(updated))))
            }
        }
        for a in arrivals {
            guard let value = a.remaining(at: date), let pattern = network.pattern(a.patternID, direction: a.direction),
                  pattern.stationIDs.contains(a.stationID),
                  let terminal = pattern.stationIDs.firstIndex(of: a.destinationStationID), terminal == pattern.stationIDs.count - 1 else { continue }
            let stopID = "\(a.patternID):\(a.direction):\(a.stationID)"
            let key = "\(pattern.lineID):\(stopID)"
            seconds[key] = min(seconds[key] ?? .max, value)
        }
        return EstimateFeed(seconds: seconds, updatedAt: date)
    }
}

public struct MetroTrainPose: Sendable {
    public let report: MetroTrainReport
    public let coordinate: Coordinate
    public let heading: Double
    public let path: [Coordinate]
    public let seconds: Double
    public let estimatedPosition: Bool
}
public enum MetroTrainProjection {
    /// Official next-station time anchors a bounded estimate on actual track.
    /// Never advance through a station or across a route branch without a new report.
    public static func pose(_ report: MetroTrainReport, network: MetroNetwork, at date: Date) -> MetroTrainPose? {
        PreparedMetroTrain(report: report, network: network)?.pose(at: date)
    }
}

/// Track geometry is prepared only when an operator report changes, never per frame.
public struct PreparedMetroTrain: Sendable {
    public let report: MetroTrainReport
    private let segment: RouteLine
    private let duration: Double
    private let atStart: Bool
    /// Sighting-based trains move along their whole pattern on a timeline instead of one segment.
    private let pattern: MetroPattern?
    private let geometry: MetroPatternGeometry?
    public init?(report: MetroTrainReport, network: MetroNetwork, geometry shared: MetroPatternGeometry? = nil) {
        guard let pattern = network.pattern(report.patternID, direction: report.direction),
              let index = pattern.stationIDs.firstIndex(of: report.nextStationID) else { return nil }
        self.report = report
        if report.plan != nil {
            guard let geometry = shared ?? MetroPatternGeometry(pattern: pattern) else { return nil }
            self.pattern = pattern; self.geometry = geometry
            segment = geometry.line; duration = 0; atStart = false
            return
        }
        self.pattern = nil; geometry = nil
        atStart = index == 0
        let line = RouteLine(coordinates: pattern.coordinates)
        let first = atStart ? 0 : index - 1, last = atStart ? 1 : index
        guard let from = line.match(pattern.stationCoordinates[first], heading: nil),
              let to = line.match(pattern.stationCoordinates[last], heading: nil) else { return nil }
        segment = RouteLine(coordinates: line.slice(from: from, to: to))
        duration = report.atPlatform || atStart ? 0 : pattern.seconds[index - 1]
    }
    /// Distance along the drawn track, used to blend a corrected position instead of jumping.
    private func along(at date: Date) -> Double? {
        if let plan = report.plan, let pattern, let geometry {
            return MetroTrainTimeline.state(plan, pattern: pattern, at: date).map(geometry.along)
        }
        let age = date.timeIntervalSince(report.observedAt)
        guard (-15...60).contains(age) else { return nil }
        if duration == 0 { return atStart ? 0 : segment.length }
        let remaining = max(0, report.remainingSeconds - max(0, age))
        return max(0, min(1, 1 - remaining / duration)) * segment.length
    }
    public func pose(at date: Date) -> MetroTrainPose? {
        guard let along = along(at: date) else { return nil }
        let sample = segment.sample(fraction: segment.length > 0 ? along / segment.length : 0)
        let seconds: Double
        if let plan = report.plan, let pattern {
            seconds = MetroTrainTimeline.state(plan, pattern: pattern, at: date)?.secondsToNext ?? 0
        } else {
            seconds = max(0, report.remainingSeconds - max(0, date.timeIntervalSince(report.observedAt)))
        }
        return MetroTrainPose(report: report, coordinate: sample.0, heading: sample.1, path: segment.coordinates,
            seconds: seconds, estimatedPosition: true)
    }
    public func renderPose(at date: Date, blendingFrom origin: Coordinate? = nil, fraction: Double = 1) -> VehiclePose? {
        guard let target = along(at: date), segment.length > 0 else { return nil }
        var position = target
        var coordinate: Coordinate?, heading: Double?
        if let origin, fraction < 1 {
            let t = min(1, max(0, fraction)), smooth = t * t * (3 - 2 * t)
            let window = report.plan == nil ? nil : max(0, target - 3_000)...min(segment.length, target + 3_000)
            if let first = segment.match(origin, heading: nil, alongRange: window), first.distance < 60 {
                position = first.along + (target - first.along) * smooth
            } else {
                // Off this track piece (a new report on the next segment): slide straight across.
                let end = segment.sample(fraction: target / segment.length)
                coordinate = origin.interpolate(to: end.0, fraction: smooth); heading = end.1
            }
        }
        let sample = segment.sample(fraction: position / segment.length)
        return VehiclePose(id: report.id, coordinate: coordinate ?? sample.0, heading: heading ?? sample.1,
            stale: false, traveledDistance: 0, observedAt: report.observedAt)
    }
}
