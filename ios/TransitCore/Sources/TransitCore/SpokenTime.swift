import Foundation

/// The time in a spoken trip request, read the way a person means it. 「明天早上」 is leaving at nine
/// tomorrow, 「三點去台大」 is being there by 15:00, 「週六下午三點出發」 is leaving that Saturday at 15:00.
/// The on-device model is not trusted with dates: it guessed days and mixed up departure and arrival.
public struct SpokenTime: Equatable, Sendable {
    public enum Kind: Sendable { case departure, arrival }
    public var date: Date
    public var kind: Kind
    /// A clock time was said. Without one, a usual hour for that part of the day is used.
    public var exact: Bool

    /// Usual hours when only a part of the day is said, most specific words first.
    private static let periods: [(words: [String], hour: Int, minute: Int, afternoon: Bool?)] = [
        (["凌晨"], 6, 0, false), (["清晨", "一大早", "一早"], 7, 0, false),
        (["早上", "上午", "早晨", "明早", "今早", "早餐"], 9, 0, false),
        (["中午", "午餐", "午飯"], 12, 0, nil), (["下午"], 14, 0, true), (["傍晚", "黃昏", "下班", "放學"], 17, 30, true),
        (["晚餐", "晚飯"], 18, 30, true), (["晚上", "今晚", "明晚", "晚間", "夜裡"], 19, 0, true), (["半夜", "深夜"], 22, 0, true),
    ]
    private static let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "兩": 2, "三": 3, "四": 4, "五": 5,
                                                   "六": 6, "七": 7, "八": 8, "九": 9]
    private static let deadlineWords = ["前", "抵達", "到達", "趕到", "趕上", "準時", "要到", "by "]
    private static let departureWords = ["出發", "離開", "動身", "點走", "分走", "半走", "leave", "depart"]

    public static func read(_ text: String, now: Date, calendar: Calendar = AssistantJourneyRequest.calendar) -> SpokenTime? {
        let value = (text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "zh_TW")))
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "：", with: ":")
        // 「一小時」 and 「三個鐘頭」 are durations, not clock times.
        // 「快一點」 asks for a faster trip; it is not one o'clock.
        let plain = ["前往", "目前", "前面", "以前的", "小時", "鐘頭", "分鐘"].reduce(value) { $0.replacingOccurrences(of: $1, with: "") }
            .replacingOccurrences(of: "(快|早|晚|慢|多|少|近|遠|簡單|輕鬆|方便|便宜)(一|1)點", with: "", options: .regularExpression)
        let offset = dayOffset(plain, now: now, calendar: calendar)
        let period = periods.first { $0.words.contains(where: plain.contains) }
        let clock = self.clock(plain)
        guard offset != nil || period != nil || clock != nil else { return nil }

        var hour: Int, minute: Int
        if let clock {
            (hour, minute) = clock
            switch period?.afternoon {
            case true?: if hour < 12 { hour += 12 }
            case false?: if hour == 12 { hour = 0 }
            case nil where period != nil: if (1...5).contains(hour) { hour += 12 }   // 中午一點
            default: if (1...6).contains(hour) { hour += 12 }   // 「三點去台大」 is in the afternoon
            }
        } else if let period {
            (hour, minute) = (period.hour, period.minute)
        } else {
            (hour, minute) = (9, 0)   // 「明天去台大」: a usual morning start
        }
        guard (0...24).contains(hour), (0...59).contains(minute) else { return nil }
        let today = calendar.startOfDay(for: now)
        guard var date = calendar.date(byAdding: .day, value: offset ?? 0, to: today)
            .flatMap({ calendar.date(byAdding: .minute, value: (hour * 60 + minute), to: $0) }) else { return nil }
        // No day said and the time has passed today: the next one.
        if offset == nil, date <= now, let next = calendar.date(byAdding: .day, value: 1, to: date) { date = next }
        guard date > now.addingTimeInterval(-300) else { return nil }

        let deadline = deadlineWords.contains(where: plain.contains)
        let kind: Kind
        if clock != nil { kind = !deadline && departureWords.contains(where: plain.contains) ? .departure : .arrival }
        else { kind = deadline ? .arrival : .departure }
        return SpokenTime(date: date, kind: kind, exact: clock != nil)
    }

    /// 今天 0, 明天 1, 後天 2, 大後天 3; 週六 the coming Saturday; 下週一 Monday of next week.
    static func dayOffset(_ text: String, now: Date, calendar: Calendar) -> Int? {
        for (words, days) in [(["大後天"], 3), (["後天"], 2), (["明天", "明早", "明晚", "明日"], 1), (["今天", "今晚", "今早", "今日"], 0)]
            where words.contains(where: text.contains) { return days }
        guard let match = text.range(of: "(下下|下個|下|這個|這|本)?(週|周|星期|禮拜|礼拜)([一二三四五六日天1-7])", options: .regularExpression) else { return nil }
        let phrase = String(text[match])
        let last = phrase.last!
        let target = last == "日" || last == "天" ? 7 : (digits[last] ?? Int(String(last)) ?? 0)
        guard (1...7).contains(target) else { return nil }
        let weekday = calendar.component(.weekday, from: now)   // Sunday 1 … Saturday 7
        let today = weekday == 1 ? 7 : weekday - 1             // Monday 1 … Sunday 7
        if phrase.hasPrefix("下下") { return (7 - today) + target + 7 }
        if phrase.hasPrefix("下") { return (7 - today) + target }
        return (target - today + 7) % 7
    }

    /// 3點, 三點半, 十點十五分, 3:30, 九點一刻.
    static func clock(_ text: String) -> (Int, Int)? {
        if let match = text.range(of: "([01]?[0-9]|2[0-4]):([0-5][0-9])", options: .regularExpression) {
            let parts = text[match].split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { return (parts[0], parts[1]) }
        }
        let number = "([0-9]{1,2}|[零〇一二兩三四五六七八九十]{1,3})"
        guard let match = text.range(of: number + "(點鐘|點|時)(半|一刻|三刻|" + number + "分?)?", options: .regularExpression) else { return nil }
        let phrase = String(text[match])
        guard let unit = phrase.range(of: "(點鐘|點|時)", options: .regularExpression),
              let hour = value(String(phrase[..<unit.lowerBound])) else { return nil }
        let rest = String(phrase[unit.upperBound...]).replacingOccurrences(of: "分", with: "")
        let minute: Int
        switch rest {
        case "": minute = 0
        case "半": minute = 30
        case "一刻": minute = 15
        case "三刻": minute = 45
        default: minute = value(rest) ?? 0
        }
        return hour <= 24 && minute < 60 ? (hour, minute) : nil
    }

    private static func value(_ text: String) -> Int? {
        if let number = Int(text) { return number }
        return StationSearch.chineseNumber(text)
    }
}
