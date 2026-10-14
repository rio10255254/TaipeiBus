import XCTest
@testable import TransitCore

final class DailyAllowanceTests: XCTestCase {
    private func taipei(_ text: String) -> Date {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func testThreeDistinctUsesPerDayAndRepeatsAreFree() {
        var allowance = DailyAllowance()
        let morning = taipei("2026-10-11 08:00")
        XCTAssertEqual(allowance.remaining(at: morning), 3)
        XCTAssertTrue(allowance.use("bus:A", at: morning))
        XCTAssertTrue(allowance.use("bus:A", at: morning), "Following the same bus again costs nothing")
        XCTAssertTrue(allowance.use("bus:B", at: morning))
        XCTAssertTrue(allowance.use("metro-trains", at: morning))
        XCTAssertEqual(allowance.remaining(at: morning), 0)
        XCTAssertFalse(allowance.allows("bus:C", at: morning))
        XCTAssertFalse(allowance.use("bus:C", at: morning))
        XCTAssertTrue(allowance.allows("bus:A", at: morning), "Something already used today stays available")
    }

    func testResetsAtTaipeiMidnight() {
        var allowance = DailyAllowance()
        let late = taipei("2026-10-11 23:50")
        for id in ["a", "b", "c"] { allowance.use(id, at: late) }
        XCTAssertEqual(allowance.remaining(at: late), 0)
        let next = taipei("2026-10-12 00:05")
        XCTAssertEqual(allowance.remaining(at: next), 3)
        XCTAssertTrue(allowance.use("d", at: next))
        XCTAssertEqual(allowance.remaining(at: next), 2)
    }

    func testRoundTripsThroughStorage() throws {
        var allowance = DailyAllowance()
        allowance.use("bus:A", at: taipei("2026-10-11 08:00"))
        let restored = try JSONDecoder().decode(DailyAllowance.self, from: JSONEncoder().encode(allowance))
        XCTAssertEqual(restored, allowance)
    }
}
