import Foundation

/// One train entering a platform, from Taipei Metro's free open-data feed
/// (https://data.taipei, "臺北捷運列車到站站名"). The feed has no train identity and no
/// countdown: only the station, the train's terminus and the provider's update time.
public struct MetroPlatformEvent: Equatable, Sendable {
    public let stationID: String
    public let patternID: String
    public let direction: String
    public let observedAt: Date
    /// Provider identity remains stable even when transport delay shifts the local clock anchor.
    public let providerTimestamp: String?
    public init(stationID: String, patternID: String, direction: String, observedAt: Date, providerTimestamp: String? = nil) {
        self.stationID = stationID; self.patternID = patternID; self.direction = direction; self.observedAt = observedAt
        self.providerTimestamp = providerTimestamp
    }
}

/// When a recently seen train should reach the rider's station. Derived from a real sighting
/// plus official running times, so it is an estimate, never an official countdown.
public struct MetroPlatformEstimate: Equatable, Sendable {
    public let seconds: Double
    /// A train for this direction is entering the rider's own station right now.
    public let entering: Bool
    public let observedAt: Date
    public init(seconds: Double, entering: Bool, observedAt: Date) {
        self.seconds = seconds; self.entering = entering; self.observedAt = observedAt
    }
}

public enum MetroPlatformFeed {
    public static let url = URL(string: "https://tcgmetro.blob.core.windows.net/stationnames/stations.json")!
    /// Sightings older than this no longer say anything useful about where a train is.
    public static let memory: TimeInterval = 15 * 60

