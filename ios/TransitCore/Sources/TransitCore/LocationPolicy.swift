import Foundation

public struct LocationSample: Codable, Equatable, Sendable {
    public let coordinate: Coordinate
    public let accuracy: Double
    public let timestamp: Date
    public init(coordinate: Coordinate, accuracy: Double, timestamp: Date) {
        self.coordinate = coordinate; self.accuracy = accuracy; self.timestamp = timestamp
    }
    public func canDisplay(at date: Date) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite && abs(coordinate.latitude) + abs(coordinate.longitude) > 0.001 &&
        (-85...85).contains(coordinate.latitude) && (-180...180).contains(coordinate.longitude) &&
        accuracy.isFinite && (0...2_000).contains(accuracy) && (-10...180).contains(date.timeIntervalSince(timestamp))
    }
    public func canPlan(at date: Date) -> Bool { canDisplay(at: date) && accuracy <= 120 && date.timeIntervalSince(timestamp) <= 60 }
    public func shouldReplace(_ old: LocationSample?, at date: Date) -> Bool {
        guard canDisplay(at: date) else { return false }
        guard let old, old.canDisplay(at: date) else { return true }
        guard timestamp >= old.timestamp else { return false }
        // A new coarse report must not replace a recent, substantially better position.
        return accuracy <= max(25, old.accuracy * 1.5) || date.timeIntervalSince(old.timestamp) > 30
    }
}
