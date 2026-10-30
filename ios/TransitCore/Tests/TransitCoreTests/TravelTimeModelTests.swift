import XCTest
@testable import TransitCore

/// The shared stop-to-stop rule (TravelTimeModel).
final class TravelTimeModelTests: XCTestCase {
    private let now = FeedDecoder.taipeiDate("2026/10/29 09:40:00")!
    private let route = BusRoute(id: "1", parentID: "1", name: "99", variantName: "", departure: "", destination: "")

    /// Hourly factors fixed so the formulas can be read off: 1.1 on profiles and a bus's own pace, none on the city pace.
    private func fixedTuning() -> ForecastTuning {
        var tuning = ForecastTuning(); tuning.workdayPaceFactors = Array(repeating: 1.1, count: 24)
        tuning.workdayCityPaceFactors = Array(repeating: 1, count: 24)
        return tuning
    }

    func testEvidenceIsTakenInOrder() throws {
        let tuning = fixedTuning()
        func segment(_ crossings: [Double], official: Double? = nil, estimates: Double? = nil,
                     pace: TravelTimeModel.Pace = .city) -> TravelTimeModel.Segment? {
            TravelTimeModel.segment(route: route, meters: 450, crossings: (crossings, crossings.count),
                official: { official }, estimates: { estimates }, pace: pace, travellingAt: now, tuning: tuning)
        }
        // Three buses' crossings outrank everything else and are not scaled.
        XCTAssertEqual(segment([60, 70, 200], official: 50, estimates: 40)?.seconds, 70)
        XCTAssertEqual(segment([60, 70, 200])?.source, .crossings)
        // The profile is scaled by the hour's pace factor, then refined by fewer crossings.
        let official = try XCTUnwrap(segment([], official: 100, estimates: 40))
        XCTAssertEqual(official.source, .officialProfile)
        XCTAssertEqual(official.seconds, 110, accuracy: 0.001)
        XCTAssertEqual(segment([140], official: 100)!.seconds, (140 + 110 * tuning.officialProfileWeight) / (1 + tuning.officialProfileWeight), accuracy: 0.001)
        // Without a profile, the live estimates; without those, a pace.
        XCTAssertEqual(segment([140], estimates: 40)?.seconds, 40)
        XCTAssertEqual(segment([140], estimates: 40)?.source, .officialEstimates)
        XCTAssertEqual(segment([])?.seconds, 450 / tuning.typicalSpeed + tuning.stopSeconds)
        XCTAssertEqual(segment([], pace: .fleet(metersPerSecond: 5))?.seconds, 90)
        XCTAssertNil(segment([], pace: .none))
    }

    func testPaceFormulas() {
        var tuning = fixedTuning()
        func seconds(_ pace: TravelTimeModel.Pace, fraction: Double = 1, correction: Double = 1) -> Double? {
            TravelTimeModel.segment(route: route, meters: 450 * fraction, fraction: fraction, pace: pace,
                travellingAt: now, correction: correction, tuning: tuning)?.seconds
        }
        // A bus's own pace pays the stop allowance only when it has not been moving; the hour's factor and
        // the session's correction both apply.
        XCTAssertEqual(seconds(.vehicle(metersPerSecond: 5, variation: 0.2, moving: true))!, 99, accuracy: 0.001)
        XCTAssertEqual(seconds(.vehicle(metersPerSecond: 5, variation: 0.2, moving: false), correction: 0.9)!, (90 + tuning.stopSeconds) * 1.1 * 0.9, accuracy: 0.001)
        // The remaining half of a segment pays half the stop allowance.
        XCTAssertEqual(seconds(.city, fraction: 0.5)!, 225 / tuning.typicalSpeed + tuning.stopSeconds / 2, accuracy: 0.001)
        XCTAssertEqual(seconds(.city, correction: 1.2)!, (450 / tuning.typicalSpeed + tuning.stopSeconds) * 1.2, accuracy: 0.001)
        // The city pace follows the hour: buses run ahead of it at night and behind it in the peaks.
        tuning.workdayCityPaceFactors[9] = 1.12
        XCTAssertEqual(seconds(.city)!, (450 / tuning.typicalSpeed + tuning.stopSeconds) * 1.12, accuracy: 0.001)
        XCTAssertEqual(seconds(.vehicle(metersPerSecond: 5, variation: 0.2, moving: true))!, 99, accuracy: 0.001, "not a bus's own pace")
    }

    func testThePaceFactorFollowsTheTaipeiHour() {
        var tuning = ForecastTuning(); tuning.workdayPaceFactors = (0..<24).map(Double.init)
        tuning.holidayPaceFactors = (0..<24).map { Double($0) + 100 }
        XCTAssertEqual(tuning.paceFactor(at: FeedDecoder.taipeiDate("2026/10/29 00:10:00")!), 0)
        XCTAssertEqual(tuning.paceFactor(at: FeedDecoder.taipeiDate("2026/10/29 07:59:59")!), 7)
        XCTAssertEqual(tuning.paceFactor(at: FeedDecoder.taipeiDate("2026/10/29 23:30:00")!), 23)
        XCTAssertEqual(tuning.paceFactor(at: FeedDecoder.taipeiDate("2026/10/31 08:00:00")!), 108, "a Saturday")
        tuning.workdayCityPaceFactors = (0..<24).map { Double($0) + 200 }
        XCTAssertEqual(tuning.cityPaceFactor(at: FeedDecoder.taipeiDate("2026/10/29 07:59:59")!), 207)
        // The shipped city table: faster than the all-day pace late at night, slower in the evening peak.
        let shipped = ForecastTuning()
        XCTAssertLessThan(shipped.cityPaceFactor(at: FeedDecoder.taipeiDate("2026/10/29 23:30:00")!), 0.9)
        XCTAssertGreaterThan(shipped.cityPaceFactor(at: FeedDecoder.taipeiDate("2026/10/29 17:30:00")!), 1.1)
    }

