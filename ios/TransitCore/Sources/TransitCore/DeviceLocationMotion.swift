import Foundation

/// Interpolates only between received positions and bearings; it never predicts a device's future position.
public struct DeviceLocationMotion: Sendable {
    public private(set) var coordinate: Coordinate?
    public private(set) var heading: Double?
    public init() {}
    public static func angleDelta(from: Double, to: Double) -> Double {
        (to - from + 540).truncatingRemainder(dividingBy: 360) - 180
    }
    public mutating func update(coordinate target: Coordinate?, heading bearing: Double?, elapsed: Double, reduceMotion: Bool) {
        let dt = min(0.1, max(0, elapsed))
        if let target {
            if let previous = coordinate, !reduceMotion, previous.distance(to: target) < 300 {
                coordinate = previous.interpolate(to: target, fraction: 1 - exp(-dt / 0.22))
            } else { coordinate = target }
        } else { coordinate = nil }
        if let bearing {
            if let previous = heading, !reduceMotion {
                heading = (previous + Self.angleDelta(from: previous, to: bearing) * (1 - exp(-dt / 0.18)) + 360)
                    .truncatingRemainder(dividingBy: 360)
            } else { heading = bearing }
        } else { heading = nil }
    }
}
