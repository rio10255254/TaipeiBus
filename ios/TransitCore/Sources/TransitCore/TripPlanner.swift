import Foundation

public struct TransitRide: Identifiable, Sendable {
    public var id: String { "\(route.id):\(direction):\(boarding.id):\(alighting.id)" }
    public let route: BusRoute
    public let direction: String
    public let stops: [BusStop]
    public let coordinates: [Coordinate]
    public var fullRouteSeconds: Double = 0
    public var boardingOffsetSeconds: Double = 0
    public var railService: BusDayService? = nil
    public var boardingAccessSeconds: Double = 0
    public var alightingAccessSeconds: Double = 0
    public init(route: BusRoute, direction: String, stops: [BusStop], coordinates: [Coordinate],
                fullRouteSeconds: Double = 0, boardingOffsetSeconds: Double = 0, railService: BusDayService? = nil,
                boardingAccessSeconds: Double = 0, alightingAccessSeconds: Double = 0) {
        self.route = route; self.direction = direction; self.stops = stops; self.coordinates = coordinates
        self.fullRouteSeconds = fullRouteSeconds; self.boardingOffsetSeconds = boardingOffsetSeconds
        self.railService = railService; self.boardingAccessSeconds = boardingAccessSeconds; self.alightingAccessSeconds = alightingAccessSeconds
    }
    public var boarding: BusStop { stops.first! }
    public var alighting: BusStop { stops.last! }
    public var stopCount: Int { stops.count - 1 }
}

public struct TransitTrip: Identifiable, Sendable {
    public var id: String { rides.map(\.id).joined(separator: "|") }
    public let rides: [TransitRide]
    /// Straight-line access distance for candidate ranking, not a verified walking route.
    public let accessDistance: Double
    public let egressDistance: Double
    public let transferDistance: Double
    public let score: Double
    public let rideSeconds: [Double]
    public var transferDistances: [Double] = []
    public var transferSeconds: [Double] = []
    public var walkingDistances: [Double] {
        [accessDistance] + (rides.count > 1 ? (transferDistances.count == rides.count - 1 ? transferDistances :
            Array(repeating: transferDistance / Double(rides.count - 1), count: rides.count - 1)) : []) + [egressDistance]
    }
    public var planningWalkSeconds: [Double] {
        var result = walkingDistances.map { $0 * 1.25 / 1.2 }
        guard !rides.isEmpty else { return result }
        result[0] += rides[0].boardingAccessSeconds
        result[result.count - 1] += rides.last!.alightingAccessSeconds
        for index in 0..<transfers {
            if transferSeconds.indices.contains(index), transferSeconds[index] >= 0 {
                result[index + 1] = transferSeconds[index]
            } else { result[index + 1] += rides[index].alightingAccessSeconds + rides[index + 1].boardingAccessSeconds }
        }
        return result
    }
    public var transfers: Int { max(0, rides.count - 1) }
    public var familyID: String { rides.map { "\($0.route.parentID):\($0.direction)" }.joined(separator: "|") }
}

/// A branch and direction retain their own stop order. A trip never joins different branches into one ride.
/// Build this index off the UI actor when metadata changes, then reuse it for destination searches.
public struct TripPlanner: Sendable {
    private struct Pattern: Sendable {
        let route: BusRoute
        let direction: String
        let stops: [BusStop]
        let distances: [Double]
        let fingerprint: UInt64
    }
    private struct Occurrence: Sendable { let pattern: Int; let index: Int }
    private struct Segment: Sendable { let pattern: Int; let board: Int; let alight: Int }
    private struct Exit { let index: Int; let walk: Double }
    private struct Candidate {
        let segments: [Segment]
        let access: Double
        let egress: Double
        let transfer: Double
        let score: Double
        let identity: String
    }
    private struct Cell: Hashable {
        let x: Int; let y: Int
        init(_ coordinate: Coordinate) {
            x = Int(floor(coordinate.longitude / 0.002)); y = Int(floor(coordinate.latitude / 0.002))
        }
        init(x: Int, y: Int) { self.x = x; self.y = y }
    }

    private let metadata: TransitMetadata
    private let patterns: [Pattern]
    private let occurrences: [String: [Occurrence]]
    private let stations: [String: Station]
    private let transferStations: [String: [(id: String, distance: Double)]]

