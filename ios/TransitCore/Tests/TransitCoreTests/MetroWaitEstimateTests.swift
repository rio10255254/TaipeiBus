import XCTest
@testable import TransitCore

final class MetroWaitEstimateTests: XCTestCase {
    private func network() throws -> MetroNetwork {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try MetroNetwork(data: Data(contentsOf: root.appendingPathComponent("TaipeiBus/MetroNetwork.json")))
    }
    private func taipei(_ text: String) -> Date {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text)!
    }
    private func ride(_ metro: MetroNetwork, from: String, to: String, at date: Date) throws -> TransitRide {
        var metadata = TransitMetadata(); metro.attach(to: &metadata)
        let a = try XCTUnwrap(metro.stations.first { $0.code == from }), b = try XCTUnwrap(metro.stations.first { $0.code == to })
        let trips = MultimodalPlanner(metadata: metadata).plan(from: a.coordinate, to: b.coordinate, maximumWalk: 200, limit: 6, at: date)
        return try XCTUnwrap(trips.first { $0.rides.count == 1 }?.rides.first)
    }

    func testPublishedZeroHeadwayMeansTheShortTurnIsNotRunning() throws {
        let metro = try network()
        // Weekday 23:30: the Beitou–Daan short turn is published with a 0-minute headway.
        let late = taipei("2026-10-07 23:30:00")
        let shortTurn = try XCTUnwrap(metro.patterns.first { $0.id == "metro:TRTC:R-2" })
        XCTAssertNil(metro.activeHeadway(shortTurn, at: late))
        XCTAssertNil(metro.service(routeID: "metro:TRTC:R-2", direction: shortTurn.direction, at: late)?.headway)
    }

    func testSharedTrunkCombinesFullAndShortTurnTrains() throws {
        let metro = try network()
        let peak = taipei("2026-10-07 08:00:00")
        let full = try XCTUnwrap(metro.patterns.first { $0.id == "metro:TRTC:BL-1" && $0.direction == "0" })
        let single = try XCTUnwrap(metro.activeHeadway(full, at: peak))
        // Two stations every Bannan line train serves.
        let from = full.stationIDs[full.stationIDs.count / 2], to = full.stationIDs[full.stationIDs.count / 2 + 2]
        let combined = try XCTUnwrap(metro.combinedService(routeID: full.id, direction: "0", from: from, to: to, at: peak)?.headway)
        XCTAssertLessThan(combined.midpoint, (single.lower + single.upper) / 2,
                          "Short-turn trains on the trunk must shorten the expected wait")
        // Beyond the short-turn terminus only the full-length service counts.
        let terminal = full.stationIDs.last!
        let beyond = try XCTUnwrap(metro.combinedService(routeID: full.id, direction: "0", from: full.stationIDs[0], to: terminal, at: peak)?.headway)
        XCTAssertGreaterThanOrEqual(beyond.midpoint, combined.midpoint)
    }

    func testOfficialFeedRowsResolveToStationsDirectionsAndShortTurns() throws {
        let metro = try network()
        let received = taipei("2026-10-08 13:16:21")
        let json = """
        [{"Station":"士林站","StationEn":"Shilin","Destination":"大安站","DestinationEn":"DAAN","UpdateTime":"20261008131602"},
         {"Station":"台北車站","StationEn":"TaipeiMainStation","Destination":"南港展覽館站","DestinationEn":"Exhibition Center","UpdateTime":"20261008131608"},
         {"Station":"台北101/世貿站","StationEn":"Taipei 101/World Trade Center","Destination":"淡水站","DestinationEn":"Tamsui","UpdateTime":"20261008131542"},
         {"Station":"不存在站","StationEn":"Nowhere","Destination":"淡水站","DestinationEn":"Tamsui","UpdateTime":"20261008131542"},
         {"Station":"士林站","StationEn":"Shilin","Destination":"淡水站","DestinationEn":"Tamsui","UpdateTime":"20261008100000"}]
        """
        let events = try MetroPlatformFeed.parse(Data("\u{FEFF}".utf8) + Data(json.utf8), network: metro, serverDate: received, receivedAt: received)
        XCTAssertEqual(events.count, 3, "Unknown stations and stale rows are dropped")
        let shilin = try XCTUnwrap(events.first { metro.station($0.stationID)?.name == "士林" })
        XCTAssertEqual(shilin.patternID, "metro:TRTC:R-2", "A Daan-bound train is the short-turn service")
        XCTAssertEqual(shilin.observedAt.timeIntervalSince(received), -19, accuracy: 0.5)
        let main = try XCTUnwrap(events.first { metro.station($0.stationID)?.name == "台北車站" })
        XCTAssertTrue(main.patternID.hasPrefix("metro:TRTC:BL"))
    }

    func testASightingUpstreamPredictsTheTrainAtTheRidersStation() throws {
        let metro = try network()
        let now = taipei("2026-10-08 13:20:00")
        let trip = try ride(metro, from: "BL12", to: "BL18", at: now)
        let pattern = try XCTUnwrap(metro.pattern(trip.route.id, direction: trip.direction))
        let board = try XCTUnwrap(pattern.stationIDs.firstIndex(of: trip.boarding.stationID))
        XCTAssertGreaterThan(board, 2)
        let upstream = pattern.stationIDs[board - 2]
        let sighting = MetroPlatformEvent(stationID: upstream, patternID: pattern.id, direction: trip.direction,
                                          observedAt: now.addingTimeInterval(-30))
        let run = try XCTUnwrap(metro.ridingSeconds(routeID: pattern.id, direction: trip.direction, from: upstream, to: trip.boarding.stationID))
        let estimate = try XCTUnwrap(MetroPlatformFeed.nextArrival(ride: trip, events: [sighting], network: metro, at: now, longestGap: 600))
        XCTAssertEqual(estimate.seconds, run + (pattern.dwellSeconds[board - 2] > 0 ? pattern.dwellSeconds[board - 2] : 25) - 30, accuracy: 1)
        XCTAssertFalse(estimate.entering)
        // The same train entering the rider's own station.
        let here = MetroPlatformEvent(stationID: trip.boarding.stationID, patternID: pattern.id, direction: trip.direction, observedAt: now.addingTimeInterval(-10))
        let entering = try XCTUnwrap(MetroPlatformFeed.nextArrival(ride: trip, events: [here], network: metro, at: now, longestGap: 600))
        XCTAssertTrue(entering.entering); XCTAssertEqual(entering.seconds, 0)
        // Trains already past the station, opposite-direction trains and far-off sightings never count.
        let past = MetroPlatformEvent(stationID: pattern.stationIDs[board + 1], patternID: pattern.id, direction: trip.direction, observedAt: now)
        let opposite = MetroPlatformEvent(stationID: upstream, patternID: pattern.id, direction: trip.direction == "0" ? "1" : "0", observedAt: now)
        XCTAssertNil(MetroPlatformFeed.nextArrival(ride: trip, events: [past, opposite], network: metro, at: now, longestGap: 600))
        let far = MetroPlatformEvent(stationID: pattern.stationIDs[0], patternID: pattern.id, direction: trip.direction, observedAt: now)
        XCTAssertNil(MetroPlatformFeed.nextArrival(ride: trip, events: [far], network: metro, at: now, longestGap: 60),
                     "Beyond one headway an unseen earlier train is likely; fall back to the headway estimate")
    }

    func testMemoryDropsOldSightingsAndDuplicates() {
        let now = Date()
        let a = MetroPlatformEvent(stationID: "s", patternID: "p", direction: "0", observedAt: now.addingTimeInterval(-30))
        let duplicate = MetroPlatformEvent(stationID: "s", patternID: "p", direction: "0", observedAt: now.addingTimeInterval(-25))
        let old = MetroPlatformEvent(stationID: "t", patternID: "p", direction: "0", observedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(MetroPlatformFeed.merge([old, a], [duplicate], at: now), [a])
    }
}
