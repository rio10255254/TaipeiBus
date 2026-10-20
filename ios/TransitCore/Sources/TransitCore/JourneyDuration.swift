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
    /// Position is estimated, but a known ride duration may still support an
    /// approximate arrival clock. Unknown departures remain a separate guard.
    public var positionUncertain = false
    /// Part of `walkingSeconds` that is spent riding a YouBike, including unlocking and docking.
    public var cyclingSeconds: Double = 0
    public var cyclingHandlingSeconds: Double = 0
    /// Already included in walkingSeconds; never added to the journey a second time.
    public var stationSeconds: Double = 0
    public var ridingEvidence: RidingTimeEstimate.Evidence = .typical
    public struct Component: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable { case walking, station, waiting, transit, cycling, handling }
        public let kind: Kind
        public let seconds: Double
        public var id: Kind { kind }
        public var title: String {
            switch kind {
            case .walking: return AppText.text("步行")
            case .station: return AppText.text("進出站與轉乘")
            case .waiting: return AppText.text("候車")
            case .transit: return AppText.text("搭車")
            case .cycling: return AppText.text("騎車")
            case .handling: return AppText.text("取還車")
            }
        }
        public var durationLabel: String { AppText.text("約 %@ 分鐘", max(1, Int(ceil(seconds / 60)))) }
    }
    /// A partition of the elapsed time, including bike handling and indoor access exactly once.
    public var components: [Component] {
        let cycling = min(walkingSeconds, max(0, cyclingSeconds))
        let handling = min(cycling, max(0, cyclingHandlingSeconds))
        let station = min(max(0, walkingSeconds - cycling), max(0, stationSeconds))
        return [Component(kind: .walking, seconds: max(0, walkingSeconds - cycling - station)),
                Component(kind: .station, seconds: station), Component(kind: .waiting, seconds: waitingSeconds),
                Component(kind: .transit, seconds: ridingSeconds), Component(kind: .cycling, seconds: cycling - handling),
                Component(kind: .handling, seconds: handling)].filter { $0.seconds > 0 }
    }
    public func timeZoneNote(in timeZone: TimeZone = .current) -> String? {
        guard let taipei = TimeZone(identifier: "Asia/Taipei"),
              timeZone.secondsFromGMT(for: referenceDate) != taipei.secondsFromGMT(for: referenceDate) else { return nil }
        return AppText.text("台北時間")
    }
    /// All preview surfaces share the same departure instant rather than creating their own clocks.
    public static func previewDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 15) * 15)
    }
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
        if unknownWaits > 0 { return AppText.text("抵達待確認") }
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
        if unknownWaits > 0 { return AppText.text("抵達待確認") }
        if latestTotalSeconds - earliestTotalSeconds >= 120 {
            return AppText.text("約 %@–%@ 抵達", clock(referenceDate.addingTimeInterval(earliestTotalSeconds)), clock(referenceDate.addingTimeInterval(latestTotalSeconds)))
        }
        return AppText.text("約 %@ 抵達", clock(referenceDate.addingTimeInterval(totalSeconds)))
    }
    /// The central estimate is the first thing to read; detailed bounds remain
    /// available in the journey's timing explanation.
    public var expectedArrivalLabel: String {
        if unknownWaits > 0 { return arrivalLabel }
        return AppText.text("約 %@ 抵達", clock(referenceDate.addingTimeInterval(totalSeconds)))
    }
    public var expectedWaitingLabel: String {
        guard !waits.isEmpty, unknownWaits == 0 else { return waitingLabel }
        return waitingSeconds < 30 ? AppText.text("已含候車 · 即將可搭") : AppText.text("含候車約 %@ 分", minutes(waitingSeconds))
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
                at date: Date = Date(), boardingBuffers: [Double] = [], departures: [[BoardingDeparture]] = []) {
        let assessment = TripRanking.assess(riding: riding, walking: walking, arrivals: arrivals,
            minimumServiceWaits: minimumServiceWaits, services: services, boardingOffsets: boardingOffsets,
            ridingSpreads: ridingSpreads, at: date, boardingBuffers: boardingBuffers, departures: departures)
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
