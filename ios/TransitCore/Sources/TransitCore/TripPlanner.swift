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
    /// Distinguishes alternatives built on the same rides, such as cycling to the first stop
    /// instead of walking. The family stays the same, so only the better one is offered.
    public var variant: String = ""
    public var id: String { rides.map(\.id).joined(separator: "|") + (variant.isEmpty ? "" : "#" + variant) }
    public let rides: [TransitRide]
    /// Straight-line access distance for candidate ranking, not a verified walking route.
    public let accessDistance: Double
    public let egressDistance: Double
    public let transferDistance: Double
    public let score: Double
    public let rideSeconds: [Double]
    public var transferDistances: [Double] = []
    public var transferSeconds: [Double] = []
    /// First-class street connections considered during the transit search, indexed like
    /// walkingDistances (access = 0, egress = rides.count).
    public var bikeConnections: [Int: BikeConnection] = [:]
    public var planningSupplyRisk: Double = 0
    public var planningCyclingSeconds: Double { bikeConnections.values.reduce(0) { $0 + $1.rideSeconds + $1.handlingSeconds } }
    public func withBikeConnections(_ connections: [Int: BikeConnection], supplyRisk: Double = 0) -> TransitTrip {
        var result = self; result.bikeConnections = connections; result.planningSupplyRisk = supplyRisk
        if !connections.isEmpty {
            result.variant = "bikes-" + connections.keys.sorted().map { "\($0)-\(BikeRouting.pairID(connections[$0]!))" }.joined(separator: "-")
        }
        return result
    }
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
        for (index, connection) in bikeConnections where result.indices.contains(index) {
            let access = index == 0 ? rides[0].boardingAccessSeconds :
                index == rides.count ? rides.last!.alightingAccessSeconds :
                rides[index - 1].alightingAccessSeconds + rides[index].boardingAccessSeconds
            result[index] = connection.totalSeconds + access
        }
        return result
    }
    public var transfers: Int { max(0, rides.count - 1) }
    public func asVariant(_ name: String) -> TransitTrip {
        var result = self; result.variant = name; return result
    }
    public func withEndpointDistances(access: Double, egress: Double) -> TransitTrip {
        var result = TransitTrip(rides: rides, accessDistance: max(0, access), egressDistance: max(0, egress),
            transferDistance: transferDistance, score: score, rideSeconds: rideSeconds,
            transferDistances: transferDistances, transferSeconds: transferSeconds)
        result.variant = variant
        result.bikeConnections = bikeConnections
        result.planningSupplyRisk = planningSupplyRisk
        return result
    }
    public func replacingRides(_ rides: [TransitRide]) -> TransitTrip {
        guard rides.count == self.rides.count else { return self }
        var result = TransitTrip(rides: rides, accessDistance: accessDistance, egressDistance: egressDistance,
            transferDistance: transferDistance, score: score, rideSeconds: rideSeconds,
            transferDistances: transferDistances, transferSeconds: transferSeconds)
        result.variant = variant; result.bikeConnections = bikeConnections; result.planningSupplyRisk = planningSupplyRisk
        return result
    }
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
        var bikes: [Int: BikeConnection] = [:]
        var supplyRisk: Double = 0
    }
    private struct FamilyBound {
        let score: Double
        let access: Double
        let egress: Double
        let walking: Double
        let riding: Double
    }
    private struct BoardingOrigin {
        let index: Int
        let cost: Double
        let walking: Double
        let ready: Double
    }
    private struct FamilyKey: Hashable, Comparable {
        let first: Int
        let second: Int
        let bikes: Int
        static func < (a: Self, b: Self) -> Bool {
            if a.first != b.first { return a.first < b.first }
            if a.second != b.second { return a.second < b.second }
            return a.bikes < b.bikes
        }
    }
    private struct BoardingKey: Hashable {
        let pattern: Int
        let index: Int
        let cycling: Bool
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
                    distances.append(distances[i - 1] + TravelTimeModel.meters(from: stops[i - 1], to: stops[i], along: anchors))
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
                     estimates: EstimateFeed? = nil, at date: Date = Date(), preservePlatforms: Bool = false,
                     accessConnections: [String: BikeConnection] = [:], egressConnections: [String: BikeConnection] = [:],
                     bikeAvailability: BikeAvailability? = nil) -> [TransitTrip] {
        guard origin.isInServiceArea, destination.isInServiceArea, maximumWalk > 0, limit > 0 else { return [] }
        func nearby(_ point: Coordinate, connections: [String: BikeConnection]) -> [(id: String, distance: Double)] {
            var matches: [(id: String, distance: Double)] = []
            var cycling: [(id: String, distance: Double)] = []
            for station in stations.values {
                let distance = station.coordinate.distance(to: point)
                if distance <= maximumWalk { matches.append((station.id, distance)) }
                else if connections[station.id] != nil { cycling.append((station.id, distance)) }
            }
            cycling.sort {
                let a = connections[$0.id]!.totalSeconds, b = connections[$1.id]!.totalSeconds
                return a == b ? $0.id < $1.id : a < b
            }
            var corridors = Set<String>()
            for candidate in cycling {
                let routes = (occurrences[candidate.id] ?? []).map { patterns[$0.pattern].route.parentID + ":" + patterns[$0.pattern].direction }
                if routes.contains(where: { !corridors.contains($0) }) {
                    matches.append(candidate); corridors.formUnion(routes)
                }
                if corridors.count >= 40 { break }
            }
            matches.sort { a, b in a.distance == b.distance ? a.id < b.id : a.distance < b.distance }
            return matches
        }
        let origins = nearby(origin, connections: accessConnections), destinations = nearby(destination, connections: egressConnections)
        guard !origins.isEmpty, !destinations.isEmpty else { return [] }
        var exits: [Int: [Exit]] = [:]
        for station in destinations {
            for occurrence in occurrences[station.id] ?? [] {
                exits[occurrence.pattern, default: []].append(Exit(index: occurrence.index, walk: station.distance))
            }
        }
        // Use source-specific times before limiting candidates: the shared rule (TravelTimeModel) with the
        // evidence a search holds, official profiles, the current arrival estimates for a trip leaving now,
        // and the city's pace.
        let tuning = ForecastTuning.current
        let live = TravelTimeModel.liveEstimates(estimates, at: date)
        let routeTimes = patterns.map { pattern -> [Double] in
            var values = [0.0]
            for index in pattern.stops.indices.dropFirst() {
                let previous = values.last!, at = date.addingTimeInterval(previous)
                let from = pattern.stops[index - 1].id, to = pattern.stops[index].id
                let segment = TravelTimeModel.segment(route: pattern.route, meters: pattern.distances[index] - pattern.distances[index - 1],
                    official: { metadata.officialTravelTimes.seconds(route: pattern.route.parentID, subroute: pattern.route.id,
                        direction: pattern.direction, from: from, to: to, travellingAt: at, observedAt: date) },
                    estimates: { live.flatMap { TravelTimeModel.estimated($0, parentRouteID: pattern.route.parentID, from: from, to: to) } },
                    pace: .city, travellingAt: at, tuning: tuning)
                values.append(previous + (segment?.seconds ?? 0))
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
                let walk = exit.walk <= maximumWalk ? exit.walk * 1.25 / 1.2 * (preferences.walkingWeight + 0.35) : .infinity
                let id = pattern.stops[exit.index].stationID
                let bike = egressConnections[id].map {
                    JourneyPreferenceCost.score(elapsed: $0.totalSeconds, walking: $0.accessSeconds + $0.egressSeconds,
                        waiting: 0, transfers: 0, rentals: 1, unknownWaits: 0,
                        supplyRisk: BikeRouting.supplyPenalty($0, availability: bikeAvailability, at: date), preferences: preferences)
                } ?? .infinity
                return routeTimes[patternIndex][exit.index] + min(walk, bike)
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
        let familyIndex = Dictionary(uniqueKeysWithValues: Set(families).sorted().enumerated().map { ($0.element,$0.offset) })
        let familyIDs = families.map { familyIndex[$0]! }
        let timeOfDay = BusServiceWindow.secondsOfDay(at: date)
        let services = patterns.map { $0.route.servicePlans[$0.direction]?.service(at: date) }
        let serviceWaits = patterns.enumerated().map { index, pattern in
            pattern.route.minimumServiceWait(direction: pattern.direction, at: date,
                fullRouteSeconds: routeTimes[index].last ?? 0)
        }
        // A long route may pass dozens of platforms inside the same access area.
        // Keep independent boarding tradeoffs once per pattern before expanding its
        // transfer combinations. This preserves every service, early boarding for
        // short trips, the nearest walk and the best downstream arrival.
        var allowedBoards: [Int: Set<Int>] = [:]
        var firstWaits: [BoardingKey: BoardingWait] = [:]
        func initialWait(_ pattern: Int, _ index: Int, walking: Double, cycling: Bool) -> BoardingWait {
            let key = BoardingKey(pattern: pattern,index: index,cycling: cycling)
            if let cached = firstWaits[key] { return cached }
            let value = BoardingTime.wait(official: arrivals[pattern][index], readyAt: walking,
                buffer: ConnectionTiming.buffer(first: true, walking: walking), service: services[pattern],
                secondsOfDay: timeOfDay, boardingOffset: routeTimes[pattern][index], minimumServiceWait: serviceWaits[pattern])
            firstWaits[key] = value; return value
        }
        if preservePlatforms {
            var originGroups: [Int: [BoardingOrigin]] = [:]
            for start in origins { for board in occurrences[start.id] ?? [] {
                let walk = start.distance * 1.25 / 1.2
                func boardingCost(seconds: Double, cycling: Double, rentals: Int, risk: Double) -> Double {
                    let wait = initialWait(board.pattern,board.index,walking: seconds,cycling: rentals > 0)
                    return JourneyPreferenceCost.score(elapsed: seconds + wait.seconds, walking: max(0,seconds-cycling),
                        waiting: wait.seconds, transfers: 0, rentals: rentals, unknownWaits: wait.evidence == .unknown ? 1 : 0,
                        supplyRisk: risk, preferences: preferences)
                }
                let footCost = start.distance <= maximumWalk ? boardingCost(seconds: walk, cycling: 0, rentals: 0, risk: 0) : .infinity
                let bike = accessConnections[start.id]
                let bikeCost = bike.map { boardingCost(seconds: $0.totalSeconds, cycling: $0.rideSeconds + $0.handlingSeconds,
                    rentals: 1, risk: BikeRouting.supplyPenalty($0, availability: bikeAvailability, at: date)) } ?? .infinity
                originGroups[board.pattern, default: []].append(BoardingOrigin(index: board.index,
                    cost: min(footCost,bikeCost) - routeTimes[board.pattern][board.index],
                    walking: min(start.distance <= maximumWalk ? walk : .infinity, bike.map { $0.accessSeconds + $0.egressSeconds } ?? .infinity),
                    ready: min(start.distance <= maximumWalk ? walk : .infinity, bike?.totalSeconds ?? .infinity)))
            } }
            for (pattern,pool) in originGroups {
                let ordered = pool.sorted { $0.cost == $1.cost ? $0.index < $1.index : $0.cost < $1.cost }
                var kept = Set(ordered.prefix(3).map(\.index))
                for candidate in [pool.min(by: { $0.walking < $1.walking }), pool.min(by: { $0.ready < $1.ready }),
                                  pool.min(by: { $0.index < $1.index })].compactMap({ $0 }) { kept.insert(candidate.index) }
                for candidate in ordered where kept.count < (limit > 54 ? 8 : 6) { kept.insert(candidate.index) }
                allowedBoards[pattern] = kept
            }
        }
        var candidates: [FamilyKey: [Candidate]] = [:]
        var familyBounds: [FamilyKey: FamilyBound] = [:]
        var bestComplete = Double.infinity, bestWithoutRental = Double.infinity
        let hasBikes = !accessConnections.isEmpty || !egressConnections.isEmpty
        var evaluated = 0, bounded = 0
        func addVariant(_ segments: [Segment], access: Double, egress: Double, transfer: Double, connections: [Int: BikeConnection]) {
            // Apply availability before ranking and limiting candidates: many cheap closed
            // routes must not crowd all usable alternatives out of the result window.
            for segment in segments {
                if let seconds = arrivals[segment.pattern][segment.board], [-2, -3, -4].contains(seconds) { return }
            }
            // Bound each family's work without collapsing different boarding/alighting
            // platforms before pedestrian routing can reveal barriers and detours.
            let key = FamilyKey(first: familyIDs[segments[0].pattern],
                second: segments.count > 1 ? familyIDs[segments[1].pattern] : -1,
                bikes: connections.keys.reduce(0) { $0 | (1 << $1) })
            let riding = segments.map { segment in
                return routeTimes[segment.pattern][segment.alight] - routeTimes[segment.pattern][segment.board]
            }
            var walking = ([access] + (segments.count > 1 ? [transfer] : []) + [egress]).map { $0 * 1.25 / 1.2 }
            for (index, bike) in connections { walking[index] = bike.totalSeconds }
            let cycling = connections.values.reduce(0) { $0 + $1.rideSeconds + $1.handlingSeconds }
            // Waiting cannot make an itinerary faster or cheaper. Once a route family
            // has enough alternatives, avoid calculating the same timetable for a
            // candidate that cannot improve either its score or any retained tradeoff.
            var minimumScore = JourneyPreferenceCost.score(elapsed: riding.reduce(0,+) + walking.reduce(0,+),
                walking: max(0,walking.reduce(0,+) - cycling), waiting: 0, transfers: max(0,segments.count-1),
                rentals: connections.count, unknownWaits: 0, preferences: preferences)
            let first = segments[0]
            let wait = initialWait(first.pattern,first.board,walking: walking[0],cycling: connections[0] != nil)
            minimumScore += wait.seconds * preferences.waitingWeight + (wait.evidence == .unknown ? 180 : 0)
            if segments.count > 1 { minimumScore += 90 * preferences.waitingWeight }
            let complete = connections.isEmpty ? bestWithoutRental : bestComplete
            if preservePlatforms, minimumScore > complete + max(1200,complete * 0.35) { bounded += 1; return }
            if !preservePlatforms, let best = candidates[key]?.first, minimumScore >= best.score { bounded += 1; return }
            let rideDistance = segments.reduce(0.0) { $0 + patterns[$1.pattern].distances[$1.alight] - patterns[$1.pattern].distances[$1.board] }
            if let bound = familyBounds[key], minimumScore >= bound.score,
               access >= bound.access, egress >= bound.egress,
               access + egress + transfer >= bound.walking, rideDistance >= bound.riding {
                bounded += 1; return
            }
            evaluated += 1
            let boardingArrivals = segments.map { arrivals[$0.pattern][$0.board] }
            let assessment = TripRanking.assess(riding: riding, walking: walking, arrivals: boardingArrivals, preferences: preferences,
                minimumServiceWaits: segments.map { serviceWaits[$0.pattern] },
                services: segments.map { services[$0.pattern] },
                boardingOffsets: segments.map { routeTimes[$0.pattern][$0.board] }, at: date,
                serviceTimeOfDay: timeOfDay, cyclingSeconds: cycling, rentalCount: connections.count)
            var cursor = 0.0, risk = 0.0
            for index in walking.indices {
                if let bike = connections[index] { risk += BikeRouting.supplyPenalty(bike, availability: bikeAvailability, pickupAfter: cursor, at: date) }
                cursor += walking[index]
                if riding.indices.contains(index) { cursor += assessment.waits[index].seconds + riding[index] }
            }
            let score = assessment.score + risk
            guard score.isFinite else { return }
            bestComplete = min(bestComplete,score)
            if connections.isEmpty { bestWithoutRental = min(bestWithoutRental,score) }
            let bikeKey = connections.isEmpty ? "" : connections.keys.sorted().map { "\($0):\(BikeRouting.pairID(connections[$0]!))" }.joined(separator: "|")
            if !preservePlatforms {
                if let best = candidates[key]?.first, best.score <= score { return }
                candidates[key] = [Candidate(segments: segments, access: access, egress: egress, transfer: transfer, score: score,
                    identity: segments.map { "\($0.pattern):\($0.board):\($0.alight)" }.joined(separator: "|") + bikeKey, bikes: connections, supplyRisk: risk)]
                return
            }
            let fingerprint = segments.map { segment in
                    let p = patterns[segment.pattern]
                    return "\(p.stops[segment.board].stationID)>\(p.stops[segment.alight].stationID):\(p.fingerprint)"
                }.joined(separator: "|") + bikeKey
            let value = Candidate(segments: segments, access: access, egress: egress, transfer: transfer, score: score, identity: fingerprint, bikes: connections, supplyRisk: risk)
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
            if pool.count >= 3 {
                familyBounds[key] = FamilyBound(score: pool.map(\.score).sorted()[2],
                    access: pool.map(\.access).min()!, egress: pool.map(\.egress).min()!,
                    walking: pool.map { $0.access + $0.egress + $0.transfer }.min()!,
                    riding: pool.map { value in value.segments.reduce(0.0) {
                        $0 + patterns[$1.pattern].distances[$1.alight] - patterns[$1.pattern].distances[$1.board]
                    } }.min()!)
            }
        }
        func add(_ segments: [Segment], access: Double, egress: Double, transfer: Double) {
            if !hasBikes {
                addVariant(segments, access: access, egress: egress, transfer: transfer, connections: [:]); return
            }
            guard let first = segments.first, let last = segments.last else { return }
            let startID = patterns[first.pattern].stops[first.board].stationID
            let endID = patterns[last.pattern].stops[last.alight].stationID
            var starts: [BikeConnection?] = access <= maximumWalk ? [nil] : []
            var ends: [BikeConnection?] = egress <= maximumWalk ? [nil] : []
            if let bike = accessConnections[startID] { starts.append(bike) }
            if let bike = egressConnections[endID] { ends.append(bike) }
            for start in starts { for end in ends {
                var connections: [Int: BikeConnection] = [:]
                if let start { connections[0] = start }
                if let end { connections[segments.count] = end }
                addVariant(segments, access: access, egress: egress, transfer: transfer, connections: connections)
            } }
        }
        for start in origins {
            if Task.isCancelled { return [] }
            for board in occurrences[start.id] ?? [] {
                if preservePlatforms, allowedBoards[board.pattern]?.contains(board.index) != true { continue }
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
        if ProcessInfo.processInfo.environment["BUS_PLANNING_PROFILE"] == "1" { print("BUS_SEARCH evaluated=\(evaluated) bounded=\(bounded)") }
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
                }).withBikeConnections(candidate.bikes, supplyRisk: candidate.supplyRisk)
        }
    }
}
