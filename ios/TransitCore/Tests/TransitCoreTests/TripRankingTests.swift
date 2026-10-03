import XCTest
@testable import TransitCore

final class TripRankingTests: XCTestCase {
    func testNightServiceDoesNotLookLikeAnEightMinuteWaitInTheAfternoon() throws {
        let window = try XCTUnwrap(BusServiceWindow(first: "2100", last: "0100"))
        let wait = window.waitBeforeOpening(secondsOfDay: 14 * 3_600, fullRouteSeconds: 3_600)
        XCTAssertEqual(wait, 7 * 3_600)
        let pending = TripRanking.assess(riding: [300], walking: [0, 0], arrivals: [-1], minimumServiceWaits: [wait])
        XCTAssertEqual(pending.waitingSeconds, wait)
        let reportedBus = TripRanking.assess(riding: [300], walking: [0, 0], arrivals: [120], minimumServiceWaits: [wait])
        XCTAssertEqual(reportedBus.waitingSeconds, 120, "A live arriving bus overrides an outdated service window")
    }
    func testOvernightLastBusAndMissingWindowsArePreserved() throws {
        let night = try XCTUnwrap(BusServiceWindow(first: "2100", last: "0100"))
        XCTAssertEqual(night.waitBeforeOpening(secondsOfDay: 30 * 60, fullRouteSeconds: 3_600), 0)
        let daytime = try XCTUnwrap(BusServiceWindow(first: "0530", last: "2330"))
        XCTAssertEqual(daytime.waitBeforeOpening(secondsOfDay: 30 * 60, fullRouteSeconds: 7_200), 0)
        XCTAssertNil(BusServiceWindow(first: "", last: "2330"))
        XCTAssertNil(BusServiceWindow(first: "9900", last: "2330"))
    }
    func testRouteKeypadShortNamesMatchTheOfficialCommuterName() {
        let catalog = RouteCatalog(routes: [
            BusRoute(id: "12", parentID: "12", name: "內科通勤專車12", variantName: "", departure: "甲", destination: "乙"),
            BusRoute(id: "2", parentID: "2", name: "內科通勤專車2", variantName: "", departure: "甲", destination: "乙")
        ])
        XCTAssertEqual(catalog.search("內科2").first?.route.id, "2")
        XCTAssertEqual(catalog.search("內科12").first?.route.id, "12")
        XCTAssertEqual(catalog.search("通勤").count, 2)
    }
    func testNearbyTimesFavorDirectOverAnExtraConnection() {
        let direct = TripRanking.assess(riding: [1_200], walking: [60, 60], arrivals: [300])
        let transfer = TripRanking.assess(riding: [450, 450], walking: [60, 90, 60], arrivals: [90, 780])
        XCTAssertLessThan(transfer.elapsedSeconds, direct.elapsedSeconds)
        XCTAssertLessThan(direct.score, transfer.score, "A small time saving should not outweigh a transfer")
    }
    func testAMuchFasterTransferCanStillBeRecommendedFirst() {
        let direct = TripRanking.assess(riding: [2_400], walking: [60, 60], arrivals: [600])
        let transfer = TripRanking.assess(riding: [450, 450], walking: [60, 90, 60], arrivals: [90, 780])
        XCTAssertLessThan(transfer.score, direct.score)
    }
    func testUnknownDirectArrivalIsNotAutomaticallyWorseThanAKnownTransfer() {
        let direct = TripRanking.assess(riding: [900], walking: [0, 0], arrivals: [nil])
        let transfer = TripRanking.assess(riding: [500, 400], walking: [0, 90, 0], arrivals: [60, nil])
        XCTAssertLessThan(direct.score, transfer.score)
        XCTAssertEqual(direct.uncertainWaits, 1)
    }
    func testAWalkingRouteThatMissesTheFirstBusDoesNotGetAFreeWait() {
        let missed = TripRanking.assess(riding: [600], walking: [420, 60], arrivals: [60])
        let catchable = TripRanking.assess(riding: [600], walking: [60, 60], arrivals: [240])
        XCTAssertTrue(missed.missedFirstArrival)
        XCTAssertGreaterThan(missed.waitingSeconds, 0)
        XCTAssertGreaterThan(missed.score, catchable.score)
        XCTAssertFalse(catchable.missedFirstArrival)
    }
    func testTransferArrivalIsComparedWithWhenThePassengerReachesIt() {
        let missed = TripRanking.assess(riding: [300, 300], walking: [0, 60, 0], arrivals: [60, 120])
        let reachable = TripRanking.assess(riding: [300, 300], walking: [0, 60, 0], arrivals: [60, 600])
        XCTAssertEqual(missed.uncertainWaits, 1)
        XCTAssertEqual(reachable.uncertainWaits, 0)
        XCTAssertEqual(reachable.waitingSeconds, 240)
        XCTAssertGreaterThan(missed.score, reachable.score)
    }
    func testClosedAndNotDepartedAreDifferent() {
        let closed = TripRanking.assess(riding: [300], walking: [0, 0], arrivals: [-4])
        let pending = TripRanking.assess(riding: [300], walking: [0, 0], arrivals: [-1])
        XCTAssertTrue(closed.unavailable)
        XCTAssertTrue(closed.score.isInfinite)
        XCTAssertFalse(pending.unavailable)
        XCTAssertGreaterThan(pending.waitingSeconds, 0)
    }
}
