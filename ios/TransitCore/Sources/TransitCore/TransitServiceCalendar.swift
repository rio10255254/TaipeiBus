import Foundation

/// Office-calendar exceptions from DGPA's published 2026/2027 CSV. Individual bus exceptions still use official arrivals.
/// Source: https://data.gov.tw/dataset/14718 (retrieved 2026-10-04).
public enum TransitServiceCalendar {
    private final class DayCache: @unchecked Sendable {
        let lock = NSLock()
        var values: [Int: Bool] = [:]
    }
    private static let cache = DayCache()
    private static let zone = TimeZone(identifier: "Asia/Taipei")!
    private static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value
    }()
    private static let holidays: Set<String> = ["20260101","20260216","20260217","20260218","20260219","20260220","20260227","20260403","20260406","20260501","20260619","20260925","20260928","20261009","20261026","20261225","20270101","20270204","20270205","20270208","20270209","20270210","20270301","20270405","20270406","20270430","20270609","20270915","20270928","20271011","20271025","20271224","20271231"]
    private static let workingWeekends: Set<String> = []
    public static func isHoliday(_ date: Date) -> Bool {
        // Thousands of boarding/transfer labels ask about the same one or two
        // service days. Reuse that answer without rounding the departure time.
        let day = Int(floor((date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for:date)))/86_400))
        cache.lock.lock(); defer { cache.lock.unlock() }
        if let value = cache.values[day] { return value }
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let key = String(format: "%04d%02d%02d", parts.year!, parts.month!, parts.day!)
        let result = holidays.contains(key) || (!workingWeekends.contains(key) && [1,7].contains(parts.weekday!))
        if cache.values.count >= 64 { cache.values.removeAll(keepingCapacity:true) }
        cache.values[day] = result
        return result
    }
}
