import XCTest
@testable import TransitCore

final class DaylightTests: XCTestCase {
    private func taipei(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: text))
    }
    func testSunsetAndSunriseFollowTheSeasonInTaipei() throws {
        // Published Taipei times: sunset 17:17 on 25 Oct, 18:47 on 21 Jun; sunrise 06:38 on 21 Dec, 05:05 on 21 Jun.
        XCTAssertFalse(Daylight.isNight(at: try taipei("2026-10-25 17:10")))
        XCTAssertTrue(Daylight.isNight(at: try taipei("2026-10-25 17:30")))
        XCTAssertFalse(Daylight.isNight(at: try taipei("2026-06-21 18:40")))
        XCTAssertTrue(Daylight.isNight(at: try taipei("2026-06-21 18:55")))
        XCTAssertTrue(Daylight.isNight(at: try taipei("2026-12-21 06:30")))
        XCTAssertFalse(Daylight.isNight(at: try taipei("2026-12-21 06:45")))
        XCTAssertTrue(Daylight.isNight(at: try taipei("2026-06-21 04:55")))
        XCTAssertFalse(Daylight.isNight(at: try taipei("2026-06-21 05:15")))
    }
    func testNoonAndMidnight() throws {
        XCTAssertGreaterThan(Daylight.solarElevation(at: try taipei("2026-06-21 12:00"), coordinate: .taipei), 80)
        XCTAssertTrue(Daylight.isNight(at: try taipei("2026-12-21 00:00")))
    }
}
