import XCTest
@testable import TransitCore

final class TripPlannerTests: XCTestCase {
    private let a = Coordinate(latitude: 25.04, longitude: 121.54)
    private let b = Coordinate(latitude: 25.04, longitude: 121.56)
    private let c = Coordinate(latitude: 25.04, longitude: 121.58)
    private let d = Coordinate(latitude: 25.06, longitude: 121.58)

    private func metadata(_ rows: [(String, String, String, [Coordinate])]) -> TransitMetadata {
        var result = TransitMetadata()
        for (id, parent, direction, points) in rows {
            result.routes[id] = BusRoute(id: id, parentID: parent, name: parent, variantName: id,
                                        departure: "起點", destination: "終點")
            for (index, point) in points.enumerated() {
                let stationID = "\(point.latitude):\(point.longitude)"
                let stop = BusStop(id: "\(id):\(index)", routeID: parent, stationID: stationID,
                                   name: "站\(index)", direction: direction, sequence: index, coordinate: point)
                result.stops[stop.id] = stop
                result.paths[id, default: []].append(StopReference(stopID: stop.id, sequence: index))
                result.stations[stationID] = Station(id: stationID, name: stationID, coordinate: point,
                                                    address: "", bearing: "E", stopIDs: [])
            }
        }
        result.rebuildRouteCatalog()
        return result
    }

    func testDirectTripUsesOnlyForwardStopsAndCorrectDirection() throws {
        let source = metadata([("go", "1", "0", [a,b,c]), ("back", "1", "1", [c,b,a])])
        let planner = TripPlanner(metadata: source)
        let outward = try XCTUnwrap(planner.plan(from: a, to: c, maximumWalk: 100).first)
        XCTAssertEqual(outward.rides.count, 1)
        XCTAssertEqual(outward.rides[0].route.id, "go")
        XCTAssertEqual(outward.rides[0].stopCount, 2)
        XCTAssertEqual(planner.plan(from: c, to: a, maximumWalk: 100).first?.rides[0].direction, "1")
    }

