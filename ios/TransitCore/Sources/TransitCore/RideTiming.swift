import Foundation

/// How long a bus takes between two consecutive stops when no official station-to-station time applies.
/// New Taipei publishes none (TDX's S2STravelTime does not cover it), and a few Taipei routes have none.
///
/// Measured against buses' actual stop-to-stop times (GetBusEvent, morning peak of 2026-10-29, legs of five
/// stops), the median error was 13% in both cities for the arrival-estimate difference below, against 12%
/// for Taipei's official profiles; 40% in New Taipei and 26% in Taipei for the generic distance estimate,
/// which was 39% and 24% too slow.
public enum RideTiming {
    /// Whether this feed may stand for a departure at `date`: current, and not for a trip planned well ahead.
    public static func liveEstimates(_ estimates: EstimateFeed?, at date: Date) -> EstimateFeed? {
        guard let estimates, estimates.error == nil, let updated = estimates.updatedAt,
              (-60...600).contains(date.timeIntervalSince(updated)) else { return nil }
        return estimates
    }

    /// The difference of the official arrival estimates at two consecutive stops. Both belong to the next bus
    /// to reach them unless a bus is already between them, which shows as the later stop expecting a bus
    /// sooner; that leg, a status code or an implausible gap gives nil.
    public static func live(_ estimates: EstimateFeed, parentRouteID: String, from: String, to: String) -> Double? {
        guard let first = estimates.seconds[parentRouteID + ":" + from], let second = estimates.seconds[parentRouteID + ":" + to],
              first >= 0, second >= first, second - first <= 1_800 else { return nil }
        return Double(max(second - first, 10))
    }

    /// The distance estimate, at the pace measured for the route's city when the region names one.
    public static func estimate(meters: Double, route: BusRoute, tuning: ForecastTuning) -> Double {
        if let pace = RegionCatalog.shared.sources[route.source]?.ridePace {
            return meters / pace.metersPerSecond + pace.stopSeconds
        }
        return meters / tuning.typicalSpeed + tuning.stopSeconds
    }
}
