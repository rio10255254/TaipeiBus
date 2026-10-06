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
    public var ridingEvidence: RidingTimeEstimate.Evidence = .typical
    public var unknownWaits: Int { waits.filter { $0.evidence == .unknown }.count }
    public var travelSeconds: Double { walkingSeconds + ridingSeconds }
    public var totalSeconds: Double { walkingSeconds + waitingSeconds + ridingSeconds }
    public var label: String {
        summaryLabel()
    }
    public func summaryLabel(remaining: Bool = false) -> String {
        let key = unknownWaits > 0 ? (remaining ? "剩餘行程約 %@ 分" : "行程約 %@ 分") : (remaining ? "剩餘約 %@ 分" : "全程約 %@ 分")
        return AppText.text(key, minutes(unknownWaits > 0 ? travelSeconds : totalSeconds))
    }
    public var comparisonLabel: String { unknownWaits > 0 ? AppText.text("全程待確認") : label }
    public var conciseLabel: String {
        unknownWaits > 0 ? AppText.text("時間待確認") : AppText.text("約 %@ 分鐘", minutes(totalSeconds))
    }
    public var arrivalClockLabel: String {
        if unknownWaits > 0 || positionUncertain { return AppText.text("抵達待確認") }
        if upperTotalSeconds - lowerTotalSeconds >= 120 {
            return clock(referenceDate.addingTimeInterval(lowerTotalSeconds)) + "–" + clock(referenceDate.addingTimeInterval(upperTotalSeconds))
        }
        return clock(referenceDate.addingTimeInterval(totalSeconds))
    }
    public var ridingSourceLabel: String {
        RidingTimeEstimate(seconds: ridingSeconds, evidence: ridingEvidence, observedVehicles: 0).sourceLabel
    }
    public var breakdownLabel: String { AppText.text("步行 %@ 分 · 搭車 %@ 分", minutes(walkingSeconds), minutes(ridingSeconds)) }
    public var waitingLabel: String {
        if waits.isEmpty { return AppText.text("步行即可") }
        if unknownWaits > 0 { return AppText.text(waits.dropFirst().contains(where: { $0.evidence == .unknown }) ? "轉乘候車待確認" : "候車待確認") }
        // Transfer waits can be correlated: arriving earlier means waiting longer
        // for the same reachable departure. Use the whole-journey bounds.
        let lower = max(0, lowerTotalSeconds - travelSeconds), upper = max(lower, upperTotalSeconds - travelSeconds)
        if upper < 30 { return AppText.text("即將可搭") }
        return minutes(upper) - minutes(lower) >= 2 ? AppText.text("候車約 %@–%@ 分", minutes(lower), minutes(upper)) : AppText.text("候車約 %@ 分", minutes(waitingSeconds))
    }
    public var missedNext: Bool { waits.first?.missedNext == true }
    public var arrivalLabel: String {
        if unknownWaits > 0 || positionUncertain { return AppText.text("抵達待確認") }
        if upperTotalSeconds - lowerTotalSeconds >= 120 {
            return AppText.text("約 %@–%@ 抵達", clock(referenceDate.addingTimeInterval(lowerTotalSeconds)), clock(referenceDate.addingTimeInterval(upperTotalSeconds)))
        }
        return AppText.text("約 %@ 抵達", clock(referenceDate.addingTimeInterval(totalSeconds)))
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