    /// Provider times are Taipei wall-clock times. The age is measured against the server's own
    /// response time when available, so a wrong phone clock cannot make data look fresh.
    public static func parse(_ data: Data, network: MetroNetwork, serverDate: Date?, receivedAt: Date) throws -> [MetroPlatformEvent] {
        guard data.count <= 256 * 1024 else { throw FeedError.invalid("Metro platform feed size") }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        guard let rows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]], rows.count <= 500 else {
            throw FeedError.invalid("Metro platform feed shape")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let reference = serverDate ?? receivedAt
        let resolver = Resolver(network: network)
        var events: [MetroPlatformEvent] = []
        for row in rows {
            guard let station = row["Station"] as? String, let destination = row["Destination"] as? String,
                  let stamp = row["UpdateTime"] as? String, let updated = formatter.date(from: stamp) else { continue }
            let age = reference.timeIntervalSince(updated)
            guard (-60...memory).contains(age),
                  let match = resolver.resolve(station: station, stationEnglish: row["StationEn"] as? String,
                                               destination: destination, destinationEnglish: row["DestinationEn"] as? String) else { continue }
            events.append(MetroPlatformEvent(stationID: match.stationID, patternID: match.patternID,
                                             direction: match.direction, observedAt: receivedAt.addingTimeInterval(-max(0, age)), providerTimestamp: stamp))
        }
        return events
    }

    /// Keeps a rolling memory of sightings: a train is only listed while it enters a station,
    /// so the most recent sighting of each train is what places it on the line.
    public static func merge(_ old: [MetroPlatformEvent], _ new: [MetroPlatformEvent], at date: Date) -> [MetroPlatformEvent] {
        var result = old.filter { date.timeIntervalSince($0.observedAt) <= memory }
        for event in new where !result.contains(where: {
            $0.stationID == event.stationID && $0.patternID == event.patternID && $0.direction == event.direction &&
                (($0.providerTimestamp != nil && event.providerTimestamp != nil) ? $0.providerTimestamp == event.providerTimestamp :
                    abs($0.observedAt.timeIntervalSince(event.observedAt)) < 20)
        }) { result.append(event) }
        return Array(result.sorted { $0.observedAt > $1.observedAt }.prefix(2000))
    }

    /// The soonest seen train that stops at the boarding station and continues to the alighting
    /// station. `longestGap` bounds how far ahead a prediction may reach: past one full headway an
    /// earlier, unseen train is likely, so the caller falls back to the headway estimate.
    public static func nextArrival(ride: TransitRide, events: [MetroPlatformEvent], network: MetroNetwork,
                                   at date: Date, longestGap: Double) -> MetroPlatformEstimate? {
        nextArrival(routeID: ride.route.id, direction: ride.direction, boardingStationID: ride.boarding.stationID,
                    alightingStationID: ride.alighting.stationID, events: events, network: network, at: date, longestGap: longestGap)
    }
    /// Without an alighting station, any train continuing beyond the boarding station counts.
    public static func nextArrival(routeID: String, direction: String, boardingStationID: String, alightingStationID: String?,
                                   events: [MetroPlatformEvent], network: MetroNetwork,
                                   at date: Date, longestGap: Double) -> MetroPlatformEstimate? {
        guard let planned = network.pattern(routeID, direction: direction) else { return nil }
        var best: MetroPlatformEstimate?
        for event in events where event.direction == direction {
            guard let pattern = network.pattern(event.patternID, direction: event.direction), pattern.lineID == planned.lineID,
                  let seen = pattern.stationIDs.firstIndex(of: event.stationID),
                  let board = pattern.stationIDs.firstIndex(of: boardingStationID),
                  seen <= board, board - seen <= MetroTrainTimeline.coastStations,
                  board < pattern.stationIDs.count - 1 else { continue }
            if let alightingStationID {
                guard let alight = pattern.stationIDs.firstIndex(of: alightingStationID), board < alight else { continue }
            }
            var travel = 0.0
            if seen < board {
                guard let run = network.ridingSeconds(routeID: pattern.id, direction: pattern.direction,
                                                      from: event.stationID, to: boardingStationID) else { continue }
                let dwell = pattern.dwellSeconds.indices.contains(seen) && pattern.dwellSeconds[seen] > 0 ? pattern.dwellSeconds[seen] : 25
                travel = run + dwell
            }
            guard travel <= 30 * 60 else { continue }
            let remaining = event.observedAt.addingTimeInterval(travel).timeIntervalSince(date)
            // Only an actual sighting at this platform can confirm arrival. An upstream
            // prediction that is already due cannot override missing follow-up evidence.
            let stillAtObservedPlatform = seen == board && remaining >= -40
            guard (stillAtObservedPlatform || remaining > 0), remaining <= max(120, longestGap) else { continue }
            let estimate = MetroPlatformEstimate(seconds: max(0, remaining),
                entering: seen == board && date.timeIntervalSince(event.observedAt) <= 45, observedAt: event.observedAt)
            if best.map({ estimate.seconds < $0.seconds }) ?? true { best = estimate }
        }
        return best
    }

    private struct Resolver {
        let network: MetroNetwork
        var byName: [String: [String]] = [:]
        init(network: MetroNetwork) {
            self.network = network
            for station in network.stations where station.operatorID == "TRTC" {
                byName[Self.key(station.name), default: []].append(station.id)
                byName[Self.key(station.englishName), default: []].append(station.id)
            }
        }
        static func key(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("站"), !text.hasSuffix("車站") { text.removeLast() }
            return text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        func ids(_ name: String, _ english: String?) -> [String] {
            let found = byName[Self.key(name)] ?? []
            return found.isEmpty ? english.flatMap { byName[Self.key($0)] } ?? [] : found
        }
        func resolve(station: String, stationEnglish: String?, destination: String, destinationEnglish: String?)
            -> (stationID: String, patternID: String, direction: String)? {
            let here = Set(ids(station, stationEnglish)), terminus = Set(ids(destination, destinationEnglish))
            guard !here.isEmpty, !terminus.isEmpty else { return nil }
            // Prefer the service that actually terminates at the destination (short turns included),
            // then any pattern passing the station before reaching the destination.
            var fallback: (String, String, String)?
            for pattern in network.patterns {
                guard let index = pattern.stationIDs.firstIndex(where: here.contains),
                      let end = pattern.stationIDs.lastIndex(where: terminus.contains), end >= index else { continue }
                let value = (pattern.stationIDs[index], pattern.id, pattern.direction)
                if end == pattern.stationIDs.count - 1 { return value }
                if fallback == nil { fallback = value }
            }
            return fallback
        }
    }
}
