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
    /// Arrival bounds that also include ride-time variability; used only for arrival clocks.
    public let earliestTotalSeconds: Double
    public let latestTotalSeconds: Double
    public var positionUncertain = false
    /// Part of `walkingSeconds` that is spent riding a YouBike, including unlocking and docking.
    public var cyclingSeconds: Double = 0
    public var cyclingHandlingSeconds: Double = 0
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
        if latestTotalSeconds - earliestTotalSeconds >= 120 {
            return clock(referenceDate.addingTimeInterval(earliestTotalSeconds)) + "–" + clock(referenceDate.addingTimeInterval(latestTotalSeconds))
        }
        return clock(referenceDate.addingTimeInterval(totalSeconds))
    }
    public var ridingSourceLabel: String {
        RidingTimeEstimate(seconds: ridingSeconds, evidence: ridingEvidence, observedVehicles: 0).sourceLabel
    }
    public var breakdownLabel: String {
        if cyclingSeconds > 0 {
            let onFoot = max(0, walkingSeconds - cyclingSeconds)
            let riding = max(0, cyclingSeconds - cyclingHandlingSeconds)
            let breakdown = ridingSeconds <= 0
                ? AppText.text("步行 %@ 分 · 騎車 %@ 分", minutes(onFoot), minutes(riding))
                : AppText.text("步行 %@ 分 · 騎車 %@ 分 · 搭車 %@ 分", minutes(onFoot), minutes(riding), minutes(ridingSeconds))
            return cyclingHandlingSeconds > 0 ? breakdown + AppText.text(" · 取還車 %@ 分", minutes(cyclingHandlingSeconds)) : breakdown
        }
        return AppText.text("步行 %@ 分 · 搭車 %@ 分", minutes(walkingSeconds), minutes(ridingSeconds))
    }
    public var waitingLabel: String {
        if waits.isEmpty { return cyclingSeconds > 0 ? AppText.text("騎車即可") : AppText.text("步行即可") }
        if unknownWaits > 0 { return AppText.text(waits.dropFirst().contains(where: { $0.evidence == .unknown }) ? "轉乘候車待確認" : "候車待確認") }
        // Transfer waits can be correlated: arriving earlier means waiting longer
        // for the same reachable departure. Use the whole-journey bounds.
        let lower = max(0, lowerTotalSeconds - travelSeconds), upper = max(lower, upperTotalSeconds - travelSeconds)
        if upper < 30 { return AppText.text("即將可搭") }
        return minutes(upper) - minutes(lower) >= 2 ? AppText.text("候車約 %@–%@ 分", minutes(lower), minutes(upper)) : AppText.text("候車約 %@ 分", minutes(waitingSeconds))
    }
    /// The headline is door-to-door; this subtitle makes clear that waiting is already included.
    public var includedWaitingLabel: String {
        guard !waits.isEmpty, unknownWaits == 0 else { return waitingLabel }
        let lower = max(0, lowerTotalSeconds - travelSeconds), upper = max(lower, upperTotalSeconds - travelSeconds)
        if upper < 30 { return AppText.text("已含候車 · 即將可搭") }
        return minutes(upper) - minutes(lower) >= 2
            ? AppText.text("含候車約 %@–%@ 分", minutes(lower), minutes(upper))
            : AppText.text("含候車約 %@ 分", minutes(waitingSeconds))
    }
    public var missedNext: Bool { waits.first?.missedNext == true }
    public var arrivalLabel: String {
        if unknownWaits > 0 || positionUncertain { return AppText.text("抵達待確認") }
        if latestTotalSeconds - earliestTotalSeconds >= 120 {
            return AppText.text("約 %@–%@ 抵達", clock(referenceDate.addingTimeInterval(earliestTotalSeconds)), clock(referenceDate.addingTimeInterval(latestTotalSeconds)))
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
                services: [BusDayService?] = [], boardingOffsets: [Double] = [], ridingSpreads: [Double] = [],
                at date: Date = Date()) {
        let assessment = TripRanking.assess(riding: riding, walking: walking, arrivals: arrivals,
            minimumServiceWaits: minimumServiceWaits, services: services, boardingOffsets: boardingOffsets,
            ridingSpreads: ridingSpreads, at: date)
        self.init(assessment: assessment, riding: riding)
    }
    public init(assessment: TripAssessment, riding: [Double]) {
        walkingSeconds = assessment.walkingSeconds
        waitingSeconds = assessment.waitingSeconds
        ridingSeconds = riding.reduce(0) { $0 + max(0, $1) }
        uncertainWaits = assessment.uncertainWaits
        waits = assessment.waits; referenceDate = assessment.referenceDate
        lowerTotalSeconds = assessment.lowerSeconds; upperTotalSeconds = assessment.upperSeconds
        earliestTotalSeconds = assessment.earliestSeconds; latestTotalSeconds = assessment.latestSeconds
    }
}
