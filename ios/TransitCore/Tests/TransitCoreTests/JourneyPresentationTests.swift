import XCTest
@testable import TransitCore

final class JourneyPresentationTests: XCTestCase {
    func testMixedJourneyBreakdownPartitionsEverySecondExactlyOnce() {
        var time = JourneyDuration(riding: [600, 420], walking: [540, 180, 240], arrivals: [660, 1500])
        time.cyclingSeconds = 360; time.cyclingHandlingSeconds = 120; time.stationSeconds = 240
        XCTAssertEqual(time.components.reduce(0) { $0 + $1.seconds }, time.totalSeconds, accuracy: 0.001)
        XCTAssertEqual(time.components.first { $0.kind == .walking }?.seconds, 360)
        XCTAssertEqual(time.components.first { $0.kind == .cycling }?.seconds, 240)
        XCTAssertEqual(time.components.first { $0.kind == .handling }?.seconds, 120)
        XCTAssertEqual(time.components.first { $0.kind == .station }?.seconds, 240)
    }
    func testOverlappingAllowancesCannotInflateRemainingTime() {
        var time = JourneyDuration(riding: [], walking: [90], arrivals: [])
        time.cyclingSeconds = 80; time.cyclingHandlingSeconds = 120; time.stationSeconds = 90
        XCTAssertEqual(time.components.reduce(0) { $0 + $1.seconds }, 90, accuracy: 0.001)
        XCTAssertFalse(time.components.contains { $0.seconds < 0 })
        XCTAssertEqual(time.totalSeconds, 90)
    }
    func testZeroLengthArrivalHasNoPhantomComponent() {
        let time = JourneyDuration(riding: [], walking: [0], arrivals: [])
        XCTAssertTrue(time.components.isEmpty); XCTAssertEqual(time.totalSeconds, 0)
    }
    func testPreviewClockStaysCoherentWithinOneUpdateAndAcrossMidnight() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-19T15:59:45Z"))
        XCTAssertEqual(JourneyDuration.previewDate(instant), JourneyDuration.previewDate(instant.addingTimeInterval(14.9)))
        XCTAssertEqual(JourneyDuration.previewDate(instant.addingTimeInterval(15)), instant.addingTimeInterval(15))
        let time = JourneyDuration(riding: [], walking: [120], arrivals: [], at: instant)
        XCTAssertTrue(time.expectedArrivalLabel.contains("10/20 00:01"))
    }
    func testTaipeiClockIsExplicitWhenDeviceUsesAnotherTimeZone() throws {
        let time = JourneyDuration(riding: [], walking: [120], arrivals: [])
        XCTAssertNil(time.timeZoneNote(in: try XCTUnwrap(TimeZone(identifier: "Asia/Taipei"))))
        XCTAssertNotNil(time.timeZoneNote(in: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))))
        XCTAssertNotNil(time.timeZoneNote(in: try XCTUnwrap(TimeZone(secondsFromGMT: 0))))
    }
    func testUnknownWaitDoesNotAcquireAPromisedArrivalFromTheBreakdown() {
        let time = JourneyDuration(riding: [600], walking: [120, 60], arrivals: [nil])
        XCTAssertGreaterThan(time.unknownWaits, 0)
        XCTAssertFalse(time.expectedArrivalLabel.contains(":"))
        XCTAssertEqual(time.components.first { $0.kind == .waiting }?.durationLabel, time.waitingLabel,
                       "A comparison-only fallback must never be presented as a confirmed wait in the time explanation")
        XCTAssertEqual(time.components.reduce(0) { $0 + $1.seconds }, time.totalSeconds, accuracy: 0.001)
    }
}
