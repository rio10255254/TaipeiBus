import XCTest
@testable import TransitCore

/// Adversarial observations modeled on the public feed, rather than idealized motion.
final class MetroReliabilityAuditTests: XCTestCase {
    private func network() throws -> MetroNetwork {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try MetroNetwork(data:Data(contentsOf:root.appendingPathComponent("TaipeiBus/MetroNetwork.json")))
    }
    func testDuplicateRowsInOnePacketAreProcessedOnce() throws {
        let metro = try network(), p = try XCTUnwrap(metro.patterns.first { $0.id.hasSuffix("BL-1") && $0.direction == "0" })
        let now = Date(timeIntervalSince1970:1_800_000_000)
        let event = MetroPlatformEvent(stationID:p.stationIDs[5],patternID:p.id,direction:p.direction,observedAt:now)
        var tracker = MetroTrainTracker();tracker.ingest([event,event,event],network:metro,at:now+1)
        XCTAssertEqual(tracker.tracks.count,1)
        XCTAssertEqual(tracker.tracks[0].sightings,1,"Duplicate provider rows are not new evidence")
    }
    func testSameProviderTimestampDoesNotBecomeANewSightingWithNetworkJitter() throws {
        let metro = try network(), now = ISO8601DateFormatter().date(from:"2026-10-08T05:16:21Z")!
        let body = Data("[{\"Station\":\"士林站\",\"Destination\":\"大安站\",\"UpdateTime\":\"20261008131602\"}]".utf8)
        let first = try MetroPlatformFeed.parse(body,network:metro,serverDate:now,receivedAt:now+1)
        let repeated = try MetroPlatformFeed.parse(body,network:metro,serverDate:now+14,receivedAt:now+19)
        var tracker = MetroTrainTracker();tracker.ingest(first,network:metro,at:now+1)
        let before = try XCTUnwrap(tracker.tracks.first)
        tracker.ingest(repeated,network:metro,at:now+19)
        let after = try XCTUnwrap(tracker.tracks.first)
        XCTAssertEqual(after.sightings,before.sightings,"Transport delay must not renew a provider observation")
        XCTAssertEqual(after.plan.lastSeen,before.plan.lastSeen)
    }
    func testMissingFollowupCannotPromiseAnArrivalFromTheHeldPosition() throws {
        let metro = try network(), p = try XCTUnwrap(metro.patterns.first { $0.id.hasSuffix("BL-1") && $0.direction == "0" })
        let now = Date(timeIntervalSince1970:1_800_000_000), index = 5
        let plan = MetroTrainPlan(stationIndex:index,arrivedAt:now,departure:now+25,lastSeen:now)
        let reach = now+25+MetroTrainTimeline.run(p,index)+MetroTrainTimeline.dwell(p,index+1)+MetroTrainTimeline.run(p,index+1)
        let held = try XCTUnwrap(MetroTrainTimeline.state(plan,pattern:p,at:reach+60))
        XCTAssertTrue(held.holding)
        XCTAssertNil(MetroTrainTimeline.secondsUntil(held.previousIndex,state:held,pattern:p),"Unconfirmed location must not say this train is arriving now")
        XCTAssertNil(MetroTrainTimeline.secondsUntil(held.previousIndex+1,state:held,pattern:p),"No departure is known after the signal is lost")
    }
}
