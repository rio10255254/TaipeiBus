import Foundation

/// Shared station-to-station planning data. No credentials or passenger locations.
public struct OfficialTravelTimes: Sendable {
    public struct Period: Codable, Sendable {
        public let weekday: Int
        public let startHour: Int
        public let endHour: Int
        public let seconds: [Int]
    }
    public struct Route: Codable, Sendable {
        public let route: String
        public let subroute: String
        public let direction: String
        public let updated: String
        public let edges: [[String]]
        public let periods: [Period]
    }
    private struct Document: Decodable { let schema: Int; let generatedAt: String?; let routes: [Route] }
    public let generatedAt: Date?
    private struct Edge: Hashable, Sendable { let from: String; let to: String }
    private struct Profile: Sendable {
        let route: String
        let updated: Date
        let edges: [Edge: Int]
        let hours: [Int: [Int]]
    }
    private var indexed: [String: [Profile]] = [:]
    public init() { generatedAt = nil }
    public init(data: Data) throws {
        guard data.count <= 32 * 1024 * 1024 else { throw FeedError.invalid("Official travel-time size") }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schema == 1, document.routes.count <= 10_000 else { throw FeedError.invalid("Official travel-time schema") }
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        generatedAt = document.generatedAt.flatMap { plain.date(from: $0) ?? fractional.date(from: $0) }
        for route in document.routes {
            guard !route.route.isEmpty, !route.subroute.isEmpty, ["0", "1", "2"].contains(route.direction),
                  route.edges.count <= 400, !route.edges.isEmpty,
                  route.edges.allSatisfy({ $0.count == 2 && !$0[0].isEmpty && !$0[1].isEmpty && $0[0] != $0[1] }),
                  route.periods.count <= 200,
                  route.periods.allSatisfy({ (0...6).contains($0.weekday) || $0.weekday == 99 }),
                  let updated = plain.date(from: route.updated) ?? fractional.date(from: route.updated) else { continue }
            var edges: [Edge: Int] = [:], hours: [Int: [Int]] = [:]
            for (index, edge) in route.edges.enumerated() { edges[Edge(from: edge[0], to: edge[1])] = index }
            guard edges.count == route.edges.count else { continue }
            for period in route.periods {
                guard (0...23).contains(period.startHour), (1...24).contains(period.endHour),
                      period.endHour > period.startHour, period.seconds.count == route.edges.count else { continue }
                for hour in period.startHour..<period.endHour { hours[period.weekday * 24 + hour] = period.seconds }
            }
            guard !hours.isEmpty else { continue }
            indexed[route.subroute + ":" + route.direction, default: []].append(
                Profile(route: route.route, updated: updated, edges: edges, hours: hours))
        }
    }
    public var patternCount: Int { indexed.values.reduce(0) { $0 + $1.count } }
    public func seconds(route: String, subroute: String, direction: String, from: String, to: String,
                        travellingAt: Date, observedAt: Date) -> Double? {
        guard let profiles = indexed[subroute + ":" + direction] else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let weekday = calendar.component(.weekday, from: travellingAt) - 1
        let hour = calendar.component(.hour, from: travellingAt)
        for profile in profiles where profile.route == route {
            guard (-300...45 * 86400).contains(observedAt.timeIntervalSince(profile.updated)),
                  let edge = profile.edges[Edge(from: from, to: to)],
                  let values = profile.hours[weekday * 24 + hour] ?? profile.hours[99 * 24 + hour],
                  (1...1800).contains(values[edge]) else { continue }
            return Double(values[edge])
        }
        return nil
    }
}
