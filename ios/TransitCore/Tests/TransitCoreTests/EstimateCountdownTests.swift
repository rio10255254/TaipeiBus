import XCTest
@testable import TransitCore

final class EstimateCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testPublishedSecondsCountDownFromSourceTimeWithoutAnotherDownload() {
        let feed = EstimateFeed(seconds: ["route:stop": 194], updatedAt: now)
        XCTAssertEqual(feed.value(routeID: "route", stopID: "stop", at: now), 194)
        XCTAssertEqual(feed.value(routeID: "route", stopID: "stop", at: now.addingTimeInterval(35)), 159)
        XCTAssertEqual(EstimateFeed.label(feed.value(routeID: "route", stopID: "stop", at: now.addingTimeInterval(35))), "2 分鐘")
    }
    func testSameFeedDownloadCannotResetTheCountdown() {
        let first = EstimateFeed(seconds: ["route:stop": 150], updatedAt: now)
        let repeated = EstimateFeed(seconds: first.seconds, updatedAt: first.updatedAt)
        XCTAssertEqual(repeated.value(routeID: "route", stopID: "stop", at: now.addingTimeInterval(45)), 105)
        XCTAssertEqual(EstimateFeed.label(121), "2 分鐘")
        XCTAssertEqual(EstimateFeed.label(119), "1 分鐘")
    }
    func testStatusCodesAndExpiredOrFailedEstimatesStayUnavailable() {
        let feed = EstimateFeed(seconds: ["route:stop": -3], updatedAt: now)
        XCTAssertEqual(feed.value(routeID: "route", stopID: "stop", at: now.addingTimeInterval(90)), -3)
        XCTAssertNil(feed.value(routeID: "route", stopID: "stop", at: now.addingTimeInterval(121)))
        XCTAssertNil(EstimateFeed(seconds: ["route:stop": 100], updatedAt: now, error: "offline").value(routeID: "route", stopID: "stop", at: now))
    }
    func testReachedZeroMeansDueSoonAndFutureClockDoesNotIncreaseWait() {
        let feed = EstimateFeed(seconds: ["route:stop": 20], updatedAt: now)
        XCTAssertEqual(feed.value(routeID: "route", stopID: "stop", at: now.addingTimeInterval(50)), 0)
        XCTAssertEqual(EstimateFeed.label(0), "1 分鐘內")
        XCTAssertEqual(feed.value(routeID: "route", stopID: "stop", at: now.addingTimeInterval(-10)), 20)
    }
}
