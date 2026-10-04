import Foundation

/// Office-calendar exceptions from DGPA's published 2026/2027 CSV. Individual bus exceptions still use official arrivals.
/// Source: https://data.gov.tw/dataset/14718 (retrieved 2026-10-04).
public enum TransitServiceCalendar {
    private static let holidays: Set<String> = ["20260101","20260216","20260217","20260218","20260219","20260220","20260227","20260403","20260406","20260501","20260619","20260925","20260928","20261009","20261026","20261225","20270101","20270204","20270205","20270208","20270209","20270210","20270301","20270405","20270406","20270430","20270609","20270915","20270928","20271011","20271025","20271224","20271231"]
    private static let workingWeekends: Set<String> = []
    public static func isHoliday(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let key = String(format: "%04d%02d%02d", parts.year!, parts.month!, parts.day!)
        if holidays.contains(key) { return true }
        if workingWeekends.contains(key) { return false }
        return [1, 7].contains(parts.weekday!)
    }
}