    func testSeparateBranchesCannotBecomeAFabricatedDirectRide() {
        let source = metadata([("one", "1", "0", [a,b]), ("two", "1", "0", [b,c])])
        XCTAssertTrue(TripPlanner(metadata: source).plan(from: a, to: c, maximumWalk: 100).isEmpty)
    }
    func testClosedRoutesCannotCrowdUsableTripsOutOfTheCandidateLimit() throws {
        let closed = (0..<24).map { ("closed\($0)", "closed\($0)", "0", [a, c]) }
        let source = metadata(closed + [("open", "open", "0", [a, b, c])])
        let date = Date()
        let unavailable = Dictionary(uniqueKeysWithValues: closed.map { ("\($0.1):\($0.0):0", -4) })
        let estimates = EstimateFeed(seconds: unavailable, updatedAt: date)
        let trips = TripPlanner(metadata: source).plan(from: a, to: c, maximumWalk: 100,
            limit: 3, estimates: estimates, at: date)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.rides.first?.route.id, "open")
        let unknown = TripPlanner(metadata: source).plan(from: a, to: c, maximumWalk: 100,
            limit: 3, estimates: estimates, at: date.addingTimeInterval(180))
        XCTAssertEqual(unknown.count, 3, "Expired arrival data must not declare routes closed")
    }

    func testOneTransferConnectsRealRideSegments() throws {
        let source = metadata([("one", "1", "0", [a,b]), ("two", "2", "0", [b,c,d])])
        let trip = try XCTUnwrap(TripPlanner(metadata: source).plan(from: a, to: d, maximumWalk: 100).first)
        XCTAssertEqual(trip.transfers, 1)
        XCTAssertEqual(trip.rides.map { $0.route.id }, ["one", "two"])
        XCTAssertEqual(trip.rides[0].alighting.stationID, trip.rides[1].boarding.stationID)
        XCTAssertEqual(trip.transferDistance, 0)
    }

    func testNearbyTransferPlatformsWorkButDistantPlatformsDoNot() {
        let near = Coordinate(latitude: b.latitude + 0.0008, longitude: b.longitude)
        let far = Coordinate(latitude: b.latitude + 0.004, longitude: b.longitude)
        let nearSource = metadata([("one", "1", "0", [a,b]), ("two", "2", "0", [near,c])])
        let farSource = metadata([("one", "1", "0", [a,b]), ("two", "2", "0", [far,c])])
        XCTAssertEqual(TripPlanner(metadata: nearSource).plan(from: a, to: c, maximumWalk: 100).first?.transfers, 1)
        XCTAssertTrue(TripPlanner(metadata: farSource).plan(from: a, to: c, maximumWalk: 100).isEmpty)
    }

    func testNearestUnusableStopDoesNotHideAReachableBoardingStop() throws {
        let accessible = Coordinate(latitude: a.latitude + 0.003, longitude: a.longitude)
        let source = metadata([("wrong", "9", "0", [a,b]), ("right", "1", "0", [accessible,d])])
        let trip = try XCTUnwrap(TripPlanner(metadata: source).plan(from: a, to: d, maximumWalk: 500).first)
        XCTAssertEqual(trip.rides[0].boarding.coordinate, accessible)
        XCTAssertEqual(trip.rides[0].route.id, "right")
        XCTAssertGreaterThan(trip.accessDistance, 300)
    }

    func testMissingGeometryDoesNotInventAWalkingOrBusPolyline() throws {
        let trip = try XCTUnwrap(TripPlanner(metadata: metadata([("go", "1", "0", [a,c])]))
            .plan(from: a, to: c, maximumWalk: 100).first)
        XCTAssertTrue(trip.rides[0].coordinates.isEmpty)
        XCTAssertEqual(trip.rides[0].stops.count, 2)
    }

    func testInvalidOriginAndUnreachableDestinationReturnNoTrip() {
        let planner = TripPlanner(metadata: metadata([("go", "1", "0", [a,b])]))
        XCTAssertTrue(planner.plan(from: Coordinate(latitude: 0, longitude: 0), to: b).isEmpty)
        XCTAssertTrue(planner.plan(from: a, to: d, maximumWalk: 100).isEmpty)
        XCTAssertTrue(planner.plan(from: a, to: b, limit: 0).isEmpty)
    }

    func testDuplicatePathsAndSourceOrderingProduceStableOptions() {
        let rows = [("go", "1", "0", [a,b,c]), ("duplicate", "1", "0", [a,b,c])]
        let first = TripPlanner(metadata: metadata(rows)).plan(from: a, to: c, maximumWalk: 100)
        let reversed = TripPlanner(metadata: metadata(Array(rows.reversed()))).plan(from: a, to: c, maximumWalk: 100)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.map(\.id), reversed.map(\.id))
    }

    func testLiveOfficialTripsPreserveBranchStopOrderAndTransferConnections() throws {
        guard let directory = ProcessInfo.processInfo.environment["BUS_LIVE_FEEDS_DIRECTORY"] else {
            throw XCTSkip("Live routing audit is enabled when capturing an iPhone preview.")
        }
        let root = URL(fileURLWithPath: directory)
        var feeds: [String: Data] = [:]
        for name in ["GetRoute", "GetStop", "GetPathDetail", "GetBusShape"] {
            feeds[name] = try Data(contentsOf: root.appendingPathComponent("\(name).json"))
        }
        let metadata = try FeedDecoder.metadata(feeds: feeds)
        let start = Date()
        let planner = TripPlanner(metadata: metadata)
        let destinations = [Coordinate(latitude: 25.0478, longitude: 121.5172),
                            Coordinate(latitude: 25.0339, longitude: 121.5645),
                            Coordinate(latitude: 25.0421, longitude: 121.5083)]
        for destination in destinations {
            let trips = planner.plan(from: .taipei, to: destination, maximumWalk: 1_200)
            XCTAssertFalse(trips.isEmpty, "No public-bus trip to \(destination)")
            for trip in trips {
                XCTAssertTrue((1...2).contains(trip.rides.count))
                XCTAssertLessThanOrEqual(trip.accessDistance, 1_200)
                XCTAssertLessThanOrEqual(trip.egressDistance, 1_200)
                XCTAssertLessThanOrEqual(trip.transferDistance, 220)
                for ride in trip.rides {
                    let stops = metadata.orderedStops(routeID: ride.route.id, direction: ride.direction)
                    let board = try XCTUnwrap(stops.firstIndex { $0.id == ride.boarding.id })
                    let alight = try XCTUnwrap(stops.firstIndex { $0.id == ride.alighting.id })
                    XCTAssertLessThan(board, alight)
                    XCTAssertEqual(ride.stops.map(\.id), Array(stops[board...alight]).map(\.id))
                }
            }
        }
        print("Official destination routing: \(destinations.count) locations verified in \(Date().timeIntervalSince(start)) seconds.")
    }
}
