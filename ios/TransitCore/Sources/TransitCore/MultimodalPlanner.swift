import Foundation

/// Round-based transit search. Each round adds one actual operating pattern;
/// shared station names never splice trains or buses into a fictitious direct service.
public struct MultimodalPlanner: Sendable {
    private struct Pattern: Sendable {
        let route: BusRoute
        let direction: String
        let stops: [BusStop]
        let cumulative: [Double]
        let dwell: [Double]
        let windows: [BusServiceWindow?]
        /// Per-segment seconds used when no official time applies: rail run plus dwell,
        /// or the road-distance estimate. Official bus times are applied per query hour.
        let fallback: [Double]
        func timed(_ times: OfficialTravelTimes, at date: Date) -> Pattern {
            guard route.mode == .bus else { return self }
            var values = [0.0]
            for index in 1..<stops.count {
                values.append(values.last! + (times.seconds(route: route.parentID, subroute: route.id, direction: direction,
                    from: stops[index - 1].id, to: stops[index].id, travellingAt: date, observedAt: date) ?? fallback[index - 1]))
            }
            return Pattern(route: route, direction: direction, stops: stops, cumulative: values, dwell: dwell,
                windows: windows, fallback: fallback)
        }
    }
    /// Bus times for the most recent query hour; a planner lives up to a day, across peaks.
    private final class TimingCache: @unchecked Sendable {
        let lock = NSLock()
        var key = ""
        var patterns: [Pattern] = []
    }
    private struct Segment: Sendable { let pattern: Int; let first: Int; let last: Int }
    private struct Link: Sendable { let id: String; let distance: Double; let seconds: Double; let internalWalk: Bool }
    private struct Label: Sendable {
        let segments: [Segment]
        let access: Double
        let distances: [Double]
        let transferSeconds: [Double]
        let elapsed: Double
        let walking: Double
        let cost: Double
        let lastStation: String
        let hasRail: Bool
        let family: String
        var bikes: [Int: BikeConnection] = [:]
        var supplyRisk: Double = 0
        var lastWalk: Double = 0
        var internalWalk = false
        var previousSpread: Double = 0
        var unknownWaits = 0
    }
    private struct Candidate {
        let label: Label
        let egress: Double
        let score: Double
        var bike: BikeConnection? = nil
        var supplyRisk: Double = 0
    }
    private let metadata: TransitMetadata
    private let patterns: [Pattern]
    private let links: [String: [Link]]
    private let stationStops: [String: BusStop]
    private let busPlanner: TripPlanner
    private let timing = TimingCache()

