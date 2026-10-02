import Foundation

public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public static let taipei = Coordinate(latitude: 25.0377, longitude: 121.56)
    public var isInServiceArea: Bool {
        latitude.isFinite && longitude.isFinite &&
        (24.94...25.23).contains(latitude) && (121.40...121.72).contains(longitude)
    }

    public func distance(to other: Coordinate) -> Double {
        let cosine = cos((latitude + other.latitude) * .pi / 360)
        return hypot((longitude - other.longitude) * cosine, latitude - other.latitude) * 111_320
    }

    public func bearing(to other: Coordinate) -> Double {
        let angle = atan2((other.longitude - longitude) * cos(latitude * .pi / 180), other.latitude - latitude)
        return (angle * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    public func interpolate(to other: Coordinate, fraction: Double) -> Coordinate {
        Coordinate(latitude: latitude + (other.latitude - latitude) * fraction,
                   longitude: longitude + (other.longitude - longitude) * fraction)
    }

    /// Normalized Web Mercator. The native map projection later scales X/Y to world pixels.
    public var mercator: (x: Double, y: Double) {
        let lat = min(85.051129, max(-85.051129, latitude))
        return ((longitude + 180) / 360,
                (1 - log(tan(.pi / 4 + lat * .pi / 360)) / .pi) / 2)
    }
}

public struct LineMatch: Sendable {
    public let coordinate: Coordinate
    public let segment: Int
    public let along: Double
    public let distance: Double
}

public struct RouteLine: Sendable {
    public let coordinates: [Coordinate]
    public let cumulative: [Double]
    public var length: Double { cumulative.last ?? 0 }

    public init(coordinates: [Coordinate]) {
        self.coordinates = coordinates
        var distances = [0.0]
        for i in coordinates.indices.dropFirst() {
            distances.append(distances.last! + coordinates[i - 1].distance(to: coordinates[i]))
        }
        cumulative = distances
    }

    public static func parse(wkt: String) -> RouteLine? {
        guard wkt.uppercased().hasPrefix("LINESTRING"),
              let start = wkt.firstIndex(of: "("), let end = wkt.lastIndex(of: ")") else { return nil }
        var coordinates: [Coordinate] = []
        for pair in wkt[wkt.index(after: start)..<end].split(separator: ",") {
            let values = pair.split(whereSeparator: { $0.isWhitespace })
            guard values.count >= 2, let lon = Double(values[0]), let lat = Double(values[1]),
                  lon.isFinite, lat.isFinite, abs(lon) <= 180, abs(lat) <= 90 else { return nil }
            coordinates.append(Coordinate(latitude: lat, longitude: lon))
        }
        return coordinates.count >= 2 ? RouteLine(coordinates: coordinates) : nil
    }

    /// Keep all nearby projections: the closest one can belong to the return leg of a route.
    public func candidates(_ point: Coordinate, maximumDistance: Double = 40) -> [LineMatch] {
        guard coordinates.count >= 2 else { return [] }
        let cosine = cos(point.latitude * .pi / 180)
        let margin = maximumDistance / 100_000
        var matches: [LineMatch] = []
        for i in 0..<(coordinates.count - 1) {
            let a = coordinates[i], b = coordinates[i + 1]
            guard point.longitude >= min(a.longitude, b.longitude) - margin,
                  point.longitude <= max(a.longitude, b.longitude) + margin,
                  point.latitude >= min(a.latitude, b.latitude) - margin,
                  point.latitude <= max(a.latitude, b.latitude) + margin else { continue }
            let dx = (b.longitude - a.longitude) * cosine, dy = b.latitude - a.latitude
            let squared = dx * dx + dy * dy
            guard squared > 0 else { continue }
            let t = max(0, min(1, ((point.longitude - a.longitude) * cosine * dx + (point.latitude - a.latitude) * dy) / squared))
            let coordinate = a.interpolate(to: b, fraction: t)
            let distance = point.distance(to: coordinate)
            if distance <= maximumDistance {
                matches.append(LineMatch(coordinate: coordinate, segment: i,
                    along: cumulative[i] + (cumulative[i + 1] - cumulative[i]) * t, distance: distance))
            }
        }
        return matches
    }

    public func bearing(at match: LineMatch, direction: Int = 1) -> Double {
        guard coordinates.indices.contains(match.segment + 1) else { return 0 }
        let bearing = coordinates[match.segment].bearing(to: coordinates[match.segment + 1])
        return (bearing + (direction < 0 ? 180 : 0)).truncatingRemainder(dividingBy: 360)
    }

    public func match(_ point: Coordinate, heading: Double?, previous: LineMatch? = nil,
                      maximumTravel: Double? = nil, travelDirection: Int = 0,
                      alongRange: ClosedRange<Double>? = nil) -> LineMatch? {
        var best: LineMatch?
        var bestScore = Double.infinity
        for candidate in candidates(point) {
            if let alongRange, !alongRange.contains(candidate.along) { continue }
            let delta = previous.map { candidate.along - $0.along }
            if let delta, let maximumTravel, abs(delta) > maximumTravel { continue }
            var angle = heading.map { Self.headingDifference(bearing(at: candidate, direction: travelDirection), $0) } ?? 0
            if travelDirection == 0 { angle = min(angle, 180 - angle) }
            var score = candidate.distance + angle * 0.18
            if let delta {
                // Discourage discontinuous branch switches and small backwards jumps, without
                // requiring a guessed future position or preventing a real turn at a terminus.
                score += abs(delta) * 0.035
                if travelDirection != 0, delta * Double(travelDirection) < -8 {
                    score += min(50, abs(delta) * 0.35)
                }
            }
            if score < bestScore { bestScore = score; best = candidate }
        }
        return best
    }

    public static func headingDifference(_ a: Double, _ b: Double) -> Double {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    public func slice(from: LineMatch, to: LineMatch) -> [Coordinate] {
        let reversed = from.along > to.along
        let start = reversed ? to : from, end = reversed ? from : to
        var points = [start.coordinate]
        if start.segment < end.segment {
            for i in (start.segment + 1)...end.segment { points.append(coordinates[i]) }
        }
        points.append(end.coordinate)
        return reversed ? points.reversed().map { $0 } : points
    }

    public func sample(fraction: Double) -> (Coordinate, Double) {
        guard let first = coordinates.first else { return (.taipei, 0) }
        guard coordinates.count >= 2, length > 0 else { return (first, 0) }
        let distance = min(length, max(0, fraction * length))
        var low = 1, high = coordinates.count - 1
        while low < high {
            let middle = (low + high) / 2
            if cumulative[middle] < distance { low = middle + 1 } else { high = middle }
        }
        let i = low
        if cumulative[i] >= distance {
            let span = cumulative[i] - cumulative[i - 1]
            let t = span > 0 ? (distance - cumulative[i - 1]) / span : 1
            return (coordinates[i - 1].interpolate(to: coordinates[i], fraction: t),
                    coordinates[i - 1].bearing(to: coordinates[i]))
        }
        return (coordinates.last!, coordinates[coordinates.count - 2].bearing(to: coordinates.last!))
    }
}