    public init(metadata: TransitMetadata) {
        self.metadata = metadata
        var patterns: [Pattern] = [], occurrences: [String: [Occurrence]] = [:]
        var usedStations: [String: Station] = [:]
        for route in metadata.routes.values.sorted(by: { $0.id < $1.id }) {
            guard route.mode == .bus else { continue }
            // These have special tickets or a restricted trip purpose. They remain
            // searchable, but are not interchangeable with ordinary city buses.
            guard !route.name.contains("觀光巴士"), !route.name.hasPrefix("懷恩專車") else { continue }
            for direction in ["0", "1"] {
                let stops = metadata.orderedStops(routeID: route.id, direction: direction)
                guard stops.count >= 2 else { continue }
                let index = patterns.count
                var distances = [0.0]
                let journey = metadata.journey(routeID: route.id, direction: direction)
                let anchors = Dictionary((journey?.anchors ?? []).map { ($0.stop.id, $0.match.along) }, uniquingKeysWith: { a, _ in a })
                for i in 1..<stops.count {
                    let distance: Double
                    if let from = anchors[stops[i - 1].id], let to = anchors[stops[i].id] {
                        distance = abs(to - from)
                    } else { distance = stops[i - 1].coordinate.distance(to: stops[i].coordinate) * 1.25 }
                    distances.append(distances[i - 1] + distance)
                }
                patterns.append(Pattern(route: route, direction: direction, stops: stops, distances: distances,
                    fingerprint: stops.flatMap { Array($0.id.utf8) + [0] }.reduce(UInt64(1_469_598_103_934_665_603)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }))
                for (position, stop) in stops.enumerated() {
                    guard let station = metadata.stations[stop.stationID] else { continue }
                    usedStations[station.id] = station
                    occurrences[station.id, default: []].append(Occurrence(pattern: index, index: position))
                }
            }
        }
        self.patterns = patterns; self.occurrences = occurrences; stations = usedStations
        let grid = Dictionary(grouping: usedStations.values, by: { Cell($0.coordinate) })
        var neighbors: [String: [(String, Double)]] = [:]
        for station in usedStations.values {
            let cell = Cell(station.coordinate)
            var nearby: [(String, Double)] = []
            for x in (cell.x - 2)...(cell.x + 2) {
                for y in (cell.y - 2)...(cell.y + 2) {
                    for other in grid[Cell(x: x, y: y)] ?? [] {
                        let distance = station.coordinate.distance(to: other.coordinate)
                        if distance <= 220 { nearby.append((other.id, distance)) }
                    }
                }
            }
            neighbors[station.id] = nearby.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
        }
        transferStations = neighbors
    }

