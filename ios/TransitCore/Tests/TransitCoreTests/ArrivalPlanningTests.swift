import XCTest
@testable import TransitCore

final class ArrivalPlanningTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-22T04:00:00Z")!
    private let deadline = ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z")!
    private func trip(published: Bool = true) -> TransitTrip {
        let a = Coordinate(latitude: 25.04, longitude: 121.52), b = Coordinate(latitude: 25.06, longitude: 121.52)
        var route = BusRoute(id: "test", parentID: "test", name: "test", variantName: "", departure: "A", destination: "B")
        if published {
            let service = BusDayService(window: BusServiceWindow(first: "0600", last: "2200"),
                headway: BusHeadway(lowerSeconds: 600, upperSeconds: 900))
            route.servicePlans = ["0": BusServicePlan(weekday: service, holiday: service)]
        }
        let stops = [BusStop(id: "a", routeID: "test", stationID: "a", name: "A", direction: "0", sequence: 1, coordinate: a),
                     BusStop(id: "b", routeID: "test", stationID: "b", name: "B", direction: "0", sequence: 2, coordinate: b)]
        let ride = TransitRide(route: route, direction: "0", stops: stops, coordinates: [a, b])
        return TransitTrip(rides: [ride], accessDistance: 100, egressDistance: 100, transferDistance: 0, score: 0, rideSeconds: [900])
    }
    func testFuturePlanUsesPublishedHeadwaysWithExplicitMargin() throws {
        let result = try XCTUnwrap(ArrivalPlanning.assess(trip(), metadata: .init(), arriveBy: deadline, walking: [120, 180], now: now))
        XCTAssertEqual(result.assessment.waits.first?.evidence, .headway)
        XCTAssertEqual(deadline.timeIntervalSince(result.latestArrival), 600, accuracy: 1)
        XCTAssertGreaterThan(result.departure, now)
        XCTAssertLessThanOrEqual(result.earliestArrival, result.latestArrival)
    }
    func testMissingServiceDataCannotInventFutureDeparture() {
        XCTAssertNil(ArrivalPlanning.assess(trip(published: false), metadata: .init(), arriveBy: deadline, walking: [120, 180], now: now))
    }
    func testInvalidWalksPastAndDistantDeadlinesAreRejected() {
        for walks in [[120.0], [Double.nan, 0], [-1, 20]] {
            XCTAssertNil(ArrivalPlanning.assess(trip(), metadata: .init(), arriveBy: deadline, walking: walks, now: now))
        }
        for date in [now, now.addingTimeInterval(-1), now.addingTimeInterval(91 * 86_400)] {
            XCTAssertNil(ArrivalPlanning.assess(trip(), metadata: .init(), arriveBy: date, walking: [120, 180], now: now))
        }
    }
    func testPreferenceDoesNotAlterDisplayedArrival() throws {
        let a = try XCTUnwrap(ArrivalPlanning.assess(trip(), metadata: .init(), arriveBy: deadline, walking: [120, 180], now: now))
        var preference = LiveSettings.Planning(); preference.walkingWeight = 2.8
        let b = try XCTUnwrap(ArrivalPlanning.assess(trip(), metadata: .init(), arriveBy: deadline, walking: [120, 180], preferences: preference, now: now))
        XCTAssertEqual(a.departure, b.departure)
        XCTAssertEqual(a.latestArrival, b.latestArrival)
        XCTAssertGreaterThan(b.assessment.score, a.assessment.score)
    }
}
