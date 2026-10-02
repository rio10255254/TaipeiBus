import XCTest
@testable import TransitCore

final class RouteCatalogTests: XCTestCase {
    private func route(_ id: String, parent: String? = nil, name: String, variant: String? = nil) -> BusRoute {
        BusRoute(id: id, parentID: parent ?? id, name: name, variantName: variant ?? name,
                 departure: "臺北車站", destination: "陽明山")
    }

    func testCompleteCatalogRemainsBrowsableWithoutVehiclesOrResultLimit() {
        let routes = (1...416).map { route("\($0)", name: "\($0)") }
        let catalog = RouteCatalog(routes: routes)
        XCTAssertEqual(catalog.search("").count, 416)
        XCTAssertEqual(catalog.search("台北").count, 416)
        XCTAssertEqual(Set(catalog.search("").map(\.id)), Set(routes.map(\.parentID)))
        XCTAssertEqual(Array(catalog.search("").prefix(12)).map(\.name), (1...12).map(String.init))
        XCTAssertEqual(catalog.search("416").first?.name, "416")
    }

    func testNamesAliasesFullWidthAndBranchesFindTheCorrectSelection() {
        var red = route("10821", name: "紅5")
        red.englishName = "R5"
        red.aliasName = "劍潭陽明山"
        let branch = route("157609", parent: "10821", name: "紅5", variant: "紅5往劍潭經文大")
        let catalog = RouteCatalog(routes: [branch, red, route("52", name: "紅52")])
        XCTAssertEqual(catalog.search("  Ｒ５  ").first?.group.id, "10821")
        XCTAssertNil(catalog.search("紅5").first?.matchedVariant)
        XCTAssertEqual(catalog.search("劍潭陽明山").first?.group.id, "10821")
        XCTAssertEqual(catalog.search("紅5往劍潭經文大").first?.matchedVariant?.id, "157609")
        XCTAssertEqual(catalog.search("文大").first?.matchedVariant?.id, "157609")
        XCTAssertTrue(catalog.search("不存在的路線").isEmpty)
    }

    func testParentRepresentativeAndSearchOrderDoNotDependOnFeedOrder() {
        let rows = [route("20", parent: "10", name: "685", variant: "685經吉林"),
                    route("10", name: "685", variant: "685不經吉林"),
                    route("31", parent: "30", name: "307", variant: "307往撫遠街"),
                    route("32", parent: "30", name: "307", variant: "307往板橋"),
                    route("50", name: "685", variant: "685")]
        let forward = RouteCatalog(routes: rows), reversed = RouteCatalog(routes: Array(rows.reversed()))
        XCTAssertEqual(forward.groups.map { $0.route.id }, reversed.groups.map { $0.route.id })
        XCTAssertEqual(forward.search("685").map(\.id), reversed.search("685").map(\.id))
        XCTAssertEqual(forward.group(parentID: "10")?.route.id, "10")
        XCTAssertEqual(Set(forward.groups.flatMap(\.variants).map(\.id)), Set(rows.map(\.id)))
    }

    private func branchMetadata() -> TransitMetadata {
        var metadata = TransitMetadata()
        let go = route("157463", parent: "16111", name: "307", variant: "307莒光往撫遠街")
        let back = route("157462", parent: "16111", name: "307", variant: "307莒光往板橋前站")
        let detour = route("20", parent: "16111", name: "307", variant: "307繞駛")
        metadata.routes = Dictionary(uniqueKeysWithValues: [go, back, detour].map { ($0.id, $0) })
        let a = Coordinate(latitude: 25.04, longitude: 121.55)
        let b = Coordinate(latitude: 25.04, longitude: 121.551)
        let c = Coordinate(latitude: 25.041, longitude: 121.551)
        let stopRows = [BusStop(id: "1", routeID: "16111", stationID: "1", name: "起點", direction: "0", sequence: 1, coordinate: a),
                        BusStop(id: "2", routeID: "16111", stationID: "2", name: "終點", direction: "0", sequence: 2, coordinate: b),
                        BusStop(id: "3", routeID: "16111", stationID: "3", name: "返程", direction: "1", sequence: 1, coordinate: b),
                        BusStop(id: "4", routeID: "16111", stationID: "4", name: "繞駛站", direction: "0", sequence: 2, coordinate: c)]
        metadata.stops = Dictionary(uniqueKeysWithValues: stopRows.map { ($0.id, $0) })
        metadata.paths = ["157463": [StopReference(stopID: "1", sequence: 1), StopReference(stopID: "2", sequence: 2)],
                          "157462": [StopReference(stopID: "3", sequence: 1)],
                          "20": [StopReference(stopID: "1", sequence: 1), StopReference(stopID: "4", sequence: 2)]]
        metadata.lines = ["sub:157463": RouteLine(coordinates: [a, b]), "sub:157462": RouteLine(coordinates: [b, a]),
                          "sub:20": RouteLine(coordinates: [a, c])]
        metadata.rebuildRouteCatalog()
        return metadata
    }

