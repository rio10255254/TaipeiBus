import Foundation

/// Elapsed travel time is independent of preference penalties used to order alternatives.
public struct JourneyDuration: Equatable, Sendable {
    public let walkingSeconds: Double
    public let waitingSeconds: Double
    public let ridingSeconds: Double
    public let uncertainWaits: Int
    public var totalSeconds: Double { walkingSeconds + waitingSeconds + ridingSeconds }
    public var label: String { "全程約 \(max(1, Int(ceil(totalSeconds / 60)))) 分" }

    public init(riding: [Double], walking: [Double], arrivals: [Int?], minimumServiceWaits: [Double] = []) {
        let assessment = TripRanking.assess(riding: riding, walking: walking, arrivals: arrivals,
                                           minimumServiceWaits: minimumServiceWaits)
        walkingSeconds = assessment.walkingSeconds
        waitingSeconds = assessment.waitingSeconds
        ridingSeconds = riding.reduce(0) { $0 + max(0, $1) }
        uncertainWaits = assessment.uncertainWaits
    }
}
