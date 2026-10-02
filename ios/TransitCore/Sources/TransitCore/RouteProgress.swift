import Foundation

public struct StopProgress: Sendable {
    public let stop: BusStop
    /// Along the official road shape. Negative means the bus has passed this stop.
    public let distance: Double
}

/// Stop order disambiguates a shape containing both legs, loops, or repeated road sections.
/// Built once with metadata, never during a map frame or for every arriving GPS observation.
public struct RouteJourney: Sendable {
    public struct Anchor: Sendable {
        public let stop: BusStop
        public let match: LineMatch
    }
    public let anchors: [Anchor]
    public let direction: Int
    public var range: ClosedRange<Double> {
        let first = anchors.first!.match.along, last = anchors.last!.match.along
        return max(0, min(first, last) - 200)...(max(first, last) + 200)
    }

    public func coordinates(on line: RouteLine) -> [Coordinate] {
        guard line.length > 0 else { return line.coordinates }
        let start = min(line.length, range.lowerBound), end = min(line.length, range.upperBound)
        var points = [line.sample(fraction: start / line.length).0]
        points += line.coordinates.enumerated().compactMap { index, coordinate in
            line.cumulative[index] > start && line.cumulative[index] < end ? coordinate : nil
        }
        points.append(line.sample(fraction: end / line.length).0)
        return direction > 0 ? points : Array(points.reversed())
    }

    public func progress(stopID: String, vehicle: BusVehicle, at date: Date) -> StopProgress? {
        guard vehicle.hasReliablePosition(at: date), vehicle.aligned, let position = vehicle.roadMatch,
              range.contains(position.along), let anchor = anchors.first(where: { $0.stop.id == stopID }) else { return nil }
        return StopProgress(stop: anchor.stop, distance: (anchor.match.along - position.along) * Double(direction))
    }

    public func upcoming(vehicle: BusVehicle, at date: Date) -> [StopProgress] {
        guard vehicle.hasReliablePosition(at: date), vehicle.aligned, let position = vehicle.roadMatch,
              range.contains(position.along) else { return [] }
        return anchors.compactMap { anchor in
            let distance = (anchor.match.along - position.along) * Double(direction)
            return distance >= -15 ? StopProgress(stop: anchor.stop, distance: max(0, distance)) : nil
        }
    }

    public static func build(stops: [BusStop], line: RouteLine, stations: [String: Station]) -> RouteJourney? {
        struct Node {
            let match: LineMatch
            var cost: Double
            var previous: Int
        }
        let located = stops.compactMap { stop -> (BusStop, [LineMatch])? in
            var candidates: [LineMatch] = []
            for match in line.candidates(stop.coordinate, maximumDistance: 70).sorted(by: { $0.distance < $1.distance }) {
                if !candidates.contains(where: { abs($0.along - match.along) < 8 }) { candidates.append(match) }
                if candidates.count == 8 { break }
            }
            return candidates.isEmpty ? nil : (stop, candidates)
        }
        guard located.count >= 2, Double(located.count) / Double(max(1, stops.count)) >= 0.8 else { return nil }
        let bearings: [String: Double] = ["N": 0, "NE": 45, "E": 90, "SE": 135, "S": 180, "SW": 225, "W": 270, "NW": 315]
        var winner: RouteJourney?
        var winningCost = Double.infinity
        for sign in [1, -1] {
            var stages: [[Node]] = []
            for (index, entry) in located.enumerated() {
                let (stop, matches) = entry
                let heading = stations[stop.stationID].flatMap { bearings[$0.bearing] }
                let baseCosts = matches.map { match -> Double in
                    let angle = heading.map { RouteLine.headingDifference(line.bearing(at: match, direction: sign), $0) } ?? 0
                    return match.distance * match.distance / 100 + angle * angle / 400
                }
                let nodes = matches.enumerated().map { candidate, match -> Node in
                    guard index > 0 else { return Node(match: match, cost: baseCosts[candidate], previous: -1) }
                    let straight = located[index - 1].0.coordinate.distance(to: stop.coordinate)
                    var best = Node(match: match, cost: .infinity, previous: -1)
                    for (priorIndex, prior) in stages[index - 1].enumerated() {
                        let distance = (match.along - prior.match.along) * Double(sign)
                        // An implausible detour usually means a stop matched the other route leg.
                        guard distance >= -15, distance <= max(500, straight * 5) else { continue }
                        let cost = prior.cost + baseCosts[candidate] + max(0, distance - straight * 2 - 80) * 0.04
                        if cost < best.cost { best = Node(match: match, cost: cost, previous: priorIndex) }
                    }
                    return best
                }
                stages.append(nodes)
            }
            guard let last = stages.last, let index = last.indices.min(by: { last[$0].cost < last[$1].cost }),
                  last[index].cost < winningCost else { continue }
            var chosen = index
            var anchors: [Anchor] = []
            for stage in stages.indices.reversed() {
                let node = stages[stage][chosen]
                anchors.append(Anchor(stop: located[stage].0, match: node.match))
                chosen = node.previous
            }
            winningCost = last[index].cost
            winner = RouteJourney(anchors: Array(anchors.reversed()), direction: sign)
        }
        return winner
    }
}
