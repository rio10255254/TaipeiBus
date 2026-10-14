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
        XCTAssertEqual(guide.emptyPositionLabel, "依官方到站預估")
        XCTAssertTrue(guide.nextBusWithoutPosition)
    }

    func testPassedBusesDoNotHideAnOfficiallyTimedNextBus() throws {
        let (metadata, ride, recorded, date) = try recorded630()
        // Keep only buses that have already passed the boarding stop.
        let approaching = Set(BoardingGuide.vehicles(ride: ride, metadata: metadata, snapshot: recorded, at: date,
                                                     approachingOnly: true).map(\.vehicle.id))
        let passed = BoardingGuide.vehicles(ride: ride, metadata: metadata, snapshot: recorded, at: date,
                                            approachingOnly: false).map(\.vehicle).filter { !approaching.contains($0.id) }
        try XCTSkipIf(passed.isEmpty, "Recording has no bus past the boarding stop")
        let snapshot = TransitSnapshot(vehicles: passed, sourceUpdatedAt: date, receivedAt: date,
                                       estimates: recorded.estimates, revision: 1)
        let guide = BoardingGuide(ride: ride, metadata: metadata, snapshot: snapshot, at: date)
        XCTAssertTrue(guide.approaches.isEmpty)
        XCTAssertEqual(guide.estimateSeconds, 528)
        XCTAssertEqual(guide.emptyPositionLabel, "下一班")
        XCTAssertTrue(guide.nextBusWithoutPosition)
    }

    func testLiveAllPublishedRoutesAndCooperatedVehicleCoverage() throws {
        guard let directory = ProcessInfo.processInfo.environment["BUS_LIVE_FEEDS_DIRECTORY"] else {
            throw XCTSkip("Complete official network audit runs during native verification.")
        }
        let root = URL(fileURLWithPath: directory)
        var feeds: [String: Data] = [:]
        for name in ["GetRoute", "GetStop", "GetPathDetail", "GetBusShape", "GetBusData"] {
            feeds[name] = try Data(contentsOf: root.appendingPathComponent(name + ".json"))
        }
        let metadata = try FeedDecoder.metadata(feeds: feeds)
        let date = try XCTUnwrap(FeedDecoder.rows(feeds["GetBusData"]!).1)
        let live = try FeedDecoder.vehicles(feeds["GetBusData"]!, metadata: metadata, previous: [], now: date)
        let snapshot = TransitSnapshot(vehicles: live.vehicles, sourceUpdatedAt: date, receivedAt: date,
                                      estimates: EstimateFeed(), revision: 1)
        var checked = 0, sharedPatterns = 0, coveredVehicles = 0
        for group in metadata.routeCatalog.groups {
            for direction in ["0", "1"] {
                let variants = group.variants.map { ($0, metadata.orderedStops(routeID: $0.id, direction: direction)) }
                    .filter { $0.1.count >= 2 }
                for (route, stops) in variants {
                    let ride = TransitRide(route: route, direction: direction, stops: stops, coordinates: stops.map(\.coordinate))
                    let allowed = metadata.routeIDs(serving: ride)
                    XCTAssertTrue(allowed.contains(route.id), "Missing selected route \(route.id)")
                    let identical = Set(variants.filter { $0.1.map(\.id) == stops.map(\.id) }.map { $0.0.id })
                    XCTAssertTrue(identical.isSubset(of: allowed), "Missing same-pattern operators for \(route.name) \(direction)")
                    if identical.count > 1 { sharedPatterns += 1 }
                    let expected = Set(live.vehicles.filter {
                        identical.contains($0.routeID) && $0.direction == direction && $0.hasReliablePosition(at: date) && ["0", "3"].contains($0.status)
                    }.map(\.id))
                    let actual = Set(BoardingGuide.vehicles(ride: ride, metadata: metadata, snapshot: snapshot,
                                                          at: date, approachingOnly: false).map(\.id))
                    XCTAssertTrue(expected.isSubset(of: actual), "Missing vehicle coverage for \(route.name) \(direction)")
                    coveredVehicles += expected.count; checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertGreaterThan(sharedPatterns, 0)
        print("Network boarding audit: \(checked) published direction/variant patterns, \(sharedPatterns) co-operated patterns, \(coveredVehicles) expected vehicle associations covered.")
    }
}
