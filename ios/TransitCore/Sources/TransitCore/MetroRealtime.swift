import Foundation

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
            guard !report.id.isEmpty, report.operatorID == "TRTC", report.remainingSeconds.isFinite,
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
    public init?(report: MetroTrainReport, network: MetroNetwork) {
        guard let pattern = network.pattern(report.patternID, direction: report.direction),
              let index = pattern.stationIDs.firstIndex(of: report.nextStationID),
              let next = network.station(report.nextStationID) else { return nil }
        self.report = report
        atStart = index == 0
        let line = RouteLine(coordinates: pattern.coordinates)
        let first = atStart ? 0 : index - 1, last = atStart ? 1 : index
        guard let from = line.match(pattern.stationCoordinates[first], heading: nil),
              let to = line.match(pattern.stationCoordinates[last], heading: nil) else { return nil }
        segment = RouteLine(coordinates: line.slice(from: from, to: to))
        duration = report.atPlatform || atStart ? 0 : pattern.seconds[index - 1]
        _ = next
    }
    public func pose(at date: Date) -> MetroTrainPose? {
        let age = date.timeIntervalSince(report.observedAt)
        guard (-15...60).contains(age) else { return nil }
        let remaining = max(0, report.remainingSeconds - max(0, age))
        if duration == 0 {
            let sample = segment.sample(fraction: atStart ? 0 : 1)
            return MetroTrainPose(report: report, coordinate: sample.0, heading: sample.1,
                path: segment.coordinates, seconds: remaining, estimatedPosition: true)
        }
        let fraction = max(0, min(1, 1 - remaining / duration))
        let sample = segment.sample(fraction: fraction)
        return MetroTrainPose(report: report, coordinate: sample.0, heading: sample.1, path: segment.coordinates,
            seconds: remaining, estimatedPosition: true)
    }
    public func renderPose(at date: Date, blendingFrom origin: Coordinate? = nil, fraction: Double = 1) -> VehiclePose? {
        guard let value = pose(at: date) else { return nil }
        var coordinate = value.coordinate, heading = value.heading
        if let origin, fraction < 1, segment.length > 0,
           let first = segment.match(origin, heading: nil), first.distance < 60,
           let target = segment.match(coordinate, heading: nil) {
            let t = min(1,max(0,fraction)), smooth = t*t*(3-2*t)
            let sample = segment.sample(fraction: (first.along + (target.along - first.along)*smooth) / segment.length)
            coordinate = sample.0; heading = sample.1
        }
        return VehiclePose(id: report.id, coordinate: coordinate, heading: heading,
            stale: false, traveledDistance: 0, observedAt: report.observedAt)
    }
}
