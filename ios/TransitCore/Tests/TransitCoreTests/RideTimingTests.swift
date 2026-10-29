import XCTest
@testable import TransitCore

/// Ride times where no official station-to-station time exists (New Taipei).
final class RideTimingTests: XCTestCase {
    private let now = FeedDecoder.taipeiDate("2026/10/29 09:40:00")!

    func testArrivalEstimatesGiveALegOnlyWhenTheyDescribeOneBus() {
        let feed = EstimateFeed(seconds: ["9:a": 120, "9:b": 300, "9:c": 60, "9:d": -1, "9:e": 4000], updatedAt: now)
        XCTAssertEqual(RideTiming.live(feed, parentRouteID: "9", from: "a", to: "b"), 180)
        // A bus already between the stops, a status code, a gap of over half an hour, a stop not listed.
        XCTAssertNil(RideTiming.live(feed, parentRouteID: "9", from: "b", to: "c"))
        XCTAssertNil(RideTiming.live(feed, parentRouteID: "9", from: "a", to: "d"))
        XCTAssertNil(RideTiming.live(feed, parentRouteID: "9", from: "a", to: "e"))
        XCTAssertNil(RideTiming.live(feed, parentRouteID: "9", from: "a", to: "x"))
        XCTAssertNil(RideTiming.live(feed, parentRouteID: "8", from: "a", to: "b"))
        XCTAssertEqual(RideTiming.live(EstimateFeed(seconds: ["9:a": 120, "9:b": 120], updatedAt: now), parentRouteID: "9", from: "a", to: "b"), 10)
    }

    func testOnlyACurrentFeedStandsForATripLeavingNow() {
        let feed = EstimateFeed(seconds: ["9:a": 120], updatedAt: now)
        XCTAssertNotNil(RideTiming.liveEstimates(feed, at: now.addingTimeInterval(30)))
        XCTAssertNotNil(RideTiming.liveEstimates(feed, at: now.addingTimeInterval(9 * 60)))
        XCTAssertNil(RideTiming.liveEstimates(feed, at: now.addingTimeInterval(11 * 60)), "a trip planned for later")
        XCTAssertNil(RideTiming.liveEstimates(feed, at: now.addingTimeInterval(-120)), "a feed newer than the departure")
        var failed = feed; failed.error = "到站預估來源連線中斷"
        XCTAssertNil(RideTiming.liveEstimates(failed, at: now))
        XCTAssertNil(RideTiming.liveEstimates(EstimateFeed(), at: now))
        XCTAssertNil(RideTiming.liveEstimates(nil, at: now))
    }

    func testNewTaipeiRoutesUseTheirMeasuredPace() throws {
        var route = BusRoute(id: "1", parentID: "1", name: "99", variantName: "", departure: "", destination: "")
        let tuning = ForecastTuning()
        XCTAssertEqual(RideTiming.estimate(meters: 900, route: route, tuning: tuning), 900 / tuning.typicalSpeed + tuning.stopSeconds)
        route.source = "ntpc"
        let pace = try XCTUnwrap(RegionCatalog.shared.sources["ntpc"]?.ridePace)
        XCTAssertEqual(pace, TransitSource.RidePace(metersPerSecond: 6.25, stopSeconds: 25))
        XCTAssertEqual(RideTiming.estimate(meters: 625, route: route, tuning: tuning), 125, accuracy: 0.001)
        XCTAssertNil(RegionCatalog.shared.sources["tpe"]?.ridePace, "Taipei keeps the shared tuning")
    }

    func testPlannedRidesUseTheEstimatesOnlyWhenLeavingNow() throws {
        func feed(_ rows: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["EssentialInfo": ["UpdateTime": "2026/10/29 09:40:00"], "BusInfo": rows])
        }
        let stops = (0..<5).map { index -> [String: Any] in
            ["Id": 300 + index, "routeId": 200, "stopLocationId": 7000 + index, "nameZh": "站\(index)", "goBack": "0",
             "seqNo": index + 1, "longitude": 121.46 + Double(index) * 0.01, "latitude": 25.01] }
        let metadata = try FeedDecoder.metadata(sources: [(source: "ntpc", feeds: [
            "GetRoute": feed([["Id": 200, "pathAttributeId": 20, "nameZh": "99", "departureZh": "起點", "destinationZh": "終點"]]),
            "GetStop": feed(stops),
            "GetPathDetail": feed((0..<5).map { ["pathAttributeId": 20, "stopId": 300 + $0, "sequenceNo": $0 + 1, "type": "0"] })])])
        XCTAssertEqual(metadata.routes["20"]?.source, "ntpc")
        let estimates = EstimateFeed(seconds: Dictionary(uniqueKeysWithValues: (0..<5).map { ("200:\(300 + $0)", 60 + $0 * 100) }), updatedAt: now)
        let planner = TripPlanner(metadata: metadata)
        let origin = Coordinate(latitude: 25.0103, longitude: 121.46), destination = Coordinate(latitude: 25.0103, longitude: 121.50)
        func ride(_ feed: EstimateFeed?, at date: Date) throws -> Double {
            let trip = try XCTUnwrap(planner.plan(from: origin, to: destination, maximumWalk: 600, estimates: feed, at: date)
                .first { $0.rides.count == 1 && $0.rides[0].boarding.id == "300" && $0.rides[0].alighting.id == "304" })
            return trip.rideSeconds[0]
        }
        // Four legs of 100 s each from the estimates; about 1 km each at New Taipei's pace otherwise.
        XCTAssertEqual(try ride(estimates, at: now), 400, accuracy: 0.5)
        let estimated = try ride(nil, at: now)
        XCTAssertGreaterThan(estimated, 500)
        XCTAssertEqual(try ride(estimates, at: now.addingTimeInterval(3_600)), estimated, accuracy: 0.5, "a later trip ignores today's estimates")
    }
}
