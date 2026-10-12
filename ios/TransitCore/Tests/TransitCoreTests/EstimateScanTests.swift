import XCTest
@testable import TransitCore

final class EstimateScanTests: XCTestCase {
    // The official file's real layout: numbers unquoted for IDs, times as strings.
    private let feed = Data(#"""
    {"EssentialInfo":{"UpdateTime":"2026/10/11 16:17:30","CoordinateSystem":"WGS84"},"BusInfo":[
    {"RouteID":10471,"StopID":187095,"EstimateTime":"-4","GoBack":"2"},
    {"RouteID":10442,"StopID":36407,"EstimateTime":"425","GoBack":"1"},
    {"RouteID":10443,"StopID":36407,"EstimateTime":"95","GoBack":"0"},
    {"RouteID":10442,"StopID":364070,"EstimateTime":"30","GoBack":"1"},
    {"RouteID":"200","StopID":"5550","EstimateTime":"600","GoBack":"0"}]}
    """#.utf8)

    func testReadsTheSourceTimeInTaipei() throws {
        let date = try XCTUnwrap(EstimateScan.updateTime(feed))
        XCTAssertEqual(date.timeIntervalSince1970, 1_791_706_650, accuracy: 0.5)
    }

    func testFindsOnlyTheRequestedRouteAtTheExactStop() {
        XCTAssertEqual(EstimateScan.estimate(in: feed, route: "10442", stop: "36407"), 425)
        XCTAssertEqual(EstimateScan.estimate(in: feed, route: "10443", stop: "36407"), 95, "Another route at the same stop")
        XCTAssertEqual(EstimateScan.estimate(in: feed, route: "10471", stop: "187095"), -4, "Status codes pass through")
        XCTAssertNil(EstimateScan.estimate(in: feed, route: "10442", stop: "3640"), "A shorter stop ID must not match a longer one")
        XCTAssertNil(EstimateScan.estimate(in: feed, route: "99999", stop: "36407"))
        XCTAssertEqual(EstimateScan.estimate(in: feed, route: "200", stop: "5550"), 600, "Quoted IDs are read too")
    }
}
