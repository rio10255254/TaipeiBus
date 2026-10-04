import XCTest
import CoreGraphics
@testable import TransitCore

final class RouteBoardingVehiclesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testMapLabelsChangeSidesAtEdgesAndAvoidControls() {
        let bounds = CGRect(x: 16, y: 140, width: 370, height: 500)
        let size = CGSize(width: 240, height: 90)
        let top = CGPoint(x: 35, y: 150)
        let first = MapLabelPlacement.frame(anchor: top, size: size, inside: bounds)
        XCTAssertTrue(bounds.contains(first)); XCTAssertFalse(first.contains(top))
        XCTAssertTrue(first.minY >= top.y + 10 || first.minX >= top.x + 10, "A corner label may use the clear side or the space below, while retaining a pin gap.")
        let bottom = CGPoint(x: 220, y: 630)
        let second = MapLabelPlacement.frame(anchor: bottom, size: size, inside: bounds)
        XCTAssertTrue(bounds.contains(second)); XCTAssertLessThan(second.maxY, bottom.y)
        let anchor = CGPoint(x: 200, y: 400)
        let control = CGRect(x: 80, y: 290, width: 240, height: 100)
        let third = MapLabelPlacement.frame(anchor: anchor, size: size, inside: bounds, avoiding: [control])
        XCTAssertFalse(third.intersects(control)); XCTAssertFalse(third.contains(anchor))
    }
    func testOnlyVerifiedApproachingBusesLeadTheSelectedStop() throws {
        var metadata = TransitMetadata()
        let route = BusRoute(id: "operator", parentID: "family", name: "630", variantName: "630", departure: "起點", destination: "終點")
        metadata.routes[route.id] = route
        let line = RouteLine(coordinates: (0..<8).map { Coordinate(latitude: 25.08, longitude: 121.59 + Double($0) * 0.002) })
        metadata.lines["sub:operator"] = line
        for i in 0..<8 {
            let stop = BusStop(id: "s\(i)", routeID: "family", stationID: "station\(i)", name: "站\(i)", direction: "0", sequence: i, coordinate: line.coordinates[i])
            metadata.stops[stop.id] = stop; metadata.paths[route.id, default: []].append(StopReference(stopID: stop.id, sequence: i))
        }
        metadata.rebuildJourneys()
        let target = try XCTUnwrap(metadata.stops["s4"])
        let along = try XCTUnwrap(metadata.journey(routeID: route.id, direction: "0")).anchors[4].match.along
        func bus(_ id: String, offset: Double, age: Double = 0, status: String = "0", direction: String = "0") -> BusVehicle {
            let coordinate = line.sample(fraction: (along + offset) / line.length).0
            let raw = BusVehicle(id: id, plate: id, routeID: route.id, parentRouteID: route.parentID, routeName: route.name,
                direction: direction, destination: "終點", coordinate: coordinate, rawCoordinate: coordinate,
                heading: 90, speed: 20, observedAt: now.addingTimeInterval(-age), status: status, lowFloor: true, provider: nil)
            return VehicleTracker.accept(raw, previous: nil, metadata: metadata, now: now.addingTimeInterval(-age))
        }
        let group = RouteBoardingVehicles(stop: target, vehicles: [bus("far", offset: -500), bus("passed", offset: 100),
            bus("nearest", offset: -80), bus("old", offset: -50, age: 300), bus("parked", offset: -20, status: "1"),
            bus("opposite", offset: -10, direction: "1")], metadata: metadata, at: now)
        XCTAssertEqual(group.approaching.map(\.id), ["nearest", "far"])
        XCTAssertEqual(group.other.first { $0.id == "passed" }?.reason, .passed)
        XCTAssertEqual(group.other.first { $0.id == "old" }?.reason, .positionUnknown)
        XCTAssertEqual(group.other.first { $0.id == "parked" }?.reason, .notRunning)
        XCTAssertFalse(group.other.contains { $0.id == "opposite" })
        XCTAssertTrue(group.approaching.allSatisfy { ($0.alongDistance ?? -1) >= 0 })
    }
    func testRecordedCooperatedRouteUsesTheSelectedPhysicalStop() throws {
        var feeds: [String: Data] = [:]
        for name in ["GetRoute", "GetStop", "GetPathDetail", "GetBusShape", "GetBusData"] {
            feeds[name] = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json")))
        }
        let metadata = try FeedDecoder.metadata(feeds: feeds)
        let now = try XCTUnwrap(FeedDecoder.taipeiDate("2026/10/04 10:46:00"))
        let data = try FeedDecoder.vehicles(feeds["GetBusData"]!, metadata: metadata, previous: [], now: now)
        let stop = try XCTUnwrap(metadata.stops["23641"])
        let fleet = metadata.vehicles(routeID: "160878", direction: "1", allVariants: true, in: data.vehicles)
        let group = RouteBoardingVehicles(stop: stop, vehicles: fleet, metadata: metadata, at: now)
        XCTAssertTrue(group.approaching.contains { $0.vehicle.plate == "389-U8" && $0.vehicle.routeID == "160879" })
        XCTAssertFalse(group.approaching.contains { $0.vehicle.plate == "357-U3" })
        XCTAssertTrue(group.other.contains { $0.vehicle.plate == "357-U3" && $0.reason == .passed })
    }
}
