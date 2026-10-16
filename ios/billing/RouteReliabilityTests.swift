import XCTest
import MapKit
@testable import TransitCore
@testable import TaipeiBus

/// The production entry point, full bundled network and real street provider. No
/// preverified options or fabricated pedestrian geometry may make this test pass.
@MainActor final class RouteReliabilityTests: XCTestCase {
    let campus = Coordinate(latitude: 25.01945, longitude: 121.53955)

    func testCampusToNeihuProductionPlanningWithCurrentSupply() async throws {
        let service = TransitService()
        let loaded = await service.offlineMetroMetadata()
        let metadata = try XCTUnwrap(loaded)
        let station = try XCTUnwrap(metadata.metro.stations.first { $0.code == "BR19" })
        let bikes = await service.bikeNetwork()
        let counts = await service.bikeAvailability(network: bikes)
        let snapshot = await service.refresh()
        print("LIVE_FEEDS gps_age=\(snapshot.sourceUpdatedAt.map { Date().timeIntervalSince($0) } ?? -1) eta_age=\(snapshot.estimates.updatedAt.map { Date().timeIntervalSince($0) } ?? -1) vehicles=\(snapshot.vehicles.count) gps_error=\(snapshot.vehicleError ?? "nil") eta_error=\(snapshot.estimates.error ?? "nil") bikes=\(counts?.docks.count ?? 0)")
        let p = JourneyPlannerModel()
        p.auditStreetDiagnostics = true
        p.updateBikes(network: bikes, availability: counts)
        p.updateSnapshot(snapshot)
        let started = Date()
        p.setDestination(TravelPlace(name: "內湖站", address: "", coordinate: station.coordinate),
                         metadata: metadata, currentLocation: campus)
        var first: Double?
        for _ in 0..<1200 {
            if first == nil, p.options.contains(where: { $0.verified && $0.walkIssue == nil }) {
                first = Date().timeIntervalSince(started)
                print("FIRST_CHECKED seconds=\(first!) options=\(p.options.count)")
            }
            if !p.planning, !p.checkingWalks { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("CAMPUS_NEIHU elapsed=\(Date().timeIntervalSince(started)) planning=\(p.planning) checking=\(p.checkingWalks) message=\(p.message ?? "nil") options=\(p.options.count)")
        for option in p.options {
            print("CHECKED_OPTION id=\(option.id) verified=\(option.verified) issue=\(option.walkIssue ?? "nil") walks=\(option.walks.map { $0.distance ?? -1 }) total=\(p.duration(option, at: Date())?.totalSeconds ?? -1)")
        }
        XCTAssertNotNil(first, "An ordinary campus-to-station journey must not end with every choice removed")
        XCTAssertFalse(p.options.isEmpty)
        XCTAssertTrue(p.options.contains { $0.verified && $0.walkIssue == nil })
        p.finish()
    }

    func testCampusStreetAnchorsAndNeihuStationCentre() async throws {
        let service = TransitService(), p = JourneyPlannerModel()
        let loaded = await service.offlineMetroMetadata(), metadata = try XCTUnwrap(loaded)
        let neihu = try XCTUnwrap(metadata.metro.stations.first { $0.code == "BR19" })
        let technology = try XCTUnwrap(metadata.metro.stations.first { $0.code == "BR08" })
        let entrance = try XCTUnwrap(metadata.metro.nearestExit(stationID: technology.id, to: campus))
        let neihuExit = try XCTUnwrap(metadata.metro.nearestExit(stationID: neihu.id, to: neihu.coordinate))
        p.auditStreetDiagnostics = true
        for (from, to) in [(campus, entrance.coordinate),
                            (Coordinate(latitude:25.01965, longitude:121.53965), entrance.coordinate),
                            (neihuExit.coordinate, neihu.coordinate)] {
            let leg = try await p.auditStreet(WalkingLeg(from: from, to: to))
            print("ANCHOR_CHECK from=\(from) to=\(to) verified=\(leg.verified) meters=\(leg.distance ?? -1)")
        }
        p.finish()
    }
}
