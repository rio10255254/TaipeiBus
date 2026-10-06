import Foundation

public struct BusHeadway: Equatable, Sendable {
    public let lowerSeconds: Double
    public let upperSeconds: Double
    public init?(published text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != "9999" else { return nil }
        let values: [Int]
        if value.count == 4, value.allSatisfy(\.isNumber) {
            values = [Int(value.prefix(2))!, Int(value.suffix(2))!]
        } else {
            values = value.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap(Int.init)
        }
        guard (1...2).contains(values.count), values.allSatisfy({ (1...120).contains($0) }) else { return nil }
        lowerSeconds = Double(values.min()! * 60); upperSeconds = Double(values.max()! * 60)
    }
    public init(lowerSeconds: Double, upperSeconds: Double) {
        self.lowerSeconds = max(60, lowerSeconds); self.upperSeconds = max(self.lowerSeconds, upperSeconds)
    }
    public static func envelope(_ values: [BusHeadway]) -> BusHeadway? {
        guard let lower = values.map(\.lowerSeconds).min(), let upper = values.map(\.upperSeconds).max() else { return nil }
        return BusHeadway(lowerSeconds: lower, upperSeconds: upper)
    }
    public var midpoint: Double { (lowerSeconds + upperSeconds) / 2 }
}

public struct BusDayService: Sendable {
    public var window: BusServiceWindow?
    public var headway: BusHeadway?
    public var departures: [Int] = []
    public init(window: BusServiceWindow? = nil, headway: BusHeadway? = nil, departures: [Int] = []) {
        self.window = window; self.headway = headway; self.departures = departures.sorted()
    }
    public static func publishedDepartures(_ text: String) -> [Int] {
        // Service notes such as "08:00–20:00 繞駛醫院" are not a timetable.
        guard !["繞", "開放", "停靠", "班距", "時段", "區間"].contains(where: text.contains),
              !text.contains("~"), !text.contains("～"), !text.contains("至") else { return [] }
        if text.range(of: "[0-9]:[0-9]{2}\\s*[-–—]\\s*[0-9]", options: .regularExpression) != nil { return [] }
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])([0-2]?[0-9]):([0-5][0-9])(?![0-9])") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let values = regex.matches(in: text, range: range).compactMap { result -> Int? in
            guard let hours = Range(result.range(at: 1), in: text), let minutes = Range(result.range(at: 2), in: text),
                  let h = Int(text[hours]), let m = Int(text[minutes]), h < 24 else { return nil }
            return h * 60 + m
        }
        return values.count >= 3 ? Array(Set(values)).sorted() : []
    }
}

public struct BusServicePlan: Sendable {
    public var weekday: BusDayService
    public var holiday: BusDayService
    public init(weekday: BusDayService = .init(), holiday: BusDayService = .init()) {
        self.weekday = weekday; self.holiday = holiday
    }
    public func service(at date: Date) -> BusDayService {
        TransitServiceCalendar.isHoliday(date) ? holiday : weekday
    }
}

public enum WaitingEvidence: String, Sendable { case official, timetable, headway, unknown }
public struct BoardingWait: Equatable, Sendable {
    public let seconds: Double
    public let lowerSeconds: Double
    public let upperSeconds: Double
    public let evidence: WaitingEvidence
    public let missedNext: Bool
    public var isEstimated: Bool { evidence == .headway || evidence == .unknown }
    public var label: String {
        if evidence == .unknown { return AppText.text("候車待確認") }
        let lower = max(1, Int(ceil(lowerSeconds / 60))), upper = max(lower, Int(ceil(upperSeconds / 60)))
        if seconds < 30 { return AppText.text("即將可搭") }
        return upper - lower >= 2 ? AppText.text("候車約 %@–%@ 分", lower, upper) : AppText.text("候車約 %@ 分", max(1, Int(ceil(seconds / 60))))
    }
}

public enum BoardingTime {
    /// Arrival is measured from query time; readyAt includes all preceding travel, not just the transfer walk.
    public static func wait(official: Int?, readyAt: Double, buffer: Double,
                            service: BusDayService? = nil, secondsOfDay: Double = 0,
                            boardingOffset: Double = 0, minimumServiceWait: Double = 0) -> BoardingWait {
        let ready = max(0, readyAt), safe = ready + max(0, buffer)
        if let arrival = official, arrival >= 0, Double(arrival) >= safe {
            let wait = max(0, Double(arrival) - ready)
            return BoardingWait(seconds: wait, lowerSeconds: wait, upperSeconds: wait, evidence: .official, missedNext: false)
        }
        let missed = official.map { $0 >= 0 && Double($0) < safe } ?? false
        if let service, !service.departures.isEmpty {
            let times = service.departures.map { Double($0 * 60) + boardingOffset - secondsOfDay }
            if let arrival = times.first(where: { $0 >= safe }) {
                let wait = arrival - ready
                return BoardingWait(seconds: wait, lowerSeconds: max(0, wait - 60), upperSeconds: wait + 120,
                    evidence: .timetable, missedNext: missed)
            }
        }
        let opening = max(0, minimumServiceWait - ready)
        if let headway = service?.headway {
            if official == nil || official! < 0 {
                let expected = max(buffer, opening, official == -1 ? headway.midpoint : headway.midpoint / 2)
                return BoardingWait(seconds: expected,
                    lowerSeconds: max(buffer, opening, official == -1 ? headway.lowerSeconds : 0),
                    upperSeconds: max(buffer, opening, headway.upperSeconds), evidence: .headway, missedNext: false)
            }
            let first: Double
            if let arrival = official, arrival >= 0 { first = Double(arrival) }
            else { first = ready + max(buffer, headway.midpoint / 2, opening) }
            let cycles = first < safe ? max(1, Int(ceil((safe - first) / headway.midpoint))) : 0
            let expected = max(0, first + Double(cycles) * headway.midpoint - ready)
            let lower = max(buffer, opening, expected - max(60, Double(max(1, cycles)) * (headway.upperSeconds - headway.lowerSeconds) / 2))
            let upper = max(lower, opening, expected + max(60, Double(max(1, cycles)) * (headway.upperSeconds - headway.lowerSeconds) / 2))
            return BoardingWait(seconds: max(expected, lower), lowerSeconds: lower, upperSeconds: upper, evidence: .headway, missedNext: missed)
        }
        // A conservative comparison cost, never a claimed actual departure or an exact arrival clock.
        let fallback = max(official == -1 ? 900 : 480, opening, buffer)
        return BoardingWait(seconds: fallback, lowerSeconds: max(buffer, opening, 300),
            upperSeconds: max(opening, fallback + 900), evidence: .unknown, missedNext: missed)
    }
}
