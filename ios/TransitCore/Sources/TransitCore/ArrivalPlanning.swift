import Foundation

/// Future journeys use the planner's timetable/headway and historical-profile
/// estimates only. This type cannot accept a live vehicle snapshot or model ETA.
public struct ArrivalPlan: Sendable {
    public let departure: Date
    public let assessment: TripAssessment
    public var earliestArrival: Date { departure.addingTimeInterval(assessment.earliestSeconds) }
    public var latestArrival: Date { departure.addingTimeInterval(assessment.latestSeconds) }
}

public enum ArrivalPlanning {
    private static func usable(_ trip: TransitTrip, walking: [Double]) -> Bool {
        !trip.rides.isEmpty && trip.bikeConnections.isEmpty && walking.count == trip.rides.count + 1 &&
            trip.rideSeconds.count == trip.rides.count && trip.rideSeconds.allSatisfy({ $0.isFinite && $0 >= 0 }) &&
            walking.allSatisfy({ $0.isFinite && $0 >= 0 })
    }
    /// Timetable and headway timing for leaving at `departure`, or nil when service is unknown or ended.
    private static func timing(_ trip: TransitTrip, metadata: TransitMetadata, at departure: Date, walking: [Double],
                               preferences: LiveSettings.Planning) -> TripAssessment? {
        // Do not carry today's rail headway into a future service period.
        var rides = trip.rides, cursor = 0.0
        for index in rides.indices {
            cursor += walking[index]
            if rides[index].route.mode != .bus {
                rides[index].railService = metadata.metro.combinedService(routeID: rides[index].route.id,
                    direction: rides[index].direction, from: rides[index].boarding.stationID,
                    to: rides[index].alighting.stationID, at: departure.addingTimeInterval(cursor))
            }
            let timing = TripRanking.assessment(trip.replacingRides(rides), estimates: .init(), at: departure,
                preferences: preferences, walkingDurations: walking.map(Optional.some))
            cursor += timing.waits[index].seconds + trip.rideSeconds[index]
        }
        let assessment = TripRanking.assessment(trip.replacingRides(rides), estimates: EstimateFeed(), at: departure,
            preferences: preferences, walkingDurations: walking.map(Optional.some))
        guard !assessment.unavailable, assessment.unknownWaits == 0,
              assessment.latestSeconds.isFinite, assessment.latestSeconds > 0,
              assessment.latestSeconds < 12 * 3600 else { return nil }
        // Live planning deliberately keeps late buses visible. A future query
        // has no observed bus, so headways alone must not imply overnight service.
        var upper = 0.0
        for index in rides.indices {
            upper += walking[index] + assessment.waits[index].upperSeconds
            let ride = rides[index]
            let service = ride.railService ?? ride.route.servicePlans[ride.direction]?.service(at: departure)
            if assessment.waits[index].evidence != .timetable {
                guard let window = service?.window else { return nil }
                var first = Double(window.firstMinute * 60), last = Double(window.lastMinute * 60)
                let boarding = BusServiceWindow.secondsOfDay(at: departure) + upper - ride.boardingOffsetSeconds
                if first > last {
                    if boarding <= last { first -= 86_400 } else { last += 86_400 }
                }
                guard boarding >= first, boarding <= last else { return nil }
            }
            upper += trip.rideSeconds[index]
        }
        return assessment
    }

    /// Leave a visible ten-minute margin beyond the planner's upper estimate.
    /// Unknown waiting times cannot produce a reassuring departure clock.
    public static func assess(_ trip: TransitTrip, metadata: TransitMetadata, arriveBy: Date, walking: [Double],
                              preferences: LiveSettings.Planning = .init(), now: Date = Date()) -> ArrivalPlan? {
        guard arriveBy > now, arriveBy.timeIntervalSince(now) <= 90 * 86_400, usable(trip, walking: walking) else { return nil }
        // Search backwards at minute resolution. Fixed timetable departures make
        // waiting time discontinuous, so a fixed-point ETA subtraction can diverge.
        let latest = arriveBy.addingTimeInterval(-walking.reduce(0, +) - trip.rideSeconds.reduce(0, +) - 600)
        let rounded = Date(timeIntervalSince1970: floor(latest.timeIntervalSince1970 / 60) * 60)
        for minute in 0..<360 {
            guard !Task.isCancelled else { return nil }
            let departure = rounded.addingTimeInterval(Double(-minute) * 60)
            guard departure > now, AssistantJourneyRequest.calendar.isDate(departure, inSameDayAs: arriveBy) else { break }
            if let result = timing(trip, metadata: metadata, at: departure, walking: walking, preferences: preferences),
               departure.addingTimeInterval(result.latestSeconds + 600) <= arriveBy {
                return ArrivalPlan(departure: departure, assessment: result)
            }
        }
        return nil
    }

    /// The same timetable estimate for leaving at a chosen time, e.g. 「明天下午三點去台大」.
    public static func depart(_ trip: TransitTrip, metadata: TransitMetadata, at departure: Date, walking: [Double],
                              preferences: LiveSettings.Planning = .init(), now: Date = Date()) -> ArrivalPlan? {
        guard departure > now.addingTimeInterval(-300), departure.timeIntervalSince(now) <= 90 * 86_400,
              usable(trip, walking: walking),
              let result = timing(trip, metadata: metadata, at: departure, walking: walking, preferences: preferences) else { return nil }
        return ArrivalPlan(departure: departure, assessment: result)
    }
}
