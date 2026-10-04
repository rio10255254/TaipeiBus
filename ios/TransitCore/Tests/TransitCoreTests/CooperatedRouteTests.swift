import XCTest
@testable import TransitCore

final class CooperatedRouteTests: XCTestCase {
    private func recorded630() throws -> (TransitMetadata, TransitRide, TransitSnapshot, Date) {
        var feeds: [String: Data] = [:]
        for name in ["GetRoute", "GetStop", "GetPathDetail", "GetBusShape", "GetBusData", "GetEstimateTime"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
            feeds[name] = try Data(contentsOf: url)
        }
        let metadata = try FeedDecoder.metadata(feeds: feeds)
        let date = try XCTUnwrap(FeedDecoder.taipeiDate("2026/10/04 10:46:00"))
        let route = try XCTUnwrap(metadata.routes["160878"])
        let stops = metadata.orderedStops(routeID: route.id, direction: "1")
        let first = try XCTUnwrap(stops.firstIndex { $0.id == "23641" })
        let last = min(first + 15, stops.count - 1)
        let ride = TransitRide(route: route, direction: "1", stops: Array(stops[first...last]),
                              coordinates: Array(stops[first...last]).map(\.coordinate))
        let live = try FeedDecoder.vehicles(feeds["GetBusData"]!, metadata: metadata, previous: [], now: date)
        let estimates = try FeedDecoder.estimates(feeds["GetEstimateTime"]!)
        return (metadata, ride, TransitSnapshot(vehicles: live.vehicles, sourceUpdatedAt: date, receivedAt: date,
            estimates: estimates, revision: 1), date)
    }

    func testRecorded630IncludesOtherOperatorWithIdenticalStops() throws {
        let (metadata, ride, snapshot, date) = try recorded630()
        XCTAssertEqual(metadata.orderedStops(routeID: "160878", direction: "1").map(\.id),
                       metadata.orderedStops(routeID: "160879", direction: "1").map(\.id))
        let guide = BoardingGuide(ride: ride, metadata: metadata, snapshot: snapshot, at: date)
        XCTAssertEqual(guide.estimateSeconds, 528)
        XCTAssertTrue(guide.approaches.contains { $0.vehicle.plate == "389-U8" && $0.vehicle.routeID == "160879" })
        XCTAssertFalse(guide.approaches.contains { $0.vehicle.direction != ride.direction })
        XCTAssertTrue(guide.approaches.allSatisfy { ($0.alongDistance ?? 0) >= 0 })
        XCTAssertFalse(guide.approaches.contains { $0.vehicle.plate == "357-U3" })
    }

    func testSameRouteNameDoesNotAdmitADifferentStopSequence() throws {
        var (metadata, ride, snapshot, date) = try recorded630()
        metadata.paths["160879"]?.removeAll { $0.stopID == ride.stops[1].id }
        XCTAssertFalse(metadata.routeIDs(serving: ride).contains("160879"))
        let guide = BoardingGuide(ride: ride, metadata: metadata, snapshot: snapshot, at: date)
        XCTAssertFalse(guide.approaches.contains { $0.vehicle.routeID == "160879" })
    }

    func testMissingGPSIsDistinguishedFromWorkingOfficialEstimate() throws {
        let (metadata, ride, recorded, date) = try recorded630()
        let empty = TransitSnapshot(vehicles: [], sourceUpdatedAt: date, receivedAt: date,
                                   estimates: recorded.estimates, revision: 1)
        let guide = BoardingGuide(ride: ride, metadata: metadata, snapshot: empty, at: date)
        XCTAssertEqual(guide.estimateSeconds, 528)
        XCTAssertEqual(guide.emptyPositionLabel, "到站預估可用 · GPS 暫缺")
    }
}
