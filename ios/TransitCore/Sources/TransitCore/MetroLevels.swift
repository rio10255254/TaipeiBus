import Foundation

/// Track height along each metro pattern: positive on viaducts, negative in tunnels, zero at
/// grade. Built offline from OpenStreetMap tunnel/bridge/layer tags (ODbL) matched onto the
/// official TDX geometry. Viaduct heights are near real; tunnel depths are layered for
/// readability (deeper lines further down) rather than surveyed.
public struct MetroLevels: Codable, Sendable {
    public let schema: Int
    public let source: String
    public let license: String
    public let networkGeneratedAt: String
    /// "patternID|direction" → [[metres along the pattern geometry, height in metres]].
    public let profiles: [String: [[Double]]]

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard schema == 1, profiles.count <= 300 else { throw FeedError.invalid("Metro levels schema") }
        for keyframes in profiles.values {
            guard !keyframes.isEmpty, keyframes.count <= 4000,
                  keyframes.allSatisfy({ $0.count == 2 && $0[0].isFinite && (-80...60).contains($0[1]) }),
                  zip(keyframes, keyframes.dropFirst()).allSatisfy({ $0[0] <= $1[0] }) else {
                throw FeedError.invalid("Metro levels profile")
            }
        }
    }
    public static func key(_ pattern: MetroPattern) -> String { pattern.id + "|" + pattern.direction }
}

public enum MetroStructure: String, Sendable {
    case underground, ground, elevated
    public init(height: Double) {
        self = height > 3 ? .elevated : height < -3 ? .underground : .ground
    }
}

/// Piecewise-linear height along one pattern.
public struct MetroHeightProfile: Sendable, Equatable {
    public let along: [Double]
    public let height: [Double]
    public init?(keyframes: [[Double]]) {
        guard !keyframes.isEmpty else { return nil }
        along = keyframes.map { $0[0] }; height = keyframes.map { $0[1] }
    }
    public func height(at distance: Double) -> Double {
        guard let first = along.first, let last = along.last else { return 0 }
        if distance <= first { return height[0] }
        if distance >= last { return height[height.count - 1] }
        var low = 0, high = along.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if along[middle] <= distance { low = middle } else { high = middle }
        }
        let span = along[high] - along[low]
        return span > 0 ? height[low] + (height[high] - height[low]) * (distance - along[low]) / span : height[high]
    }
    /// Runs of one structure, as [start, end) distances, for drawing tunnels and viaducts.
    public func runs(length: Double, step: Double = 10) -> [(structure: MetroStructure, start: Double, end: Double)] {
        var result: [(structure: MetroStructure, start: Double, end: Double)] = []
        var distance = 0.0
        while distance < length {
            let next = min(length, distance + step)
            let structure = MetroStructure(height: height(at: (distance + next) / 2))
            if let last = result.last, last.structure == structure { result[result.count - 1].end = next }
            else { result.append((structure, distance, next)) }
            distance = next
        }
        return result
    }
}

extension MetroNetwork {
    /// Bundled levels apply only to the network snapshot they were matched against.
    public func withLevels(_ levels: MetroLevels) -> MetroNetwork {
        guard levels.networkGeneratedAt == generatedAt else { return self }
        var copy = self
        copy.heightProfiles = levels.profiles.compactMapValues(MetroHeightProfile.init(keyframes:))
        return copy
    }
    public func heightProfile(_ pattern: MetroPattern) -> MetroHeightProfile? {
        heightProfiles[MetroLevels.key(pattern)]
    }
}

extension RouteLine {
    /// The track between two distances along it, for drawing one structure run as its own line.
    public func slice(fromAlong start: Double, toAlong end: Double) -> [Coordinate] {
        guard coordinates.count >= 2, end > start else { return [] }
        let from = max(0, start), to = min(length, end)
        guard to > from else { return [] }
        func point(_ distance: Double) -> Coordinate { sample(fraction: length > 0 ? distance / length : 0).0 }
        var result = [point(from)]
        for index in coordinates.indices where cumulative[index] > from && cumulative[index] < to { result.append(coordinates[index]) }
        result.append(point(to))
        return result
    }
}

extension MetroHeightProfile {
    /// The pattern's geometry cut into underground, at-grade and viaduct pieces.
    public func pieces(of line: RouteLine) -> [(structure: MetroStructure, coordinates: [Coordinate])] {
        runs(length: line.length).compactMap { run in
            let coordinates = line.slice(fromAlong: run.start, toAlong: run.end)
            return coordinates.count >= 2 ? (run.structure, coordinates) : nil
        }
    }
}
