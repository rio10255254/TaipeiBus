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

    /// Taipei's public immediate feed. Rows for stations the app does not know, rows missing
    /// counts and counts stamped in the future are dropped rather than guessed at.
    public init(data: Data, network: BikeNetwork, at date: Date = Date()) throws {
        guard data.count <= 8 * 1_024 * 1_024 else { throw FeedError.invalid("YouBike 即時資料") }
        var bytes = data
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        guard let rows = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]],
              !rows.isEmpty, rows.count <= 20_000 else { throw FeedError.invalid("YouBike 即時資料") }
        var result: [String: BikeDock] = [:]
        for row in rows {
            let id = FeedDecoder.text(row["sno"])
            guard !id.isEmpty, let station = network.station(id) else { continue }
            guard let rentable = FeedDecoder.number(row["available_rent_bikes"]),
                  let returnable = FeedDecoder.number(row["available_return_bikes"]) else { continue }
            let capacity = FeedDecoder.number(row["Quantity"]) ?? Double(station.capacity)
            guard (0...500).contains(rentable), (0...500).contains(returnable), (0...500).contains(capacity) else { continue }
            let reported = ["infoTime", "srcUpdateTime", "updateTime", "mday"]
                .compactMap { FeedDecoder.taipeiDate(FeedDecoder.text(row[$0])) }.max()
            guard let reported, reported.timeIntervalSince(date) < 600 else { continue }
            result[id] = BikeDock(stationID: id, rentable: Int(rentable), returnable: Int(returnable),
                                  capacity: Int(capacity), active: FeedDecoder.text(row["act"]) != "0",
                                  observedAt: reported)
        }
        guard !result.isEmpty else { throw FeedError.invalid("YouBike 即時資料") }
        docks = result; receivedAt = date
    }

    public var isEmpty: Bool { docks.isEmpty }
    public func dock(_ id: String) -> BikeDock? { docks[id] }
    /// The dock only while its counts are recent enough to show.
    public func dock(_ id: String, at date: Date) -> BikeDock? {
        docks[id].flatMap { $0.isFresh(at: date) ? $0 : nil }
    }
}
