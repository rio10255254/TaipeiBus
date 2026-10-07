import Foundation

/// Geographic bounds of received trajectories, reused before evaluating motion.
public struct GeoBounds: Sendable {
    public let south: Double
    public let west: Double
    public let north: Double
    public let east: Double
    public init(south: Double, west: Double, north: Double, east: Double) {
        self.south = south; self.west = west; self.north = north; self.east = east
    }
    public init(_ coordinates: [Coordinate]) {
        south = coordinates.map(\.latitude).min() ?? 0; north = coordinates.map(\.latitude).max() ?? 0
        west = coordinates.map(\.longitude).min() ?? 0; east = coordinates.map(\.longitude).max() ?? 0
    }
    public func intersects(_ other: GeoBounds) -> Bool {
        north >= other.south && south <= other.north && east >= other.west && west <= other.east
    }
    public func contains(_ coordinate: Coordinate) -> Bool {
        (south...north).contains(coordinate.latitude) && (west...east).contains(coordinate.longitude)
    }
    public func union(_ other: GeoBounds) -> GeoBounds {
        GeoBounds(south: min(south, other.south), west: min(west, other.west),
                  north: max(north, other.north), east: max(east, other.east))
    }
}

public struct MapBuilding: Sendable {
    public let rings: [[Coordinate]]
    public let height: Double
    public let baseHeight: Double
    public init(rings: [[Coordinate]], height: Double, baseHeight: Double = 0) {
        self.rings = rings; self.height = height; self.baseHeight = baseHeight
    }
}

public struct ClearCameraAngle: Sendable {
    public let heading: Double
    public let pitch: Double
}

/// Finds an unobstructed sight line before rotating the actual camera. A bounded
/// search avoids visible trial-and-error spins and can fall back to an overhead view.
public enum CameraVisibility {
    public static func isBlocked(target: Coordinate, altitude: Double, heading: Double, pitch: Double,
                                 buildings: [MapBuilding]) -> Bool {
        guard pitch > 1, altitude > 3 else { return false }
        let length = altitude * tan(min(65, pitch) * .pi / 180)
        let angle = heading * .pi / 180
        let eye = SIMD2(-sin(angle) * length, -cos(angle) * length)
        for building in buildings where building.height > 2 && !building.rings.isEmpty {
            let rings = building.rings.map { ring in ring.map { point in
                SIMD2((point.longitude - target.longitude) * 111_320 * cos(target.latitude * .pi / 180),
                      (point.latitude - target.latitude) * 111_320)
            } }
            var cuts = [0.0, 1.0]
            for ring in rings where ring.count >= 3 {
                for i in ring.indices {
                    let a = ring[i], edge = ring[(i + 1) % ring.count] - a
                    let cross = eye.x * edge.y - eye.y * edge.x
                    guard abs(cross) > 0.0001 else { continue }
                    let t = (a.x * edge.y - a.y * edge.x) / cross
                    let u = (a.x * eye.y - a.y * eye.x) / cross
                    if t >= 0 && t <= 1 && u >= 0 && u <= 1 { cuts.append(t) }
                }
            }
            cuts.sort()
            for pair in zip(cuts, cuts.dropFirst()) where pair.1 - pair.0 > 0.00001 {
                let t = (pair.0 + pair.1) / 2
                let point = eye * t
                if contains(point, ring: rings[0]), !rings.dropFirst().contains(where: { contains(point, ring: $0) }),
                   2 + (altitude - 2) * pair.0 < building.height + 2,
                   2 + (altitude - 2) * pair.1 > building.baseHeight { return true }
            }
        }
        return false
    }
    public static func clearAngle(target: Coordinate, altitude: Double, heading: Double, pitch: Double,
                                  buildings: [MapBuilding]) -> ClearCameraAngle {
        for tilt in [pitch, min(pitch, 28), 0] {
            for offset in [0.0, 45, -45, 90, -90, 135, -135, 180] {
                let direction = (heading + offset + 360).truncatingRemainder(dividingBy: 360)
                if !isBlocked(target: target, altitude: altitude, heading: direction, pitch: tilt, buildings: buildings) {
                    return ClearCameraAngle(heading: direction, pitch: tilt)
                }
            }
        }
        return ClearCameraAngle(heading: heading, pitch: 0)
    }
    private static func contains(_ p: SIMD2<Double>, ring: [SIMD2<Double>]) -> Bool {
        guard ring.count >= 3 else { return false }
        var result = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
        }
        return result
    }
}
