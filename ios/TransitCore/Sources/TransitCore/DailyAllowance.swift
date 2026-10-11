import Foundation

/// Free uses of a Pro feature per Taipei calendar day. Using the same thing again the same day
/// (following the same bus twice, reopening live trains) does not cost another use.
public struct DailyAllowance: Codable, Equatable, Sendable {
    public static let dailyLimit = 3
    public private(set) var day: String
    public private(set) var used: [String]

    public init() { day = ""; used = [] }

    public static func dayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    private func current(_ date: Date) -> [String] { day == Self.dayKey(date) ? used : [] }

    public func remaining(at date: Date) -> Int { max(0, Self.dailyLimit - current(date).count) }
    public func allows(_ id: String, at date: Date) -> Bool {
        current(date).contains(id) || remaining(at: date) > 0
    }
    /// Records a use and returns whether it was allowed.
    @discardableResult
    public mutating func use(_ id: String, at date: Date) -> Bool {
        let today = Self.dayKey(date)
        if day != today { day = today; used = [] }
        if used.contains(id) { return true }
        guard used.count < Self.dailyLimit else { return false }
        used.append(id)
        return true
    }
}
