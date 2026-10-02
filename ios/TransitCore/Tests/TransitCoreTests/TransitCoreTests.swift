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

    func testUnavailableOptionalGeometryNeverDisablesStationArrivals() throws {
        let metadata = try FeedDecoder.metadata(feeds: [
            "GetRoute": feed([["Id": 100, "pathAttributeId": 10, "nameZh": "284"]]),
            "GetStop": feed([["Id": 101, "routeId": 100, "stopLocationId": 6922, "nameZh": "站牌",
                "goBack": "0", "seqNo": 1, "longitude": 121.55, "latitude": 25.04]]),
            "GetBusShape": Data("[]".utf8), "GetPathDetail": Data("{\"error\":\"unavailable\"}".utf8),
            "GetProvider": Data("invalid".utf8)])
        XCTAssertEqual(metadata.stations.count, 1)
        XCTAssertTrue(metadata.lines.isEmpty)
        let estimates = try FeedDecoder.estimates(feed([["RouteID": 100, "StopID": 101, "EstimateTime": 120]]))
        let arrivals = StationArrival.rows(station: metadata.stations["6922"]!, metadata: metadata,
            snapshot: TransitSnapshot(estimates: estimates), now: now)
        XCTAssertEqual(arrivals.first?.estimateSeconds, 120)
        XCTAssertThrowsError(try FeedDecoder.metadata(feeds: ["GetRoute": Data("[]".utf8)]))
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
        motion.finishAnimations(time: 18, now: now)
        XCTAssertEqual(motion.pose(id: "physical-1", time: 18, now: now)!.coordinate, second[0].coordinate)
        XCTAssertFalse(motion.isAnimating(time: 18, now: now))
        motion.ingest(second, time: 19, now: now)
        XCTAssertFalse(motion.isAnimating(time: 19, now: now))
    }

    private func movingBus(_ points: [Coordinate], observedAt: Date, speed: Double = 36,
                           heading: Double = 90, route: String = "10") -> BusVehicle {
        BusVehicle(id: "bus", plate: "ABC-123", routeID: route, parentRouteID: "100", routeName: "284",
                   direction: "0", destination: "終點", coordinate: points.last!, rawCoordinate: points.last!,
                   heading: heading, speed: speed, observedAt: observedAt, status: "0", lowFloor: true,
                   provider: nil, aligned: true, path: points)
    }

    func testGPSRetargetKeepsRenderedPositionHeadingWheelsAndRemainingCorners() {
        let a = Coordinate(latitude: 25.04, longitude: 121.55)
        let b = Coordinate(latitude: 25.04, longitude: 121.551)
        let c = Coordinate(latitude: 25.041, longitude: 121.551)
        let d = Coordinate(latitude: 25.041, longitude: 121.552)
        var motion = VehicleMotion()
        motion.ingest([movingBus([a], observedAt: now.addingTimeInterval(-30))], time: 0, now: now)
        motion.ingest([movingBus([a,b,c], observedAt: now.addingTimeInterval(-15), heading: 0)], time: 10, now: now)
        let before = motion.pose(id: "bus", time: 14, now: now)!
        motion.ingest([movingBus([c,d], observedAt: now)], time: 14, now: now)
        let after = motion.pose(id: "bus", time: 14, now: now)!
        XCTAssertLessThan(before.coordinate.distance(to: after.coordinate), 0.001)
        XCTAssertEqual(before.heading, after.heading, accuracy: 0.001)
        XCTAssertEqual(before.traveledDistance, after.traveledDistance, accuracy: 0.001)
        let road = RouteLine(coordinates: [a,b,c,d])
        var previousDistance = after.traveledDistance
        for index in 0...150 {
            let pose = motion.pose(id: "bus", time: 14 + Double(index) / 10, now: now)!
            XCTAssertLessThan(road.match(pose.coordinate, heading: nil)!.distance, 0.01)
            XCTAssertGreaterThanOrEqual(pose.traveledDistance, previousDistance)
            previousDistance = pose.traveledDistance
        }
        XCTAssertLessThan(motion.pose(id: "bus", time: 60, now: now)!.coordinate.distance(to: d), 0.001)
    }

    func testNorthHeadingWrapAndAStopNeverRotateOrExtrapolate() {
        let a = Coordinate(latitude: 25.04, longitude: 121.55)
        let b = Coordinate(latitude: 25.041, longitude: 121.55)
        var motion = VehicleMotion()
        motion.ingest([movingBus([a], observedAt: now.addingTimeInterval(-15), heading: 359)], time: 0, now: now)
        motion.ingest([movingBus([a,b], observedAt: now, speed: 0, heading: 1)], time: 1, now: now)
        let turning = motion.pose(id: "bus", time: 1.35, now: now)!
        XCTAssertTrue(turning.heading > 350 || turning.heading < 10)
        XCTAssertLessThan(motion.pose(id: "bus", time: 16, now: now)!.coordinate.distance(to: b), 0.001)
        XCTAssertEqual(motion.pose(id: "bus", time: 16, now: now)!.traveledDistance,
                       motion.pose(id: "bus", time: 50, now: now)!.traveledDistance)
        let stoppedHeading = motion.pose(id: "bus", time: 16, now: now)!.heading
        motion.ingest([movingBus([b,b], observedAt: now.addingTimeInterval(15), speed: 0, heading: 180)], time: 17, now: now)
        XCTAssertEqual(motion.pose(id: "bus", time: 18, now: now)!.heading, stoppedHeading, accuracy: 0.001)
    }

    func testOlderGPSIsIgnoredAndChangedRouteDoesNotDriveAcrossBlocks() {
        let a = Coordinate(latitude: 25.04, longitude: 121.55)
        let b = Coordinate(latitude: 25.041, longitude: 121.55)
        let c = Coordinate(latitude: 25.042, longitude: 121.553)
        var motion = VehicleMotion()
        motion.ingest([movingBus([a], observedAt: now)], time: 0, now: now)
        motion.ingest([movingBus([b], observedAt: now.addingTimeInterval(-15))], time: 1, now: now)
        XCTAssertEqual(motion.pose(id: "bus", time: 1, now: now)!.coordinate, a)
        motion.ingest([movingBus([a,c], observedAt: now.addingTimeInterval(15), route: "11")], time: 2, now: now)
        XCTAssertEqual(motion.pose(id: "bus", time: 2, now: now)!.coordinate, c)
        XCTAssertFalse(motion.isAnimating(time: 2, now: now))
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

    func testContinuousMatchingDoesNotJumpToParallelReturnLegOrEarlierCrossing() {
        let a = Coordinate(latitude: 25.04, longitude: 121.55)
        let b = Coordinate(latitude: 25.04, longitude: 121.56)
        let c = Coordinate(latitude: 25.04015, longitude: 121.56)
        let d = Coordinate(latitude: 25.04015, longitude: 121.55)
        let line = RouteLine(coordinates: [a,b,c,d])
        let old = line.match(Coordinate(latitude: 25.04, longitude: 121.551), heading: 90)!
        let noisy = Coordinate(latitude: 25.0401, longitude: 121.5512)
        XCTAssertEqual(line.match(noisy, heading: 90)?.segment, 2)
        let continuous = line.match(noisy, heading: 90, previous: old, maximumTravel: 200, travelDirection: 1)!
        XCTAssertEqual(continuous.segment, 0)
        XCTAssertLessThan(abs(continuous.along - old.along), 30)
        let crossing = RouteLine(coordinates: [a,b,c,a,Coordinate(latitude: 25.039, longitude: 121.55)])
        let from = crossing.candidates(a).max(by: { $0.along < $1.along })!
        let match = crossing.match(Coordinate(latitude: 25.03995, longitude: 121.55), heading: 180,
            previous: from, maximumTravel: 80, travelDirection: 1)!
        XCTAssertEqual(match.segment, 3)
    }

    func testStationaryGPSNoiseUpdatesTimestampWithoutMovingTheBus() throws {
        let metadata = try metadata()
        let first = try FeedDecoder.vehicles(feed([row(["Speed": 0])]), metadata: metadata, previous: [], now: now).vehicles
        let second = try FeedDecoder.vehicles(feed([row(["Speed": 0, "Azimuth": 270, "Longitude": 121.55016,
            "DataTime": "2026-10-02 10:15:30"])]), metadata: metadata, previous: first, now: now).vehicles
        XCTAssertEqual(second[0].coordinate, first[0].coordinate)
        XCTAssertNotEqual(second[0].rawCoordinate, first[0].rawCoordinate)
        XCTAssertEqual(second[0].observedAt, now)
        XCTAssertEqual(second[0].path.count, 1)
        var motion = VehicleMotion()
        motion.ingest(first, time: 0, now: now); motion.ingest(second, time: 15, now: now)
        XCTAssertEqual(motion.pose(id: "physical-1", time: 17, now: now)?.heading, first[0].heading)
        XCTAssertFalse(motion.isAnimating(time: 17, now: now))
    }

    func testMissingHeadingIsNotInventedAsNorthAtACrossing() throws {
        var metadata = try metadata()
        metadata.lines["sub:10"] = RouteLine(coordinates: [Coordinate(latitude: 25.04, longitude: 121.55),
            Coordinate(latitude: 25.04, longitude: 121.552), Coordinate(latitude: 25.042, longitude: 121.552),
            Coordinate(latitude: 25.042, longitude: 121.551), Coordinate(latitude: 25.039, longitude: 121.551)])
        let vehicles = try FeedDecoder.vehicles(feed([row(["Azimuth": NSNull(), "Longitude": 121.55093])]),
            metadata: metadata, previous: [], now: now).vehicles
        XCTAssertFalse(vehicles[0].hasHeading)
        XCTAssertEqual(vehicles[0].roadMatch?.segment, 0)
        XCTAssertEqual(vehicles[0].heading, 90, accuracy: 0.01)
    }

    func testUnknownSpeedDoesNotBecomeAStationaryFixOrAFalseZeroSpeedLabel() throws {
        let metadata = try metadata()
        let first = try FeedDecoder.vehicles(feed([row(["Speed": 0])]), metadata: metadata, previous: [], now: now).vehicles
        for unknown in [NSNull() as Any, "invalid", 180] {
            let second = try FeedDecoder.vehicles(feed([row(["Speed": unknown, "Longitude": 121.55016,
                "DataTime": "2026-10-02 10:15:30"])]), metadata: metadata, previous: first, now: now).vehicles[0]
            XCTAssertFalse(second.hasSpeed)
            XCTAssertEqual(second.speedLabel, "速度未提供")
            XCTAssertGreaterThan(second.coordinate.distance(to: first[0].coordinate), 5)
        }
    }

    func testOlderGPSCannotRewindDetailsOrSwitchThePhysicalBusToAnOldRoute() throws {
        let metadata = try metadata()
        let first = try FeedDecoder.vehicles(feed([row(["DataTime": "2026-10-02 10:15:30"])]), metadata: metadata, previous: [], now: now).vehicles
        let older = try FeedDecoder.vehicles(feed([row(["RouteID": 999, "GoBack": "1", "Longitude": 121.559,
            "DataTime": "2026-10-02 10:15:15"])]), metadata: metadata, previous: first, now: now).vehicles
        XCTAssertEqual(older[0].observedAt, now)
        XCTAssertEqual(older[0].routeID, "10")
        XCTAssertEqual(older[0].coordinate, first[0].coordinate)
    }

    func testTeleportIsQuarantinedAndTwoCoherentFixesReacquireWithoutDrivingAcrossBlocks() throws {
        let metadata = try metadata()
        let first = try FeedDecoder.vehicles(feed([row()]), metadata: metadata, previous: [], now: now).vehicles
        let rejected = try FeedDecoder.vehicles(feed([row(["Longitude": 121.59, "Latitude": 25.05,
            "DataTime": "2026-10-02 10:15:30"])]), metadata: metadata, previous: first, now: now).vehicles
        XCTAssertEqual(rejected[0].coordinate, first[0].coordinate)
        XCTAssertEqual(rejected[0].observedAt, first[0].observedAt)
        XCTAssertEqual(rejected[0].trackingIssue, .rejected)
        let recovered = try FeedDecoder.vehicles(feed([row(["Longitude": 121.5901, "Latitude": 25.05,
            "DataTime": "2026-10-02 10:15:45"])]), metadata: metadata, previous: rejected, now: now.addingTimeInterval(15)).vehicles
        XCTAssertNil(recovered[0].trackingIssue)
        XCTAssertEqual(recovered[0].rawCoordinate.longitude, 121.5901)
        XCTAssertEqual(recovered[0].path.count, 1)
    }

    func testMissingPacketRetainsOriginalAgeButAnExplicitEndAndExpiredGraceRemoveTheBus() throws {
        let metadata = try metadata()
        let first = try FeedDecoder.vehicles(feed([row()]), metadata: metadata, previous: [], now: now).vehicles
        let other = row(["CarID": "other", "BusID": "DEF-456", "DataTime": "2026-10-02 10:15:30"])
        let missing = try FeedDecoder.vehicles(feed([other]), metadata: metadata, previous: first, now: now).vehicles
        let retained = missing.first { $0.id == "physical-1" }!
        XCTAssertEqual(retained.observedAt, first[0].observedAt)
        XCTAssertEqual(retained.trackingIssue, .missing)
        XCTAssertFalse(retained.hasReliablePosition(at: now))
        let ended = try FeedDecoder.vehicles(feed([other, row(["DutyStatus": "2", "Longitude": 0,
            "DataTime": "2026-10-02 10:15:30"])]), metadata: metadata, previous: first, now: now).vehicles
        XCTAssertEqual(ended.map(\.id), ["other"])
        let expired = try FeedDecoder.vehicles(feed([other]), metadata: metadata, previous: missing,
                                               now: now.addingTimeInterval(80)).vehicles
        XCTAssertFalse(expired.contains { $0.id == "physical-1" })
    }

    private func progressMetadata() -> TransitMetadata {
        var metadata = TransitMetadata()
        let route = BusRoute(id: "10", parentID: "100", name: "284", variantName: "284", departure: "西", destination: "東")
        metadata.routes["10"] = route; metadata.parents["100"] = route
        metadata.lines["sub:10"] = RouteLine(coordinates: [Coordinate(latitude: 25.04, longitude: 121.55),
            Coordinate(latitude: 25.04, longitude: 121.56), Coordinate(latitude: 25.04015, longitude: 121.56),
            Coordinate(latitude: 25.04015, longitude: 121.55)])
        for direction in ["0", "1"] {
            for index in 0..<3 {
                let id = "\(direction)-\(index)"
                let coordinate = Coordinate(latitude: direction == "0" ? 25.04 : 25.04015,
                    longitude: direction == "0" ? 121.551 + Double(index) * 0.003 : 121.557 - Double(index) * 0.003)
                metadata.stops[id] = BusStop(id: id, routeID: "100", stationID: id, name: "站\(index)",
                    direction: direction, sequence: index + 1, coordinate: coordinate)
                metadata.stations[id] = Station(id: id, name: "站\(index)", coordinate: coordinate,
                    address: "", bearing: direction == "0" ? "E" : "W", stopIDs: [id])
            }
        }
        metadata.rebuildJourneys()
        return metadata
    }

    func testOrderedStopsDisambiguateTwoDirectionsAndVehicleProgress() {
        let metadata = progressMetadata()
        let outbound = metadata.journey(routeID: "10", direction: "0")!
        let inbound = metadata.journey(routeID: "10", direction: "1")!
        XCTAssertTrue(outbound.anchors.allSatisfy { $0.match.segment == 0 })
        XCTAssertTrue(inbound.anchors.allSatisfy { $0.match.segment == 2 })
        let bus = VehicleTracker.accept(movingBus([Coordinate(latitude: 25.04002, longitude: 121.553)], observedAt: now),
                                       previous: nil, metadata: metadata, now: now)
        XCTAssertTrue(bus.aligned)
        let ahead = outbound.upcoming(vehicle: bus, at: now)
        XCTAssertEqual(ahead.map { $0.stop.id }, ["0-1", "0-2"])
        XCTAssertEqual(ahead[0].distance, 100.8, accuracy: 2)
        XCTAssertLessThan(outbound.progress(stopID: "0-0", vehicle: bus, at: now)!.distance, 0)
        XCTAssertTrue(outbound.upcoming(vehicle: bus, at: now.addingTimeInterval(121)).isEmpty)
    }

    func testApproachingVehiclesExcludePassedStopsAndDoNotUseUncertainFixes() {
        let metadata = progressMetadata()
        var approaching = VehicleTracker.accept(movingBus([Coordinate(latitude: 25.04, longitude: 121.553)], observedAt: now),
                                                previous: nil, metadata: metadata, now: now)
        let passed = VehicleTracker.accept(movingBus([Coordinate(latitude: 25.04, longitude: 121.5545)], observedAt: now),
                                           previous: nil, metadata: metadata, now: now)
        let station = metadata.stations["0-1"]!
        let rows = StationArrival.rows(station: station, metadata: metadata,
            snapshot: TransitSnapshot(vehicles: [passed, approaching]), now: now)
        XCTAssertEqual(rows[0].approaches.count, 1)
        XCTAssertEqual(rows[0].approaches[0].alongDistance!, 100.8, accuracy: 2)
        approaching.trackingIssue = .missing
        XCTAssertTrue(StationArrival.rows(station: station, metadata: metadata,
            snapshot: TransitSnapshot(vehicles: [approaching]), now: now)[0].approaches.isEmpty)
        XCTAssertNil(rows[0].estimateSeconds)
    }

    func testNoStopProgressIsInventedWhenTheShapeOrStopOrderIsUnusable() {
        let a = Coordinate(latitude: 25.04, longitude: 121.55)
        let stop = BusStop(id: "1", routeID: "100", stationID: "1", name: "站", direction: "0", sequence: 1, coordinate: a)
        XCTAssertNil(RouteJourney.build(stops: [stop], line: RouteLine(coordinates: [a]), stations: [:]))
        var metadata = progressMetadata()
        metadata.lines = [:]; metadata.rebuildJourneys()
        let bus = VehicleTracker.accept(movingBus([a], observedAt: now), previous: nil, metadata: metadata, now: now)
        XCTAssertFalse(bus.aligned)
        XCTAssertNil(metadata.journey(routeID: "10", direction: "0"))
        XCTAssertEqual(bus.coordinate, a)
    }
}
