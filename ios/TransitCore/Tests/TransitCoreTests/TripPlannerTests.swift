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
    func testSpecialPurposeServicesRemainSearchableButAreNotCommuteShortcuts() {
        let source = metadata([("tourist", "臺北觀光巴士紅線", "0", [a, c]),
            ("special", "懷恩專車S31", "0", [a, c]), ("city", "一般公車", "0", [a, b, c])])
        XCTAssertFalse(source.routeCatalog.search("觀光巴士").isEmpty)
        XCTAssertFalse(source.routeCatalog.search("懷恩").isEmpty)
        let trips = TripPlanner(metadata: source).plan(from: a, to: c, maximumWalk: 100)
        XCTAssertEqual(trips.count, 1)
        XCTAssertEqual(trips.first?.rides.first?.route.id, "city")
    }

    func testDenseNearbyPlatformsDoNotHideADirectBoardingStop() throws {
        let crowded = (0..<30).map { index in
            ("other\(index)", "other\(index)", "0", [Coordinate(latitude: a.latitude + Double(index) * 0.00001, longitude: a.longitude), b])
        }
        let directStop = Coordinate(latitude: a.latitude + 0.003, longitude: a.longitude)
        let source = metadata(crowded + [("direct", "direct", "0", [directStop, d])])
        let trips = TripPlanner(metadata: source).plan(from: a, to: d, maximumWalk: 500)
        XCTAssertTrue(trips.contains { $0.rides.count == 1 && $0.rides[0].route.id == "direct" })
    }

    func testDirectAlternativeSurvivesFasterTransferCandidates() {
        let detour = Coordinate(latitude: 25.17, longitude: 121.68)
        let source = metadata([("direct", "direct", "0", [a, detour, c]), ("first", "first", "0", [a, b])] +
            (0..<4).map { ("connection\($0)", "connection\($0)", "0", [b, c]) })
        let planner = TripPlanner(metadata: source)
        let trips = planner.plan(from: a, to: c, maximumWalk: 100, limit: 3)
        XCTAssertEqual(trips.count, 3)
        XCTAssertEqual(trips.first?.transfers, 1, "A huge direct detour should not be preferred")
        XCTAssertTrue(trips.contains { $0.transfers == 0 })
        let all = planner.plan(from: a, to: c, maximumWalk: 100, limit: 18)
        let ranked = TripRanking.recommended(all, estimates: EstimateFeed(), at: Date(), limit: 3)
        XCTAssertEqual(ranked.first?.transfers, 1)
        XCTAssertFalse(ranked.contains { $0.transfers == 0 }, "Do not force an extreme direct detour into the useful shortlist")
    }

    func testRankingUsesRoadGeometryAndVerifiedWalkingTime() throws {
        var source = metadata([("direct", "direct", "0", [a, c])])
        source.lines["sub:direct"] = RouteLine(coordinates: [a, d, c])
        source.rebuildJourneys()
        let trip = try XCTUnwrap(TripPlanner(metadata: source).plan(from: a, to: c, maximumWalk: 100).first)
        XCTAssertGreaterThan(trip.rideSeconds[0], a.distance(to: c) / 4.5 + 20)
        let date = Date()
        let estimates = EstimateFeed(seconds: ["direct:direct:0": 120], updatedAt: date)
        let quickWalk = TripRanking.assessment(trip, estimates: estimates, at: date, walkingDurations: [30, 30])
        let actualDetour = TripRanking.assessment(trip, estimates: estimates, at: date, walkingDurations: [600, 30])
        XCTAssertFalse(quickWalk.missedFirstArrival)
        XCTAssertTrue(actualDetour.missedFirstArrival)
        XCTAssertGreaterThan(actualDetour.score, quickWalk.score)
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
                            Coordinate(latitude: 25.0421, longitude: 121.5083),
                            Coordinate(latitude: 25.0838, longitude: 121.5942),
                            Coordinate(latitude: 25.0174, longitude: 121.5404),
                            Coordinate(latitude: 25.0496, longitude: 121.5779)]
        for destination in destinations {
            let trips = planner.plan(from: .taipei, to: destination, maximumWalk: 1_200)
            XCTAssertFalse(trips.isEmpty, "No public-bus trip to \(destination)")
            print("Destination comparison \(destination): " + trips.prefix(3).map { trip in
                trip.rides.map { $0.route.name }.joined(separator: " → ") +
                    " [\(trip.transfers) transfer, \(Int(trip.accessDistance + trip.egressDistance + trip.transferDistance)) m access]"
            }.joined(separator: "; "))
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
        for name in ["藍27", "南京幹線", "307"] {
            let route = try XCTUnwrap(metadata.routeCatalog.search(name).first?.route)
            let stops = metadata.orderedStops(routeID: route.id, direction: "0")
            let first = try XCTUnwrap(stops.first), last = try XCTUnwrap(stops.last)
            let trips = planner.plan(from: first.coordinate, to: last.coordinate, maximumWalk: 150, limit: 3)
            XCTAssertTrue(trips.contains { $0.transfers == 0 }, "An official direct route must remain visible: \(name)")
        }
        print("Official destination routing: \(destinations.count) locations verified in \(Date().timeIntervalSince(start)) seconds.")
    }
}
