import Foundation

public enum VehicleArrivalEstimate: Equatable, Sendable {
    case nearStop
    case minutes(lower: Int, upper: Int)
    case unavailable

    public var label: String {
        switch self {
        case .nearStop: return AppText.text("已在站牌附近")
        case .minutes(let lower, let upper): return AppText.text("約 %@ 分", max(1, Int((Double(lower + upper) / 2).rounded())))
        case .unavailable: return AppText.text("暫無法估算")
        }
    }
}

public struct VehicleArrivalPrediction: Equatable, Sendable {
    public enum Evidence: String, Sendable { case roadHistory, officialProfile, recentMovement, routeProgress, limited }
    public let seconds: Double
    public let uncertaintySeconds: Double
    public let evidence: Evidence
    public let nearStop: Bool
    public var hasUsableTime: Bool {
        nearStop || (evidence != .limited && seconds <= 1_800 &&
            uncertaintySeconds <= (evidence == .routeProgress ? 180 : 300) &&
            uncertaintySeconds <= max(60, seconds * 0.4))
    }
    public var label: String {
        if nearStop { return AppText.text("站牌附近") }
        guard hasUsableTime else { return AppText.text("時間待確認") }
        return AppText.text("約 %@ 分", max(1, Int(ceil(seconds / 60))))
    }
    public var rangeLabel: String {
        let lower = max(1, Int(ceil((seconds - uncertaintySeconds) / 60)))
        let upper = max(lower, Int(ceil((seconds + uncertaintySeconds) / 60)))
        return lower == upper ? AppText.text("約 %@ 分", lower) : AppText.text("參考範圍 %@–%@ 分", lower, upper)
    }
    public var evidenceLabel: String {
        switch evidence {
        case .roadHistory: return AppText.text("依近期車輛通過各站的時間估算")
        case .officialProfile: return AppText.text("依官方分時段車程與近期車流估算")
        case .recentMovement: return AppText.text("依這輛車近期的行駛情況估算")
        case .routeProgress: return AppText.text("依 GPS 位置與沿線車程估算")
        case .limited: return AppText.text("行駛紀錄較少，時間僅供參考")
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

/// A whole-ride planning estimate, never the official arrival time of a named bus.
public struct RidingTimeEstimate: Equatable, Sendable {
    public enum Evidence: String, Sendable {
        case stationHistory, officialProfile, railProfile, recentTraffic, typical
        /// Share of the ride time it may plausibly run early or late, by how the time was obtained.
        /// Calibrated remotely (ForecastTuning) against recorded arrivals.
        public var spreadFraction: Double {
            let tuning = ForecastTuning.current
            switch self {
            case .railProfile: return tuning.railSpread
            case .stationHistory: return tuning.stationHistorySpread
            case .officialProfile: return tuning.officialProfileSpread
            case .recentTraffic: return tuning.recentTrafficSpread
            case .typical: return tuning.typicalSpread
            }
        }
    }
    public let seconds: Double
    public let evidence: Evidence
    public let observedVehicles: Int
    public init(seconds: Double, evidence: Evidence, observedVehicles: Int) {
        self.seconds = seconds; self.evidence = evidence; self.observedVehicles = observedVehicles
    }
    public var spreadSeconds: Double { seconds * evidence.spreadFraction }
    public var sourceLabel: String {
        switch evidence {
        case .stationHistory: return AppText.text("依近期站間紀錄")
        case .officialProfile: return AppText.text("依官方分時段車程")
        case .railProfile: return AppText.text("依官方捷運站間車程")
        case .recentTraffic: return AppText.text("依目前路線車流")
        case .typical: return AppText.text("一般車程估計")
        }
    }
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
    private var roadSignatures: [String: Int] = [:]
    private var timingFeedback = ArrivalTimingFeedback()
    private var feedbackCursor = 0
    public init() {}

    public mutating func ingest(_ vehicles: [BusVehicle], metadata: TransitMetadata, at date: Date) {
        if metadataRevision != metadata.revision {
            var signatures: [String: Int] = [:]
            let contexts = vehicles.map { ($0.routeID, $0.direction) } + history.values.compactMap { values in
                values.last.map { ($0.route, $0.direction) }
            }
            for (route, direction) in contexts {
                let key = route + ":" + direction
                guard signatures[key] == nil else { continue }
                var hash = Hasher()
                for anchor in metadata.journey(routeID: route, direction: direction)?.anchors ?? [] {
                    hash.combine(anchor.stop.id); hash.combine(anchor.match.along)
                }
                for point in metadata.line(route, direction: direction)?.coordinates ?? [] {
                    hash.combine(point.latitude); hash.combine(point.longitude)
                }
                signatures[key] = hash.finalize()
            }
            history = history.filter { _, values in
                guard let latest = values.last else { return false }
                let key = latest.route + ":" + latest.direction
                return signatures[key] != nil && signatures[key] == roadSignatures[key]
            }
            crossings = crossings.filter { history[$0.key] != nil }
            roadSignatures = signatures; metadataRevision = metadata.revision
        }
        // One missing packet must not erase the preceding traffic sample. The
        // public prediction still requires a fresh GPS report from this vehicle.
        var current = history.filter { $0.value.last.map { (-5...90).contains(date.timeIntervalSince($0.date)) } ?? false }
        var currentCrossings = crossings.filter { current[$0.key] != nil }
        for bus in vehicles {
            current[bus.id] = nil; currentCrossings[bus.id] = nil
            guard bus.hasReliablePosition(at: date), ["0", "3"].contains(bus.status), bus.aligned, let match = bus.roadMatch,
                  let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction) else {
                timingFeedback.discard(vehicle: bus.id); continue
            }
            var samples = (history[bus.id] ?? []).filter {
                $0.route == bus.routeID && $0.direction == bus.direction &&
                (-5...600).contains(date.timeIntervalSince($0.date))
            }
            let along = match.along * Double(journey.direction)
            var crossing = samples.isEmpty ? nil : crossings[bus.id]
            if let last = samples.last,
               along < last.along - 20 || bus.observedAt.timeIntervalSince(last.date) > 90 {
                samples.removeAll(); crossing = nil; timingFeedback.discard(vehicle: bus.id)
            }
            if samples.isEmpty { timingFeedback.discard(vehicle: bus.id) }
            if samples.last.map({ bus.observedAt > $0.date }) ?? true {
                if let last = samples.last {
                    let interval = bus.observedAt.timeIntervalSince(last.date), moved = along - last.along
                    if (1...90).contains(interval), moved > 2, moved / interval <= 25 {
                        for (index, anchor) in journey.anchors.enumerated() {
                            let point = anchor.match.along * Double(journey.direction)
                            guard point > last.along, point <= along else { continue }
                            let time = last.date.addingTimeInterval(interval * (point - last.along) / moved)
                            if index > 0 {
                                timingFeedback.crossed(vehicle: bus.id,
                                    key: segmentKey(bus.routeID,bus.direction,journey,index,metadata),stopID: anchor.stop.id,at: time)
                            }
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
        timingFeedback.prune(at: date)
        // Feedback is auxiliary work on the main app's snapshot path. Rotate a
        // bounded sample so a city-wide refresh cannot add thousands of forecasts.
        let count = min(64,vehicles.count)
        for offset in 0..<count {
            let bus = vehicles[(feedbackCursor+offset) % vehicles.count]
            guard bus.hasReliablePosition(at:date), ["0","3"].contains(bus.status) else { continue }
            guard timingFeedback.needsPrediction(vehicle:bus.id),
                  let journey = metadata.journey(routeID: bus.routeID,direction: bus.direction),
                  let along = bus.roadMatch.map({ $0.along * Double(journey.direction) }),
                  let index = journey.anchors.indices.dropFirst().first(where: {
                      journey.anchors[$0].match.along * Double(journey.direction) > along
                  }), journey.anchors[index].match.along * Double(journey.direction) > along+30,
                  let estimate = prediction(bus,stopID:journey.anchors[index].stop.id,metadata:metadata,
                      at:bus.observedAt,applyCalibration:false), estimate.hasUsableTime,
                  estimate.evidence == .routeProgress || estimate.evidence == .recentMovement else { continue }
            timingFeedback.begin(vehicle:bus.id,key:segmentKey(bus.routeID,bus.direction,journey,index,metadata),
                stopID:journey.anchors[index].stop.id,seconds:estimate.seconds,at:bus.observedAt)
        }
        if !vehicles.isEmpty { feedbackCursor = (feedbackCursor+count) % vehicles.count }
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
                           allowTypicalWhenStopped: Bool = false, applyCalibration: Bool = true) -> VehicleArrivalPrediction? {
        let tuning = ForecastTuning.current
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
            speed = min(16, tuning.typicalSpeed * 0.6 + bus.speed / 3.6 * 0.4)
        }
        let along = match.along * Double(journey.direction)
        let firstAlong = journey.anchors.first.map { $0.match.along * Double(journey.direction) } ?? along
        // A bus standing at its first stop may be in a terminal layover; the official
        // running time says nothing about when it leaves.
        let inService = movingHistory || (bus.hasSpeed && bus.speed >= 5) || along > firstAlong + 150
        var seconds = 0.0, variance = 0.0, learned = 0, profiled = 0, fallback = 0
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
            let vehicles = Set(records.map(\.vehicleID)).count
            let duration: Double, margin: Double
            let official = vehicles >= 3 || !inService ? nil : metadata.officialTravelTimes.seconds(route: bus.parentRouteID,
                subroute: bus.routeID, direction: bus.direction, from: journey.anchors[index - 1].stop.id,
                to: journey.anchors[index].stop.id, travellingAt: date.addingTimeInterval(seconds), observedAt: date)
            if vehicles >= 3 {
                let typical = median(values)
                duration = typical * fraction
                margin = max(12, median(values.map { abs($0 - typical) }) * 1.5) * fraction
                learned += 1
            } else if let official {
                // The official hour profile is the baseline; one or two recent crossings refine it
                // as if the profile were worth officialProfileWeight observations.
                let weight = tuning.officialProfileWeight
                let typical = vehicles == 0 ? official : (median(values) * Double(vehicles) + official * weight) / (Double(vehicles) + weight)
                duration = typical * fraction
                margin = max(12, typical * tuning.officialSegmentMargin) * fraction
                profiled += 1
            } else {
                guard let pace = speed ?? (allowTypicalWhenStopped ? tuning.typicalSpeed : nil) else { return nil }
                let correction = applyCalibration ? timingFeedback.factor(for:segmentKey(bus.routeID,bus.direction,journey,index,metadata),at:date) : 1
                duration = (remaining / pace + (movingHistory ? 0 : tuning.stopSeconds * fraction)) * correction
                margin = max(12, duration * speedVariation); fallback += 1
            }
            seconds += duration; variance += margin * margin
        }
        if target == 0 || along < firstAlong {
            guard let pace = speed ?? (allowTypicalWhenStopped ? tuning.typicalSpeed : nil) else { return nil }
            let leading = target == 0 ? progress.distance : firstAlong - along
            seconds += leading / pace; variance += pow(leading / pace * speedVariation, 2); fallback += 1
        }
        guard seconds > 0 else { return nil }
        // A short movement sample cannot describe distant traffic or extrapolate a terminal dwell over the whole route.
        let withinObservedHorizon = seconds <= 900 && progress.distance <= max(1_200, observedDistance * 4 + 40)
        // One fresh moving GPS report can provide a short-range estimate before
        // history matures. Never extend a terminal layover or a 50-minute crawl
        // across the route, and never use a straight-line distance to the stop.
        let localGPS = age <= 30 && inService && bus.hasSpeed && (5...80).contains(bus.speed) &&
            seconds <= 600 && progress.distance <= 2_500
        let evidence: VehicleArrivalPrediction.Evidence = age > 30 ? .limited :
            fallback == 0 && profiled > 0 ? .officialProfile :
            learned > 0 && fallback == 0 ? .roadHistory : matureHistory && withinObservedHorizon ? .recentMovement :
            localGPS ? .routeProgress : .limited
        // Do not count down a stopped bus, or manufacture an arrival after GPS updates cease.
        let elapsed = bus.hasSpeed && bus.speed >= 5 ? min(age, 15, seconds * 0.1) : 0
        return VehicleArrivalPrediction(seconds: max(15, seconds - elapsed),
            uncertaintySeconds: max(30, sqrt(variance), seconds * (evidence == .limited ? tuning.limitedUncertainty : tuning.minimumUncertainty)) + age * 0.35,
            evidence: evidence, nearStop: false)
    }

    public func display(_ bus: BusVehicle, stopID: String, metadata: TransitMetadata, at date: Date,
                        officialSeconds: Int? = nil, allowTypicalWhenStopped: Bool = false) -> VehicleArrivalDisplay {
        let officialAdvice = (officialSeconds ?? -1) >= 0 ? AppText.text("候車請以官方下一班為準。") : ""
        guard let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction),
              let progress = journey.progress(stopID: stopID, vehicle: bus, at: date) else {
            return VehicleArrivalDisplay(label: AppText.text("位置待確認"), positionLabel: AppText.text("位置待確認"),
                explanation: AppText.text("車輛位置尚未確認，暫停推估到站時間。") + officialAdvice, prediction: nil)
        }
        if progress.distance < -20 {
            return VehicleArrivalDisplay(label: AppText.text("已過站"), positionLabel: AppText.text("已過站"),
                explanation: AppText.text("這輛車已通過此站。"), prediction: nil)
        }
        let stops = journey.upcoming(vehicle: bus, at: date)
        let count = stops.firstIndex { $0.stop.id == stopID }.map { $0 + 1 }
        let position = progress.distance <= 40 ? AppText.text("站牌附近") : count.map { AppText.remainingStops($0) } ?? AppText.text("位置待確認")
        if let official = officialSeconds, official < 0 {
            return VehicleArrivalDisplay(label: position, positionLabel: position,
                explanation: AppText.text("官方目前標示「%@」，候車以官方資訊為準。", EstimateFeed.label(official)), prediction: nil)
        }
        guard date.timeIntervalSince(bus.observedAt) <= 30 else {
            return VehicleArrivalDisplay(label: AppText.text("位置更新中"), positionLabel: AppText.text("上次位置 · ") + position,
                explanation: AppText.text("車輛位置等待更新，暫停顯示分鐘數。") + officialAdvice, prediction: nil)
        }
        guard let result = prediction(bus, stopID: stopID, metadata: metadata, at: date,
                                      allowTypicalWhenStopped: allowTypicalWhenStopped) else {
            return VehicleArrivalDisplay(label: position, positionLabel: position,
                explanation: AppText.text("尚未累積足夠行駛紀錄，先顯示車輛距離此站的站數。") + officialAdvice, prediction: nil)
        }
        if let official = officialSeconds, official >= 0,
           (result.seconds + result.uncertaintySeconds + max(60, Double(official) * 0.1) < Double(official) ||
            (result.evidence == .routeProgress && abs(result.seconds - Double(official)) > 60)) {
            return VehicleArrivalDisplay(label: position, positionLabel: position,
                explanation: AppText.text("候車請以官方下一班為準。車輛推估尚不一致，先保留位置與站數，不指定到站車牌。"), prediction: nil)
        }
        guard result.hasUsableTime else {
            return VehicleArrivalDisplay(label: position, positionLabel: position,
                explanation: AppText.text("行駛紀錄較少或變化較大，先顯示站數，等待時間確認。") + officialAdvice, prediction: nil)
        }
        return VehicleArrivalDisplay(label: result.label, positionLabel: position,
            explanation: result.evidenceLabel, prediction: result)
    }

    /// Only real, fresh, upstream buses on the complete requested stop pattern.
    /// A route-level official ETA is kept independent of these physical buses.
    public func departures(for ride: TransitRide, metadata: TransitMetadata, snapshot: TransitSnapshot,
                           at date: Date) -> [BoardingDeparture] {
        guard ride.route.mode == .bus else { return [] }
        let official = snapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: date)
        if let official, official < 0 { return [] }
        return BoardingGuide.vehicles(ride: ride, metadata: metadata, snapshot: snapshot, at: date, approachingOnly: true)
            .compactMap { approach in
                let result = display(approach.vehicle, stopID: ride.boarding.id, metadata: metadata,
                    at: date, officialSeconds: official).prediction
                guard let result, result.hasUsableTime else { return nil }
                return BoardingDeparture(seconds: result.seconds, spread: result.uncertaintySeconds)
            }.sorted { $0.seconds < $1.seconds }
    }

    public func ridingSeconds(_ ride: TransitRide, metadata: TransitMetadata, at date: Date) -> Double {
        ridingEstimate(ride, metadata: metadata, at: date).seconds
    }

    /// Walk and waiting time determine the hour in which each ride actually starts.
    /// Observation freshness stays anchored to now, even for a later transfer.
    public func plannedRidingEstimates(_ trip: TransitTrip, metadata: TransitMetadata, estimates: EstimateFeed,
                                      walkingDurations: [Double?], preferences: LiveSettings.Planning = .init(),
                                      at date: Date, departures: [[BoardingDeparture]] = []) -> [RidingTimeEstimate] {
        let walks = trip.planningWalkSeconds.enumerated().map { index, seconds in
            walkingDurations.indices.contains(index) ? walkingDurations[index] ?? seconds : seconds
        }
        var durations = trip.rideSeconds, result: [RidingTimeEstimate] = [], elapsed = 0.0
        for (index, ride) in trip.rides.enumerated() {
            let assessment = TripRanking.assessment(trip, estimates: estimates, at: date, preferences: preferences,
                walkingDurations: walkingDurations, ridingDurations: durations, departures: departures)
            elapsed += max(0, walks[index]) + assessment.waits[index].seconds
            let value = ridingEstimate(ride, metadata: metadata, at: date, travellingAt: date.addingTimeInterval(elapsed))
            durations[index] = value.seconds; result.append(value); elapsed += value.seconds
        }
        return result
    }

    public func ridingEstimate(_ ride: TransitRide, metadata: TransitMetadata, at date: Date,
                              travellingAt: Date? = nil, progress: OnboardProgress? = nil, to stopID: String? = nil) -> RidingTimeEstimate {
        let tuning = ForecastTuning.current
        let riderProgress = progress?.rideID == ride.id ? progress : nil
        let targetID = stopID ?? ride.alighting.id
        if ride.route.mode != .bus, let seconds = metadata.metro.ridingSeconds(routeID: ride.route.id, direction: ride.direction,
            from: ride.boarding.stationID, to: ride.alighting.stationID) {
            return RidingTimeEstimate(seconds: seconds, evidence: .railProfile, observedVehicles: 0)
        }
        guard let journey = metadata.journey(routeID: ride.route.id, direction: ride.direction),
              let first = journey.anchors.firstIndex(where: { $0.stop.id == ride.boarding.id }),
              let last = journey.anchors.firstIndex(where: { $0.stop.id == targetID }), last > first else {
            let points = ride.coordinates.count >= 2 ? ride.coordinates : ride.stops.map(\.coordinate)
            let distance = zip(points, points.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) } * (ride.coordinates.count >= 2 ? 1 : 1.25)
            let spans = zip(ride.stops, ride.stops.dropFirst()).map { $0.coordinate.distance(to: $1.coordinate) }
            let totalSpan = spans.reduce(0, +)
            var seconds = 0.0, published = 0, remainingSegments = 0
            let endIndex = ride.stops.firstIndex(where: { $0.id == targetID }) ?? ride.stops.count-1
            for index in ride.stops.indices.dropFirst() where index <= endIndex {
                let from = ride.stops[index - 1], to = ride.stops[index]
                let fraction: Double = riderProgress?.remainingSegmentFraction(from: from.id, to: to.id) ?? (riderProgress?.remainingFraction ?? 1.0)
                guard fraction > 0 else { continue }
                remainingSegments += 1
                if let official = metadata.officialTravelTimes.seconds(route: ride.route.parentID,
                    subroute: ride.route.id, direction: ride.direction, from: from.id, to: to.id,
                    travellingAt: (travellingAt ?? date).addingTimeInterval(seconds), observedAt: date) {
                    seconds += official * fraction; published += 1
                } else {
                    let share = totalSpan > 1 ? spans[index - 1] / totalSpan : 1 / Double(max(1, ride.stopCount))
                    seconds += (distance * share / tuning.typicalSpeed + tuning.stopSeconds) * fraction
                }
            }
            return RidingTimeEstimate(seconds: seconds,
                evidence: published == remainingSegments && published > 0 ? .officialProfile : .typical, observedVehicles: 0)
        }
        let traffic = observedRidePace(ride, journey: journey, first: first, last: last, at: date)
        var seconds = 0.0, measured = 0, published = 0, fallback = 0
        for index in (first + 1)...last {
            let fraction: Double = riderProgress?.remainingSegmentFraction(from: journey.anchors[index-1].stop.id,
                to: journey.anchors[index].stop.id) ?? 1
            guard fraction > 0 else { continue }
            let records = (segments[segmentKey(ride.route.id, ride.direction, journey, index, metadata)] ?? [])
                .filter { (-5...1_200).contains(date.timeIntervalSince($0.date)) }
            let samples = records.map(\.seconds)
            let distance = abs(journey.anchors[index].match.along - journey.anchors[index - 1].match.along)
            if Set(records.map(\.vehicleID)).count >= 3 {
                seconds += median(samples) * fraction; measured += 1
            } else if let official = metadata.officialTravelTimes.seconds(route: ride.route.parentID,
                        subroute: ride.route.id, direction: ride.direction,
                        from: journey.anchors[index - 1].stop.id, to: journey.anchors[index].stop.id,
                        travellingAt: (travellingAt ?? date).addingTimeInterval(seconds), observedAt: date) {
                seconds += official * fraction; published += 1
            } else if let traffic {
                // The observed elapsed time already contains signals, congestion
                // and dwell. Adding another 20 seconds per stop would count it twice.
                seconds += distance / traffic.speed * fraction; fallback += 1
            } else {
                let correction = timingFeedback.factor(for:segmentKey(ride.route.id,ride.direction,journey,index,metadata),at:date)
                seconds += (distance / tuning.typicalSpeed + tuning.stopSeconds) * fraction * correction; fallback += 1
            }
        }
        return RidingTimeEstimate(seconds: seconds,
            evidence: fallback == 0 && published > 0 ? .officialProfile : fallback == 0 && measured > 0 ? .stationHistory : traffic != nil ? .recentTraffic : .typical,
            observedVehicles: traffic?.count ?? 0)
    }

    private func observedRidePace(_ ride: TransitRide, journey: RouteJourney, first: Int, last: Int,
                                  at date: Date) -> (speed: Double, count: Int)? {
        let start = journey.anchors[first].match.along * Double(journey.direction)
        let end = journey.anchors[last].match.along * Double(journey.direction)
        let span = end - start
        guard span >= 800 else { return nil }
        let terminalStart = journey.anchors.first!.match.along * Double(journey.direction)
        let terminalEnd = journey.anchors.last!.match.along * Double(journey.direction)
        var durations = 0.0, distance = 0.0, positions: [Double] = []
        for records in history.values {
            guard let latest = records.last, latest.route == ride.route.id, latest.direction == ride.direction,
                  (-5...30).contains(date.timeIntervalSince(latest.date)) else { continue }
            let samples = records.filter { latest.date.timeIntervalSince($0.date) <= 180 }
            guard samples.count >= 3, let earliest = samples.first else { continue }
            let elapsed = latest.date.timeIntervalSince(earliest.date)
            let moved = max(0, latest.along - earliest.along)
            let midpoint = (latest.along + earliest.along) / 2
            guard elapsed >= 45, moved / elapsed <= 18,
                  earliest.along >= start - 20, latest.along <= end + 20,
                  midpoint > terminalStart + 75, midpoint < terminalEnd - 75 else { continue }
            // Include stationary vehicles inside the ride, not terminal layovers.
            durations += elapsed; distance += moved; positions.append(midpoint)
        }
        guard positions.count >= 3,
              (positions.max()! - positions.min()!) / span >= 0.35,
              Set(positions.map { min(7, max(0, Int(($0 - start) / span * 8))) }).count >= 3,
              durations > 0 else { return nil }
        let speed = distance / durations
        guard (0.6...18).contains(speed) else { return nil }
        return (speed, positions.count)
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