    public func plan(from origin: Coordinate, to destination: Coordinate,
                     maximumWalk: Double = 1_000, limit: Int = 6,
                     preferences: LiveSettings.Planning = LiveSettings.Planning(),
                     estimates: EstimateFeed? = nil, at date: Date = Date(), preservePlatforms: Bool = false) -> [TransitTrip] {
        guard origin.isInServiceArea, destination.isInServiceArea, maximumWalk > 0, limit > 0 else { return [] }
        func nearby(_ point: Coordinate) -> [(id: String, distance: Double)] {
            var matches: [(id: String, distance: Double)] = []
            for station in stations.values {
                let distance = station.coordinate.distance(to: point)
                if distance <= maximumWalk { matches.append((station.id, distance)) }
            }
            matches.sort { a, b in a.distance == b.distance ? a.id < b.id : a.distance < b.distance }
            return matches
        }
        let origins = nearby(origin), destinations = nearby(destination)
        guard !origins.isEmpty, !destinations.isEmpty else { return [] }
        var exits: [Int: [Exit]] = [:]
        for station in destinations {
            for occurrence in occurrences[station.id] ?? [] {
                exits[occurrence.pattern, default: []].append(Exit(index: occurrence.index, walk: station.distance))
            }
        }
        // Use source-specific times before limiting candidates.
        let routeTimes = patterns.map { pattern -> [Double] in
            var values = [0.0]
            for index in pattern.stops.indices.dropFirst() {
                let previous = values.last!
                let official = metadata.officialTravelTimes.seconds(route: pattern.route.parentID,
                    subroute: pattern.route.id, direction: pattern.direction,
                    from: pattern.stops[index - 1].id, to: pattern.stops[index].id,
                    travellingAt: date.addingTimeInterval(previous), observedAt: date)
                values.append(previous + (official ??
                    ((pattern.distances[index] - pattern.distances[index - 1]) / 4.5 + 20)))
            }
            return values
        }
        // The final ride's best alighting stop is independent of when the passenger
        // boards it. Cache that suffix once instead of enumerating every destination
        // platform for every possible transfer. Keep a second distinct platform for
        // the rule that rejects a loop back to the departure platform.
        let bestExits: [[[Exit]]] = patterns.enumerated().map { patternIndex, pattern in
            let byIndex = Dictionary(grouping: exits[patternIndex] ?? [], by: \.index)
            func exitCost(_ exit: Exit) -> Double {
                routeTimes[patternIndex][exit.index] + exit.walk * 1.25 / 1.2 * preferences.walkingWeight
            }
            var best: [Exit] = []
            var result = Array(repeating: [Exit](), count: pattern.stops.count)
            for index in pattern.stops.indices.reversed() {
                result[index] = best
                if let additions = byIndex[index] {
                    let ordered = (best + additions).sorted {
                        let a = exitCost($0), b = exitCost($1)
                        return a == b ? $0.index < $1.index : a < b
                    }
                    var seen = Set<String>()
                    let distinct = ordered.filter { seen.insert(pattern.stops[$0.index].stationID).inserted }
                    // Keep different alighting trade-offs until actual walking is known.
                    var retained = Array(distinct.prefix(2))
                    if let shortestWalk = distinct.min(by: { $0.walk < $1.walk }), !retained.contains(where: { $0.index == shortestWalk.index }) {
                        retained.append(shortestWalk)
                    }
                    best = retained
                }
            }
            return result
        }
        let arrivals = patterns.map { pattern in pattern.stops.map {
            estimates?.value(routeID: pattern.route.parentID, stopID: $0.id, at: date)
        } }
        let families = patterns.map { "\($0.route.parentID):\($0.direction)" }
        let timeOfDay = BusServiceWindow.secondsOfDay(at: date)
        let services = patterns.map { $0.route.servicePlans[$0.direction]?.service(at: date) }
        let serviceWaits = patterns.enumerated().map { index, pattern in
            pattern.route.minimumServiceWait(direction: pattern.direction, at: date,
                fullRouteSeconds: routeTimes[index].last ?? 0)
        }
        var candidates: [String: [Candidate]] = [:]
        func add(_ segments: [Segment], access: Double, egress: Double, transfer: Double) {
            // Apply availability before ranking and limiting candidates: many cheap closed
            // routes must not crowd all usable alternatives out of the result window.
            for segment in segments {
                if let seconds = arrivals[segment.pattern][segment.board], [-2, -3, -4].contains(seconds) { return }
            }
            // Bound each family's work without collapsing different boarding/alighting
            // platforms before pedestrian routing can reveal barriers and detours.
            let key = segments.map { families[$0.pattern] }.joined(separator: "|")
            let riding = segments.map { segment in
                return routeTimes[segment.pattern][segment.alight] - routeTimes[segment.pattern][segment.board]
            }
            let walking = ([access] + (segments.count > 1 ? [transfer] : []) + [egress]).map { $0 * 1.25 / 1.2 }
            let boardingArrivals = segments.map { arrivals[$0.pattern][$0.board] }
            let score = TripRanking.assess(riding: riding, walking: walking, arrivals: boardingArrivals, preferences: preferences,
                minimumServiceWaits: segments.map { serviceWaits[$0.pattern] },
                services: segments.map { services[$0.pattern] },
                boardingOffsets: segments.map { routeTimes[$0.pattern][$0.board] }, at: date,
                serviceTimeOfDay: timeOfDay).score
            if !preservePlatforms {
                if let best = candidates[key]?.first, best.score <= score { return }
                candidates[key] = [Candidate(segments: segments, access: access, egress: egress, transfer: transfer, score: score,
                    identity: segments.map { "\($0.pattern):\($0.board):\($0.alight)" }.joined(separator: "|"))]
                return
            }
            let fingerprint = segments.map { segment in
                    let p = patterns[segment.pattern]
                    return "\(p.stops[segment.board].stationID)>\(p.stops[segment.alight].stationID):\(p.fingerprint)"
                }.joined(separator: "|")
            let value = Candidate(segments: segments, access: access, egress: egress, transfer: transfer, score: score, identity: fingerprint)
            var pool = candidates[key] ?? []
            if let index = pool.firstIndex(where: { $0.identity == fingerprint }) {
                if pool[index].score <= score { return }; pool.remove(at: index)
            }
            pool.append(value)
            if pool.count > 6 {
                let ordered = pool.sorted { $0.score < $1.score }
                var retained = Array(ordered.prefix(3))
                for candidate in [pool.min(by: { $0.access < $1.access }), pool.min(by: { $0.egress < $1.egress }),
                                  pool.min(by: { ($0.access + $0.egress + $0.transfer) < ($1.access + $1.egress + $1.transfer) }),
                                  pool.min(by: { a, b in
                                      let ar = a.segments.reduce(0.0) { $0 + patterns[$1.pattern].distances[$1.alight] - patterns[$1.pattern].distances[$1.board] }
                                      let br = b.segments.reduce(0.0) { $0 + patterns[$1.pattern].distances[$1.alight] - patterns[$1.pattern].distances[$1.board] }
                                      return ar < br
                                  })].compactMap({ $0 }) {
                    if !retained.contains(where: { $0.identity == candidate.identity }) { retained.append(candidate) }
                    if retained.count == 6 { break }
                }
                pool = retained
            }
            candidates[key] = pool
        }
        for start in origins {
            if Task.isCancelled { return [] }
            for board in occurrences[start.id] ?? [] {
                let first = patterns[board.pattern]
                guard board.index < first.stops.count - 1 else { continue }
                for exit in bestExits[board.pattern][board.index].prefix(preservePlatforms ? 3 : 1) {
                    add([Segment(pattern: board.pattern, board: board.index, alight: exit.index)],
                        access: start.distance, egress: exit.walk, transfer: 0)
                }
                for interchange in (board.index + 1)..<first.stops.count {
                    let station = first.stops[interchange].stationID
                    for neighbor in transferStations[station] ?? [] {
                        for next in occurrences[neighbor.id] ?? [] {
                            let second = patterns[next.pattern]
                            guard second.route.parentID != first.route.parentID else { continue }
                            for exit in bestExits[next.pattern][next.index].filter({ second.stops[$0.index].stationID != start.id }).prefix(preservePlatforms ? 3 : 1) {
                                add([Segment(pattern: board.pattern, board: board.index, alight: interchange),
                                     Segment(pattern: next.pattern, board: next.index, alight: exit.index)],
                                    access: start.distance, egress: exit.walk, transfer: neighbor.distance)
                            }
                        }
                    }
                }
            }
        }
        let pools = candidates.keys.sorted()
        let all = pools.flatMap { candidates[$0]! }
        let eligible = preservePlatforms ? all : pools.compactMap { candidates[$0]!.min { $0.score < $1.score } }
        let ordered = eligible.sorted { $0.score == $1.score ? $0.identity < $1.identity : $0.score < $1.score }
        var limited = Array(ordered.prefix(limit))
        if limit >= 2 {
            let representatives = [ordered.first(where: { $0.segments.count == 1 }),
                limit >= 3 ? ordered.min(by: { ($0.access + $0.egress + $0.transfer) < ($1.access + $1.egress + $1.transfer) }) : nil].compactMap { $0 }
            for (index, candidate) in representatives.enumerated() {
                if !limited.contains(where: { $0.segments.map { "\($0.pattern):\($0.board):\($0.alight)" } == candidate.segments.map { "\($0.pattern):\($0.board):\($0.alight)" } }) {
                    limited[max(0, limited.count - 1 - index)] = candidate
                }
            }
        }
        return limited.map { candidate in
            let rides = candidate.segments.map { segment -> TransitRide in
                let pattern = patterns[segment.pattern]
                let stops = Array(pattern.stops[segment.board...segment.alight])
                var coordinates: [Coordinate] = []
                if let line = metadata.line(pattern.route.id, direction: pattern.direction),
                   let journey = metadata.journey(routeID: pattern.route.id, direction: pattern.direction),
                   let from = journey.anchors.first(where: { $0.stop.id == stops.first!.id }),
                   let to = journey.anchors.first(where: { $0.stop.id == stops.last!.id }) {
                    coordinates = line.slice(from: from.match, to: to.match)
                }
                // Do not draw straight segments across buildings when the official road geometry is unavailable.
                return TransitRide(route: pattern.route, direction: pattern.direction, stops: stops, coordinates: coordinates,
                    fullRouteSeconds: routeTimes[segment.pattern].last ?? 0,
                    boardingOffsetSeconds: routeTimes[segment.pattern][segment.board])
            }
            return TransitTrip(rides: rides, accessDistance: candidate.access, egressDistance: candidate.egress,
                transferDistance: candidate.transfer, score: candidate.score,
                rideSeconds: candidate.segments.map { segment in
                    return routeTimes[segment.pattern][segment.alight] - routeTimes[segment.pattern][segment.board]
                })
        }
    }
}
