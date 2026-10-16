import XCTest
@testable import TransitCore

final class PedestrianAnchorTests: XCTestCase {
    func testStreetPathConnectsBothRequestedAnchorsWithoutReplacingItsGeometry() throws {
        let start = Coordinate(latitude:25.04,longitude:121.54)
        let first = Coordinate(latitude:25.04005,longitude:121.5401)
        let middle = Coordinate(latitude:25.0405,longitude:121.5401)
        let last = Coordinate(latitude:25.0405,longitude:121.541)
        let end = Coordinate(latitude:25.04055,longitude:121.5411)
        let result = try XCTUnwrap(AnchoredPedestrianPath.make([first,middle,last],from:start,to:end))
        XCTAssertEqual(result.coordinates,[start,first,middle,last,end])
        XCTAssertEqual(result.accessDistance,start.distance(to:first)+last.distance(to:end),accuracy:0.001)
    }
    func testDistantDisconnectedRoutesAreNotJoinedByAnInventedLongLine() {
        let start=Coordinate(latitude:25.04,longitude:121.54), end=Coordinate(latitude:25.04,longitude:121.55)
        XCTAssertNil(AnchoredPedestrianPath.make([end,Coordinate(latitude:25.04,longitude:121.551)],from:start,to:end))
        XCTAssertNil(AnchoredPedestrianPath.make([],from:start,to:end))
    }
    func testIndoorWalkingAccessSurvivesSmallGPSChangesAtZhihong() throws {
        // A real provider response near this public building starts roughly 54 m
        // from an indoor fix. The former 50 m cutoff rejected the whole journey.
        let indoor = Coordinate(latitude:25.0189833,longitude:121.5396361)
        let pathStart = Coordinate(latitude:25.01947,longitude:121.5396361)
        let end = Coordinate(latitude:25.026154,longitude:121.543636)
        XCTAssertGreaterThan(indoor.distance(to:pathStart),50)
        XCTAssertNil(AnchoredPedestrianPath.make([pathStart,end],from:indoor,to:end))
        let walking = try XCTUnwrap(AnchoredPedestrianPath.make([pathStart,end],from:indoor,to:end,
            maximumOffset:AnchoredPedestrianPath.maximumWalkingAccess))
        XCTAssertEqual(walking.coordinates,[indoor,pathStart,end])
        XCTAssertEqual(walking.accessDistance,indoor.distance(to:pathStart),accuracy:0.01)
        let shifted = Coordinate(latitude:indoor.latitude,longitude:indoor.longitude+0.0001)
        XCTAssertNotNil(AnchoredPedestrianPath.make([pathStart,end],from:shifted,to:end,
            maximumOffset:AnchoredPedestrianPath.maximumWalkingAccess))
    }
    func testBuildingAccessBoundStillRejectsDistantOrInvalidPaths() {
        let a=Coordinate(latitude:25.019,longitude:121.5395), b=Coordinate(latitude:25.026,longitude:121.5436)
        let far=Coordinate(latitude:25.0205,longitude:121.5395)
        XCTAssertNil(AnchoredPedestrianPath.make([far,b],from:a,to:b,
            maximumOffset:AnchoredPedestrianPath.maximumWalkingAccess))
        XCTAssertNil(AnchoredPedestrianPath.make([.init(latitude:.nan,longitude:121.54),b],from:a,to:b,
            maximumOffset:AnchoredPedestrianPath.maximumWalkingAccess))
    }
    func testExactEndpointsDoNotGainExtraSegmentsOrTime() throws {
        let a=Coordinate(latitude:25.04,longitude:121.54), b=Coordinate(latitude:25.04,longitude:121.541)
        let result=try XCTUnwrap(AnchoredPedestrianPath.make([a,b],from:a,to:b))
        XCTAssertEqual(result.coordinates,[a,b]);XCTAssertEqual(result.accessDistance,0)
    }
    func testReportedSongjiangWalkEndsAtExitFiveNotTheStationCentre() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TaipeiBus")
        let metro = try MetroNetwork(data:Data(contentsOf:root.appendingPathComponent("MetroNetwork.json")))
        let departure = Coordinate(latitude:25.04459,longitude:121.55252)
        let entrance = try XCTUnwrap(metro.nearestExit(stationID:"metro:TRTC:O08",to:departure))
        XCTAssertTrue(entrance.name.contains("5"))
        let station = try XCTUnwrap(metro.station("metro:TRTC:O08"))
        XCTAssertGreaterThan(entrance.coordinate.distance(to:station.coordinate),100)
        let dropoff = Coordinate(latitude:25.05189,longitude:121.53517)
        let snapped = Coordinate(latitude:25.05188,longitude:121.53415)
        let anchored = try XCTUnwrap(AnchoredPedestrianPath.make([dropoff,snapped],from:dropoff,to:entrance.coordinate))
        XCTAssertEqual(anchored.coordinates.last,entrance.coordinate)
        XCTAssertNotEqual(anchored.coordinates.last,station.coordinate,"Do not invent an outdoor walk to an underground station centre")
    }
    func testCurrentCountsNeverPromiseStaleOrSuspendedReturnSpaces() {
        let now=Date()
        let fresh=BikeDock(stationID:"station",rentable:3,returnable:7,capacity:10,active:true,observedAt:now)
        XCTAssertEqual(fresh.availableCount(returning:true,at:now),7)
        XCTAssertEqual(fresh.availableCount(returning:false,at:now),3)
        XCTAssertNil(fresh.availableCount(returning:true,at:now.addingTimeInterval(901)))
        let suspended=BikeDock(stationID:"station",rentable:3,returnable:7,capacity:10,active:false,observedAt:now)
        XCTAssertNil(suspended.availableCount(returning:true,at:now))
        let full=BikeDock(stationID:"station",rentable:10,returnable:0,capacity:10,active:true,observedAt:now)
        XCTAssertEqual(full.availableCount(returning:true,at:now),0)
    }
}
