import Foundation

/// Round-based transit search. Each round adds one actual operating pattern;
/// shared station names never splice trains or buses into a fictitious direct service.
public struct MultimodalPlanner: Sendable {
    /// A class, so the search's many reads of a pattern share it instead of copying its arrays.
    private final class Pattern: Sendable {
        let route: BusRoute
        let direction: String
        let stops: [BusStop]
        let cumulative: [Double]
        let dwell: [Double]
        let windows: [BusServiceWindow?]
        /// Rail segments: run plus dwell. Bus segments: the road distance, timed by the shared rule.
        let fallback: [Double]
        let meters: [Double]
        /// Per bus segment, the source `timed` used, so the current estimates replace only paced segments.
        let sources: [TravelTimeModel.Source]
        init(route: BusRoute, direction: String, stops: [BusStop], cumulative: [Double], dwell: [Double],
             windows: [BusServiceWindow?], fallback: [Double], meters: [Double], sources: [TravelTimeModel.Source] = []) {
            self.route = route; self.direction = direction; self.stops = stops; self.cumulative = cumulative; self.dwell = dwell
            self.windows = windows; self.fallback = fallback; self.meters = meters; self.sources = sources
        }
        /// Bus times for the query hour by the shared rule (TravelTimeModel).
        func timed(_ times: OfficialTravelTimes, at date: Date, tuning: ForecastTuning) -> Pattern {
            guard route.mode == .bus else { return self }
            var values = [0.0], used: [TravelTimeModel.Source] = []
            for index in 1..<stops.count {
                let from = stops[index - 1].id, to = stops[index].id
                let segment = TravelTimeModel.segment(route: route, meters: meters[index - 1],
                    official: { times.seconds(route: route.parentID, subroute: route.id, direction: direction,
                        from: from, to: to, travellingAt: date, observedAt: date) },
                    pace: .city, travellingAt: date, tuning: tuning)
                values.append(values.last! + (segment?.seconds ?? 0)); used.append(segment?.source ?? .cityPace)
            }
            return Pattern(route: route, direction: direction, stops: stops, cumulative: values, dwell: dwell,
                windows: windows, fallback: fallback, meters: meters, sources: used)
        }
        /// For a trip leaving now: paced segments retimed from the current arrival estimates, which the
        /// shared rule ranks after the official profile and before any pace.
        func live(_ estimates: EstimateFeed) -> Pattern {
            guard route.mode == .bus, sources.count == stops.count - 1, sources.contains(.cityPace) else { return self }
            var values = [0.0], used = sources, changed = false
            for index in 1..<stops.count {
                var seconds = cumulative[index] - cumulative[index - 1]
                if sources[index - 1] == .cityPace, let current = TravelTimeModel.estimated(estimates, parentRouteID: route.parentID,
                                                                                          from: stops[index - 1].id, to: stops[index].id) {
                    seconds = current; used[index - 1] = .officialEstimates; changed = true
                }
                values.append(values.last! + seconds)
            }
            return changed ? Pattern(route: route, direction: direction, stops: stops, cumulative: values, dwell: dwell,
                windows: windows, fallback: fallback, meters: meters, sources: used) : self
        }
    }
    /// Bus times for the most recent query hour; a planner lives up to a day, across peaks.
    private final class TimingCache: @unchecked Sendable {
        let lock = NSLock()
        var key = ""
        var patterns: [Pattern] = []
        var liveKey = ""
        var livePatterns: [Pattern] = []
    }
    private struct Segment: Sendable { let pattern: Int; let first: Int; let last: Int }
    private struct Link: Sendable { let id: String; let distance: Double; let seconds: Double; let internalWalk: Bool }
    /// A class, so pools and candidates share a label instead of copying its arrays. A label is
    /// only changed while it is being made, before any pool or other thread can see it.
    private final class Label: @unchecked Sendable {
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
        init(segments: [Segment], access: Double, distances: [Double], transferSeconds: [Double], elapsed: Double,
             walking: Double, cost: Double, lastStation: String, hasRail: Bool, family: String) {
            self.segments = segments; self.access = access; self.distances = distances; self.transferSeconds = transferSeconds
            self.elapsed = elapsed; self.walking = walking; self.cost = cost; self.lastStation = lastStation
            self.hasRail = hasRail; self.family = family
        }
        var bikes: [Int: BikeConnection] = [:]
        var supplyRisk: Double = 0
        var lastWalk: Double = 0
        var internalWalk = false
        var previousSpread: Double = 0
        var unknownWaits = 0
        var bikeMask: Int { bikes.keys.reduce(0) { $0 | (1 << $1) } }
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
                var cumulative = [0.0], fallback: [Double] = [], meters: [Double] = []
                let railPattern = route.mode != .bus ? metadata.metro.pattern(route.id, direction: direction) : nil
                let anchors = Dictionary((metadata.journey(routeID: route.id, direction: direction)?.anchors ?? [])
                    .map { ($0.stop.id, $0.match.along) }, uniquingKeysWith: { a, _ in a })
                for index in 1..<stops.count {
                    let a = stops[index - 1], b = stops[index]
                    let rail = route.mode != .bus ? metadata.metro.ridingSeconds(routeID: route.id, direction: direction, from: a.stationID, to: b.stationID) : nil
                    let distance = TravelTimeModel.meters(from: a, to: b, along: anchors)
                    let dwell = index > 1 && railPattern?.dwellSeconds.indices.contains(index - 1) == true ? railPattern!.dwellSeconds[index - 1] : 0
                    meters.append(distance)
                    fallback.append((rail ?? TravelTimeModel.cityPace(meters: distance, route: route, tuning: tuning)) + dwell)
                    cumulative.append(cumulative.last! + fallback.last!)
                }
                let windows = route.mode != .bus ? stops.map { metadata.metro.boardingWindow(routeID: route.id, direction: direction, stationID: $0.stationID) } : []
                patterns.append(Pattern(route: route, direction: direction, stops: stops, cumulative: cumulative,
                    dwell: railPattern?.dwellSeconds ?? [], windows: windows, fallback: fallback, meters: meters))
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

