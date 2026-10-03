import XCTest
@testable import TransitCore

final class TripRankingTests: XCTestCase {
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
