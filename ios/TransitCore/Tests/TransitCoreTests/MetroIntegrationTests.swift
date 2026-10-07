import XCTest
@testable import TransitCore

final class MetroIntegrationTests: XCTestCase {
    private func network() throws -> MetroNetwork {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try MetroNetwork(data: Data(contentsOf: root.appendingPathComponent("TaipeiBus/MetroNetwork.json")))
    }
    private func noon() -> Date { ISO8601DateFormatter().date(from: "2026-10-08T04:00:00Z")! }
    private func trips(_ from: String, _ to: String, at date: Date? = nil) throws -> [TransitTrip] {
        let metro = try network(); var metadata = TransitMetadata(); metro.attach(to: &metadata)
        let a = try XCTUnwrap(metro.stations.first { $0.code == from }), b = try XCTUnwrap(metro.stations.first { $0.code == to })
        return MultimodalPlanner(metadata: metadata).plan(from: a.coordinate, to: b.coordinate,
            maximumWalk: 200, limit: 12, at: date ?? noon())
    }
    func testActualOfficialNetworkIsCompleteAndSearchable() throws {
        let metro = try network(); var metadata = TransitMetadata(); metro.attach(to: &metadata)
        XCTAssertEqual(metro.lines.count, 7); XCTAssertEqual(metro.stations.count, 148)
        XCTAssertEqual(metro.stations.flatMap(\.exits).count, 486)
        XCTAssertTrue(metadata.stationSearch.search("BR18", near: .taipei).contains { $0.mode == .metro && $0.name == "內湖" })
        XCTAssertTrue(metadata.stationSearch.search("Neihu", near: .taipei).contains { $0.mode == .metro && $0.name == "內湖" })
        for pattern in metro.patterns {
            XCTAssertGreaterThan(pattern.coordinates.count, pattern.stationIDs.count)
            XCTAssertEqual(metadata.orderedStops(routeID: pattern.id, direction: pattern.direction).count, pattern.stationIDs.count)
        }
    }
    func testNeihuToZhongxiaoFuxingUsesDirectWenhuTrainAndOfficialSeconds() throws {
        let result = try trips("BR18", "BR10"), first = try XCTUnwrap(result.first)
        XCTAssertEqual(first.rides.count, 1); XCTAssertEqual(first.rides[0].route.lineCode, "BR")
        XCTAssertEqual(first.rides[0].boarding.name, "內湖"); XCTAssertEqual(first.rides[0].alighting.name, "忠孝復興")
        XCTAssertGreaterThan(first.rideSeconds[0], 600); XCTAssertLessThan(first.rideSeconds[0], 1800)
        XCTAssertNotNil(first.rides[0].railService?.headway)
        let assessment = TripRanking.assessment(first, estimates: .init(), at: noon())
        XCTAssertLessThan(assessment.elapsedSeconds, 2400)
        XCTAssertEqual(assessment.waits[0].evidence, .headway)
    }
    func testShuttleNeedsRealTransferAndCannotBeJoinedIntoDirectRide() throws {
        let result = try trips("R22A", "R10"), first = try XCTUnwrap(result.first)
        XCTAssertGreaterThanOrEqual(first.transfers, 1)
        XCTAssertEqual(first.rides[0].boarding.name, "新北投")
        XCTAssertEqual(first.rides[0].alighting.name, "北投")
        XCTAssertEqual(first.rides[1].boarding.name, "北投")
        XCTAssertEqual(first.walkingDistances.count, first.rides.count + 1)
    }
    func testOrangeBranchesTransferAtActualInterchange() throws {
        let first = try XCTUnwrap(trips("O54", "O21").first)
        XCTAssertEqual(first.rides[0].boarding.name, "蘆洲")
        XCTAssertGreaterThanOrEqual(first.transfers, 1)
        XCTAssertFalse(first.rides.contains { $0.boarding.name == "蘆洲" && $0.alighting.name == "迴龍" })
    }
    func testExternalInterchangeAndOfficialTransferTimeArePreserved() throws {
        let metro = try network()
        let transfer = try XCTUnwrap(metro.transfers.first { $0.from.hasSuffix(":BL08") && $0.to.hasSuffix(":Y17") })
        XCTAssertTrue(transfer.external); XCTAssertEqual(transfer.seconds, 540)
        XCTAssertTrue(metro.transfers.contains { $0.from.hasSuffix(":BL01") && $0.to.hasSuffix(":LB01") })
    }
    func testNightDoesNotRecommendWaitingHoursForClosedMetro() throws {
        let night = ISO8601DateFormatter().date(from: "2026-10-07T19:00:00Z")!
        XCTAssertTrue(try trips("BR18", "BR10", at: night).isEmpty)
    }
    func testSeveralTransfersKeepAllWalksInDuration() throws {
        let result = try trips("R22A", "G03A")
        let first = try XCTUnwrap(result.first)
        XCTAssertGreaterThanOrEqual(first.rides.count, 3)
        XCTAssertEqual(first.walkingDistances.count, first.rides.count + 1)
        XCTAssertEqual(first.transferSeconds.count, first.transfers)
        let value = TripRanking.assessment(first, estimates: .init(), at: noon())
        XCTAssertTrue(value.elapsedSeconds.isFinite)
        XCTAssertGreaterThan(value.walkingSeconds, 210)
    }
}