    private func timedPatterns(at date: Date, estimates: EstimateFeed? = nil) -> [Pattern] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let key = "\(parts.year!)-\(parts.month!)-\(parts.day!)-\(parts.hour!)"
        timing.lock.lock(); defer { timing.lock.unlock() }
        if timing.key != key {
            // Tuning is read here, not when the planner was built, so a remote change applies within the hour.
            let tuning = ForecastTuning.current
            timing.patterns = patterns.map { $0.timed(metadata.officialTravelTimes, at: date, tuning: tuning) }
            timing.key = key
            timing.liveKey = ""
        }
        // A trip leaving now uses the current arrival estimates where no official time applies;
        // they change every 20 seconds, so they are layered over the hour's official times.
        guard let live = TravelTimeModel.liveEstimates(estimates, at: date), let updated = live.updatedAt else { return timing.patterns }
        let liveKey = key + "|" + String(updated.timeIntervalSince1970)
        if timing.liveKey != liveKey {
            timing.livePatterns = timing.patterns.map { $0.live(live) }
            timing.liveKey = liveKey
        }
        return timing.livePatterns
    }

    public func plan(from origin: Coordinate, to destination: Coordinate, maximumWalk: Double = 1000, limit: Int = 36,
                     preferences: LiveSettings.Planning = .init(), estimates: EstimateFeed = .init(), at date: Date = Date(),
                     bikeNetwork: BikeNetwork = .empty, bikeAvailability: BikeAvailability? = nil,
                     onPreliminary: (@Sendable ([TransitTrip]) -> Void)? = nil) -> [TransitTrip] {
        guard origin.isInServiceArea, destination.isInServiceArea, maximumWalk > 0, limit > 0 else { return [] }
        let profile = ProcessInfo.processInfo.environment["BUS_PLANNING_PROFILE"] == "1"
        let began = ProcessInfo.processInfo.systemUptime
        let cycling = preferences.bikeRouting && !bikeNetwork.stations.isEmpty && bikeAvailability != nil
        guard !metadata.metro.patterns.isEmpty || cycling else {
            return busPlanner.plan(from: origin, to: destination, maximumWalk: maximumWalk, limit: limit,
                preferences: preferences, estimates: estimates, at: date, preservePlatforms: true)
        }
        let patterns = timedPatterns(at: date, estimates: estimates)
        let budget = JourneySearchBudget(distance: origin.distance(to: destination), cycling: cycling)
        let bikeRadius = min(TransitBikePolicy.maximumFeederSearchMeters,preferences.bikeMaximumRideMeters, max(1_500, origin.distance(to: destination) * 0.5))
        func streetDistance(_ stop: BusStop, to c: Coordinate) -> Double {
            if stop.mode == .bus { return stop.coordinate.distance(to: c) }
            return (metadata.metro.nearestExit(stationID: stop.stationID, to: c)?.coordinate ?? stop.coordinate).distance(to: c)
        }
        var accessBikes: [String: [BikeConnection]] = [:], egressBikes: [String: [BikeConnection]] = [:]
        let bikeSearch = BikeConnectionSearch(network: bikeNetwork, availability: bikeAvailability, preferences: preferences, at: date, feederOnly:true)
        if cycling {
            // Every station is independent here, so they are worked out in parallel, each group
            // with its own search.
            let ids = stationStops.keys.sorted()
            let groupSize = max(1, (ids.count + 31) / 32)
            let chunks = stride(from: 0, to: ids.count, by: groupSize).map { ids[$0..<min(ids.count, $0 + groupSize)] }
            var found = [[(id: String, access: [BikeConnection]?, egress: [BikeConnection]?)]](repeating: [], count: chunks.count)
            found.withUnsafeMutableBufferPointer { output in
                DispatchQueue.concurrentPerform(iterations: chunks.count) { chunk in
                    let search = BikeConnectionSearch(network: bikeNetwork, availability: bikeAvailability, preferences: preferences, at: date, feederOnly: true)
                    output[chunk] = chunks[chunk].map { id in
                        let stop = stationStops[id]!
                        let access = streetDistance(stop, to: origin), egress = streetDistance(stop, to: destination)
                        var accessBikes: [BikeConnection]?, egressBikes: [BikeConnection]?
                        if access >= preferences.bikeMinimumRideMeters, access <= bikeRadius {
                            let entry = stop.mode == .bus ? stop.coordinate : metadata.metro.nearestExit(stationID: id, to: origin)?.coordinate ?? stop.coordinate
                            accessBikes = search.connections(from: origin, to: entry)
                        }
                        if egress >= preferences.bikeMinimumRideMeters, egress <= bikeRadius {
                            let exit = stop.mode == .bus ? stop.coordinate : metadata.metro.nearestExit(stationID: id, to: destination)?.coordinate ?? stop.coordinate
                            egressBikes = search.connections(from: exit, to: destination)
                        }
                        return (id, accessBikes, egressBikes)
                    }
                }
            }
            for list in found { for item in list {
                if let value = item.access { accessBikes[item.id] = value }
                if let value = item.egress { egressBikes[item.id] = value }
            } }
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
                let label = Label(segments: [], access: distance, distances: [], transferSeconds: [], elapsed: walking,
                    walking: walking, cost: walking * (preferences.walkingWeight + 0.35), lastStation: id, hasRail: false, family: "")
                label.lastWalk = walking; previous[id] = [label]
            }
            for bike in accessBikes[id] ?? [] {
                let station = stop.mode == .bus ? 0.0 : 120.0
                let elapsed = bike.totalSeconds + station, walking = bike.accessSeconds + bike.egressSeconds + station
                let risk = BikeRouting.supplyPenalty(bike, availability: bikeAvailability, at: date)
                let label = Label(segments: [], access: distance, distances: [], transferSeconds: [], elapsed: elapsed,
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
        // The patterns of a round are expanded in parallel, in fixed groups. Each group keeps its
        // own caches across rounds; every cache key names its pattern, so a value is always
        // computed by the same first call as when the patterns were expanded one after another.
        let groupCount = max(1, min(patterns.count, ProcessInfo.processInfo.activeProcessorCount * 8))
        let groups = (0..<groupCount).map { (patterns.count * $0 / groupCount)..<(patterns.count * ($0 + 1) / groupCount) }
        var serviceCaches = [[String: BusDayService]](repeating: [:], count: groupCount)
        var railCaches = [[String: BusDayService]](repeating: [:], count: groupCount)
        func service(_ index: Int, ready: Double, cache serviceCache: inout [String: BusDayService]) -> BusDayService {
            let key = "\(index):\(Int(ready / 60))"
            if let value = serviceCache[key] { return value }
            let pattern = patterns[index], value: BusDayService
            if pattern.route.mode == .bus { value = pattern.route.servicePlans[pattern.direction]?.service(at: date.addingTimeInterval(ready)) ?? .init() }
            else { value = metadata.metro.service(routeID: pattern.route.id, direction: pattern.direction, at: date.addingTimeInterval(ready)) ?? .init() }
            serviceCache[key] = value; return value
        }
        // Rail waits count every service that stops here and reaches the destination stop.
        func railService(_ index: Int, from: Int, to: Int?, ready: Double, cache railCache: inout [String: BusDayService]) -> BusDayService {
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
        // Cells are numbered rather than named, and each station's distance to the destination is
        // kept beside it, because every transfer station scans the 49 cells around it.
        func transferCell(_ x: Int, _ y: Int) -> Int { x &* 1_000_003 &+ y }
        let transferStops = cycling ? Array(stationStops.values) : []
        let transferGrid = Dictionary(grouping: transferStops.indices, by: {
            transferCell(Int(floor(transferStops[$0].coordinate.longitude / 0.01)), Int(floor(transferStops[$0].coordinate.latitude / 0.01)))
        })
        let destinationPotential = transferStops.map { $0.coordinate.distance(to: destination) / 12 }
        let transferIDs = transferStops.map(\.stationID), transferPoints = transferStops.map(\.coordinate)
        var streetLinks: [String: [(Link, BikeConnection?)]] = [:]
        /// A station's walking links and, when cycling, its bicycle links. It reads only what the
        /// search fixed beforehand, so several stations can be worked out at once, each with its own `search`.
        func streetConnections(from id: String, search bikeSearch: BikeConnectionSearch) -> [(Link, BikeConnection?)] {
            var result = (links[id] ?? []).map { ($0, Optional<BikeConnection>.none) }
            guard cycling, let stop = stationStops[id] else { return result }
            let start = stop.mode == .bus ? stop.coordinate : metadata.metro.nearestExit(stationID: id, to: destination)?.coordinate ?? stop.coordinate
            guard bikeSearch.stations(near: start).contains(where: {
                BikeRouting.confirmed($0, availability: bikeAvailability, renting: true, at: date)
            }) else { return result }
            // Targets in order of cost, then station: the rail targets all, the rest only until
            // the corridor slots fill, so they are drawn from a heap instead of sorting thousands.
            var heap: [(cost: Double, index: Int)] = []
            let indoors = Set((links[id] ?? []).filter(\.internalWalk).map(\.id))
            let x = Int(floor(start.longitude / 0.01)), y = Int(floor(start.latitude / 0.01))
            for dx in -3...3 { for dy in -3...3 {
                for index in transferGrid[transferCell(x + dx, y + dy)] ?? [] {
                    guard transferIDs[index] != id, !indoors.contains(transferIDs[index]) else { continue }
                    let distance = start.distance(to: transferPoints[index])
                    if distance >= preferences.bikeMinimumRideMeters, distance <= min(2_500, bikeRadius) {
                        heap.append((distance / preferences.bikeSpeed + destinationPotential[index], index))
                    }
                }
            } }
            func precedes(_ a: (cost: Double, index: Int), _ b: (cost: Double, index: Int)) -> Bool {
                a.cost == b.cost ? transferIDs[a.index] < transferIDs[b.index] : a.cost < b.cost
            }
            let railTargets = heap.filter { transferStops[$0.index].mode != .bus }.sorted(by: precedes).map { transferStops[$0.index] }
            func siftDown(_ start: Int, _ count: Int) {
                var parent = start
                while true {
                    let left = 2 * parent + 1, right = left + 1
                    var smallest = parent
                    if left < count, precedes(heap[left], heap[smallest]) { smallest = left }
                    if right < count, precedes(heap[right], heap[smallest]) { smallest = right }
                    if smallest == parent { return }
                    heap.swapAt(parent, smallest); parent = smallest
                }
            }
            for index in stride(from: heap.count / 2 - 1, through: 0, by: -1) { siftDown(index, heap.count) }
            var remaining = heap.count
            func nextTarget() -> BusStop? {
                guard remaining > 0 else { return nil }
                let first = heap[0]
                remaining -= 1
                heap.swapAt(0, remaining)
                siftDown(0, remaining)
                return transferStops[first.index]
            }
            var corridors = Set<String>(), added = Set<String>()
            // Include every published outdoor interchange even when its corridor is also
            // represented by another nearby station. Indoor transfers never rent a bike.
            var eligible = (links[id] ?? []).filter { !$0.internalWalk && $0.distance >= preferences.bikeMinimumRideMeters }
                .compactMap { stationStops[$0.id] }
            // Nearby bus route numbers must not crowd every rail line out of the
            // transfer budget. Include the nearest useful platform of each line,
            // then fill the remaining corridor slots using the same travel bound.
            for other in railTargets {
                let route = metadata.routes[other.routeID]
                let corridor = "rail:" + (route?.lineCode ?? other.routeID)
                if corridors.insert(corridor).inserted { eligible.append(other) }
            }
            while let other = nextTarget() {
                let route = metadata.routes[other.routeID]
                let corridor = other.mode == .bus ? "bus:" + (route?.parentID ?? other.routeID) : "rail:" + (route?.lineCode ?? other.routeID)
                if corridors.insert(corridor).inserted { eligible.append(other) }
                if corridors.count >= (budget.candidates > 54 ? 12 : 8) { break }
            }
            for other in eligible where added.insert(other.stationID).inserted {
                let end = other.mode == .bus ? other.coordinate : metadata.metro.nearestExit(stationID: other.stationID, to: start)?.coordinate ?? other.coordinate
                let distance = start.distance(to: end)
                let station = (stop.mode == .bus ? 0.0 : 90) + (other.mode == .bus ? 0.0 : 120)
                for bike in bikeSearch.connections(from: start, to: end) {
                    result.append((Link(id: other.stationID, distance: distance, seconds: bike.totalSeconds + station, internalWalk: false), bike))
                }
            }
            return result
        }
        func connections(from id: String) -> [(Link, BikeConnection?)] {
            if let cached = streetLinks[id] { return cached }
            let result = streetConnections(from: id, search: bikeSearch)
            streetLinks[id] = result; return result
        }
        func materialize(_ values: [Candidate], maximum: Int) -> [TransitTrip] {
            let grouped = Dictionary(grouping:values,by:{ candidate in
                candidate.label.family + "|bikes:" + (candidate.label.bikes.keys.sorted().map(String.init) + (candidate.bike == nil ? [] : ["end"])).joined(separator: "-")
            })
            var representative: [Candidate] = []
            for pool in grouped.values { representative.append(contentsOf:pool.sorted { $0.score < $1.score }.prefix(3)) }
            representative.sort { $0.score == $1.score ? $0.label.family < $1.label.family : $0.score < $1.score }
            let retained = representative.prefix(maximum)
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
            return results
        }
        if !bus.isEmpty { onPreliminary?(Array(bus.prefix(3))) }
        // Three transfers cover bus–metro–metro–bus and cross-branch rail journeys.
        for round in 0..<4 {
            if Task.isCancelled { return [] }
            // A completed itinerary is an upper bound. Continue to keep a generous
            // convenience window, with a separate no-rental bound so a quick bicycle
            // estimate can never eliminate every walk-to-transit alternative.
            let allBest = min(bus.map(\.score).min() ?? .infinity, candidates.map(\.score).min() ?? .infinity)
            let footBest = min(bus.filter { $0.bikeConnections.isEmpty }.map(\.score).min() ?? .infinity,
                candidates.filter { $0.label.bikes.isEmpty && $0.bike == nil }.map(\.score).min() ?? .infinity)
            func ceiling(_ label: Label) -> Double {
                let best = label.bikes.isEmpty ? footBest : allBest
                return best + max(1200, best * 0.35)
            }
            var arrived: [String: [Label]] = [:]
            func insert(_ label: Label, in values: inout [String: [Label]], at id: String) {
                // A cheaper but later label must not erase a path which can catch an
                // earlier connection. Rental count and remaining boarding time both matter.
                if let pool = values[id], pool.contains(where: { $0.cost <= label.cost && $0.elapsed <= label.elapsed && $0.walking <= label.walking &&
                    $0.bikes.count <= label.bikes.count && $0.hasRail == label.hasRail && $0.previousSpread <= label.previousSpread &&
                    $0.unknownWaits <= label.unknownWaits }) { return }
                // The pool is changed where it is stored; a copy taken out and written back
                // duplicated the whole pool on every insertion.
                prune(&values[id, default: []], with: label)
            }
            func prune(_ pool: inout [Label], with label: Label) {
                pool.removeAll { label.cost <= $0.cost && label.elapsed <= $0.elapsed && label.walking <= $0.walking &&
                    label.bikes.count <= $0.bikes.count && label.hasRail == $0.hasRail && label.previousSpread <= $0.previousSpread &&
                    label.unknownWaits <= $0.unknownWaits }
                pool.append(label)
                guard pool.count > budget.labels else { return }
                pool.sort { $0.cost == $1.cost ? $0.elapsed < $1.elapsed : $0.cost < $1.cost }
                // Preserve the earliest connection and least walking, not a rectangle
                // made from several different labels which can erase a useful tradeoff.
                let fastest = pool.min { $0.elapsed < $1.elapsed }!
                let leastWalk = pool.min { $0.walking < $1.walking }!
                var kept: [Label] = []
                for candidate in [pool[0],fastest,leastWalk] + pool {
                    if kept.count == budget.labels { break }
                    if !kept.contains(where: { $0.elapsed == candidate.elapsed && $0.walking == candidate.walking &&
                        $0.cost == candidate.cost && $0.family == candidate.family && $0.bikeMask == candidate.bikeMask }) { kept.append(candidate) }
                }
                pool = kept
            }
            // Each group lists its labels in pattern order; inserting the lists one after another
            // gives the same pools as expanding every pattern in turn.
            var expanded = [[(String, Label)]](repeating: [], count: groupCount)
            let reached = previous
            expanded.withUnsafeMutableBufferPointer { output in
            serviceCaches.withUnsafeMutableBufferPointer { serviceSlots in
            railCaches.withUnsafeMutableBufferPointer { railSlots in
            DispatchQueue.concurrentPerform(iterations: groupCount) { group in
                var found: [(String, Label)] = []
                for pIndex in groups[group] {
                    let pattern = patterns[pIndex]
                        var boarding: [(label: Label, index: Int, wait: Double, railHeadway: Double?, unknown: Bool)] = []
                        for index in pattern.stops.indices {
                            let stop = pattern.stops[index]
                            // Ride only after boarding; this prevents zero-station transfer legs.
                            for boarded in boarding {
                                let source = boarded.label, seconds: Double
                                let boardingDwell = boarded.index > 0 && pattern.dwell.indices.contains(boarded.index) ? pattern.dwell[boarded.index] : 0
                                seconds = pattern.cumulative[index] - pattern.cumulative[boarded.index] - boardingDwell
                                let fixedCost = source.cost + seconds + (boarded.unknown ? 180 : 0) + (round > 0 ? preferences.effectiveTransferPenaltySeconds : 0)
                                if fixedCost + boarded.wait * preferences.waitingWeight > ceiling(source) { continue }
                                // Short-turn trains that stop short of this stop do not help: wait for
                                // the sparser service that does reach it.
                                var wait = boarded.wait
                                if let near = boarded.railHeadway,
                                   let far = railService(pIndex, from: boarded.index, to: index, ready: source.elapsed, cache: &railSlots[group]).headway?.midpoint,
                                   far > near { wait *= far / near }
                                let elapsed = source.elapsed + wait + seconds
                                guard elapsed.isFinite, elapsed < 4 * 3600 else { continue }
                                let cost = fixedCost + wait * preferences.waitingWeight
                                if cost > ceiling(source) { continue }
                                let label = Label(segments: source.segments + [Segment(pattern: pIndex, first: boarded.index, last: index)],
                                    access: source.access, distances: source.distances, transferSeconds: source.transferSeconds,
                                    elapsed: elapsed, walking: source.walking,
                                    cost: cost,
                                    lastStation: stop.stationID, hasRail: source.hasRail || pattern.route.mode != .bus,
                                    family: source.family + "|" + pattern.route.parentID)
                                label.bikes = source.bikes; label.supplyRisk = source.supplyRisk
                                label.unknownWaits = source.unknownWaits + (boarded.unknown ? 1 : 0)
                                label.previousSpread = seconds * (pattern.route.mode == .bus ? RidingTimeEstimate.Evidence.officialProfile : .railProfile).spreadFraction
                                found.append((stop.stationID, label))
                            }
                            guard index < pattern.stops.count - 1 else { continue }
                            for source in reached[stop.stationID] ?? [] {
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
                                let currentService = rail ? railService(pIndex, from: index, to: nil, ready: source.elapsed, cache: &railSlots[group]) : service(pIndex, ready: source.elapsed, cache: &serviceSlots[group])
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
                output[group] = found
            } } } }
            for list in expanded { for (id, label) in list { insert(label, in: &arrived, at: id) } }
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
            if round < 2, onPreliminary != nil, !candidates.isEmpty, !Task.isCancelled {
                let early = materialize(candidates, maximum: 6)
                onPreliminary?(TripRanking.recommended(early, estimates: estimates, at: date,
                    preferences: preferences, limit: 3, diverse: false))
            }
            if round == 3 { break }
            var next: [String: [Label]] = [:]
            if cycling {
                // Bicycle links take most of this step; the stations reached for the first time
                // are worked out in parallel before the links are followed in the usual order.
                let missing = arrived.filter { id, labels in streetLinks[id] == nil && labels.contains(where: { $0.cost <= ceiling($0) }) }.keys.sorted()
                let groupSize = max(1, (missing.count + groupCount - 1) / groupCount)
                let chunks = stride(from: 0, to: missing.count, by: groupSize).map { missing[$0..<min(missing.count, $0 + groupSize)] }
                var computed = [[(String, [(Link, BikeConnection?)])]](repeating: [], count: chunks.count)
                computed.withUnsafeMutableBufferPointer { output in
                    DispatchQueue.concurrentPerform(iterations: chunks.count) { chunk in
                        let search = BikeConnectionSearch(network: bikeNetwork, availability: bikeAvailability,
                            preferences: preferences, at: date, feederOnly: true)
                        output[chunk] = chunks[chunk].map { ($0, streetConnections(from: $0, search: search)) }
                    }
                }
                for list in computed { for (id, value) in list { streetLinks[id] = value } }
            }
            for (id, labels) in arrived {
                guard labels.contains(where: { $0.cost <= ceiling($0) }) else { continue }
                for (link, bike) in connections(from: id) {
                    for label in labels {
                        if label.cost > ceiling(label) { continue }
                        if let last = label.segments.last, patterns[last.pattern].route.mode == .bus,
                           stationStops[link.id]?.mode == .bus, bike == nil { continue }
                        // Same platform changing trains still includes a short platform allowance.
                        let duration = link.seconds
                        let foot = bike.map { max(0, duration - $0.rideSeconds - $0.handlingSeconds) } ?? duration
                        let risk = bike.map { BikeRouting.supplyPenalty($0, availability: bikeAvailability, pickupAfter: label.elapsed, at: date) } ?? 0
                        let extra = JourneyPreferenceCost.score(elapsed: duration, walking: foot, waiting: 0, transfers: 0,
                            rentals: bike == nil ? 0 : 1, unknownWaits: 0, supplyRisk: risk, preferences: preferences)
                        let value = Label(segments: label.segments, access: label.access, distances: label.distances + [link.distance],
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
        let results = materialize(candidates, maximum: max(36, limit * 2))
        let unique = Dictionary((bus + results).map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.score < b.score ? a : b })
        if profile { print("PLANNING_PHASE complete seconds=\(ProcessInfo.processInfo.systemUptime - began) materialized=\(unique.count)") }
        return TripRanking.recommended(Array(unique.values), estimates: estimates, at: date, preferences: preferences, limit: limit, diverse: false)
    }
}
