import XCTest
@testable import TransitCore

final class NavigationGuidanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func source() -> (TransitMetadata, TransitRide) {
        var metadata = TransitMetadata()
        let route = BusRoute(id: "branch", parentID: "main", name: "287", variantName: "287區間",
                             departure: "起點", destination: "終點")
        metadata.routes[route.id] = route
        let line = RouteLine(coordinates: (0...6).map { Coordinate(latitude: 25.08, longitude: 121.59 + Double($0) * 0.002) })
        metadata.lines["sub:branch"] = line
        var stops: [BusStop] = []
        for index in 0...6 {
            let stop = BusStop(id: "stop-\(index)", routeID: "main", stationID: "station-\(index)",
                               name: "站\(index)", direction: "0", sequence: index,
                               coordinate: line.coordinates[index])
            stops.append(stop)
            metadata.stops[stop.id] = stop
            metadata.paths[route.id, default: []].append(StopReference(stopID: stop.id, sequence: index))
            metadata.stations[stop.stationID] = Station(id: stop.stationID, name: stop.name, coordinate: stop.coordinate,
                                                       address: "道路同側", bearing: "E", stopIDs: [stop.id])
        }
        metadata.rebuildJourneys()
        return (metadata, TransitRide(route: route, direction: "0", stops: Array(stops[4...6]),
                                      coordinates: Array(line.coordinates[4...6])))
    }

    private func bus(_ id: String, longitude: Double, metadata: TransitMetadata, age: Double = 0,
                     route: String = "branch", direction: String = "0", speed: Double = 25) -> BusVehicle {
        let point = Coordinate(latitude: 25.08, longitude: longitude)
        let vehicle = BusVehicle(id: id, plate: id, routeID: route, parentRouteID: "main", routeName: "287",
                                 direction: direction, destination: "終點", coordinate: point, rawCoordinate: point,
                                 heading: 90, speed: speed, observedAt: now.addingTimeInterval(-age), status: "0", lowFloor: true, provider: nil)
        return VehicleTracker.accept(vehicle, previous: nil, metadata: metadata, now: now)
    }

    func testNeihuMetroAliasesRankBeforeCloserHospitalMatchesAndKeepDirections() {
        var metadata = TransitMetadata()
        let names = ["三總內湖站", "三總內湖站(急診部)", "三總內湖站", "捷運內湖站", "捷運內湖站", "捷運內湖站(內湖)"]
        for (index, name) in names.enumerated() {
            metadata.stations[String(index)] = Station(id: String(index), name: name,
                coordinate: Coordinate(latitude: 25.04 + Double(index) * 0.001, longitude: 121.55),
                address: "道路\(index)", bearing: index % 2 == 0 ? "N" : "S", stopIDs: [])
        }
        for query in ["內湖站", "內湖", "内湖站", "  內湖 站  "] {
            let results = StationSearch.search(query, metadata: metadata, near: .taipei, limit: 4)
            XCTAssertEqual(results.count, 4)
            XCTAssertTrue(results.prefix(3).allSatisfy { $0.name.hasPrefix("捷運內湖站") })
            XCTAssertEqual(Set(results.prefix(3).map(\.id)), Set(["3", "4", "5"]))
        }
        XCTAssertEqual(StationSearch.search("三總內湖站", metadata: metadata, near: .taipei).first?.name, "三總內湖站")
    }

    func testSearchRetainsOfficialAlternateNamesEnglishAndTaipeiSpelling() {
        var metadata = TransitMetadata()
        var station = Station(id: "one", name: "捷運內湖站", coordinate: .taipei, address: "成功路", bearing: "N", stopIDs: [])
        station.searchNames = ["MRT Neihu Sta."]
        metadata.stations[station.id] = station
        metadata.stations["taipei"] = Station(id: "taipei", name: "臺北車站(忠孝)", coordinate: .taipei, address: "", bearing: "W", stopIDs: [])
        XCTAssertEqual(StationSearch.search("ＮＥＩＨＵ", metadata: metadata, near: .taipei).first?.id, "one")
        XCTAssertEqual(StationSearch.search("台北車站", metadata: metadata, near: .taipei).first?.id, "taipei")
        XCTAssertEqual(StationSearch.placeQueries("內湖站").first, "捷運內湖站")
        XCTAssertEqual(StationSearch.placeQueries("北車").first, "臺北車站")
        XCTAssertEqual(StationSearch.placeQueries("臺北車站"), ["臺北車站"])
        XCTAssertTrue(StationSearch.search("不存在的地方", metadata: metadata, near: .taipei).isEmpty)
    }

    func testBoardingCandidatesExcludePassedOppositeBranchExpiredAndUncertainVehicles() {
        let (metadata, ride) = source()
        let near = bus("near", longitude: 121.597, metadata: metadata)
        let far = bus("far", longitude: 121.592, metadata: metadata)
        var uncertain = bus("uncertain", longitude: 121.596, metadata: metadata); uncertain.trackingIssue = .missing
        var rejected = bus("rejected", longitude: 121.596, metadata: metadata); rejected.trackingIssue = .rejected
        let snapshot = TransitSnapshot(vehicles: [far, bus("passed", longitude: 121.599, metadata: metadata),
            bus("other-branch", longitude: 121.597, metadata: metadata, route: "other"),
            bus("opposite", longitude: 121.597, metadata: metadata, direction: "1"),
            bus("stale", longitude: 121.597, metadata: metadata, age: 121), uncertain, near, rejected],
            estimates: EstimateFeed(seconds: ["main:stop-4": 180], updatedAt: now))
        let guide = BoardingGuide(ride: ride, metadata: metadata, snapshot: snapshot, at: now)
        XCTAssertEqual(guide.approaches.map(\.id), ["near", "far"])
        XCTAssertEqual(guide.arrivalLabel, "約 3 分鐘到上車站")
        XCTAssertEqual(guide.station?.bearingLabel, "東向")
    }

    func testEveryVehicleCanBeTrackedSeparatelyAndOfficialETAIsNeverAssignedToItsPlate() {
        let (metadata, ride) = source()
        let vehicles = [bus("near", longitude: 121.597, metadata: metadata), bus("far", longitude: 121.592, metadata: metadata)]
        var forecast = VehicleArrivalForecast(); forecast.ingest(vehicles, metadata: metadata, at: now)
        let approaches = BoardingGuide(ride: ride, metadata: metadata, snapshot: TransitSnapshot(vehicles: vehicles), at: now).approaches
        let first = forecast.estimate(approaches[0], ride: ride, metadata: metadata, at: now)
        let second = forecast.estimate(approaches[1], ride: ride, metadata: metadata, at: now)
        guard case .minutes(let nearLow, let nearHigh) = first, case .minutes(let farLow, let farHigh) = second else {
            return XCTFail("Both received moving vehicles should have individual estimates")
        }
        XCTAssertGreaterThanOrEqual(nearHigh, nearLow)
        XCTAssertGreaterThan(farLow, nearLow); XCTAssertGreaterThan(farHigh, nearHigh)
        for seconds in [60, 900, -3] {
            let guide = BoardingGuide(ride: ride, metadata: metadata,
                snapshot: TransitSnapshot(vehicles: vehicles, estimates: EstimateFeed(seconds: ["main:stop-4": seconds], updatedAt: now)), at: now)
            XCTAssertEqual(forecast.estimate(guide.approaches[0], ride: ride, metadata: metadata, at: now), first)
        }
    }

    func testStaleMissingSpeedUnmatchedGPSAndPassedStopHaveNoFabricatedTime() {
        let (metadata, ride) = source()
        let forecast = VehicleArrivalForecast()
        var unknownSpeed = bus("unknown", longitude: 121.595, metadata: metadata); unknownSpeed.hasSpeed = false
        var unmatched = bus("unmatched", longitude: 121.595, metadata: metadata); unmatched.aligned = false
        for vehicle in [unknownSpeed, unmatched, bus("stopped", longitude: 121.595, metadata: metadata, speed: 0),
                        bus("stale", longitude: 121.595, metadata: metadata, age: 121),
                        bus("passed", longitude: 121.599, metadata: metadata)] {
            let approach = VehicleApproach(vehicle: vehicle, alongDistance: 300, directDistance: 300)
            XCTAssertEqual(forecast.estimate(approach, ride: ride, metadata: metadata, at: now), .unavailable)
        }
        let near = bus("at-stop", longitude: 121.598, metadata: metadata, speed: 0)
        XCTAssertEqual(forecast.estimate(VehicleApproach(vehicle: near, alongDistance: 0, directDistance: 0),
                                       ride: ride, metadata: metadata, at: now), .nearStop)
    }

    func testReceivedMovementCanEstimateAStoppedVehicleButDuplicateSnapshotsCannotInventMovement() {
        let (metadata, ride) = source()
        let first = bus("one", longitude: 121.593, metadata: metadata, age: 30, speed: 0)
        let second = bus("one", longitude: 121.595, metadata: metadata, speed: 0)
        var forecast = VehicleArrivalForecast()
        forecast.ingest([first], metadata: metadata, at: now)
        forecast.ingest([first], metadata: metadata, at: now)
        XCTAssertEqual(forecast.estimate(VehicleApproach(vehicle: first, alongDistance: 500, directDistance: 500),
                                       ride: ride, metadata: metadata, at: now), .unavailable)
        forecast.ingest([second], metadata: metadata, at: now)
        let approach = VehicleApproach(vehicle: second, alongDistance: 300, directDistance: 300)
        guard case .minutes = forecast.estimate(approach, ride: ride, metadata: metadata, at: now) else {
            return XCTFail("Use genuine observed road progress even while the latest report is stopped")
        }
        forecast.ingest([bus("one", longitude: 121.595, metadata: metadata, route: "different", speed: 0)], metadata: metadata, at: now)
        XCTAssertEqual(forecast.estimate(approach, ride: ride, metadata: metadata, at: now), .unavailable)
    }

    func testOfficialEstimateFailuresAndAgeStayVisibleAsUnavailable() {
        let (metadata, ride) = source()
        for estimates in [EstimateFeed(), EstimateFeed(seconds: ["main:stop-4": 0], updatedAt: now.addingTimeInterval(-121)),
                          EstimateFeed(seconds: ["main:stop-4": 120], updatedAt: now, error: "offline")] {
            let guide = BoardingGuide(ride: ride, metadata: metadata, snapshot: TransitSnapshot(estimates: estimates), at: now)
            XCTAssertEqual(guide.arrivalLabel, "目前沒有到站預估"); XCTAssertNil(guide.estimateUpdatedAt)
        }
    }

    func testLiveOfficialNeihuQueryFindsMetroPlatformsBeforeHospitalStops() throws {
        guard let directory = ProcessInfo.processInfo.environment["BUS_LIVE_FEEDS_DIRECTORY"] else { throw XCTSkip("Live feeds are checked during native preview capture") }
        let root = URL(fileURLWithPath: directory)
        var feeds: [String: Data] = [:]
        for name in ["GetRoute", "GetStop", "GetPathDetail", "GetBusShape"] { feeds[name] = try Data(contentsOf: root.appendingPathComponent(name + ".json")) }
        let metadata = try FeedDecoder.metadata(feeds: feeds)
        for query in ["內湖站", "內湖", "内湖站", "Neihu"] {
            let stations = StationSearch.search(query, metadata: metadata, near: .taipei, limit: 4)
            XCTAssertFalse(stations.isEmpty, "Missing \(query)")
            XCTAssertTrue(stations.allSatisfy { $0.name.hasPrefix("捷運內湖站") }, "Wrong \(query): \(stations.map(\.name))")
        }
    }
}
