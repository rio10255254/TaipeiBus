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
    /// Leave a visible ten-minute margin beyond the planner's upper estimate.
    /// Unknown waiting times cannot produce a reassuring departure clock.
    public static func assess(_ trip: TransitTrip, metadata: TransitMetadata, arriveBy: Date, walking: [Double],
                              preferences: LiveSettings.Planning = .init(), now: Date = Date()) -> ArrivalPlan? {
        guard arriveBy > now, arriveBy.timeIntervalSince(now) <= 90 * 86_400, !trip.rides.isEmpty,
              trip.bikeConnections.isEmpty,
              walking.count == trip.rides.count + 1,
              walking.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        var departure = arriveBy.addingTimeInterval(-3600)
        var result: TripAssessment?
        for _ in 0..<8 {
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
            // Cross-midnight service-day changes need a separate timetable solver.
            guard AssistantJourneyRequest.calendar.isDate(departure, inSameDayAs: arriveBy) else { return nil }
            let assessment = TripRanking.assessment(trip.replacingRides(rides), estimates: EstimateFeed(), at: departure,
                preferences: preferences, walkingDurations: walking.map(Optional.some))
            guard !assessment.unavailable, assessment.unknownWaits == 0,
                  assessment.latestSeconds.isFinite, assessment.latestSeconds > 0,
                  assessment.latestSeconds < 12 * 3600 else { return nil }
            let next = arriveBy.addingTimeInterval(-assessment.latestSeconds - 600)
            if abs(next.timeIntervalSince(departure)) < 1 { result = assessment; break }
            departure = next
        }
        guard let result, departure > now,
              departure.addingTimeInterval(result.latestSeconds + 599) <= arriveBy else { return nil }
        return ArrivalPlan(departure: departure, assessment: result)
    }
}
