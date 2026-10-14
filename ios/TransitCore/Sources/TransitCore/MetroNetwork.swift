import Foundation

public struct MetroLine: Codable, Identifiable, Sendable {
    public let id: String
    public let operatorID: String
    public let code: String
    public let name: String
    public let englishName: String
    public let color: String
    public let mode: TransportMode
    public let coordinates: [Coordinate]
}
public struct MetroExit: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let englishName: String
    public let coordinate: Coordinate
    public let accessible: Bool
}
public struct MetroStation: Codable, Identifiable, Sendable {
    public let id: String
    public let operatorID: String
    public let code: String
    public let name: String
    public let englishName: String
    public let coordinate: Coordinate
    public let exits: [MetroExit]
}
public struct MetroPattern: Codable, Identifiable, Sendable {
    public let id: String
    public let lineID: String
    public let direction: String
    public let stationIDs: [String]
    public let stationCoordinates: [Coordinate]
    public let coordinates: [Coordinate]
    public let seconds: [Double]
    public let dwellSeconds: [Double]
    public let firstDeparture: String
    public let lastDeparture: String
    public let headwaySeconds: Double
    public let periods: [MetroServicePeriod]
    public let stationWindows: [MetroStationWindow]
}
public struct MetroStationWindow: Codable, Sendable {
    public let stationID: String
    public let first: String
    public let last: String
}
public struct MetroServicePeriod: Codable, Sendable {
    public let weekdays: [Int]
    public let holiday: Bool
    public let start: String
    public let end: String
    public let minimumSeconds: Double
    public let maximumSeconds: Double
}
public struct MetroTransfer: Codable, Sendable {
    public let from: String
    public let to: String
    public let seconds: Double
    public let instructions: String
    public let external: Bool
}
public struct MetroNetwork: Codable, Sendable {
    public let schema: Int
    public let generatedAt: String
    public let source: String
    public let lines: [MetroLine]
    public let stations: [MetroStation]
    public let patterns: [MetroPattern]
    public let transfers: [MetroTransfer]
    /// Track heights, attached from MetroLevels after decoding.
    public internal(set) var heightProfiles: [String: MetroHeightProfile] = [:]
    private enum CodingKeys: String, CodingKey { case schema, generatedAt, source, lines, stations, patterns, transfers }
    public static let empty = MetroNetwork(schema: 1, generatedAt: "", source: "", lines: [], stations: [], patterns: [], transfers: [])
    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
        guard schema == 1, stations.count <= 500, patterns.count <= 150,
              Set(stations.map(\.id)).count == stations.count,
              Set(lines.map(\.id)).count == lines.count else { throw FeedError.invalid("Metro network schema") }
        let ids = Set(stations.map(\.id)), lineIDs = Set(lines.map(\.id))
        guard stations.allSatisfy({ $0.coordinate.latitude.isFinite && $0.coordinate.longitude.isFinite && !$0.name.isEmpty }),
              patterns.allSatisfy({ lineIDs.contains($0.lineID) && ["0", "1"].contains($0.direction) &&
                  $0.stationIDs.count >= 2 && $0.stationIDs.allSatisfy(ids.contains) &&
                  $0.stationCoordinates.count == $0.stationIDs.count &&
                  $0.seconds.count == $0.stationIDs.count - 1 && $0.seconds.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1800 }) }) else {
            throw FeedError.invalid("Metro network topology")
        }
    }
    private init(schema: Int, generatedAt: String, source: String, lines: [MetroLine], stations: [MetroStation], patterns: [MetroPattern], transfers: [MetroTransfer]) {
        self.schema = schema; self.generatedAt = generatedAt; self.source = source; self.lines = lines
        self.stations = stations; self.patterns = patterns; self.transfers = transfers
    }
    public func line(_ id: String) -> MetroLine? { lines.first { $0.id == id } }
    public func station(_ id: String) -> MetroStation? { stations.first { $0.id == id } }
    public func pattern(_ id: String, direction: String) -> MetroPattern? { patterns.first { $0.id == id && $0.direction == direction } }
    public func canServe(_ ride: TransitRide, patternID: String, direction: String, destinationStationID: String) -> Bool {
        guard direction == ride.direction, let pattern = pattern(patternID, direction: direction),
              let planned = self.pattern(ride.route.id, direction: direction), pattern.lineID == planned.lineID,
              let board = pattern.stationIDs.firstIndex(of: ride.boarding.stationID),
              let destination = pattern.stationIDs.firstIndex(of: destinationStationID),
              destination >= board + ride.stopCount,
              board + ride.stops.count <= pattern.stationIDs.count else { return false }
        return Array(pattern.stationIDs[board..<(board + ride.stops.count)]) == ride.stops.map(\.stationID)
    }
    public func ridingSeconds(routeID: String, direction: String, from: String, to: String) -> Double? {
        guard let pattern = pattern(routeID, direction: direction),
              let first = pattern.stationIDs.firstIndex(of: from), let last = pattern.stationIDs.firstIndex(of: to), last > first else { return nil }
        var total: Double = pattern.seconds[first..<last].reduce(0.0, +)
        for index in (first + 1)..<last {
            total += pattern.dwellSeconds.indices.contains(index) ? pattern.dwellSeconds[index] : 20.0
        }
        return total
    }
    public func nearestExit(stationID: String, to point: Coordinate) -> MetroExit? {
        station(stationID)?.exits.min { $0.coordinate.distance(to: point) < $1.coordinate.distance(to: point) }
    }
    /// The headway band a pattern is actually running at, or nil when the timetable says
    /// it does not run in this period (published as 0 for short-turn and branch services).
    public func activeHeadway(_ pattern: MetroPattern, at date: Date) -> (lower: Double, upper: Double)? {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let weekday = calendar.component(.weekday, from: date) - 1
        let time = BusServiceWindow.secondsOfDay(at: date), holiday = TransitServiceCalendar.isHoliday(date)
        let holidayProfile = holiday && pattern.periods.contains { $0.holiday }
        let period = pattern.periods.first {
            guard (holidayProfile ? $0.holiday : $0.weekdays.contains(weekday)),
                  let window = BusServiceWindow(first: $0.start, last: $0.end) else { return false }
            let first = Double(window.firstMinute * 60), last = Double(window.lastMinute * 60)
            return first < last ? time >= first && time < last : time >= first || time < last
        }
        let lower = period?.minimumSeconds ?? pattern.headwaySeconds
        let upper = period?.maximumSeconds ?? pattern.headwaySeconds
        guard lower > 0, upper > 0, lower.isFinite, upper.isFinite else { return nil }
        return (lower, max(lower, upper))
    }
    public func service(routeID: String, direction: String, at date: Date) -> BusDayService? {
        guard let pattern = pattern(routeID, direction: direction) else { return nil }
        let window = BusServiceWindow(first: pattern.firstDeparture, last: pattern.lastDeparture)
        let headway = activeHeadway(pattern, at: date).map { BusHeadway(lowerSeconds: $0.lower, upperSeconds: $0.upper) }
        return BusDayService(window: window, headway: headway)
    }
    /// Every train that can actually take the rider from `from` to `to` counts, not only the
    /// planned pattern: on a trunk shared by full-length and short-turn services the combined
    /// frequency is what a rider on the platform experiences. Patterns that are not running
    /// now, or not yet serving this station, are left out. Without `to`, a train only needs
    /// to continue beyond `from`.
    public func combinedService(routeID: String, direction: String, from: String, to: String? = nil, at date: Date) -> BusDayService? {
        guard let base = pattern(routeID, direction: direction) else { return nil }
        var lowerRate = 0.0, upperRate = 0.0
        for candidate in patterns where candidate.lineID == base.lineID && candidate.direction == direction {
            guard let start = candidate.stationIDs.firstIndex(of: from), start < candidate.stationIDs.count - 1 else { continue }
            if let to { guard let end = candidate.stationIDs.firstIndex(of: to), end > start else { continue } }
            guard isOperating(routeID: candidate.id, direction: direction, stationID: from, at: date),
                  let headway = activeHeadway(candidate, at: date) else { continue }
            lowerRate += 1 / headway.lower; upperRate += 1 / headway.upper
        }
        let window = BusServiceWindow(first: base.firstDeparture, last: base.lastDeparture)
        guard lowerRate > 0, upperRate > 0 else { return BusDayService(window: window, headway: nil) }
        return BusDayService(window: window, headway: BusHeadway(lowerSeconds: 1 / lowerRate, upperSeconds: 1 / upperRate))
    }
    /// Expected platform wait for a rider arriving at a random moment: half the headway on
    /// average, never more than one full headway. Rounded to whole minutes for display.
    public static func expectedWait(_ headway: BusHeadway) -> (typical: Double, longest: Double) {
        (headway.midpoint / 2, headway.upperSeconds)
    }
    public func boardingWindow(routeID: String, direction: String, stationID: String) -> BusServiceWindow? {
        guard let p = pattern(routeID, direction: direction) else { return nil }
        if let value = p.stationWindows.first(where: { $0.stationID == stationID }) {
            return BusServiceWindow(first: value.first, last: value.last)
        }
        // A terminal departure does not imply that all intermediate stations close then.
        guard let window = BusServiceWindow(first: p.firstDeparture, last: p.lastDeparture),
              let index = p.stationIDs.firstIndex(of: stationID) else { return nil }
        let offset = Int((p.seconds.prefix(index).reduce(0,+) + p.dwellSeconds.prefix(index + 1).reduce(0,+)) / 60)
        func clock(_ minute: Int) -> String { let v = minute % 1440; return String(format: "%02d:%02d", v / 60, v % 60) }
        return BusServiceWindow(first: clock(window.firstMinute + offset), last: clock(window.lastMinute + offset))
    }
    /// Do not propose overnight waiting as an ordinary available metro connection.
    public func isOperating(routeID: String, direction: String, stationID: String, at date: Date) -> Bool {
        guard let window = boardingWindow(routeID: routeID, direction: direction, stationID: stationID) else { return false }
        let t = BusServiceWindow.secondsOfDay(at: date), first = Double(window.firstMinute * 60), last = Double(window.lastMinute * 60)
        return first <= last ? t >= first && t <= last : t >= first || t <= last
    }
    public func attach(to metadata: inout TransitMetadata) {
        metadata.metro = self
        let lookup = Dictionary(uniqueKeysWithValues: stations.map { ($0.id, $0) })
        for station in stations {
            let lineName = lines.first { station.code.hasPrefix($0.code) }?.name ?? ""
            var value = Station(id: station.id, name: station.name, coordinate: station.coordinate,
                address: station.code + " · " + lineName, bearing: station.code, stopIDs: [])
            value.englishName = station.englishName; value.mode = .metro
            value.searchNames = [station.code, "捷運" + station.name, station.englishName]
            metadata.stations[value.id] = value
        }
        for pattern in patterns {
            guard let line = line(pattern.lineID), let first = pattern.stationIDs.first.flatMap({ lookup[$0] }),
                  let last = pattern.stationIDs.last.flatMap({ lookup[$0] }) else { continue }
            var route = metadata.routes[pattern.id] ?? BusRoute(id: pattern.id, parentID: line.id, name: line.name,
                variantName: line.name, departure: first.name, destination: last.name)
            route.mode = line.mode; route.lineCode = line.code; route.lineColor = line.color; route.englishName = line.englishName
            if pattern.direction == "0" {
                route = BusRoute(id: pattern.id, parentID: line.id, name: line.name, variantName: first.name + "–" + last.name,
                    departure: first.name, destination: last.name, englishName: line.englishName,
                    englishVariantName: first.englishName + "–" + last.englishName,
                    englishDeparture: first.englishName, englishDestination: last.englishName,
                    mode: line.mode, lineCode: line.code, lineColor: line.color)
            }
            route.aliasName = ["BR":"棕線","R":"紅線","G":"綠線","O":"橘線","BL":"藍線","Y":"黃線"][line.code] ?? ""
            metadata.routes[route.id] = route
            if metadata.parents[route.parentID] == nil { metadata.parents[route.parentID] = route }
            var references = metadata.paths[route.id] ?? []
            for (index, id) in pattern.stationIDs.enumerated() {
                guard let station = lookup[id] else { continue }
                let stopID = "\(pattern.id):\(pattern.direction):\(id)"
                var stop = BusStop(id: stopID, routeID: line.id, stationID: id, name: station.name,
                    direction: pattern.direction, sequence: index, coordinate: pattern.stationCoordinates[index])
                stop.englishName = station.englishName; stop.mode = line.mode
                stop.serviceID = pattern.id
                metadata.stops[stop.id] = stop
                metadata.stations[id]?.stopIDs.append(stop.id)
                references.append(StopReference(stopID: stop.id, sequence: index))
            }
            metadata.paths[route.id] = references
            if pattern.coordinates.count >= 2 {
                let shape = RouteLine(coordinates: pattern.coordinates)
                metadata.directionalLines["sub:\(route.id):\(pattern.direction)"] = shape
                if let journey = RouteJourney.build(stops: metadata.orderedStops(routeID:route.id,direction:pattern.direction), line:shape, stations:metadata.stations) {
                    metadata.journeys["\(route.id):\(pattern.direction)"] = journey
                }
            }
        }
        metadata.rebuildRouteCatalog()
        metadata.stationSearch = StationSearchIndex(stations: Array(metadata.stations.values))
    }
}
