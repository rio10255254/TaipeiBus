import Foundation

/// Round-based transit search. Each round adds one actual operating pattern;
/// shared station names never splice trains or buses into a fictitious direct service.
public struct MultimodalPlanner: Sendable {
    private struct Pattern: Sendable {
        let route: BusRoute
        let direction: String
        let stops: [BusStop]
        let cumulative: [Double]
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
                let anchors = Dictionary((metadata.journey(routeID: route.id, direction: direction)?.anchors ?? [])
                    .map { ($0.stop.id, $0.match.along) }, uniquingKeysWith: { a, _ in a })
                for index in 1..<stops.count {
                    let a = stops[index - 1], b = stops[index]
                    let rail = metadata.metro.ridingSeconds(routeID: route.id, direction: direction, from: a.stationID, to: b.stationID)
                    let published = metadata.officialTravelTimes.seconds(route: route.parentID, subroute: route.id,
                        direction: direction, from: a.id, to: b.id, travellingAt: Date(), observedAt: Date())
                    let distance = anchors[a.id].flatMap { first in anchors[b.id].map { abs($0 - first) } } ?? a.coordinate.distance(to: b.coordinate) * 1.25
                    cumulative.append(cumulative.last! + (rail ?? published ?? (distance / 4.5 + 20)))
                }
                patterns.append(Pattern(route: route, direction: direction, stops: stops, cumulative: cumulative))
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
            var adjacent = [Link(id: id, distance: 0, seconds: 0, internalWalk: stop.mode != .bus)]
            for dx in -2...2 { for dy in -2...2 {
                for other in grid["\(x + dx):\(y + dy)"] ?? [] where other.stationID != id {
                    if stop.mode != .bus && other.mode != .bus { continue }
                    let from = metadata.metro.nearestExit(stationID: id, to: other.coordinate)?.coordinate ?? stop.coordinate
                    let to = metadata.metro.nearestExit(stationID: other.stationID, to: from)?.coordinate ?? other.coordinate
                    let distance = from.distance(to: to)
                    let maximum = stop.mode == .bus && other.mode == .bus ? 220.0 : 450.0
                    if distance <= maximum {
                        let stationAccess = (stop.mode != .bus ? 120.0 : 0) + (other.mode != .bus ? 120.0 : 0)
                        adjacent.append(Link(id: other.stationID, distance: distance, seconds: distance * 1.25 / 1.2 + stationAccess, internalWalk: false))
                    }
                }
            } }
            for official in metadata.metro.transfers where official.from == id {
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
            (metadata.metro.nearestExit(stationID: stop.stationID, to: c)?.coordinate ?? stop.coordinate).distance(to: c)
        }
        var previous: [String: [Label]] = [:]
        for (id, stop) in stationStops {
            let distance = streetDistance(stop, to: origin)
            if distance <= maximumWalk {
                let walking = distance * 1.25 / 1.2 + (stop.mode != .bus ? 120 : 0)
                previous[id] = [Label(segments: [], access: distance, distances: [], transferSeconds: [], elapsed: walking,
                    walking: walking, cost: walking * preferences.walkingWeight, lastStation: id, hasRail: false)]
            }
        }
        var results: [TransitTrip] = []
        // Three transfers cover bus–metro–metro–bus and cross-branch rail journeys.
        for round in 0..<4 {
            if Task.isCancelled { return [] }
            var arrived: [String: [Label]] = [:]
            func insert(_ label: Label, in values: inout [String: [Label]], at id: String) {
                var pool = values[id] ?? []
                let family = label.segments.map { patterns[$0.pattern].route.parentID }.joined(separator: "|")
                if let same = pool.firstIndex(where: { $0.segments.map { patterns[$0.pattern].route.parentID }.joined(separator: "|") == family }) {
                    guard pool[same].cost > label.cost else { return }; pool.remove(at: same)
                }
                if pool.contains(where: { $0.cost <= label.cost && $0.walking <= label.walking && $0.hasRail == label.hasRail }) { return }
                pool.append(label); pool.sort { $0.cost < $1.cost }; values[id] = Array(pool.prefix(4))
            }
            for (pIndex, pattern) in patterns.enumerated() {
                var boarding: [(label: Label, index: Int, wait: Double)] = []
                for index in pattern.stops.indices {
                    let stop = pattern.stops[index]
                    // Ride only after boarding; this prevents zero-station transfer legs.
                    for boarded in boarding {
                        let source = boarded.label, seconds: Double
                        if pattern.route.mode != .bus {
                            seconds = metadata.metro.ridingSeconds(routeID: pattern.route.id, direction: pattern.direction,
                                from: pattern.stops[boarded.index].stationID, to: stop.stationID) ?? .infinity
                        } else { seconds = pattern.cumulative[index] - pattern.cumulative[boarded.index] }
                        let elapsed = source.elapsed + boarded.wait + seconds
                        guard elapsed.isFinite, elapsed < 4 * 3600 else { continue }
                        let label = Label(segments: source.segments + [Segment(pattern: pIndex, first: boarded.index, last: index)],
                            access: source.access, distances: source.distances, transferSeconds: source.transferSeconds,
                            elapsed: elapsed, walking: source.walking,
                            cost: source.cost + boarded.wait * preferences.waitingWeight + seconds + (round > 0 ? min(300, preferences.transferPenaltySeconds) : 0),
                            lastStation: stop.stationID, hasRail: source.hasRail || pattern.route.mode != .bus)
                        insert(label, in: &arrived, at: stop.stationID)
                    }
                    guard index < pattern.stops.count - 1 else { continue }
                    for source in previous[stop.stationID] ?? [] {
                        if source.segments.contains(where: { $0.pattern == pIndex }) { continue }
                        if let last = source.segments.last {
                            let previousRoute = patterns[last.pattern].route
                            if previousRoute.mode == .bus && pattern.route.mode == .bus && previousRoute.parentID == pattern.route.parentID { continue }
                            if patterns[last.pattern].stops[last.first].stationID == stop.stationID { continue }
                        }
                        let service = pattern.route.mode == .bus ? pattern.route.servicePlans[pattern.direction]?.service(at: date.addingTimeInterval(source.elapsed)) :
                            metadata.metro.service(routeID: pattern.route.id, direction: pattern.direction, at: date.addingTimeInterval(source.elapsed))
                        let official = estimates.value(routeID: pattern.route.parentID, stopID: stop.id, at: date)
                        if let official, [-2,-3,-4].contains(official) { continue }
                        let wait = BoardingTime.wait(official: official, readyAt: source.elapsed, buffer: pattern.route.mode == .bus ? (round > 0 ? 90 : 60) : 30,
                            service: service, secondsOfDay: BusServiceWindow.secondsOfDay(at: date), boardingOffset: pattern.cumulative[index],
                            minimumServiceWait: pattern.route.minimumServiceWait(direction: pattern.direction, at: date, fullRouteSeconds: pattern.cumulative.last ?? 0))
                        if pattern.route.mode != .bus && wait.evidence != .official && !metadata.metro.isOperating(routeID: pattern.route.id, direction: pattern.direction,
                            stationID: stop.stationID, at: date.addingTimeInterval(source.elapsed + wait.seconds)) { continue }
                        boarding.append((source, index, wait.seconds))
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
                        let rides = label.segments.map { segment -> TransitRide in
                            let p = patterns[segment.pattern], stops = Array(p.stops[segment.first...segment.last])
                            var coordinates: [Coordinate] = []
                            if let line = metadata.line(p.route.id, direction: p.direction),
                               let from = line.match(stops[0].coordinate, heading: nil), let to = line.match(stops.last!.coordinate, heading: nil) {
                                coordinates = line.slice(from: from, to: to)
                            }
                            return TransitRide(route: p.route, direction: p.direction, stops: stops, coordinates: coordinates,
                                fullRouteSeconds: p.cumulative.last ?? 0, boardingOffsetSeconds: p.cumulative[segment.first],
                                railService: p.route.mode != .bus ? metadata.metro.service(routeID: p.route.id, direction: p.direction, at: date) : nil,
                                boardingAccessSeconds: p.route.mode != .bus ? 120 : 0, alightingAccessSeconds: p.route.mode != .bus ? 90 : 0)
                        }
                        let times = label.segments.map { s in
                            let p = patterns[s.pattern]
                            return metadata.metro.ridingSeconds(routeID: p.route.id, direction: p.direction,
                                from: p.stops[s.first].stationID, to: p.stops[s.last].stationID) ?? (p.cumulative[s.last] - p.cumulative[s.first])
                        }
                        results.append(TransitTrip(rides: rides, accessDistance: label.access, egressDistance: egress,
                            transferDistance: label.distances.reduce(0,+), score: label.cost + egress * 1.25 / 1.2 * preferences.walkingWeight,
                            rideSeconds: times, transferDistances: label.distances, transferSeconds: label.transferSeconds))
                    }
                }
            }
            var next: [String: [Label]] = [:]
            for (id, labels) in arrived {
                for link in links[id] ?? [] {
                    for label in labels {
                        // Same platform changing trains still includes a short platform allowance.
                        let duration = link.id == id && link.internalWalk ? 60.0 : link.seconds
                        let value = Label(segments: label.segments, access: label.access, distances: label.distances + [link.distance],
                            transferSeconds: label.transferSeconds + [duration], elapsed: label.elapsed + duration,
                            walking: label.walking + duration, cost: label.cost + duration * preferences.walkingWeight,
                            lastStation: link.id, hasRail: label.hasRail)
                        insert(value, in: &next, at: link.id)
                    }
                }
            }
            previous = next
        }
        let unique = Dictionary((bus + results).map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.score < b.score ? a : b })
        return TripRanking.recommended(Array(unique.values), estimates: estimates, at: date, preferences: preferences, limit: limit, diverse: false)
    }
}
