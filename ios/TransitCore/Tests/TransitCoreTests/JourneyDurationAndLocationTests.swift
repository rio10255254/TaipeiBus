import XCTest
@testable import TransitCore

final class JourneyDurationAndLocationTests: XCTestCase {
    func testTotalIncludesEachWalkRideAndCatchableTransferWithoutPreferencePenalty() {
        let duration = JourneyDuration(riding: [300, 420], walking: [60, 120, 90], arrivals: [180, 720])
        XCTAssertEqual(duration.walkingSeconds, 270)
        XCTAssertEqual(duration.waitingSeconds, 240)
        XCTAssertEqual(duration.ridingSeconds, 720)
        XCTAssertEqual(duration.totalSeconds, 1_230)
        XCTAssertEqual(duration.label, "全程約 21 分")
        let preferenceScore = TripRanking.assess(riding: [300, 420], walking: [60, 120, 90], arrivals: [180, 720]).score
        XCTAssertGreaterThan(preferenceScore, duration.totalSeconds)
    }
    func testWalkingOnlyAndUnknownWaitRemainHonest() {
        let walk = JourneyDuration(riding: [], walking: [300], arrivals: [])
        XCTAssertEqual(walk.totalSeconds, 300); XCTAssertEqual(walk.waitingSeconds, 0)
        let unknown = JourneyDuration(riding: [300], walking: [30, 60], arrivals: [nil])
        XCTAssertEqual(unknown.uncertainWaits, 1)
        XCTAssertGreaterThan(unknown.totalSeconds, 390)
        let beforeService = JourneyDuration(riding: [300], walking: [30, 60], arrivals: [nil], minimumServiceWaits: [1_800])
        XCTAssertEqual(beforeService.totalSeconds, 2_160)
    }
    func testDeviceDirectionUsesTheShortWayAcrossNorthAndGPSDoesNotExtrapolate() throws {
        var motion = DeviceLocationMotion()
        let start = Coordinate.taipei, target = Coordinate(latitude: start.latitude + 0.0001, longitude: start.longitude)
        motion.update(coordinate: start, heading: 359, elapsed: 0.016, reduceMotion: false)
        motion.update(coordinate: target, heading: 1, elapsed: 0.016, reduceMotion: false)
        let point = try XCTUnwrap(motion.coordinate), heading = try XCTUnwrap(motion.heading)
        XCTAssertGreaterThan(point.latitude, start.latitude); XCTAssertLessThan(point.latitude, target.latitude)
        XCTAssertGreaterThan(heading, 359)
        for _ in 0..<180 { motion.update(coordinate: target, heading: 1, elapsed: 0.016, reduceMotion: false) }
        XCTAssertLessThan(try XCTUnwrap(motion.coordinate).distance(to: target), 0.001)
        XCTAssertEqual(try XCTUnwrap(motion.heading), 1, accuracy: 0.001)
        motion.update(coordinate: nil, heading: nil, elapsed: 0.016, reduceMotion: false)
        XCTAssertNil(motion.coordinate); XCTAssertNil(motion.heading)
    }
    func testLargeGPSCorrectionsAndReducedMotionSnapToReceivedFix() {
        var motion = DeviceLocationMotion()
        let first = Coordinate.taipei, distant = Coordinate(latitude: 25.08, longitude: 121.6)
        motion.update(coordinate: first, heading: 90, elapsed: 0.016, reduceMotion: false)
        motion.update(coordinate: distant, heading: 270, elapsed: 0.016, reduceMotion: false)
        XCTAssertEqual(motion.coordinate, distant)
        motion.update(coordinate: first, heading: 90, elapsed: 0.016, reduceMotion: true)
        XCTAssertEqual(motion.coordinate, first); XCTAssertEqual(motion.heading, 90)
    }
}
