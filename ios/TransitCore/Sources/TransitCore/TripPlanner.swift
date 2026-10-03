import Foundation

public struct TransitRide: Identifiable, Sendable {
    public var id: String { "\(route.id):\(direction):\(boarding.id):\(alighting.id)" }
    public let route: BusRoute
    public let direction: String
    public let stops: [BusStop]
    public let coordinates: [Coordinate]
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
    public var transfers: Int { max(0, rides.count - 1) }
}

/// A branch and direction retain their own stop order. A trip never joins different branches into one ride.
/// Build this index off the UI actor when metadata changes, then reuse it for destination searches.
public struct TripPlanner: Sendable {
    private struct Pattern: Sendable {
        let route: BusRoute
        let direction: String
        let stops: [BusStop]
        let distances: [Double]
    }
    private struct Occurrence: Sendable { let pattern: Int; let index: Int }
    private struct Segment: Sendable { let pattern: Int; let board: Int; let alight: Int }
    private struct Candidate {
        let segments: [Segment]
        let access: Double
        let egress: Double
        let transfer: Double
        let score: Double
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
                patterns.append(Pattern(route: route, direction: direction, stops: stops, distances: distances))
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
                     estimates: EstimateFeed? = nil, at date: Date = Date()) -> [TransitTrip] {
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
        var exits: [Int: [(index: Int, walk: Double)]] = [:]
        for station in destinations {
            for occurrence in occurrences[station.id] ?? [] {
                exits[occurrence.pattern, default: []].append((occurrence.index, station.distance))
            }
        }
        var candidates: [String: Candidate] = [:]
        func add(_ segments: [Segment], access: Double, egress: Double, transfer: Double) {
            // Apply availability before ranking and limiting candidates: many cheap closed
            // routes must not crowd all usable alternatives out of the result window.
            for segment in segments {
                let pattern = patterns[segment.pattern]
                if let seconds = estimates?.value(routeID: pattern.route.parentID,
                    stopID: pattern.stops[segment.board].id, at: date), [-2, -3, -4].contains(seconds) { return }
            }
            let key = segments.map { segment in
                let pattern = patterns[segment.pattern]
                return "\(pattern.route.parentID):\(pattern.direction):\(pattern.stops[segment.board].stationID):\(pattern.stops[segment.alight].stationID)"
            }.joined(separator: "|")
            let riding = segments.map { segment in
                let p = patterns[segment.pattern]
                return (p.distances[segment.alight] - p.distances[segment.board]) / 4.5 + Double(segment.alight - segment.board) * 20
            }
            let walking = ([access] + (segments.count > 1 ? [transfer] : []) + [egress]).map { $0 * 1.25 / 1.2 }
            let arrivals = segments.map { segment in
                let p = patterns[segment.pattern]
                return estimates?.value(routeID: p.route.parentID, stopID: p.stops[segment.board].id, at: date)
            }
            let score = TripRanking.assess(riding: riding, walking: walking, arrivals: arrivals, preferences: preferences).score
            guard candidates[key].map({ $0.score <= score }) != true else { return }
            candidates[key] = Candidate(segments: segments, access: access, egress: egress, transfer: transfer, score: score)
        }
        for start in origins {
            for board in occurrences[start.id] ?? [] {
                let first = patterns[board.pattern]
                guard board.index < first.stops.count - 1 else { continue }
                for exit in exits[board.pattern] ?? [] where exit.index > board.index {
                    add([Segment(pattern: board.pattern, board: board.index, alight: exit.index)],
                        access: start.distance, egress: exit.walk, transfer: 0)
                }
                for interchange in (board.index + 1)..<first.stops.count {
                    let station = first.stops[interchange].stationID
                    for neighbor in transferStations[station] ?? [] {
                        for next in occurrences[neighbor.id] ?? [] {
                            let second = patterns[next.pattern]
                            guard second.route.parentID != first.route.parentID else { continue }
                            for exit in exits[next.pattern] ?? [] where exit.index > next.index {
                                // Reject a transfer that only loops back through the departure platform.
                                guard second.stops[exit.index].stationID != start.id else { continue }
                                add([Segment(pattern: board.pattern, board: board.index, alight: interchange),
                                     Segment(pattern: next.pattern, board: next.index, alight: exit.index)],
                                    access: start.distance, egress: exit.walk, transfer: neighbor.distance)
                            }
                        }
                    }
                }
            }
        }
        let ordered = candidates.keys.sorted { a, b in
            let x = candidates[a]!, y = candidates[b]!
            return x.score == y.score ? a < b : x.score < y.score
        }
        var seenFamilies = Set<String>()
        let choices = ordered.filter { key in
            let family = candidates[key]!.segments.map {
                "\(patterns[$0.pattern].route.parentID):\(patterns[$0.pattern].direction)"
            }.joined(separator: "|")
            return seenFamilies.insert(family).inserted
        }
        var limited = Array(choices.prefix(limit))
        if limit >= 2, let direct = choices.first(where: { candidates[$0]!.segments.count == 1 }), !limited.contains(direct) {
            limited[limited.count - 1] = direct
        }
        return limited.map { key in
            let candidate = candidates[key]!
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
                return TransitRide(route: pattern.route, direction: pattern.direction, stops: stops, coordinates: coordinates)
            }
            return TransitTrip(rides: rides, accessDistance: candidate.access, egressDistance: candidate.egress,
                transferDistance: candidate.transfer, score: candidate.score,
                rideSeconds: candidate.segments.map { segment in
                    let p = patterns[segment.pattern]
                    return (p.distances[segment.alight] - p.distances[segment.board]) / 4.5 + Double(segment.alight - segment.board) * 20
                })
        }
    }
}
