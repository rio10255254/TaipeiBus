import Foundation

/// One station's published bike and dock counts, with the time the station reported them.
public struct BikeDock: Sendable, Equatable, Identifiable {
    public let stationID: String
    public let rentable: Int
    public let returnable: Int
    public let capacity: Int
    /// False while the operator has the station suspended.
    public let active: Bool
    public let observedAt: Date
    public var id: String { stationID }
    public init(stationID: String, rentable: Int, returnable: Int, capacity: Int, active: Bool, observedAt: Date) {
        self.stationID = stationID; self.rentable = rentable; self.returnable = returnable
        self.capacity = capacity; self.active = active; self.observedAt = observedAt
    }
    /// Stations report about once a minute. Counts older than a quarter of an hour are
    /// not presented as what is standing there now.
    public static let freshnessSeconds: TimeInterval = 15 * 60
    public func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(observedAt)
        return age > -120 && age < Self.freshnessSeconds
    }
    /// A displayed count must belong to an active station and a current report.
    public func availableCount(returning: Bool, at date: Date) -> Int? {
        guard active, isFresh(at: date) else { return nil }
        return returning ? returnable : rentable
    }
}

/// What a rider can count on at a station right now: enough, a couple left, none, or not known.
public enum BikeSupply: String, Sendable {
    case plenty, few, empty, suspended, unknown
    /// `returning` asks about free docks instead of bikes.
    public static func level(_ dock: BikeDock?, at date: Date, returning: Bool = false) -> BikeSupply {
        guard let dock, dock.isFresh(at: date) else { return .unknown }
        guard dock.active else { return .suspended }
        let count = returning ? dock.returnable : dock.rentable
        if count <= 0 { return .empty }
        return count <= 3 ? .few : .plenty
    }
}

/// A decoded city-wide YouBike snapshot, keyed by station.
public struct BikeAvailability: Sendable, Equatable {
    public let docks: [String: BikeDock]
    /// When this app received the file; the counts carry their own report times.
    public let receivedAt: Date

    public init(docks: [String: BikeDock] = [:], receivedAt: Date = .distantPast) {
        self.docks = docks; self.receivedAt = receivedAt
    }

    /// Taipei's public immediate feed, or New Taipei's, which names the same counts differently
    /// (`sbi_quantity`, `bemp`, `tot_quantity`) and stamps them `20261029T003403`. Rows for stations
    /// the app does not know, rows missing counts and counts stamped in the future are dropped rather
    /// than guessed at.
    public init(data: Data, network: BikeNetwork, at date: Date = Date()) throws {
        guard data.count <= 8 * 1_024 * 1_024 else { throw FeedError.invalid("YouBike 即時資料") }
        var bytes = data
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        guard let rows = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
              !rows.isEmpty, rows.count <= 20_000 else { throw FeedError.invalid("YouBike 即時資料") }
        var result: [String: BikeDock] = [:]
        // Most stations share the same few timestamp strings. Parse each once using one
        // formatter, rather than rebuilding several formatters for every station.
        let formatter = FeedDecoder.makeTaipeiFormatter()
        var dates: [String: Date] = [:], invalidDates = Set<String>()
        func timestamp(_ value: Any?) -> Date? {
            var text = FeedDecoder.text(value)
            guard !text.isEmpty, !invalidDates.contains(text) else { return nil }
            if let date = dates[text] { return date }
            let key = text, bytes = Array(text.utf8)
            // New Taipei's "20261029T003403", in Taipei time like every other stamp.
            if bytes.count == 15, bytes[8] == UInt8(ascii: "T"),
               bytes.enumerated().allSatisfy({ $0.offset == 8 || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0.element) }) {
                func part(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
                text = "\(part(0..<4))-\(part(4..<6))-\(part(6..<8)) \(part(9..<11)):\(part(11..<13)):\(part(13..<15))"
            }
            guard let parsed = FeedDecoder.taipeiDate(text, formatter: formatter) else {
                invalidDates.insert(key); return nil
            }
            dates[key] = parsed; return parsed
        }
        func count(_ row: [String: Any], _ keys: String...) -> Double? { keys.lazy.compactMap { FeedDecoder.number(row[$0]) }.first }
        for row in rows {
            let id = FeedDecoder.text(row["sno"])
            guard !id.isEmpty, let station = network.station(id) else { continue }
            guard let rentable = count(row, "available_rent_bikes", "sbi_quantity", "sbi"),
                  let returnable = count(row, "available_return_bikes", "bemp") else { continue }
            let capacity = count(row, "Quantity", "tot_quantity", "tot") ?? Double(station.capacity)
            guard (0...500).contains(rentable), (0...500).contains(returnable), (0...500).contains(capacity) else { continue }
            // infoTime belongs to this station; a newer city-wide publication timestamp
            // must not revive a station that stopped reporting.
            let reported = ["infoTime", "srcUpdateTime", "updateTime", "mday"]
                .lazy.compactMap { timestamp(row[$0]) }.first
            guard let reported, reported.timeIntervalSince(date) < 600 else { continue }
            result[id] = BikeDock(stationID: id, rentable: Int(rentable), returnable: Int(returnable),
                                  capacity: Int(capacity), active: FeedDecoder.text(row["act"]) != "0",
                                  observedAt: reported)
        }
        guard !result.isEmpty else { throw FeedError.invalid("YouBike 即時資料") }
        docks = result; receivedAt = date
    }

    /// Each city's own file as one: no station is in two cities, and the newest receipt marks a change.
    public static func combining(_ parts: [BikeAvailability]) -> BikeAvailability? {
        guard let first = parts.first else { return nil }
        guard parts.count > 1 else { return first }
        var docks: [String: BikeDock] = [:]
        for part in parts { docks.merge(part.docks) { current, _ in current } }
        return BikeAvailability(docks: docks, receivedAt: parts.map(\.receivedAt).max() ?? first.receivedAt)
    }

    public var isEmpty: Bool { docks.isEmpty }
    public func dock(_ id: String) -> BikeDock? { docks[id] }
    /// The dock only while its counts are recent enough to show.
    public func dock(_ id: String, at date: Date) -> BikeDock? {
        docks[id].flatMap { $0.isFresh(at: date) ? $0 : nil }
    }
}
