import Foundation

public struct BusServiceWindow: Sendable {
    public let firstMinute: Int
    public let lastMinute: Int
    public init?(first: String, last: String) {
        func minutes(_ text: String) -> Int? {
            let digits = text.filter(\.isNumber)
            guard digits.count == 4, let hour = Int(digits.prefix(2)), let minute = Int(digits.suffix(2)),
                  (0...24).contains(hour), (0..<60).contains(minute), hour < 24 || minute == 0 else { return nil }
            return hour * 60 + minute
        }
        guard let first = minutes(first), let last = minutes(last) else { return nil }
        firstMinute = first; lastMinute = last
    }
    public static func secondsOfDay(at date: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(parts.hour ?? 0)
        let minute = Double(parts.minute ?? 0)
        let second = Double(parts.second ?? 0)
        return hour * 3_600 + minute * 60 + second
    }
    /// Only a lower bound before the first departure. It never declares a route
    /// closed after its last terminal departure, when buses may still be on the road.
    public func waitBeforeOpening(secondsOfDay time: Double, fullRouteSeconds: Double) -> Double {
        let first = Double(firstMinute * 60), last = Double(lastMinute * 60)
        guard first != last else { return 0 }
        if first > last, time <= last + fullRouteSeconds { return 0 }
        if first < last, time <= last + fullRouteSeconds - 86_400 { return 0 }
        return time < first ? first - time : 0
    }
}

extension BusRoute {
    public func minimumServiceWait(direction: String, secondsOfDay: Double, fullRouteSeconds: Double) -> Double {
        // Consider the earliest published weekday/holiday window. Holiday calendars
        // are not available here, so a calendar guess must not hide a valid service.
        serviceWindows[direction]?.map { $0.waitBeforeOpening(secondsOfDay: secondsOfDay, fullRouteSeconds: fullRouteSeconds) }.min() ?? 0
    }
}
