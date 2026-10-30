import Foundation

/// How long a bus takes from one stop to the next: the one rule behind the stop countdown, trip planning,
/// planned ride times and the remaining time on board. Callers differ only in the evidence they hold (a
/// countdown knows its bus's own pace, a planner does not); which evidence wins, how it is scaled and how
/// sure it is are decided here, so a tuning change or a new source reaches every screen at once.
///
/// Evidence, first that applies:
/// 1. Crossings: three or more buses timed on this segment in the last 20 minutes; their median.
/// 2. The official station-to-station profile for the hour, scaled by the hourly pace factor and refined by
///    one or two recent crossings (ForecastTuning.officialProfileWeight).
/// 3. Official arrival estimates: for a trip leaving now, the difference of the next bus's estimates at the
///    two stops. New Taipei publishes no station-to-station times (TDX's S2STravelTime does not cover it).
/// 4. A pace: this bus's own recent pace (countdown), the route's recent traffic (rides), else the city's
///    measured pace (regions.json `ridePace`) or ForecastTuning's typical speed, scaled by the hour's
///    city pace factor (buses run far faster than the all-day pace at night, slower in the peaks).
///
/// Measured against buses' actual stop-to-stop times (GetBusEvent, morning peak of 2026-10-29, legs of five
/// stops, the planner's own distances), the median error was 13% in both cities for the arrival-estimate
/// difference, against 12% for Taipei's official profiles. The generic 4.5 m/s + 20 s estimate was 27% off in
/// New Taipei (24% too slow); New Taipei's best pace, 6.2 m/s + 25 s (21%), is the 6.25 m/s + 25 s that two
/// weeks of Taipei recordings fit (tools/arrival-benchmark/fortnight-2026-10.md).
public enum TravelTimeModel {
    public enum Source: String, Sendable { case crossings, officialProfile, officialEstimates, vehiclePace, fleetPace, cityPace }
    public struct Segment: Sendable, Equatable {
        public let seconds: Double
        /// One standard deviation, in seconds.
        public let margin: Double
        public let source: Source
    }
    /// The pace used when no time for the segment is known.
    public enum Pace: Sendable {
        /// This bus's own recent pace; a bus that has not been moving also pays the stop allowance.
        case vehicle(metersPerSecond: Double, variation: Double, moving: Bool)
        /// The route's recent traffic, which already includes signals and dwell.
        case fleet(metersPerSecond: Double)
        /// Nothing observed: the city's measured pace.
        case city
        /// No pace may be assumed; the segment has no time.
        case none
    }

    /// One segment, or the remaining `fraction` of it.
    /// - Parameters:
    ///   - meters: the distance left on the segment.
    ///   - crossings: recent crossing times of this segment, and how many distinct buses made them.
    ///   - official: the official profile's seconds for the whole segment at the travelling time, asked only if needed.
    ///   - estimates: the official arrival estimates' difference for the whole segment, asked only if needed.
    ///   - correction: the session's measured correction for pace-based times (ArrivalTimingFeedback).
    public static func segment(route: BusRoute, meters: Double, fraction: Double = 1,
                               crossings: (seconds: [Double], vehicles: Int) = ([], 0),
                               official: () -> Double? = { nil }, estimates: () -> Double? = { nil },
                               pace: Pace, travellingAt: Date, correction: Double = 1,
                               tuning: ForecastTuning = .current) -> Segment? {
        if crossings.vehicles >= 3 {
            let typical = median(crossings.seconds)
            return Segment(seconds: typical * fraction,
                           margin: max(12, median(crossings.seconds.map { abs($0 - typical) }) * 1.5) * fraction, source: .crossings)
        }
        if let profile = official() {
            // The profile runs short in busy hours, so it is first scaled by the measured pace factor; one or
            // two recent crossings refine it as if it were worth officialProfileWeight observations.
            let scaled = profile * tuning.paceFactor(at: travellingAt), weight = tuning.officialProfileWeight
            let typical = crossings.vehicles == 0 ? scaled :
                (median(crossings.seconds) * Double(crossings.vehicles) + scaled * weight) / (Double(crossings.vehicles) + weight)
            return Segment(seconds: typical * fraction, margin: max(12, typical * tuning.officialSegmentMargin) * fraction,
                           source: .officialProfile)
        }
        if let current = estimates() {
            return Segment(seconds: current * fraction, margin: max(12, current * tuning.officialSegmentMargin) * fraction,
                           source: .officialEstimates)
        }
        switch pace {
        case .vehicle(let speed, let variation, let moving):
            // The pace factor applies before the session feedback, which learns only what remains after it.
            let seconds = (meters / speed + (moving ? 0 : tuning.stopSeconds * fraction)) * tuning.paceFactor(at: travellingAt) * correction
            return Segment(seconds: seconds, margin: max(12, seconds * variation), source: .vehiclePace)
        case .fleet(let speed):
            let seconds = meters / speed
            return Segment(seconds: seconds, margin: max(12, seconds * 0.3), source: .fleetPace)
        case .city:
            let seconds = cityPace(meters: meters, fraction: fraction, route: route, tuning: tuning)
                * tuning.cityPaceFactor(at: travellingAt) * correction
            return Segment(seconds: seconds, margin: max(12, seconds * tuning.typicalSpread), source: .cityPace)
        case .none:
            return nil
        }
    }

    /// A segment's road distance: along the route line where both stops are placed on it, else the
    /// straight line with a quarter added for the streets in between.
    public static func meters(from: BusStop, to: BusStop, along: [String: Double]) -> Double {
        if let start = along[from.id], let end = along[to.id] { return abs(end - start) }
        return from.coordinate.distance(to: to.coordinate) * 1.25
    }

    /// The distance at the pace measured for the route's city when the region names one.
    public static func cityPace(meters: Double, fraction: Double = 1, route: BusRoute, tuning: ForecastTuning = .current) -> Double {
        if let pace = RegionCatalog.shared.sources[route.source]?.ridePace {
            return meters / pace.metersPerSecond + pace.stopSeconds * fraction
        }
        return meters / tuning.typicalSpeed + tuning.stopSeconds * fraction
    }

    /// The feed, if it may stand for a departure at `date`: current, and not for a trip planned well ahead.
    public static func liveEstimates(_ estimates: EstimateFeed?, at date: Date) -> EstimateFeed? {
        guard let estimates, estimates.error == nil, let updated = estimates.updatedAt,
              (-60...600).contains(date.timeIntervalSince(updated)) else { return nil }
        return estimates
    }

    /// The difference of the official arrival estimates at two consecutive stops. Both belong to the next bus
    /// to reach them unless a bus is already between them, which shows as the later stop expecting a bus
    /// sooner; that leg, a status code or an implausible gap gives nil.
    public static func estimated(_ estimates: EstimateFeed, parentRouteID: String, from: String, to: String) -> Double? {
        guard let first = estimates.seconds[parentRouteID + ":" + from], let second = estimates.seconds[parentRouteID + ":" + to],
              first >= 0, second >= first, second - first <= 1_800 else { return nil }
        return Double(max(second - first, 10))
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(), middle = sorted.count / 2
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
