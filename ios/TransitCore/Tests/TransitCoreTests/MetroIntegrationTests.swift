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
        XCTAssertTrue(metadata.stationSearch.search("BR19", near: .taipei).contains { $0.mode == .metro && $0.name == "內湖" })
        XCTAssertTrue(metadata.stationSearch.search("Neihu", near: .taipei).contains { $0.mode == .metro && $0.name == "內湖" })
        for pattern in metro.patterns {
            XCTAssertGreaterThan(pattern.coordinates.count, pattern.stationIDs.count)
            XCTAssertEqual(metadata.orderedStops(routeID: pattern.id, direction: pattern.direction).count, pattern.stationIDs.count)
            XCTAssertEqual(metadata.journey(routeID:pattern.id,direction:pattern.direction)?.anchors.count,pattern.stationIDs.count)
        }
    }
    func testNeihuToZhongxiaoFuxingUsesDirectWenhuTrainAndOfficialSeconds() throws {
        let result = try trips("BR19", "BR10"), first = try XCTUnwrap(result.first)
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
        XCTAssertTrue(try trips("BR19", "BR10", at: night).isEmpty)
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
    func testTrainProjectionStaysOnTrackStopsAtReportedStationAndExpires() throws {
        let metro = try network(), pattern = try XCTUnwrap(metro.patterns.first { $0.lineID.hasSuffix(":BR") && $0.direction == "0" })
        let station = try XCTUnwrap(metro.station(pattern.stationIDs[5])), date = noon()
        let report = MetroTrainReport(id: "TEST-TRAIN", operatorID: "TRTC", patternID: pattern.id, direction: pattern.direction,
            nextStationID: station.id, destinationStationID: pattern.stationIDs.last!, remainingSeconds: 30, observedAt: date, atPlatform: false)
        let prepared = try XCTUnwrap(PreparedMetroTrain(report: report, network: metro))
        let start = try XCTUnwrap(prepared.pose(at: date)), moving = try XCTUnwrap(prepared.pose(at: date.addingTimeInterval(15)))
        XCTAssertGreaterThan(start.coordinate.distance(to: moving.coordinate), 10)
        XCTAssertLessThan(moving.coordinate.distance(to: station.coordinate), start.coordinate.distance(to: station.coordinate))
        let stopped = try XCTUnwrap(prepared.pose(at: date.addingTimeInterval(45)))
        XCTAssertLessThan(stopped.coordinate.distance(to: pattern.stationCoordinates[5]), 1)
        XCTAssertEqual(stopped.seconds, 0); XCTAssertTrue(stopped.estimatedPosition)
        XCTAssertNil(prepared.pose(at: date.addingTimeInterval(76)))
        let track = RouteLine(coordinates: pattern.coordinates)
        XCTAssertLessThan(try XCTUnwrap(track.match(moving.coordinate, heading: nil)).distance, 1)
    }
    func testOfficialCountdownUsesSourceTimestampAndDoesNotReviveExpiredBusData() throws {
        let metro = try network(), pattern = try XCTUnwrap(metro.patterns.first { $0.lineID.hasSuffix(":BR") && $0.direction == "0" })
        let date = noon(), stamp = ISO8601DateFormatter().string(from: date)
        let arrival: [String:Any] = ["stationID":pattern.stationIDs[1],"patternID":pattern.id,"direction":pattern.direction,
            "destinationStationID":pattern.stationIDs.last!,"seconds":120,"observedAt":stamp]
        let bytes = try JSONSerialization.data(withJSONObject:["schema":1,"source":"Taipei Metro authorized API","trains":[],"arrivals":[arrival]])
        let packet = try MetroRealtime(data: bytes, network: metro, at: date)
        let mixed = packet.applying(to: EstimateFeed(seconds:["bus:stop":800],updatedAt:date.addingTimeInterval(-300)),network:metro,at:date.addingTimeInterval(30))
        let id = "\(pattern.lineID):\(pattern.id):\(pattern.direction):\(pattern.stationIDs[1])"
        XCTAssertNil(mixed.seconds["bus:stop"])
        XCTAssertEqual(mixed.seconds[id],90)
        XCTAssertNil(packet.arrivals[0].remaining(at:date.addingTimeInterval(76)))
        let fake = try JSONSerialization.data(withJSONObject:["schema":1,"source":"schedule simulation","trains":[],"arrivals":[arrival]])
        XCTAssertThrowsError(try MetroRealtime(data:fake,network:metro,at:date))
    }
    func testBusMetroBusJourneyKeepsBothActualTransfers() throws {
        let metro = try network(); var metadata = TransitMetadata(); metro.attach(to:&metadata)
        let a = try XCTUnwrap(metro.stations.first { $0.code == "BR19" }), b = try XCTUnwrap(metro.stations.first { $0.code == "BR10" })
        let origin = Coordinate(latitude:a.coordinate.latitude+0.015,longitude:a.coordinate.longitude)
        let destination = Coordinate(latitude:b.coordinate.latitude-0.015,longitude:b.coordinate.longitude)
        for (name,points) in [("feeder-in",[origin,a.coordinate]),("feeder-out",[b.coordinate,destination])] {
            metadata.routes[name] = BusRoute(id:name,parentID:name,name:name,variantName:name,departure:"A",destination:"B")
            for (index,coordinate) in points.enumerated() {
                let id = "\(name):\(index)", stop = BusStop(id:id,routeID:name,stationID:id,name:id,direction:"0",sequence:index,coordinate:coordinate)
                metadata.stops[id] = stop;metadata.stations[id] = Station(id:id,name:id,coordinate:coordinate,address:"",bearing:"",stopIDs:[id])
                metadata.paths[name,default:[]].append(StopReference(stopID:id,sequence:index))
            }
        }
        metadata.rebuildRouteCatalog()
        let result = MultimodalPlanner(metadata:metadata).plan(from:origin,to:destination,maximumWalk:100,limit:12,at:noon())
        let trip = try XCTUnwrap(result.first { $0.rides.map(\.route.mode) == [.bus,.metro,.bus] })
        XCTAssertEqual(trip.walkingDistances.count,4);XCTAssertEqual(trip.transferSeconds.count,2)
        XCTAssertTrue(TripRanking.assessment(trip,estimates:.init(),at:noon()).elapsedSeconds.isFinite)
    }
    func testBoardingAnAlternateOperatingPatternRequiresEveryPlannedStationInOrder() throws {
        let metro = try network(); var metadata = TransitMetadata(); metro.attach(to:&metadata)
        let pattern = try XCTUnwrap(metro.patterns.first { $0.id.hasSuffix("BL-1") && $0.direction == "1" })
        let stops = metadata.orderedStops(routeID:pattern.id,direction:"1")
        let route = try XCTUnwrap(metadata.routes[pattern.id])
        let short = TransitRide(route:route,direction:"1",stops:Array(stops[1...3]),coordinates:[])
        let alternate = try XCTUnwrap(metro.patterns.first { $0.id.hasSuffix("BL-2") && $0.direction == "1" })
        XCTAssertTrue(metro.canServe(short,patternID:alternate.id,direction:"1",destinationStationID:alternate.stationIDs.last!))
        let beyond = TransitRide(route:route,direction:"1",stops:Array(stops[1...]),coordinates:[])
        XCTAssertFalse(metro.canServe(beyond,patternID:alternate.id,direction:"1",destinationStationID:alternate.stationIDs.last!))
    }
    func testPublishedDwellBelongsToOriginStationInBothDirections() throws {
        let metro = try network()
        let a = try XCTUnwrap(metro.patterns.first { $0.id.hasSuffix("BL-1") && $0.direction == "0" })
        let b = try XCTUnwrap(metro.patterns.first { $0.id == a.id && $0.direction == "1" })
        let stop = try XCTUnwrap(a.stationIDs.firstIndex { $0.hasSuffix(":BL22") })
        let back = try XCTUnwrap(b.stationIDs.firstIndex { $0.hasSuffix(":BL22") })
        XCTAssertEqual(a.dwellSeconds[stop],24);XCTAssertEqual(b.dwellSeconds[back],24)
        XCTAssertEqual(metro.ridingSeconds(routeID:a.id,direction:a.direction,from:a.stationIDs[0],to:a.stationIDs[1]),a.seconds[0])
    }
    func testLiveCityCatalogHasUsefulMetroAlternativesWithoutExcessiveSearchTime() throws {
        guard let folder = ProcessInfo.processInfo.environment["BUS_LIVE_FEEDS_DIRECTORY"] else { throw XCTSkip("Live city metadata not requested") }
        var feeds: [String:Data] = [:]
        for name in ["GetRoute","GetStop","GetPathDetail","GetBusShape"] {
            feeds[name] = try Data(contentsOf:URL(fileURLWithPath:folder).appendingPathComponent(name+".json"))
        }
        var metadata = try FeedDecoder.metadata(feeds:feeds); let metro = try network();metro.attach(to:&metadata)
        let began = Date(), planner = MultimodalPlanner(metadata:metadata)
        XCTAssertLessThan(Date().timeIntervalSince(began),10)
        for (from,to) in [("BR19","BR10"),("R22A","G03A"),("LB12","BR19"),("O54","O21")] {
            let a = try XCTUnwrap(metro.stations.first { $0.code == from }), b = try XCTUnwrap(metro.stations.first { $0.code == to })
            let start = Date(), trips = planner.plan(from:a.coordinate,to:b.coordinate,maximumWalk:800,limit:12,at:noon())
            XCTAssertFalse(trips.isEmpty);XCTAssertTrue(trips.contains { $0.rides.contains { $0.route.mode != .bus } })
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed,10)
            print("METRO_LIVE_AUDIT",from,to,"seconds",elapsed,"choices",trips.count,"rides",trips.first?.rides.map { $0.route.name } ?? [])
        }
    }
    func testEveryOfficialStationHasAUsableTrainTrackIncludingOffsetStationCentres() throws {
        let metro = try network(), date = noon()
        for pattern in metro.patterns {
            for index in pattern.stationIDs.indices {
                let report = MetroTrainReport(id:"TRACK-TEST",operatorID:"TRTC",patternID:pattern.id,direction:pattern.direction,
                    nextStationID:pattern.stationIDs[index],destinationStationID:pattern.stationIDs.last!,remainingSeconds:0,observedAt:date,atPlatform:true)
                let prepared = try XCTUnwrap(PreparedMetroTrain(report:report,network:metro),pattern.id+" "+pattern.stationIDs[index])
                let pose = try XCTUnwrap(prepared.pose(at:date))
                XCTAssertLessThan(pose.coordinate.distance(to:pattern.stationCoordinates[index]),1)
            }
        }
    }
}
