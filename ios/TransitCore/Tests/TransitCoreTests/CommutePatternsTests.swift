import XCTest
@testable import TransitCore

final class CommutePatternsTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testAUsualWeekdayStartIsTheMiddleOfThreeWeekdays() {
        let work = UUID(), gym = UUID()
        var patterns = CommutePatterns()
        // Monday to Wednesday around 08:10 to work, two evenings at the gym (not a habit yet), and a
        // Saturday that does not count; recorded in the order they happened.
        let events: [(UUID, String)] = [(work, "2026-10-19T08:05:00+08:00"), (gym, "2026-10-19T19:00:00+08:00"),
                                        (work, "2026-10-20T08:20:00+08:00"), (gym, "2026-10-20T19:05:00+08:00"),
                                        (work, "2026-10-21T08:10:00+08:00"), (work, "2026-10-24T11:00:00+08:00")]
        for (id, time) in events { patterns.record(journeyID: id, at: date(time)) }
        let starts = patterns.usualWeekdayStarts(available: [work, gym], at: date("2026-10-26T07:00:00+08:00"))
        XCTAssertEqual(starts.map(\.journeyID), [work])
        XCTAssertEqual(starts.first?.minute, 8 * 60 + 10)
        XCTAssertTrue(patterns.usualWeekdayStarts(available: [gym], at: date("2026-10-26T07:00:00+08:00")).isEmpty)
    }
}