    func testSingleDirectionVariantsAndMainStopsRemainUsable() {
        let metadata = branchMetadata()
        XCTAssertEqual(metadata.directions(routeID: "157462", allVariants: false), ["1"])
        XCTAssertEqual(metadata.directions(routeID: "157463", allVariants: false), ["0"])
        XCTAssertEqual(metadata.directions(routeID: "157462", allVariants: true), ["0", "1"])
        XCTAssertEqual(metadata.displayStops(routeID: "157462", direction: "1", allVariants: true).map(\.id), ["3"])
        XCTAssertEqual(metadata.displayStops(routeID: "20", direction: "0", allVariants: false).map(\.id), ["1", "4"])
        XCTAssertEqual(metadata.displayStops(routeID: "157462", direction: "0", allVariants: true).count, 2)
    }

    func testAllRoutesViewIncludesBranchesButSelectedVariantExcludesOtherVehicles() {
        let metadata = branchMetadata(), now = Date(timeIntervalSince1970: 1000)
        func bus(_ id: String, route: String, direction: String = "0", age: Double = 0, missing: Bool = false) -> BusVehicle {
            var vehicle = BusVehicle(id: id, plate: id, routeID: route, parentRouteID: "16111", routeName: "307",
                direction: direction, destination: "終點", coordinate: .taipei, rawCoordinate: .taipei, heading: 0,
                speed: 0, observedAt: now.addingTimeInterval(-age), status: "0", lowFloor: false, provider: nil)
            if missing { vehicle.trackingIssue = .missing }
            return vehicle
        }
        let vehicles = [bus("go", route: "157463"), bus("branch", route: "20"), bus("back", route: "157462", direction: "1"),
                        bus("stale", route: "20", age: 121), bus("missing", route: "20", missing: true)]
        XCTAssertEqual(Set(metadata.vehicles(routeID: "157463", direction: "0", allVariants: true, in: vehicles).map(\.id)),
                       Set(["go", "branch", "stale", "missing"]))
        XCTAssertEqual(metadata.vehicles(routeID: "157463", direction: "0", allVariants: false, in: vehicles).map(\.id), ["go"])
        let counts = RouteVehicleCounts(vehicles: vehicles, at: now)
        XCTAssertEqual(counts.count(route: metadata.routes["157463"]!, allVariants: true), 3)
        XCTAssertEqual(counts.count(route: metadata.routes["20"]!, allVariants: false), 1)
    }

    func testMapUsesEachBranchGeometryAndOmitsOppositeOnlyVersions() {
        let metadata = branchMetadata()
        XCTAssertEqual(metadata.displayPaths(routeID: "157463", direction: "0", allVariants: true).count, 2)
        XCTAssertEqual(metadata.displayPaths(routeID: "157463", direction: "0", allVariants: false),
                       [metadata.lines["sub:157463"]!.coordinates])
        XCTAssertTrue(metadata.displayPaths(routeID: "157462", direction: "0", allVariants: false).isEmpty)
        XCTAssertEqual(metadata.displayPaths(routeID: "157463", direction: "1", allVariants: true),
                       [metadata.lines["sub:157462"]!.coordinates])
    }

    func testWesternCrossCityStopsAreNotClippedFromCatalog() {
        XCTAssertTrue(Coordinate(latitude: 25.034, longitude: 121.391224).isInServiceArea)
        XCTAssertFalse(Coordinate(latitude: 0, longitude: 0).isInServiceArea)
        XCTAssertFalse(Coordinate(latitude: 24.5, longitude: 121.5).isInServiceArea)
    }

