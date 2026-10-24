import XCTest
@testable import TransitCore

final class SpokenTimeTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-22T04:00:00Z")!   // Thursday 12:00 in Taipei
    private func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func read(_ text: String) -> SpokenTime? { SpokenTime.read(text, now: now) }

    func testAPartOfTheDayBecomesAUsualDeparture() {
        XCTAssertEqual(read("明天早上去台大"), SpokenTime(date: at("2026-10-23T01:00:00Z"), kind: .departure, exact: false))
        XCTAssertEqual(read("晚上去101")?.date, at("2026-10-22T11:00:00Z"))
        XCTAssertEqual(read("明天去台大"), SpokenTime(date: at("2026-10-23T01:00:00Z"), kind: .departure, exact: false))
        XCTAssertEqual(read("早上去公司")?.date, at("2026-10-23T01:00:00Z"), "This morning has passed: tomorrow morning")
    }
    func testAClockTimeIsWhenToBeThereUnlessLeavingIsSaid() {
        XCTAssertEqual(read("明天下午三點去台大"), SpokenTime(date: at("2026-10-23T07:00:00Z"), kind: .arrival, exact: true))
        XCTAssertEqual(read("明天下午三點出發去台大")?.kind, .departure)
        XCTAssertEqual(read("三點前出發去台大")?.kind, .arrival, "…前 is always a deadline")
        XCTAssertEqual(read("三點前到北車")?.date, at("2026-10-22T07:00:00Z"), "No period: three o'clock is in the afternoon")
        XCTAssertEqual(read("九點到公司")?.date, at("2026-10-23T01:00:00Z"), "Nine has passed today: tomorrow")
        XCTAssertEqual(read("晚上八點半到信義區")?.date, at("2026-10-22T12:30:00Z"))
        XCTAssertEqual(read("3:30前到")?.date, at("2026-10-22T07:30:00Z"))
        XCTAssertEqual(read("下三點去台大")?.date, at("2026-10-22T07:00:00Z"), "A dropped 午 still reads as the afternoon")
    }
    func testWeekdays() {
        XCTAssertEqual(read("週六下午去淡水")?.date, at("2026-10-24T06:00:00Z"))
        XCTAssertEqual(read("下週一早上八點半出發去公司"), SpokenTime(date: at("2026-10-26T00:30:00Z"), kind: .departure, exact: true))
        XCTAssertEqual(read("禮拜天去動物園")?.date, at("2026-10-25T01:00:00Z"))
        XCTAssertEqual(read("十點一刻出發")?.date, at("2026-10-23T02:15:00Z"))
    }
    func testNoTimeMeansNow() {
        XCTAssertNil(read("現在去台大"))
        XCTAssertNil(read("騎單車去台大"))
        XCTAssertNil(read("回家，快一點"))
        XCTAssertNil(read("去一小時車程的地方"))
    }
}
