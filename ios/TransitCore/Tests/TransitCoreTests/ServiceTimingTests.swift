import XCTest
@testable import TransitCore

final class ServiceTimingTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testPublishedHeadwayEncodingAndHolidayCalendar() throws {
        let headway = try XCTUnwrap(BusHeadway(published: "0710"))
        XCTAssertEqual(headway.lowerSeconds, 420); XCTAssertEqual(headway.upperSeconds, 600)
        XCTAssertEqual(BusHeadway(published: "10-20")?.upperSeconds, 1200)
        for value in ["", "每天", "9999", "0000", "0800~2130"] { XCTAssertNil(BusHeadway(published: value)) }
        XCTAssertTrue(TransitServiceCalendar.isHoliday(date("2026-10-09T04:00:00Z")), "Official National Day observed holiday")
        XCTAssertFalse(TransitServiceCalendar.isHoliday(date("2026-10-08T04:00:00Z")))
        let plan = BusServicePlan(weekday: .init(headway: BusHeadway(published: "0710")),
            holiday: .init(headway: BusHeadway(published: "1020")))
        XCTAssertEqual(plan.service(at: date("2026-10-04T04:00:00Z")).headway?.lowerSeconds, 600)
    }
    func testArrivalMustFollowWalkingAndBoardingBuffer() {
        let missed = BoardingTime.wait(official: 120, readyAt: 140, buffer: 60)
        XCTAssertTrue(missed.missedNext); XCTAssertEqual(missed.evidence, .unknown)
        let atStation = BoardingTime.wait(official: 20, readyAt: 0, buffer: 0)
        XCTAssertEqual(atStation.seconds, 20); XCTAssertEqual(atStation.evidence, .official)
        let reachable = BoardingTime.wait(official: 300, readyAt: 120, buffer: 60)
        XCTAssertEqual(reachable.seconds, 180)
    }
    func testMissedNextUsesRouteHeadwayWithoutPretendingItIsOfficial() throws {
        let service = BusDayService(headway: try XCTUnwrap(BusHeadway(published: "1020")))
        let result = BoardingTime.wait(official: 120, readyAt: 420, buffer: 60, service: service)
        XCTAssertTrue(result.missedNext); XCTAssertEqual(result.evidence, .headway)
        XCTAssertEqual(result.seconds, 600)
        XCTAssertEqual(result.lowerSeconds, 300); XCTAssertEqual(result.upperSeconds, 900)
        XCTAssertTrue(result.label.contains("約"))
    }
    func testTimetableAndServiceNotesAreDistinguished() {
        XCTAssertEqual(BusDayService.publishedDepartures("06:30、07:30、08:30 發車"), [390, 450, 510])
        XCTAssertTrue(BusDayService.publishedDepartures("每日08:00~20:00繞駛醫院，06:30、07:30不停靠").isEmpty)
        let service = BusDayService(departures: [390, 450, 510])
        let result = BoardingTime.wait(official: nil, readyAt: 300, buffer: 60, service: service,
            secondsOfDay: 7 * 3600, boardingOffset: 120)
        XCTAssertEqual(result.evidence, .timetable); XCTAssertEqual(result.seconds, 1620)
    }
    func testMovingWaitingAndArrivalClockAgreeAcrossMidnight() {
        let timing = JourneyDuration(riding: [600], walking: [60, 60], arrivals: [300], at: date("2026-10-04T15:55:00Z"))
        XCTAssertEqual(timing.travelSeconds, 720); XCTAssertEqual(timing.waitingSeconds, 240)
        XCTAssertEqual(timing.totalSeconds, 960); XCTAssertTrue(timing.arrivalLabel.contains("10/5 00:11"))
        let unknown = JourneyDuration(riding: [600], walking: [60, 60], arrivals: [nil], at: date("2026-10-04T04:00:00Z"))
        XCTAssertEqual(unknown.arrivalLabel, "抵達待確認")
        XCTAssertTrue(unknown.label.hasPrefix("行程")); XCTAssertEqual(unknown.waitingLabel, "候車待確認")
    }
}
