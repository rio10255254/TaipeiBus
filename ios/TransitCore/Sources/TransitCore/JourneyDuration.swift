import Foundation

/// Elapsed travel time is independent of preference penalties used to order alternatives.
public struct JourneyDuration: Equatable, Sendable {
    public let walkingSeconds: Double
    public let waitingSeconds: Double
    public let ridingSeconds: Double
    public let uncertainWaits: Int
    public let waits: [BoardingWait]
    public let referenceDate: Date
    public let lowerTotalSeconds: Double
    public let upperTotalSeconds: Double
    public var positionUncertain = false
    public var unknownWaits: Int { waits.filter { $0.evidence == .unknown }.count }
    public var travelSeconds: Double { walkingSeconds + ridingSeconds }
    public var totalSeconds: Double { walkingSeconds + waitingSeconds + ridingSeconds }
    public var label: String {
        unknownWaits > 0 ? "行程約 \(minutes(travelSeconds)) 分" : "全程約 \(minutes(totalSeconds)) 分"
    }
    public var comparisonLabel: String { unknownWaits > 0 ? "全程待確認" : label }
    public var breakdownLabel: String { "步行 \(minutes(walkingSeconds)) 分 · 搭車 \(minutes(ridingSeconds)) 分" }
    public var waitingLabel: String {
        if waits.isEmpty { return "步行即可" }
        if unknownWaits > 0 { return waits.dropFirst().contains(where: { $0.evidence == .unknown }) ? "轉乘候車待確認" : "候車待確認" }
        let lower = waits.reduce(0) { $0 + $1.lowerSeconds }, upper = waits.reduce(0) { $0 + $1.upperSeconds }
        if upper < 30 { return "即將可搭" }
        return minutes(upper) - minutes(lower) >= 2 ? "候車約 \(minutes(lower))–\(minutes(upper)) 分" : "候車約 \(minutes(waitingSeconds)) 分"
    }
    public var missedNext: Bool { waits.first?.missedNext == true }
    public var arrivalLabel: String {
        if unknownWaits > 0 || positionUncertain { return "抵達待確認" }
        if upperTotalSeconds - lowerTotalSeconds >= 120 {
            return "約 \(clock(referenceDate.addingTimeInterval(lowerTotalSeconds)))–\(clock(referenceDate.addingTimeInterval(upperTotalSeconds))) 抵達"
        }
        return "約 \(clock(referenceDate.addingTimeInterval(totalSeconds))) 抵達"
    }
    private func minutes(_ seconds: Double) -> Int { max(seconds > 0 ? 1 : 0, Int(ceil(max(0, seconds) / 60))) }
    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_TW"); formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = formatter.timeZone!
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: referenceDate) ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: date)
    }

    public init(riding: [Double], walking: [Double], arrivals: [Int?], minimumServiceWaits: [Double] = [],
                services: [BusDayService?] = [], boardingOffsets: [Double] = [], at date: Date = Date()) {
        let assessment = TripRanking.assess(riding: riding, walking: walking, arrivals: arrivals,
            minimumServiceWaits: minimumServiceWaits, services: services, boardingOffsets: boardingOffsets, at: date)
        self.init(assessment: assessment, riding: riding)
    }
    public init(assessment: TripAssessment, riding: [Double]) {
        walkingSeconds = assessment.walkingSeconds
        waitingSeconds = assessment.waitingSeconds
        ridingSeconds = riding.reduce(0) { $0 + max(0, $1) }
        uncertainWaits = assessment.uncertainWaits
        waits = assessment.waits; referenceDate = assessment.referenceDate
        lowerTotalSeconds = assessment.lowerSeconds; upperTotalSeconds = assessment.upperSeconds
    }
}