    func testRoadDistanceFollowsTheLineWhenBothStopsAreOnIt() {
        let a = BusStop(id: "a", routeID: "1", stationID: "a", name: "甲", direction: "0", sequence: 1, coordinate: Coordinate(latitude: 25.0, longitude: 121.5))
        let b = BusStop(id: "b", routeID: "1", stationID: "b", name: "乙", direction: "0", sequence: 2, coordinate: Coordinate(latitude: 25.0, longitude: 121.51))
        XCTAssertEqual(TravelTimeModel.meters(from: a, to: b, along: ["a": 100, "b": 1_300]), 1_200)
        XCTAssertEqual(TravelTimeModel.meters(from: a, to: b, along: ["a": 100]), a.coordinate.distance(to: b.coordinate) * 1.25)
    }

    func testArrivalEstimatesGiveALegOnlyWhenTheyDescribeOneBus() {
        let feed = EstimateFeed(seconds: ["9:a": 120, "9:b": 300, "9:c": 60, "9:d": -1, "9:e": 4000], updatedAt: now)
        XCTAssertEqual(TravelTimeModel.estimated(feed, parentRouteID: "9", from: "a", to: "b"), 180)
        // A bus already between the stops, a status code, a gap of over half an hour, a stop not listed.
        XCTAssertNil(TravelTimeModel.estimated(feed, parentRouteID: "9", from: "b", to: "c"))
        XCTAssertNil(TravelTimeModel.estimated(feed, parentRouteID: "9", from: "a", to: "d"))
        XCTAssertNil(TravelTimeModel.estimated(feed, parentRouteID: "9", from: "a", to: "e"))
        XCTAssertNil(TravelTimeModel.estimated(feed, parentRouteID: "9", from: "a", to: "x"))
        XCTAssertNil(TravelTimeModel.estimated(feed, parentRouteID: "8", from: "a", to: "b"))
        XCTAssertEqual(TravelTimeModel.estimated(EstimateFeed(seconds: ["9:a": 120, "9:b": 120], updatedAt: now), parentRouteID: "9", from: "a", to: "b"), 10)
    }

    func testOnlyACurrentFeedStandsForATripLeavingNow() {
        let feed = EstimateFeed(seconds: ["9:a": 120], updatedAt: now)
        XCTAssertNotNil(TravelTimeModel.liveEstimates(feed, at: now.addingTimeInterval(30)))
        XCTAssertNotNil(TravelTimeModel.liveEstimates(feed, at: now.addingTimeInterval(9 * 60)))
        XCTAssertNil(TravelTimeModel.liveEstimates(feed, at: now.addingTimeInterval(11 * 60)), "a trip planned for later")
        XCTAssertNil(TravelTimeModel.liveEstimates(feed, at: now.addingTimeInterval(-120)), "a feed newer than the departure")
        var failed = feed; failed.error = "到站預估來源連線中斷"
        XCTAssertNil(TravelTimeModel.liveEstimates(failed, at: now))
        XCTAssertNil(TravelTimeModel.liveEstimates(EstimateFeed(), at: now))
        XCTAssertNil(TravelTimeModel.liveEstimates(nil, at: now))
    }

    func testNewTaipeiRoutesUseTheirMeasuredPace() throws {
        var route = route
        let tuning = ForecastTuning()
        XCTAssertEqual(TravelTimeModel.cityPace(meters: 900, route: route, tuning: tuning), 900 / tuning.typicalSpeed + tuning.stopSeconds)
        route.source = "ntpc"
        let pace = try XCTUnwrap(RegionCatalog.shared.sources["ntpc"]?.ridePace)
        XCTAssertEqual(pace, TransitSource.RidePace(metersPerSecond: 6.25, stopSeconds: 25))
        XCTAssertEqual(TravelTimeModel.cityPace(meters: 625, route: route, tuning: tuning), 125, accuracy: 0.001)
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
        // A trip at the same hour tomorrow ignores today's estimates.
        XCTAssertEqual(try ride(estimates, at: now.addingTimeInterval(86_400)), estimated, accuracy: 0.5, "a later trip ignores today's estimates")

        // The ride time shown once the trip is chosen is the one the search ranked it by.
        for (feed, date) in [(estimates, now), (nil, now), (estimates, now.addingTimeInterval(86_400))] {
            let trip = try XCTUnwrap(planner.plan(from: origin, to: destination, maximumWalk: 600, estimates: feed, at: date)
                .first { $0.rides.count == 1 && $0.rides[0].boarding.id == "300" && $0.rides[0].alighting.id == "304" })
            let shown = VehicleArrivalForecast().ridingEstimate(trip.rides[0], metadata: metadata, at: date, estimates: feed)
            XCTAssertEqual(shown.seconds, trip.rideSeconds[0], accuracy: 1)
        }
    }
}