    public init(metadata: TransitMetadata) {
        self.metadata = metadata; busPlanner = TripPlanner(metadata: metadata)
        var patterns: [Pattern] = [], stationStops: [String: BusStop] = [:]
        let tuning = ForecastTuning.current
        for route in metadata.routes.values.sorted(by: { $0.id < $1.id }) {
            guard !route.name.contains("觀光巴士"), !route.name.hasPrefix("懷恩專車") else { continue }
            for direction in ["0", "1"] {
                let stops = metadata.orderedStops(routeID: route.id, direction: direction)
                guard stops.count > 1 else { continue }
                var cumulative = [0.0], fallback: [Double] = []
                let railPattern = route.mode != .bus ? metadata.metro.pattern(route.id, direction: direction) : nil
                let anchors = Dictionary((metadata.journey(routeID: route.id, direction: direction)?.anchors ?? [])
                    .map { ($0.stop.id, $0.match.along) }, uniquingKeysWith: { a, _ in a })
                for index in 1..<stops.count {
                    let a = stops[index - 1], b = stops[index]
                    let rail = route.mode != .bus ? metadata.metro.ridingSeconds(routeID: route.id, direction: direction, from: a.stationID, to: b.stationID) : nil
                    let distance = anchors[a.id].flatMap { first in anchors[b.id].map { abs($0 - first) } } ?? a.coordinate.distance(to: b.coordinate) * 1.25
                    let dwell = index > 1 && railPattern?.dwellSeconds.indices.contains(index - 1) == true ? railPattern!.dwellSeconds[index - 1] : 0
                    fallback.append((rail ?? (distance / tuning.typicalSpeed + tuning.stopSeconds)) + dwell)
                    cumulative.append(cumulative.last! + fallback.last!)
                }
                let windows = route.mode != .bus ? stops.map { metadata.metro.boardingWindow(routeID: route.id, direction: direction, stationID: $0.stationID) } : []
                patterns.append(Pattern(route: route, direction: direction, stops: stops, cumulative: cumulative,
                    dwell: railPattern?.dwellSeconds ?? [], windows: windows, fallback: fallback))
                for stop in stops { stationStops[stop.stationID] = stop }
            }
        }
        self.patterns = patterns; self.stationStops = stationStops
        // Indexed cells keep construction linear for a full city bus catalog.
        func cell(_ c: Coordinate) -> String { "\(Int(floor(c.longitude / 0.003))):\(Int(floor(c.latitude / 0.003)))" }
        let grid = Dictionary(grouping: stationStops.values, by: { cell($0.coordinate) })
        var links: [String: [Link]] = [:]
        for (id, stop) in stationStops {
            let x = Int(floor(stop.coordinate.longitude / 0.003)), y = Int(floor(stop.coordinate.latitude / 0.003))
            let platformWalk = metadata.metro.transfers.first { $0.from == id && $0.to == id }?.seconds ?? 60
            var adjacent = [Link(id: id, distance: 0, seconds: stop.mode == .bus ? 0 : platformWalk, internalWalk: stop.mode != .bus)]
            for dx in -2...2 { for dy in -2...2 {
                for other in grid["\(x + dx):\(y + dy)"] ?? [] where other.stationID != id {
                    if stop.mode != .bus && other.mode != .bus { continue }
                    let from = stop.mode == .bus ? stop.coordinate : metadata.metro.nearestExit(stationID: id, to: other.coordinate)?.coordinate ?? stop.coordinate
                    let to = other.mode == .bus ? other.coordinate : metadata.metro.nearestExit(stationID: other.stationID, to: from)?.coordinate ?? other.coordinate
                    let distance = from.distance(to: to)
                    let maximum = stop.mode == .bus && other.mode == .bus ? 220.0 : 450.0
                    if distance <= maximum {
                        let stationAccess = (stop.mode != .bus ? 120.0 : 0) + (other.mode != .bus ? 120.0 : 0)
                        adjacent.append(Link(id: other.stationID, distance: distance, seconds: distance * 1.25 / 1.2 + stationAccess, internalWalk: false))
                    }
                }
            } }
            for official in metadata.metro.transfers where official.from == id && official.to != id {
                guard let other = stationStops[official.to] else { continue }
                adjacent.append(Link(id: official.to, distance: official.external ? stop.coordinate.distance(to: other.coordinate) : 0,
                    seconds: official.seconds, internalWalk: !official.external))
            }
            links[id] = adjacent.sorted { $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds < $1.seconds }
        }
        self.links = links
    }

