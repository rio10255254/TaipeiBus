import Foundation

public enum VehicleArrivalEstimate: Equatable, Sendable {
    case nearStop
    case minutes(lower: Int, upper: Int)
    case unavailable

    public var label: String {
        switch self {
        case .nearStop: return "已在站牌附近"
        case .minutes(let lower, let upper): return "約 \(max(1, Int((Double(lower + upper) / 2).rounded()))) 分"
        case .unavailable: return "暫無法估算"
        }
    }
}

public struct VehicleArrivalPrediction: Equatable, Sendable {
    public enum Evidence: String, Sendable { case roadHistory, recentMovement, limited }
    public let seconds: Double
    public let uncertaintySeconds: Double
    public let evidence: Evidence
    public let nearStop: Bool
    public var hasUsableTime: Bool {
        nearStop || (evidence != .limited && uncertaintySeconds <= 120 && uncertaintySeconds <= max(60, seconds * 0.4))
    }
    public var label: String {
        if nearStop { return "站牌附近" }
        guard hasUsableTime else { return "時間待確認" }
        let lower = max(1, Int(ceil((seconds - uncertaintySeconds) / 60)))
        let upper = max(lower, Int(ceil((seconds + uncertaintySeconds) / 60)))
        return upper - lower >= 2 ? "約 \(lower)–\(upper) 分" : "約 \(max(1, Int(ceil(seconds / 60)))) 分"
    }
    public var rangeLabel: String {
        let lower = max(1, Int(ceil((seconds - uncertaintySeconds) / 60)))
        let upper = max(lower, Int(ceil((seconds + uncertaintySeconds) / 60)))
        return lower == upper ? "約 \(lower) 分" : "參考範圍 \(lower)–\(upper) 分"
    }
    public var evidenceLabel: String {
        switch evidence {
        case .roadHistory: return "依近期車輛通過各站的時間估算"
        case .recentMovement: return "依這輛車近期的行駛情況估算"
        case .limited: return "行駛紀錄較少，時間僅供參考"
        }
    }
}

public struct VehicleArrivalDisplay: Equatable, Sendable {
    public let label: String
    public let positionLabel: String
    public let explanation: String
    /// Present only when there is sufficient evidence and no known source conflict.
    public let prediction: VehicleArrivalPrediction?
}

/// Predictions belong to a physical vehicle. Official route/stop ETAs have no vehicle identifier.
public struct VehicleArrivalForecast: Sendable {
    private struct Observation: Sendable {
        let route: String
        let direction: String
        let along: Double
        let date: Date
    }
    private struct Crossing: Sendable { let index: Int; let date: Date }
    private struct SegmentSample: Sendable { let vehicleID: String; let seconds: Double; let date: Date }
    private var history: [String: [Observation]] = [:]
    private var crossings: [String: Crossing] = [:]
    private var segments: [String: [SegmentSample]] = [:]
    private var metadataRevision: UUID?
    public init() {}

