import XCTest
@testable import TransitCore

final class TransitCoreTests: XCTestCase {
    private let now = FeedDecoder.taipeiDate("2026/10/02 10:15:30")!

    private func feed(_ rows: [[String: Any]], time: String = "2026/10/02 10:15:30") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["EssentialInfo": ["UpdateTime": time], "BusInfo": rows])
    }
    private func metadata() throws -> TransitMetadata {
        try FeedDecoder.metadata(feeds: [
            "GetRoute": feed([["Id": 100, "pathAttributeId": 10, "nameZh": "284", "pathAttributeName": "284",
                               "departureZh": "起點", "destinationZh": "終點"]]),
            "GetStop": feed([
                ["Id": 101, "routeId": 100, "stopLocationId": 6922, "nameZh": "國父紀念館", "goBack": "0", "seqNo": 1,
                 "longitude": 121.55, "latitude": 25.04, "bearing": "W"],
                ["Id": 102, "routeId": 100, "stopLocationId": 6921, "nameZh": "國父紀念館", "goBack": "1", "seqNo": 2,
                 "longitude": 121.5502, "latitude": 25.0401, "bearing": "E"]]),
            "GetPathDetail": feed([["pathAttributeId": 10, "stopId": 101, "sequenceNo": 1, "type": "0"]]),
            "GetProvider": feed([["id": 4, "nameZn": "公車業者"]]),
            "GetBusShape": JSONSerialization.data(withJSONObject: [["RouteID": 100, "SubRouteID": 10,
                "wkt": "LINESTRING(121.55 25.04,121.551 25.04,121.551 25.041)"]])
        ])
    }
    private func row(_ changes: [String: Any] = [:]) -> [String: Any] {
        var row: [String: Any] = ["BusID": "ABC-123", "CarID": "physical-1", "RouteID": 10, "ProviderID": 4,
            "Longitude": 121.5501, "Latitude": 25.04001, "Speed": 30, "Azimuth": 90,
            "GoBack": "0", "BusStatus": "0", "DutyStatus": "0", "CarType": "1", "DataTime": "2026-10-02 10:15:15"]
        row.merge(changes, uniquingKeysWith: { _, new in new })
        return row
    }

    func testTaipeiTimezoneIsIndependentOfDeviceTimezone() {
        XCTAssertEqual(FeedDecoder.taipeiDate("2026/10/02 10:15:30")?.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-10-02T02:15:30Z")?.timeIntervalSince1970)
        XCTAssertNil(FeedDecoder.taipeiDate("invalid"))
    }

    func testPhysicalStationDirectionsAndBranchStopsRemainDistinct() throws {
        let metadata = try metadata()
        XCTAssertEqual(metadata.stations.count, 2)
        XCTAssertEqual(metadata.stations["6922"]?.bearingLabel, "西向")
        XCTAssertEqual(metadata.orderedStops(routeID: "10", direction: "0").map(\.id), ["101"])
        XCTAssertTrue(metadata.orderedStops(routeID: "10", direction: "1").isEmpty)
    }

    func testInvalidAndEndedVehiclesNeverReplaceLiveData() throws {
        let metadata = try metadata()
        let good = row()
        for bad in [row(["CarID": "bad", "DataTime": "invalid"]), row(["CarID": "bad", "DutyStatus": "2"]),
                    row(["CarID": "bad", "BusStatus": "99"]), row(["CarID": "bad", "Longitude": 0]),
                    row(["CarID": "bad", "DataTime": "2026-10-02 10:00:00"]),
                    row(["CarID": "bad", "DataTime": "2026-10-02 10:17:30"])] {
            let vehicles = try FeedDecoder.vehicles(feed([good, bad]), metadata: metadata, previous: [], now: now).vehicles
            XCTAssertEqual(vehicles.map(\.id), ["physical-1"])
            XCTAssertEqual(vehicles[0].provider, "公車業者")
            XCTAssertTrue(vehicles[0].lowFloor)
        }
    }

    func testRoadAnimationPreservesCornerAndReversedPath() throws {
        let metadata = try metadata()
        let first = try FeedDecoder.vehicles(feed([row()]), metadata: metadata, previous: [], now: now).vehicles
        let second = try FeedDecoder.vehicles(feed([row(["Longitude": 121.55101, "Latitude": 25.0409,
                                                        "Azimuth": 0, "DataTime": "2026-10-02 10:15:30"])]),
                                              metadata: metadata, previous: first, now: now).vehicles
        XCTAssertEqual(second[0].path.count, 3)
        XCTAssertEqual(second[0].path[1], Coordinate(latitude: 25.04, longitude: 121.551))
        let line = metadata.line("10")!
        let a = line.match(first[0].rawCoordinate, heading: 90)!, b = line.match(second[0].rawCoordinate, heading: 0)!
        XCTAssertEqual(line.slice(from: b, to: a), line.slice(from: a, to: b).reversed().map { $0 })
        XCTAssertNil(line.match(Coordinate(latitude: 25.05, longitude: 121.56), heading: nil))
    }

    func testRepeatedSnapshotDoesNotRestartAnimationAndStaleDataStops() throws {
        let metadata = try metadata()
        let first = try FeedDecoder.vehicles(feed([row()]), metadata: metadata, previous: [], now: now).vehicles
        let second = try FeedDecoder.vehicles(feed([row(["Longitude": 121.55101, "Latitude": 25.0409,
                                                        "DataTime": "2026-10-02 10:15:30"])]),
                                              metadata: metadata, previous: first, now: now).vehicles
        var motion = VehicleMotion()
        motion.ingest(first, time: 0, now: now)
        motion.ingest(second, time: 15, now: now)
        let before = motion.pose(id: "physical-1", time: 18, now: now)!
        motion.ingest(second, time: 18, now: now)
        XCTAssertEqual(before.coordinate, motion.pose(id: "physical-1", time: 18, now: now)!.coordinate)
        let stale = motion.pose(id: "physical-1", time: 18, now: now.addingTimeInterval(180))!
        XCTAssertTrue(stale.stale)
        XCTAssertEqual(stale.coordinate, second[0].coordinate)
        XCTAssertFalse(motion.isAnimating(time: 18, now: now.addingTimeInterval(180)))
    }

    func testETANullFailureAndAgeNeverTurnIntoAnArrivingBus() throws {
        let data = try feed([
            ["RouteID": 100, "StopID": 101, "EstimateTime": NSNull()],
            ["RouteID": 100, "StopID": 102, "EstimateTime": "194"],
            ["RouteID": 100, "StopID": 103, "EstimateTime": "-2"]])
        var estimates = try FeedDecoder.estimates(data)
        XCTAssertNil(estimates.value(routeID: "100", stopID: "101", at: now))
        XCTAssertEqual(EstimateFeed.label(estimates.value(routeID: "100", stopID: "102", at: now)), "4 分鐘")
        XCTAssertEqual(EstimateFeed.label(-2), "交管不停靠")
        XCTAssertNil(estimates.value(routeID: "100", stopID: "102", at: now.addingTimeInterval(121)))
        estimates.error = "offline"
        XCTAssertNil(estimates.value(routeID: "100", stopID: "102", at: now))
    }

    func testRouteETAAndNearbyVehicleIdentityAreSeparateAndBranchesFiltered() throws {
        let metadata = try metadata()
        let vehicles = try FeedDecoder.vehicles(feed([row(), row(["CarID": "opposite", "GoBack": "1"])]),
                                                metadata: metadata, previous: [], now: now).vehicles
        let estimates = try FeedDecoder.estimates(feed([["RouteID": 100, "StopID": 101, "EstimateTime": 194]]))
        let snapshot = TransitSnapshot(vehicles: vehicles, estimates: estimates)
        let arrivals = StationArrival.rows(station: metadata.stations["6922"]!, metadata: metadata, snapshot: snapshot, now: now)
        XCTAssertEqual(arrivals.count, 1)
        XCTAssertEqual(arrivals[0].estimateSeconds, 194)
        XCTAssertEqual(arrivals[0].nearbyVehicles.map(\.id), ["physical-1"])
        XCTAssertTrue(StationArrival.rows(station: metadata.stations["6921"]!, metadata: metadata, snapshot: snapshot, now: now)[0].nearbyVehicles.isEmpty)
    }
}