    private func timedPatterns(at date: Date) -> [Pattern] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let key = "\(parts.year!)-\(parts.month!)-\(parts.day!)-\(parts.hour!)"
        timing.lock.lock(); defer { timing.lock.unlock() }
        if timing.key != key {
            timing.patterns = patterns.map { $0.timed(metadata.officialTravelTimes, at: date) }
            timing.key = key
        }
        return timing.patterns
    }

    public func plan(from origin: Coordinate, to destination: Coordinate, maximumWalk: Double = 1000, limit: Int = 36,
                     preferences: LiveSettings.Planning = .init(), estimates: EstimateFeed = .init(), at date: Date = Date(),
                     bikeNetwork: BikeNetwork = .empty, bikeAvailability: BikeAvailability? = nil) -> [TransitTrip] {
        guard origin.isInServiceArea, destination.isInServiceArea, maximumWalk > 0, limit > 0 else { return [] }
        let profile = ProcessInfo.processInfo.environment["BUS_PLANNING_PROFILE"] == "1"
        let began = ProcessInfo.processInfo.systemUptime
        let cycling = preferences.bikeRouting && !bikeNetwork.stations.isEmpty && bikeAvailability != nil
        guard !metadata.metro.patterns.isEmpty || cycling else {
            return busPlanner.plan(from: origin, to: destination, maximumWalk: maximumWalk, limit: limit,
                preferences: preferences, estimates: estimates, at: date, preservePlatforms: true)
        }
        let patterns = timedPatterns(at: date)
        let budget = JourneySearchBudget(distance: origin.distance(to: destination), cycling: cycling)
        let bikeRadius = min(preferences.bikeMaximumRideMeters, max(1_500, origin.distance(to: destination) * 0.5))
        func streetDistance(_ stop: BusStop, to c: Coordinate) -> Double {
            if stop.mode == .bus { return stop.coordinate.distance(to: c) }
            return (metadata.metro.nearestExit(stationID: stop.stationID, to: c)?.coordinate ?? stop.coordinate).distance(to: c)
        }
        var accessBikes: [String: [BikeConnection]] = [:], egressBikes: [String: [BikeConnection]] = [:]
        if cycling {
            for (id, stop) in stationStops {
                let access = streetDistance(stop, to: origin), egress = streetDistance(stop, to: destination)
                if access >= preferences.bikeMinimumRideMeters, access <= bikeRadius {
                    let entry = stop.mode == .bus ? stop.coordinate : metadata.metro.nearestExit(stationID: id, to: origin)?.coordinate ?? stop.coordinate
                    accessBikes[id] = BikeRouting.connections(from: origin, to: entry, network: bikeNetwork,
                        availability: bikeAvailability, preferences: preferences, at: date, limit: 1)
                }
                if egress >= preferences.bikeMinimumRideMeters, egress <= bikeRadius {
                    let exit = stop.mode == .bus ? stop.coordinate : metadata.metro.nearestExit(stationID: id, to: destination)?.coordinate ?? stop.coordinate
                    egressBikes[id] = BikeRouting.connections(from: exit, to: destination, network: bikeNetwork,
                        availability: bikeAvailability, preferences: preferences, at: date, limit: 1)
                }
            }
        }
        let bus = busPlanner.plan(from: origin, to: destination, maximumWalk: maximumWalk, limit: limit,
            preferences: preferences, estimates: estimates, at: date, preservePlatforms: true,
            accessConnections: accessBikes.compactMapValues(\.first), egressConnections: egressBikes.compactMapValues(\.first),
            bikeAvailability: bikeAvailability)
        if profile { print("PLANNING_PHASE endpoints_bus seconds=\(ProcessInfo.processInfo.systemUptime - began) access=\(accessBikes.count) egress=\(egressBikes.count) bus=\(bus.count)") }
        var previous: [String: [Label]] = [:]
        for (id, stop) in stationStops {
            let distance = streetDistance(stop, to: origin)
            if distance <= maximumWalk {
                let walking = distance * 1.25 / 1.2 + (stop.mode != .bus ? 120 : 0)
                var label = Label(segments: [], access: distance, distances: [], transferSeconds: [], elapsed: walking,
                    walking: walking, cost: walking * (preferences.walkingWeight + 0.35), lastStation: id, hasRail: false, family: "")
                label.lastWalk = walking; previous[id] = [label]
            }
            for bike in accessBikes[id] ?? [] {
                let station = stop.mode == .bus ? 0.0 : 120.0
                let elapsed = bike.totalSeconds + station, walking = bike.accessSeconds + bike.egressSeconds + station
                let risk = BikeRouting.supplyPenalty(bike, availability: bikeAvailability, at: date)
                var label = Label(segments: [], access: distance, distances: [], transferSeconds: [], elapsed: elapsed,
                    walking: walking, cost: JourneyPreferenceCost.score(elapsed: elapsed, walking: walking, waiting: 0,
                        transfers: 0, rentals: 1, unknownWaits: 0, supplyRisk: risk, preferences: preferences),
                    lastStation: id, hasRail: false, family: "")
                label.bikes[0] = bike; label.supplyRisk = risk; label.lastWalk = elapsed
                previous[id, default: []].append(label)
            }
        }
        var candidates: [Candidate] = []
        let secondsOfDay = BusServiceWindow.secondsOfDay(at: date)
        let minimumWaits = patterns.map { $0.route.minimumServiceWait(direction: $0.direction, at: date, fullRouteSeconds: $0.cumulative.last ?? 0) }
        var serviceCache: [String: BusDayService] = [:]
        func service(_ index: Int, ready: Double) -> BusDayService {
            let key = "\(index):\(Int(ready / 60))"
            if let value = serviceCache[key] { return value }
            let pattern = patterns[index], value: BusDayService
            if pattern.route.mode == .bus { value = pattern.route.servicePlans[pattern.direction]?.service(at: date.addingTimeInterval(ready)) ?? .init() }
            else { value = metadata.metro.service(routeID: pattern.route.id, direction: pattern.direction, at: date.addingTimeInterval(ready)) ?? .init() }
            serviceCache[key] = value; return value
        }
        // Rail waits count every service that stops here and reaches the destination stop.
        var railCache: [String: BusDayService] = [:]
        func railService(_ index: Int, from: Int, to: Int?, ready: Double) -> BusDayService {
            let key = "\(index):\(from):\(to ?? -1):\(Int(ready / 60))"
            if let value = railCache[key] { return value }
            let pattern = patterns[index]
            let value = metadata.metro.combinedService(routeID: pattern.route.id, direction: pattern.direction,
                from: pattern.stops[from].stationID, to: to.map { pattern.stops[$0].stationID },
                at: date.addingTimeInterval(ready)) ?? .init()
            railCache[key] = value; return value
        }
        // Bike transfers are street connections in the same search, not a later rewrite
        // of a route already selected for walking. The spatial index and corridor diversity
        // bound work without selecting only the two nearest metro lines.
        func transferCell(_ point: Coordinate) -> String {
            "\(Int(floor(point.longitude / 0.01))):\(Int(floor(point.latitude / 0.01)))"
        }
        let transferGrid = cycling ? Dictionary(grouping: stationStops.values, by: { transferCell($0.coordinate) }) : [:]
        var streetLinks: [String: [(Link, BikeConnection?)]] = [:]
        func connections(from id: String) -> [(Link, BikeConnection?)] {
            if let cached = streetLinks[id] { return cached }
            var result = (links[id] ?? []).map { ($0, Optional<BikeConnection>.none) }
            guard cycling, let stop = stationStops[id] else { streetLinks[id] = result; return result }
            let start = stop.mode == .bus ? stop.coordinate : metadata.metro.nearestExit(stationID: id, to: destination)?.coordinate ?? stop.coordinate
            guard bikeNetwork.stations(near: start, radius: preferences.bikeAccessMeters, limit: 20).contains(where: {
                BikeRouting.confirmed($0, availability: bikeAvailability, renting: true, at: date)
            }) else { streetLinks[id] = result; return result }
            var targets: [BusStop] = []
            let x = Int(floor(start.longitude / 0.01)), y = Int(floor(start.latitude / 0.01))
            for dx in -3...3 { for dy in -3...3 {
                for other in transferGrid["\(x + dx):\(y + dy)"] ?? [] where other.stationID != id {
                    let distance = start.distance(to: other.coordinate)
                    if distance >= preferences.bikeMinimumRideMeters, distance <= min(2_500, bikeRadius) { targets.append(other) }
                }
            } }
            targets.sort {
                let a = start.distance(to: $0.coordinate) / preferences.bikeSpeed + $0.coordinate.distance(to: destination) / 12
                let b = start.distance(to: $1.coordinate) / preferences.bikeSpeed + $1.coordinate.distance(to: destination) / 12
                return a == b ? $0.stationID < $1.stationID : a < b
            }
            var corridors = Set<String>(), added = Set<String>()
            // Include every published outdoor interchange even when its corridor is also
            // represented by another nearby station. Indoor transfers never rent a bike.
            var eligible = (links[id] ?? []).filter { !$0.internalWalk && $0.distance >= preferences.bikeMinimumRideMeters }
                .compactMap { stationStops[$0.id] }
            for other in targets {
                let route = metadata.routes[other.routeID]
                let corridor = other.mode == .bus ? "bus:" + (route?.parentID ?? other.routeID) : "rail:" + (route?.lineCode ?? other.routeID)
                if corridors.insert(corridor).inserted { eligible.append(other) }
                if corridors.count >= (budget.candidates > 54 ? 12 : 8) { break }
            }
            for other in eligible where added.insert(other.stationID).inserted {
                let end = other.mode == .bus ? other.coordinate : metadata.metro.nearestExit(stationID: other.stationID, to: start)?.coordinate ?? other.coordinate
                let distance = start.distance(to: end)
                let station = (stop.mode == .bus ? 0.0 : 90) + (other.mode == .bus ? 0.0 : 120)
                for bike in BikeRouting.connections(from: start, to: end, network: bikeNetwork,
                    availability: bikeAvailability, preferences: preferences, at: date, limit: 1) {
                    result.append((Link(id: other.stationID, distance: distance, seconds: bike.totalSeconds + station, internalWalk: false), bike))
                }
            }
            streetLinks[id] = result; return result
        }
        // Three transfers cover bus–metro–metro–bus and cross-branch rail journeys.
        for round in 0..<4 {
            if Task.isCancelled { return [] }
            var arrived: [String: [Label]] = [:]
            func insert(_ label: Label, in values: inout [String: [Label]], at id: String) {
                var pool = values[id] ?? []
                let bikeMask = label.bikes.keys.sorted()
                let family = pool.filter { $0.family == label.family && $0.bikes.keys.sorted() == bikeMask }
                // Keep time and convenience representatives of a service chain, rather
                // than every boarding platform which produces almost the same journey.
                if family.contains(where: { abs($0.elapsed - label.elapsed) < 30 && abs($0.walking - label.walking) < 30 && $0.cost <= label.cost }) { return }
                if family.count >= 2, let fastest = family.map(\.elapsed).min(), let cheapest = family.map(\.cost).min(),
                   let leastWalking = family.map(\.walking).min(), label.elapsed >= fastest,
                   label.cost >= cheapest, label.walking >= leastWalking { return }
                // A cheaper but later label must not erase a path which can catch an
                // earlier connection. Rental count and remaining boarding time both matter.
                if pool.contains(where: { $0.cost <= label.cost && $0.elapsed <= label.elapsed && $0.walking <= label.walking &&
                    $0.bikes.count <= label.bikes.count && $0.hasRail == label.hasRail && $0.previousSpread <= label.previousSpread &&
                    $0.unknownWaits <= label.unknownWaits }) { return }
                pool.removeAll { label.cost <= $0.cost && label.elapsed <= $0.elapsed && label.walking <= $0.walking &&
                    label.bikes.count <= $0.bikes.count && label.hasRail == $0.hasRail && label.previousSpread <= $0.previousSpread &&
                    label.unknownWaits <= $0.unknownWaits }
                pool.append(label); pool.sort { $0.cost == $1.cost ? $0.elapsed < $1.elapsed : $0.cost < $1.cost }
                // Retain the fastest label explicitly before filling the preference slots.
                let fastest = pool.min { $0.elapsed < $1.elapsed }!
                var kept = Array(pool.prefix(budget.labels))
                if !kept.contains(where: { $0.elapsed == fastest.elapsed && $0.family == fastest.family && $0.bikes.count == fastest.bikes.count }) {
                    kept.removeLast(); kept.append(fastest)
                }
                values[id] = kept
            }
            for (pIndex, pattern) in patterns.enumerated() {
                var boarding: [(label: Label, index: Int, wait: Double, railHeadway: Double?, unknown: Bool)] = []
                for index in pattern.stops.indices {
                    let stop = pattern.stops[index]
                    // Ride only after boarding; this prevents zero-station transfer legs.
                    for boarded in boarding {
                        let source = boarded.label, seconds: Double
                        let boardingDwell = boarded.index > 0 && pattern.dwell.indices.contains(boarded.index) ? pattern.dwell[boarded.index] : 0
                        seconds = pattern.cumulative[index] - pattern.cumulative[boarded.index] - boardingDwell
                        // Short-turn trains that stop short of this stop do not help: wait for
                        // the sparser service that does reach it.
                        var wait = boarded.wait
                        if let near = boarded.railHeadway,
                           let far = railService(pIndex, from: boarded.index, to: index, ready: source.elapsed).headway?.midpoint,
                           far > near { wait *= far / near }
                        let elapsed = source.elapsed + wait + seconds
                        guard elapsed.isFinite, elapsed < 4 * 3600 else { continue }
                        var label = Label(segments: source.segments + [Segment(pattern: pIndex, first: boarded.index, last: index)],
                            access: source.access, distances: source.distances, transferSeconds: source.transferSeconds,
                            elapsed: elapsed, walking: source.walking,
                            cost: source.cost + wait * preferences.waitingWeight + seconds + (boarded.unknown ? 180 : 0) + (round > 0 ? preferences.effectiveTransferPenaltySeconds : 0),
                            lastStation: stop.stationID, hasRail: source.hasRail || pattern.route.mode != .bus,
                            family: source.family + "|" + pattern.route.parentID)
                        label.bikes = source.bikes; label.supplyRisk = source.supplyRisk
                        label.unknownWaits = source.unknownWaits + (boarded.unknown ? 1 : 0)
                        label.previousSpread = seconds * (pattern.route.mode == .bus ? RidingTimeEstimate.Evidence.officialProfile : .railProfile).spreadFraction
                        insert(label, in: &arrived, at: stop.stationID)
                    }
                    guard index < pattern.stops.count - 1 else { continue }
                    for source in previous[stop.stationID] ?? [] {
                        if source.segments.contains(where: { $0.pattern == pIndex }) { continue }
                        if let last = source.segments.last {
                            let previousRoute = patterns[last.pattern].route
                            // Bus-only chains are already handled by the indexed bus planner.
                            // A mixed search must not expand the entire city's bus–bus graph
                            // before it has entered rail; one feeder on each side is retained.
                            // The indexed bus planner covers ordinary bus-bus changes.
                            // The round search adds bus-bus links when a real bicycle
                            // connection between them makes a new boarding point reachable.
                            if previousRoute.mode == .bus && pattern.route.mode == .bus &&
                                source.bikes[source.segments.count] == nil { continue }
                            if previousRoute.mode == .bus && pattern.route.mode == .bus && previousRoute.parentID == pattern.route.parentID { continue }
                            if patterns[last.pattern].stops[last.first].stationID == stop.stationID { continue }
                        }
                        let rail = pattern.route.mode != .bus
                        let currentService = rail ? railService(pIndex, from: index, to: nil, ready: source.elapsed) : service(pIndex, ready: source.elapsed)
                        let official = estimates.value(routeID: pattern.route.parentID, stopID: stop.id, at: date)
                        if let official, [-2,-3,-4].contains(official) { continue }
                        // No rail service runs from here right now (e.g. a short-turn pattern
                        // published as 0 for this period): never treat that as a short wait.
                        if rail, official == nil, currentService.headway == nil { continue }
                        let buffer = ConnectionTiming.buffer(first: round == 0, walking: source.lastWalk,
                            from: source.segments.last.map { patterns[$0.pattern].route.mode }, to: pattern.route.mode,
                            internalTransfer: source.internalWalk, samePlatform: source.segments.last.map {
                                patterns[$0.pattern].stops[$0.last].stationID == stop.stationID
                            } ?? false, previousSpread: source.previousSpread)
                        let wait = BoardingTime.wait(official: official, readyAt: source.elapsed, buffer: buffer,
                            service: currentService, secondsOfDay: secondsOfDay, boardingOffset: pattern.cumulative[index], minimumServiceWait: minimumWaits[pIndex])
                        if pattern.route.mode != .bus && wait.evidence != .official {
                            guard pattern.windows.indices.contains(index), let window = pattern.windows[index] else { continue }
                            let t = (secondsOfDay + source.elapsed + wait.seconds).truncatingRemainder(dividingBy: 86400)
                            let first = Double(window.firstMinute * 60), last = Double(window.lastMinute * 60)
                            if first <= last ? t < first || t > last : t < first && t > last { continue }
                        }
                        boarding.append((source, index, wait.seconds,
                                         rail && wait.evidence == .headway ? currentService.headway?.midpoint : nil,
                                         wait.evidence == .unknown))
                    }
                    // Keep independent arrival/walking tradeoffs without a combinatorial explosion.
                    if boarding.count > 8 {
                        boarding.sort { ($0.label.cost + $0.wait - pattern.cumulative[$0.index]) < ($1.label.cost + $1.wait - pattern.cumulative[$1.index]) }
                        boarding = Array(boarding.prefix(8))
                    }
                }
            }
            for (id, labels) in arrived {
                guard let stop = stationStops[id] else { continue }
                let egress = streetDistance(stop, to: destination)
                if egress <= maximumWalk {
                    for label in labels where label.hasRail || !label.bikes.isEmpty {
                        let finalAccess = stop.mode != .bus ? 90.0 : 0
                        candidates.append(Candidate(label:label,egress:egress,score:label.cost + (egress * 1.25 / 1.2 + finalAccess) * (preferences.walkingWeight + 0.35), supplyRisk: label.supplyRisk))
                    }
                }
                for label in labels {
                    for bike in egressBikes[id] ?? [] {
                        let finalAccess = stop.mode == .bus ? 0.0 : 90.0
                        let elapsed = bike.totalSeconds + finalAccess
                        let foot = bike.accessSeconds + bike.egressSeconds + finalAccess
                        let risk = BikeRouting.supplyPenalty(bike, availability: bikeAvailability,
                            pickupAfter: label.elapsed + finalAccess, at: date)
                        let extra = JourneyPreferenceCost.score(elapsed: elapsed, walking: foot, waiting: 0,
                            transfers: 0, rentals: 1, unknownWaits: 0, supplyRisk: risk, preferences: preferences)
                        candidates.append(Candidate(label: label, egress: egress, score: label.cost + extra,
                            bike: bike, supplyRisk: label.supplyRisk + risk))
                    }
                }
            }
            if round == 3 { break }
            let bestCost = candidates.map(\.score).min() ?? .infinity
            var next: [String: [Label]] = [:]
            for (id, labels) in arrived {
                guard labels.contains(where: { $0.cost <= bestCost + 900 }) else { continue }
                for (link, bike) in connections(from: id) {
                    for label in labels {
                        if label.cost > bestCost + 900 { continue }
                        if let last = label.segments.last, patterns[last.pattern].route.mode == .bus,
                           stationStops[link.id]?.mode == .bus, bike == nil { continue }
                        // Same platform changing trains still includes a short platform allowance.
                        let duration = link.seconds
                        let foot = bike.map { max(0, duration - $0.rideSeconds - $0.handlingSeconds) } ?? duration
                        let risk = bike.map { BikeRouting.supplyPenalty($0, availability: bikeAvailability, pickupAfter: label.elapsed, at: date) } ?? 0
                        let extra = JourneyPreferenceCost.score(elapsed: duration, walking: foot, waiting: 0, transfers: 0,
                            rentals: bike == nil ? 0 : 1, unknownWaits: 0, supplyRisk: risk, preferences: preferences)
                        var value = Label(segments: label.segments, access: label.access, distances: label.distances + [link.distance],
                            transferSeconds: label.transferSeconds + [duration], elapsed: label.elapsed + duration,
                            walking: label.walking + foot, cost: label.cost + extra,
                            lastStation: link.id, hasRail: label.hasRail, family: label.family)
                        value.bikes = label.bikes
                        if let bike { value.bikes[label.segments.count] = bike }
                        value.supplyRisk = label.supplyRisk + risk; value.lastWalk = duration
                        value.internalWalk = link.internalWalk; value.previousSpread = label.previousSpread
                        value.unknownWaits = label.unknownWaits
                        insert(value, in: &next, at: link.id)
                    }
                }
            }
            previous = next
            if profile { print("PLANNING_PHASE round=\(round) seconds=\(ProcessInfo.processInfo.systemUptime - began) nodes=\(previous.count) candidates=\(candidates.count) transfer_nodes=\(streetLinks.count)") }
        }
        // Construct road slices only for useful candidates, after the complete graph
        // search. Thousands of dominated trips do not need expensive map geometry.
        let grouped = Dictionary(grouping:candidates,by:{ candidate in
            candidate.label.family + "|bikes:" + (candidate.label.bikes.keys.sorted().map(String.init) + (candidate.bike == nil ? [] : ["end"])).joined(separator: "-")
        })
        var representative: [Candidate] = []
        for pool in grouped.values { representative.append(contentsOf:pool.sorted { $0.score < $1.score }.prefix(3)) }
        representative.sort { $0.score == $1.score ? $0.label.family < $1.label.family : $0.score < $1.score }
        let retained = representative.prefix(max(36,limit * 2))
        let results = retained.map { candidate -> TransitTrip in
            let label = candidate.label
            let rides = label.segments.map { segment -> TransitRide in
                let p = patterns[segment.pattern], stops = Array(p.stops[segment.first...segment.last])
                var coordinates: [Coordinate] = []
                if let line = metadata.line(p.route.id,direction:p.direction),
                   let journey = metadata.journey(routeID:p.route.id,direction:p.direction),
                   let from = journey.anchors.first(where:{ $0.stop.id == stops[0].id }),
                   let to = journey.anchors.first(where:{ $0.stop.id == stops.last!.id }) {
                    coordinates = line.slice(from:from.match,to:to.match)
                }
                return TransitRide(route:p.route,direction:p.direction,stops:stops,coordinates:coordinates,
                    fullRouteSeconds:p.cumulative.last ?? 0,boardingOffsetSeconds:p.cumulative[segment.first],
                    railService:p.route.mode != .bus ? metadata.metro.combinedService(routeID:p.route.id,direction:p.direction,
                        from:stops[0].stationID,to:stops.last!.stationID,at:date) : nil,
                    boardingAccessSeconds:p.route.mode != .bus ? 120 : 0,alightingAccessSeconds:p.route.mode != .bus ? 90 : 0)
            }
            let times = label.segments.map { s -> Double in
                let p = patterns[s.pattern], dwell = s.first > 0 && p.dwell.indices.contains(s.first) ? p.dwell[s.first] : 0
                return p.cumulative[s.last] - p.cumulative[s.first] - dwell
            }
            var trip = TransitTrip(rides:rides,accessDistance:label.access,egressDistance:candidate.egress,
                transferDistance:label.distances.reduce(0,+),score:candidate.score,rideSeconds:times,
                transferDistances:label.distances,transferSeconds:label.transferSeconds)
            var connections = label.bikes
            if let bike = candidate.bike { connections[rides.count] = bike }
            trip = trip.withBikeConnections(connections, supplyRisk: candidate.supplyRisk)
            return trip
        }
        let unique = Dictionary((bus + results).map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.score < b.score ? a : b })
        if profile { print("PLANNING_PHASE complete seconds=\(ProcessInfo.processInfo.systemUptime - began) materialized=\(unique.count)") }
        return TripRanking.recommended(Array(unique.values), estimates: estimates, at: date, preferences: preferences, limit: limit, diverse: false)
    }
}
