import Foundation

/// Street routers snap a requested location to a nearby walkable path. Keep that
/// verified path and connect only the bounded access offset to its requested anchors.
public struct AnchoredPedestrianPath: Sendable {
    public let coordinates: [Coordinate]
    public let accessDistance: Double
    public static func make(_ points: [Coordinate], from: Coordinate, to: Coordinate,
                            maximumOffset: Double = 50) -> AnchoredPedestrianPath? {
        guard points.count >= 2, let first = points.first, let last = points.last,
              maximumOffset.isFinite, maximumOffset >= 0 else { return nil }
        let startGap = first.distance(to: from), endGap = last.distance(to: to)
        guard startGap.isFinite, endGap.isFinite, startGap <= maximumOffset, endGap <= maximumOffset else { return nil }
        var path = points
        if startGap > 0.5 { path.insert(from, at: 0) } else { path[0] = from }
        if endGap > 0.5 { path.append(to) } else { path[path.count - 1] = to }
        return AnchoredPedestrianPath(coordinates: path, accessDistance: startGap + endGap)
    }
}