    public mutating func ingest(_ vehicles: [BusVehicle], metadata: TransitMetadata, at date: Date) {
        if metadataRevision != metadata.revision {
            history.removeAll(); crossings.removeAll(); segments.removeAll(); metadataRevision = metadata.revision
        }
        var current: [String: [Observation]] = [:], currentCrossings: [String: Crossing] = [:]
        for bus in vehicles where bus.hasReliablePosition(at: date) {
            guard bus.aligned, let match = bus.roadMatch,
                  let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction) else { continue }
            var samples = (history[bus.id] ?? []).filter {
                $0.route == bus.routeID && $0.direction == bus.direction &&
                (-5...600).contains(date.timeIntervalSince($0.date))
            }
            let along = match.along * Double(journey.direction)
            var crossing = samples.isEmpty ? nil : crossings[bus.id]
            if let last = samples.last,
               along < last.along - 20 || bus.observedAt.timeIntervalSince(last.date) > 90 {
                samples.removeAll(); crossing = nil
            }
            if samples.last.map({ bus.observedAt > $0.date }) ?? true {
                if let last = samples.last {
                    let interval = bus.observedAt.timeIntervalSince(last.date), moved = along - last.along
                    if (1...90).contains(interval), moved > 2, moved / interval <= 25 {
                        for (index, anchor) in journey.anchors.enumerated() {
                            let point = anchor.match.along * Double(journey.direction)
                            guard point > last.along, point <= along else { continue }
                            let time = last.date.addingTimeInterval(interval * (point - last.along) / moved)
                            if let prior = crossing, prior.index == index - 1 {
                                let seconds = time.timeIntervalSince(prior.date)
                                if (5...900).contains(seconds) {
                                    let key = segmentKey(bus.routeID, bus.direction, journey, index, metadata)
                                    segments[key, default: []].append(SegmentSample(vehicleID: bus.id, seconds: seconds, date: time))
                                    segments[key] = Array(segments[key, default: []].suffix(30))
                                }
                            }
                            crossing = Crossing(index: index, date: time)
                        }
                    }
                }
                samples.append(Observation(route: bus.routeID, direction: bus.direction, along: along, date: bus.observedAt))
            }
            current[bus.id] = Array(samples.suffix(40)); currentCrossings[bus.id] = crossing
        }
        history = current; crossings = currentCrossings
        segments = segments.compactMapValues { values in
            let fresh = values.filter { (-5...1_200).contains(date.timeIntervalSince($0.date)) }
            return fresh.isEmpty ? nil : fresh
        }
    }

    public func estimate(_ approach: VehicleApproach, ride: TransitRide, metadata: TransitMetadata,
                         at date: Date) -> VehicleArrivalEstimate {
        guard approach.alongDistance != nil, metadata.canServe(ride, vehicle: approach.vehicle),
              let result = prediction(approach.vehicle, stopID: ride.boarding.id, metadata: metadata, at: date),
              result.hasUsableTime else { return .unavailable }
        if result.nearStop { return .nearStop }
        let lower = max(1, Int(ceil((result.seconds - result.uncertaintySeconds) / 60)))
        let upper = max(lower, Int(ceil((result.seconds + result.uncertaintySeconds) / 60)))
        return .minutes(lower: lower, upper: upper)
    }

    public func prediction(_ bus: BusVehicle, stopID: String, metadata: TransitMetadata, at date: Date,
                           allowTypicalWhenStopped: Bool = false) -> VehicleArrivalPrediction? {
        guard bus.hasReliablePosition(at: date), bus.aligned, let match = bus.roadMatch,
              (-5...90).contains(date.timeIntervalSince(bus.observedAt)),
              let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction),
              let target = journey.anchors.firstIndex(where: { $0.stop.id == stopID }),
              let progress = journey.progress(stopID: stopID, vehicle: bus, at: date), progress.distance >= -20 else { return nil }
        if bus.hasHeading, bus.hasSpeed, bus.speed >= 8,
           let line = metadata.line(bus.routeID, direction: bus.direction),
           RouteLine.headingDifference(bus.heading, line.bearing(at: match, direction: journey.direction)) > 135 {
            return nil // The reported direction and actual moving heading disagree; keep GPS available, withhold ETA.
        }
        let age = max(0, date.timeIntervalSince(bus.observedAt))
        if progress.distance <= 40 {
            guard age <= 30 else { return nil }
            return VehicleArrivalPrediction(seconds: 0, uncertaintySeconds: 30, evidence: .recentMovement, nearStop: true)
        }
        let samples = (history[bus.id] ?? []).filter {
            $0.route == bus.routeID && $0.direction == bus.direction && (-5...180).contains(bus.observedAt.timeIntervalSince($0.date))
        }
        var speed: Double?, movingHistory = false, matureHistory = false, observedDistance = 0.0, speedVariation = 0.3
        if let first = samples.first, let last = samples.last {
            let interval = last.date.timeIntervalSince(first.date), moved = last.along - first.along
            if interval >= 20, moved >= 30 {
                // Include stopped reports in elapsed time, so congestion and station dwell are not discarded.
                speed = min(18, max(0.6, moved / interval)); movingHistory = true
                observedDistance = moved
                matureHistory = samples.count >= 3 && interval >= 45 && moved >= 80
                let rates = zip(samples, samples.dropFirst()).compactMap { a, b -> Double? in
                    let dt = b.date.timeIntervalSince(a.date)
                    return dt >= 5 ? max(0, b.along - a.along) / dt : nil
                }
                if !rates.isEmpty { speedVariation = min(0.6, max(0.12, median(rates.map { abs($0 - speed!) }) / speed!)) }
            }
        }
        if speed == nil, bus.hasSpeed, (5...80).contains(bus.speed) {
            // A current speed is a short sample; blend it with a conservative urban driving baseline.
            speed = min(16, 4.5 * 0.6 + bus.speed / 3.6 * 0.4)
        }
        let along = match.along * Double(journey.direction)
        var seconds = 0.0, variance = 0.0, learned = 0, fallback = 0
        let indices = journey.anchors.indices.dropFirst().prefix(target)
        for index in indices {
            let start = journey.anchors[index - 1].match.along * Double(journey.direction)
            let end = journey.anchors[index].match.along * Double(journey.direction)
            let span = end - start, remaining = end - max(start, along)
            guard span > 1, remaining > 0 else { continue }
            let fraction = min(1, remaining / span)
            let records = (segments[segmentKey(bus.routeID, bus.direction, journey, index, metadata)] ?? [])
                .filter { (-5...1_200).contains(date.timeIntervalSince($0.date)) }
            let values = records.map(\.seconds)
            let duration: Double, margin: Double
            if Set(records.map(\.vehicleID)).count >= 3 {
                let typical = median(values)
                duration = typical * fraction
                margin = max(12, median(values.map { abs($0 - typical) }) * 1.5) * fraction
                learned += 1
            } else {
                guard let pace = speed ?? (allowTypicalWhenStopped ? 4.5 : nil) else { return nil }
                duration = remaining / pace + (movingHistory ? 0 : 20 * fraction)
                margin = max(12, duration * speedVariation); fallback += 1
            }
            seconds += duration; variance += margin * margin
        }
        let firstAlong = journey.anchors.first.map { $0.match.along * Double(journey.direction) } ?? along
        if target == 0 || along < firstAlong {
            guard let pace = speed ?? (allowTypicalWhenStopped ? 4.5 : nil) else { return nil }
            let leading = target == 0 ? progress.distance : firstAlong - along
            seconds += leading / pace; variance += pow(leading / pace * speedVariation, 2); fallback += 1
        }
        guard seconds > 0 else { return nil }
        // A short movement sample cannot describe distant traffic or extrapolate a terminal dwell over the whole route.
        let withinObservedHorizon = seconds <= 900 && progress.distance <= max(1_200, observedDistance * 4 + 40)
        let evidence: VehicleArrivalPrediction.Evidence = age > 30 ? .limited :
            learned > 0 && fallback == 0 ? .roadHistory : matureHistory && withinObservedHorizon ? .recentMovement : .limited
        // Do not count down a stopped bus, or manufacture an arrival after GPS updates cease.
        let elapsed = bus.hasSpeed && bus.speed >= 5 ? min(age, 15, seconds * 0.1) : 0
        return VehicleArrivalPrediction(seconds: max(15, seconds - elapsed),
            uncertaintySeconds: max(30, sqrt(variance), seconds * (evidence == .limited ? 0.3 : 0.12)) + age * 0.35,
            evidence: evidence, nearStop: false)
    }

    public func display(_ bus: BusVehicle, stopID: String, metadata: TransitMetadata, at date: Date,
                        officialSeconds: Int? = nil, allowTypicalWhenStopped: Bool = false) -> VehicleArrivalDisplay {
        let officialAdvice = (officialSeconds ?? -1) >= 0 ? "候車請以官方下一班為準。" : ""
        guard let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction),
              let progress = journey.progress(stopID: stopID, vehicle: bus, at: date) else {
            return VehicleArrivalDisplay(label: "位置待確認", positionLabel: "位置待確認",
                explanation: "車輛位置尚未確認，暫停推估到站時間。" + officialAdvice, prediction: nil)
        }
        if progress.distance < -20 {
            return VehicleArrivalDisplay(label: "已過站", positionLabel: "已過站",
                explanation: "這輛車已通過此站。", prediction: nil)
        }
        let stops = journey.upcoming(vehicle: bus, at: date)
        let count = stops.firstIndex { $0.stop.id == stopID }.map { $0 + 1 }
        let position = progress.distance <= 40 ? "站牌附近" : count.map { "還有 \($0) 站" } ?? "位置待確認"
        if let official = officialSeconds, official < 0 {
            return VehicleArrivalDisplay(label: position, positionLabel: position,
                explanation: "官方目前標示「\(EstimateFeed.label(official))」，候車以官方資訊為準。", prediction: nil)
        }
        guard date.timeIntervalSince(bus.observedAt) <= 30 else {
            return VehicleArrivalDisplay(label: "位置更新中", positionLabel: "上次位置 · " + position,
                explanation: "車輛位置等待更新，暫停顯示分鐘數。" + officialAdvice, prediction: nil)
        }
        guard let result = prediction(bus, stopID: stopID, metadata: metadata, at: date,
                                      allowTypicalWhenStopped: allowTypicalWhenStopped) else {
            return VehicleArrivalDisplay(label: position, positionLabel: position,
                explanation: "尚未累積足夠行駛紀錄，先顯示車輛距離此站的站數。" + officialAdvice, prediction: nil)
        }
        if let official = officialSeconds, official >= 0,
           result.seconds + result.uncertaintySeconds + max(60, Double(official) * 0.1) < Double(official) {
            return VehicleArrivalDisplay(label: "時間待確認", positionLabel: position,
                explanation: "候車請以官方下一班為準。車輛推估尚不一致，先保留位置與站數，不指定到站車牌。", prediction: nil)
        }
        guard result.hasUsableTime else {
            return VehicleArrivalDisplay(label: position, positionLabel: position,
                explanation: "行駛紀錄較少或變化較大，先顯示站數，等待時間確認。" + officialAdvice, prediction: nil)
        }
        return VehicleArrivalDisplay(label: result.label, positionLabel: position,
            explanation: result.evidenceLabel, prediction: result)
    }

    public func ridingSeconds(_ ride: TransitRide, metadata: TransitMetadata, at date: Date) -> Double {
        guard let journey = metadata.journey(routeID: ride.route.id, direction: ride.direction),
              let first = journey.anchors.firstIndex(where: { $0.stop.id == ride.boarding.id }),
              let last = journey.anchors.firstIndex(where: { $0.stop.id == ride.alighting.id }), last > first else {
            let distance = zip(ride.coordinates, ride.coordinates.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            return distance / 4.5 + Double(ride.stopCount) * 20
        }
        return ((first + 1)...last).reduce(0) { result, index in
            let records = (segments[segmentKey(ride.route.id, ride.direction, journey, index, metadata)] ?? [])
                .filter { (-5...1_200).contains(date.timeIntervalSince($0.date)) }
            let samples = records.map(\.seconds)
            let distance = abs(journey.anchors[index].match.along - journey.anchors[index - 1].match.along)
            return result + (Set(records.map(\.vehicleID)).count >= 3 ? median(samples) : distance / 4.5 + 20)
        }
    }

    private func segmentKey(_ route: String, _ direction: String, _ journey: RouteJourney, _ index: Int,
                            _ metadata: TransitMetadata) -> String {
        let from = journey.anchors[index - 1], to = journey.anchors[index]
        let family = metadata.routes[route]?.parentID ?? route
        // Share measured traffic across co-operators, but distinguish detours with the same two stop IDs.
        let span = abs(to.match.along - from.match.along)
        let line = metadata.line(route, direction: direction)
        let midpoint = line.flatMap { $0.length > 0 ? $0.sample(fraction: (from.match.along + to.match.along) / 2 / $0.length).0 : nil }
        let geometry = midpoint.map { "\(Int(($0.latitude * 10_000).rounded())):\(Int(($0.longitude * 10_000).rounded()))" } ?? route
        return "\(family):\(direction):\(from.stop.id):\(to.stop.id):\(Int((span / 50).rounded())):\(geometry)"
    }
    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