    func testGoAndReturnShapesSurviveFeedDecodingAndMatchTheCorrectRoad() throws {
        func feed(_ rows: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["BusInfo": rows])
        }
        let go = "LINESTRING(121.55 25.04,121.552 25.04)"
        let back = "LINESTRING(121.55 25.0403,121.552 25.0403)"
        let shapes: [[String: Any]] = [
            ["RouteID": 100, "SubRouteID": -1, "GoBack": 1, "wkt": back],
            ["RouteID": 100, "SubRouteID": -1, "GoBack": 0, "wkt": go],
            // The official feed labels some single-direction return variants as shape GoBack=0.
            ["RouteID": 100, "SubRouteID": 20, "GoBack": 0, "wkt": back]]
        let metadata = try FeedDecoder.metadata(feeds: [
            "GetRoute": feed([["Id": 100, "pathAttributeId": 10, "nameZh": "307", "pathAttributeName": "307"],
                               ["Id": 100, "pathAttributeId": 20, "nameZh": "307", "pathAttributeName": "307往板橋"]]),
            "GetStop": feed([["Id": 101, "routeId": 100, "nameZh": "去程", "goBack": "0", "seqNo": 1,
                              "longitude": 121.55, "latitude": 25.04],
                             ["Id": 102, "routeId": 100, "nameZh": "返程", "goBack": "1", "seqNo": 1,
                              "longitude": 121.55, "latitude": 25.0403]]),
            "GetPathDetail": feed([["pathAttributeId": 10, "stopId": 101, "sequenceNo": 1],
                                   ["pathAttributeId": 10, "stopId": 102, "sequenceNo": 1],
                                   ["pathAttributeId": 20, "stopId": 102, "sequenceNo": 1]]),
            "GetBusShape": JSONSerialization.data(withJSONObject: shapes)])
        XCTAssertEqual(metadata.line("10", direction: "0")?.coordinates, RouteLine.parse(wkt: go)?.coordinates)
        XCTAssertEqual(metadata.line("10", direction: "1")?.coordinates, RouteLine.parse(wkt: back)?.coordinates)
        XCTAssertEqual(metadata.line("20", direction: "1")?.coordinates, RouteLine.parse(wkt: back)?.coordinates)
        XCTAssertEqual(metadata.directionalLines.count, 3)
        let now = Date(timeIntervalSince1970: 1000)
        let coordinate = Coordinate(latitude: 25.04031, longitude: 121.551)
        let vehicle = BusVehicle(id: "return", plate: "ABC-123", routeID: "10", parentRouteID: "100", routeName: "307",
            direction: "1", destination: "板橋", coordinate: coordinate, rawCoordinate: coordinate, heading: 90,
            speed: 30, observedAt: now, status: "0", lowFloor: false, provider: nil)
        let matched = VehicleTracker.accept(vehicle, previous: nil, metadata: metadata, now: now)
        XCTAssertTrue(matched.aligned)
        XCTAssertEqual(matched.coordinate.latitude, 25.0403, accuracy: 0.000001)
    }

    /// Optional cloud audit: compare the decoder/catalog against every currently published official ID.
    func testLiveOfficialCatalogMatchesEveryPublishedRouteAndVariant() throws {
        guard let directory = ProcessInfo.processInfo.environment["BUS_LIVE_FEEDS_DIRECTORY"] else {
            throw XCTSkip("Live-feed audit is enabled when capturing an iPhone preview.")
        }
        let root = URL(fileURLWithPath: directory)
        var feeds: [String: Data] = [:]
        for name in ["GetRoute", "GetStop", "GetPathDetail", "GetBusShape"] {
            feeds[name] = try Data(contentsOf: root.appendingPathComponent("\(name).json"))
        }
        let source = try FeedDecoder.rows(feeds["GetRoute"]!).0
        let expectedParents = Set(source.map { FeedDecoder.text($0["Id"]) }.filter { !$0.isEmpty })
        let expectedVariants = Set(source.map { FeedDecoder.text($0["pathAttributeId"]) }.filter { !$0.isEmpty })
        let metadata = try FeedDecoder.metadata(feeds: feeds)
        XCTAssertGreaterThan(expectedParents.count, 60)
        XCTAssertEqual(Set(metadata.routeCatalog.search("").map(\.id)), expectedParents)
        XCTAssertEqual(Set(metadata.routes.keys), expectedVariants)
        XCTAssertEqual(Set(metadata.routeCatalog.groups.flatMap(\.variants).map(\.id)), expectedVariants)
        XCTAssertTrue(metadata.routeCatalog.groups.allSatisfy { !metadata.routeCatalog.search($0.route.name).isEmpty })
        print("Official live catalog: \(expectedParents.count) routes, \(expectedVariants.count) variants, \(metadata.stations.count) stations.")
    }
}
