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
    }
    private struct Candidate {
        let label: Label
        let egress: Double
        let score: Double
    }
    private let metadata: TransitMetadata
    private let patterns: [Pattern]
    private let links: [String: [Link]]
    private let stationStops: [String: BusStop]
    private let busPlanner: TripPlanner

    public init(metadata: TransitMetadata) {
        self.metadata = metadata; busPlanner = TripPlanner(metadata: metadata)
        var patterns: [Pattern] = [], stationStops: [String: BusStop] = [:]
        for route in metadata.routes.values.sorted(by: { $0.id < $1.id }) {
            guard !route.name.contains("觀光巴士"), !route.name.hasPrefix("懷恩專車") else { continue }
            for direction in ["0", "1"] {
                let stops = metadata.orderedStops(routeID: route.id, direction: direction)
                guard stops.count > 1 else { continue }
                var cumulative = [0.0]
                let railPattern = route.mode != .bus ? metadata.metro.pattern(route.id, direction: direction) : nil
                let anchors = Dictionary((metadata.journey(routeID: route.id, direction: direction)?.anchors ?? [])
                    .map { ($0.stop.id, $0.match.along) }, uniquingKeysWith: { a, _ in a })
                for index in 1..<stops.count {
                    let a = stops[index - 1], b = stops[index]
                    let rail = route.mode != .bus ? metadata.metro.ridingSeconds(routeID: route.id, direction: direction, from: a.stationID, to: b.stationID) : nil
                    let published = metadata.officialTravelTimes.seconds(route: route.parentID, subroute: route.id,
                        direction: direction, from: a.id, to: b.id, travellingAt: Date(), observedAt: Date())
                    let distance = anchors[a.id].flatMap { first in anchors[b.id].map { abs($0 - first) } } ?? a.coordinate.distance(to: b.coordinate) * 1.25
                    let dwell = index > 1 && railPattern?.dwellSeconds.indices.contains(index - 1) == true ? railPattern!.dwellSeconds[index - 1] : 0
                    cumulative.append(cumulative.last! + (rail ?? published ?? (distance / 4.5 + 20)) + dwell)
                }
                let windows = route.mode != .bus ? stops.map { metadata.metro.boardingWindow(routeID: route.id, direction: direction, stationID: $0.stationID) } : []
                patterns.append(Pattern(route: route, direction: direction, stops: stops, cumulative: cumulative,
                    dwell: railPattern?.dwellSeconds ?? [], windows: windows))
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

    public func plan(from origin: Coordinate, to destination: Coordinate, maximumWalk: Double = 1000, limit: Int = 36,
                     preferences: LiveSettings.Planning = .init(), estimates: EstimateFeed = .init(), at date: Date = Date()) -> [TransitTrip] {
        guard origin.isInServiceArea, destination.isInServiceArea, maximumWalk > 0, limit > 0 else { return [] }
        let bus = busPlanner.plan(from: origin, to: destination, maximumWalk: maximumWalk, limit: limit,
            preferences: preferences, estimates: estimates, at: date, preservePlatforms: true)
        guard !metadata.metro.patterns.isEmpty else { return bus }
        func streetDistance(_ stop: BusStop, to c: Coordinate) -> Double {
            if stop.mode == .bus { return stop.coordinate.distance(to: c) }
            return (metadata.metro.nearestExit(stationID: stop.stationID, to: c)?.coordinate ?? stop.coordinate).distance(to: c)
        }
        var previous: [String: [Label]] = [:]
        for (id, stop) in stationStops {
            let distance = streetDistance(stop, to: origin)
            if distance <= maximumWalk {
                let walking = distance * 1.25 / 1.2 + (stop.mode != .bus ? 120 : 0)
                previous[id] = [Label(segments: [], access: distance, distances: [], transferSeconds: [], elapsed: walking,
                    walking: walking, cost: walking * preferences.walkingWeight, lastStation: id, hasRail: false, family: "")]
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
        // Three transfers cover bus–metro–metro–bus and cross-branch rail journeys.
        for round in 0..<4 {
            if Task.isCancelled { return [] }
            var arrived: [String: [Label]] = [:]
            func insert(_ label: Label, in values: inout [String: [Label]], at id: String) {
                var pool = values[id] ?? []
                if let same = pool.firstIndex(where: { $0.family == label.family }) {
                    guard pool[same].cost > label.cost else { return }; pool.remove(at: same)
                }
                if pool.contains(where: { $0.cost <= label.cost && $0.walking <= label.walking && $0.hasRail == label.hasRail }) { return }
                pool.append(label); pool.sort { $0.cost < $1.cost }; values[id] = Array(pool.prefix(4))
            }
            for (pIndex, pattern) in patterns.enumerated() {
                var boarding: [(label: Label, index: Int, wait: Double, railHeadway: Double?)] = []
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
                        let label = Label(segments: source.segments + [Segment(pattern: pIndex, first: boarded.index, last: index)],
                            access: source.access, distances: source.distances, transferSeconds: source.transferSeconds,
                            elapsed: elapsed, walking: source.walking,
                            cost: source.cost + wait * preferences.waitingWeight + seconds + (round > 0 ? min(300, preferences.transferPenaltySeconds) : 0),
                            lastStation: stop.stationID, hasRail: source.hasRail || pattern.route.mode != .bus,
                            family: source.family + "|" + pattern.route.parentID)
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
                            if previousRoute.mode == .bus && pattern.route.mode == .bus { continue }
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
                        let wait = BoardingTime.wait(official: official, readyAt: source.elapsed, buffer: pattern.route.mode == .bus ? (round > 0 ? 90 : 60) : 30,
                            service: currentService, secondsOfDay: secondsOfDay, boardingOffset: pattern.cumulative[index], minimumServiceWait: minimumWaits[pIndex])
                        if pattern.route.mode != .bus && wait.evidence != .official {
                            guard pattern.windows.indices.contains(index), let window = pattern.windows[index] else { continue }
                            let t = (secondsOfDay + source.elapsed + wait.seconds).truncatingRemainder(dividingBy: 86400)
                            let first = Double(window.firstMinute * 60), last = Double(window.lastMinute * 60)
                            if first <= last ? t < first || t > last : t < first && t > last { continue }
                        }
                        boarding.append((source, index, wait.seconds,
                                         rail && wait.evidence == .headway ? currentService.headway?.midpoint : nil))
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
                    for label in labels where label.hasRail {
                        let finalAccess = stop.mode != .bus ? 90.0 : 0
                        candidates.append(Candidate(label:label,egress:egress,score:label.cost + (egress * 1.25 / 1.2 + finalAccess) * preferences.walkingWeight))
                    }
                }
            }
            if round == 3 { break }
            var next: [String: [Label]] = [:]
            for (id, labels) in arrived {
                for link in links[id] ?? [] {
                    for label in labels {
                        if let last = label.segments.last, patterns[last.pattern].route.mode == .bus,
                           stationStops[link.id]?.mode == .bus { continue }
                        // Same platform changing trains still includes a short platform allowance.
                        let duration = link.seconds
                        let value = Label(segments: label.segments, access: label.access, distances: label.distances + [link.distance],
                            transferSeconds: label.transferSeconds + [duration], elapsed: label.elapsed + duration,
                            walking: label.walking + duration, cost: label.cost + duration * preferences.walkingWeight,
                            lastStation: link.id, hasRail: label.hasRail, family: label.family)
                        insert(value, in: &next, at: link.id)
                    }
                }
            }
            previous = next
        }
        // Construct road slices only for useful candidates, after the complete graph
        // search. Thousands of dominated trips do not need expensive map geometry.
        let grouped = Dictionary(grouping:candidates,by:{ $0.label.family })
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
            return TransitTrip(rides:rides,accessDistance:label.access,egressDistance:candidate.egress,
                transferDistance:label.distances.reduce(0,+),score:candidate.score,rideSeconds:times,
                transferDistances:label.distances,transferSeconds:label.transferSeconds)
        }
        let unique = Dictionary((bus + results).map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.score < b.score ? a : b })
        return TripRanking.recommended(Array(unique.values), estimates: estimates, at: date, preferences: preferences, limit: limit, diverse: false)
    }
}
