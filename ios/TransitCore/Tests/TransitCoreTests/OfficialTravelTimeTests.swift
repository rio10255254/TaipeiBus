import XCTest
@testable import TransitCore

final class OfficialTravelTimeTests: XCTestCase {
    private struct Document: Decodable { let routes: [OfficialTravelTimes.Route] }
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func catalog(route: String = "family", subroute: String = "arbitrary-subroute", updated: String = "2026-10-05T05:26:38+08:00", seconds: [Int] = [30]) throws -> OfficialTravelTimes {
        let object: [String: Any] = ["schema": 1, "routes": [["route": route, "subroute": subroute, "direction": "1", "updated": updated, "edges": [["from", "to"]], "periods": [["weekday": 2, "startHour": 10, "endHour": 11, "seconds": seconds]]]]]
        return try OfficialTravelTimes(data: JSONSerialization.data(withJSONObject: object))
    }
    func testAllRouteIdentifiersUseTheirOwnDirectionDayHourAndStops() throws {
        let at = date("2026-10-06T10:15:00+08:00")
        let value = try catalog()
        XCTAssertEqual(value.seconds(route: "family", subroute: "arbitrary-subroute", direction: "1", from: "from", to: "to", travellingAt: at, observedAt: at), 30)
        for (family, subroute, direction, from, to) in [("another-family", "arbitrary-subroute", "1", "from", "to"), ("family", "another-subroute", "1", "from", "to"), ("family", "arbitrary-subroute", "0", "from", "to"), ("family", "arbitrary-subroute", "1", "to", "from")] {
            XCTAssertNil(value.seconds(route: family, subroute: subroute, direction: direction, from: from, to: to, travellingAt: at, observedAt: at))
        }
        XCTAssertNil(value.seconds(route: "family", subroute: "arbitrary-subroute", direction: "1", from: "from", to: "to", travellingAt: date("2026-10-06T11:15:00+08:00"), observedAt: at))
        XCTAssertNil(value.seconds(route: "family", subroute: "arbitrary-subroute", direction: "1", from: "from", to: "to", travellingAt: date("2026-10-07T10:15:00+08:00"), observedAt: at))
    }
    func testExpiredAndUnavailableSourceValuesAreNeverOfficialTimes() throws {
        let at = date("2026-10-06T10:15:00+08:00")
        for value in [try catalog(updated: "2026-08-01T05:26:38+08:00"), try catalog(seconds: [-1]), try catalog(seconds: [0]), try catalog(seconds: [4000])] {
            XCTAssertNil(value.seconds(route: "family", subroute: "arbitrary-subroute", direction: "1", from: "from", to: "to", travellingAt: at, observedAt: at))
        }
    }
    func testRecordedOfficial630EighteenSegmentsTotal1635Seconds() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Official630TimingEvidence", withExtension: "json"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let values = try XCTUnwrap(raw["stop_to_stop_seconds"] as? [Int])
        let edges = (23640..<23658).map { [String($0), String($0 + 1)] }
        let object: [String: Any] = ["schema": 1, "routes": [["route": "10861", "subroute": "160878", "direction": "1", "updated": raw["source_updated_at"]!, "edges": edges, "periods": [["weekday": 2, "startHour": 10, "endHour": 11, "seconds": values]]]]]
        let profile = try OfficialTravelTimes(data: JSONSerialization.data(withJSONObject: object))
        let at = date("2026-10-06T10:15:00+08:00")
        let total = try edges.reduce(0.0) { sum, edge in
            sum + (try XCTUnwrap(profile.seconds(route: "10861", subroute: "160878", direction: "1", from: edge[0], to: edge[1], travellingAt: at, observedAt: at)))
        }
        XCTAssertEqual(total, 1635); XCTAssertEqual(total / 60, 27.25)
    }

    func testDownloadedCatalogMatchesEveryRecordedNeihuToDunhuaSegment() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "OfficialTravelProfilesRecorded", withExtension: "json"))
        let value = try OfficialTravelTimes(data: Data(contentsOf: url))
        XCTAssertEqual(value.patternCount, 4)
        let at = date("2026-10-06T10:15:00+08:00")
        let total = try (23640..<23658).reduce(0.0) { sum, stop in
            sum + (try XCTUnwrap(value.seconds(route: "10861", subroute: "160878", direction: "1",
                from: String(stop), to: String(stop + 1), travellingAt: at, observedAt: at)))
        }
        XCTAssertEqual(total, 1635)
    }

    func testSharedEstimatorUsesOfficialTimeWithoutAddingDwellAgain() throws {
        let pair = RidingTrafficTests().source()
        var metadata = pair.0
        let ride = pair.1
        let periods: [[String: Any]] = [["weekday": 2, "startHour": 10, "endHour": 11, "seconds": [100, 100, 100, 100]],
                                       ["weekday": 2, "startHour": 11, "endHour": 12, "seconds": [300, 300, 300, 300]]]
        let object: [String: Any] = ["schema": 1, "routes": [["route": "family", "subroute": "observed", "direction": "0",
            "updated": "2026-10-05T05:26:38.100+08:00", "edges": (0..<4).map { ["s\($0)", "s\($0 + 1)"] }, "periods": periods]]]
        metadata.officialTravelTimes = try OfficialTravelTimes(data: JSONSerialization.data(withJSONObject: object))
        let now = date("2026-10-06T10:50:00+08:00"), forecast = VehicleArrivalForecast()
        let estimate = forecast.ridingEstimate(ride, metadata: metadata, at: now)
        XCTAssertEqual(estimate.seconds, 400); XCTAssertEqual(estimate.evidence, .officialProfile)
        // The walk and official departure cross into 11:00 before boarding.
        let trip = TransitTrip(rides: [ride], accessDistance: 100, egressDistance: 0, transferDistance: 0,
                               score: 0, rideSeconds: [400])
        let values = forecast.plannedRidingEstimates(trip, metadata: metadata,
            estimates: EstimateFeed(seconds: ["family:s0": 900], updatedAt: now), walkingDurations: [180, 0], at: now)
        XCTAssertEqual(values.first?.seconds, 1200)
        XCTAssertEqual(values.first?.evidence, .officialProfile)
        // GPS freshness is evaluated now, not against the later boarding clock.
        XCTAssertEqual(forecast.ridingEstimate(ride, metadata: metadata, at: now,
            travellingAt: date("2026-10-06T11:15:00+08:00")).seconds, 1200)
    }

    func testCandidateSearchUsesOfficialTimesBeforeDiscardingRoutes() throws {
        let source = RidingTrafficTests().source()
        var metadata = source.0
        let first = source.1.stops.first!, last = source.1.stops.last!
        for stop in source.1.stops {
            metadata.stations[stop.stationID] = Station(id: stop.stationID, name: stop.name,
                coordinate: stop.coordinate, address: "", bearing: "E", stopIDs: [stop.id])
        }
        let competitor = BusRoute(id: "shorter-road", parentID: "other-family", name: "另一條路線",
                                  variantName: "", departure: "起點", destination: "終點")
        metadata.routes[competitor.id] = competitor
        let a = BusStop(id: "a", routeID: competitor.parentID, stationID: first.stationID, name: first.name,
                        direction: "0", sequence: 0, coordinate: first.coordinate)
        let b = BusStop(id: "b", routeID: competitor.parentID, stationID: last.stationID, name: last.name,
                        direction: "0", sequence: 1, coordinate: last.coordinate)
        metadata.stops[a.id] = a; metadata.stops[b.id] = b
        metadata.paths[competitor.id] = [StopReference(stopID: a.id, sequence: 0), StopReference(stopID: b.id, sequence: 1)]
        metadata.lines["sub:" + competitor.id] = RouteLine(coordinates: [a.coordinate, b.coordinate])
        metadata.rebuildJourneys()
        let routes: [[String: Any]] = [
            ["route": "family", "subroute": "observed", "direction": "0", "updated": "2026-10-05T05:26:38+08:00",
             "edges": (0..<4).map { ["s\($0)", "s\($0 + 1)"] },
             "periods": [["weekday": 2, "startHour": 10, "endHour": 11, "seconds": [50, 50, 50, 50]]]],
            ["route": "other-family", "subroute": "shorter-road", "direction": "0", "updated": "2026-10-05T05:26:38+08:00",
             "edges": [["a", "b"]], "periods": [["weekday": 2, "startHour": 10, "endHour": 11, "seconds": [900]]]]]
        metadata.officialTravelTimes = try OfficialTravelTimes(data: JSONSerialization.data(withJSONObject: ["schema": 1, "routes": routes]))
        let result = TripPlanner(metadata: metadata).plan(from: first.coordinate, to: last.coordinate,
            maximumWalk: 30, limit: 1, at: date("2026-10-06T10:15:00+08:00"))
        XCTAssertEqual(result.first?.rides.first?.route.id, "observed")
        XCTAssertEqual(result.first?.rideSeconds.first, 200)
    }

    func testLiveFullCatalogReportsCoverageAcrossEveryPublishedRoute() throws {
        guard let directory = ProcessInfo.processInfo.environment["BUS_LIVE_FEEDS_DIRECTORY"],
              let catalogPath = ProcessInfo.processInfo.environment["BUS_OFFICIAL_TRAVEL_TIMES"] else {
            throw XCTSkip("Explicit full official-data coverage audit only")
        }
        let root = URL(fileURLWithPath: directory), data = try Data(contentsOf: URL(fileURLWithPath: catalogPath))
        var feeds: [String: Data] = [:]
        for name in ["GetRoute", "GetStop", "GetPathDetail", "GetBusShape"] {
            feeds[name] = try Data(contentsOf: root.appendingPathComponent(name + ".json"))
        }
        var metadata = try FeedDecoder.metadata(feeds: feeds)
        metadata.officialTravelTimes = try OfficialTravelTimes(data: data)
        let document = try JSONDecoder().decode(Document.self, from: data), at = Date()
        XCTAssertGreaterThan(metadata.officialTravelTimes.patternCount, 100)
        XCTAssertGreaterThan(document.routes.count, 100)
        var complete = 0, partial = 0, absent = 0, edges = 0, available = 0
        var records: [[String: Any]] = []
        for group in metadata.routeCatalog.groups {
            var groupAvailable = 0, groupEdges = 0
            for route in group.variants {
                for direction in ["0", "1", "2"] {
                    let stops = metadata.orderedStops(routeID: route.id, direction: direction)
                    guard stops.count >= 2 else { continue }
                    var matches = 0
                    for index in stops.indices.dropFirst() {
                        if let value = metadata.officialTravelTimes.seconds(route: route.parentID, subroute: route.id,
                            direction: direction, from: stops[index - 1].id, to: stops[index].id, travellingAt: at, observedAt: at) {
                            XCTAssertTrue((1...1800).contains(value)); matches += 1
                        }
                    }
                    groupAvailable += matches; groupEdges += stops.count - 1
                    if matches == stops.count - 1 { complete += 1 }
                    else if matches > 0 { partial += 1 }
                    else { absent += 1 }
                }
            }
            edges += groupEdges; available += groupAvailable
            records.append(["route": group.id, "name": group.route.name, "official_edges": groupAvailable,
                            "published_edges": groupEdges])
        }
        XCTAssertGreaterThan(available, 100)
        let result: [String: Any] = ["source_patterns": document.routes.count, "loaded_patterns": metadata.officialTravelTimes.patternCount,
            "published_route_families": records.count, "complete_patterns_now": complete, "partial_patterns_now": partial,
            "missing_patterns_now": absent, "official_edges_now": available, "published_edges": edges, "routes": records]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("official-travel-time-coverage.json"))
        print("Official data coverage: \(records.count) route families, \(complete) complete / \(partial) partial / \(absent) missing patterns at the audit hour; \(available) / \(edges) matching stop pairs.")
    }
}
