import XCTest
@testable import TransitCore

final class IntegratedPlanningTests: XCTestCase {
    let a = Coordinate(latitude:25.04,longitude:121.54)
    let b = Coordinate(latitude:25.04,longitude:121.555)
    let c = Coordinate(latitude:25.06,longitude:121.58)
    let d = Coordinate(latitude:25.06,longitude:121.595)
    var date: Date { ISO8601DateFormatter().date(from:"2026-10-16T01:23:00Z")! }
    func fixture() -> (TransitMetadata,BikeNetwork,BikeAvailability) {
        var metadata = TransitMetadata()
        let route = BusRoute(id:"bus",parentID:"bus",name:"公車",variantName:"",departure:"上車",destination:"下車")
        metadata.routes[route.id] = route
        for (i,point) in [b,c].enumerated() {
            let id = "stop-\(i)", station = "station-\(i)"
            let stop = BusStop(id:id,routeID:route.id,stationID:station,name:id,direction:"0",sequence:i,coordinate:point)
            metadata.stops[id] = stop;metadata.paths[route.id,default:[]].append(StopReference(stopID:id,sequence:i))
            metadata.stations[station] = Station(id:station,name:station,coordinate:point,address:"",bearing:"E",stopIDs:[id])
        }
        metadata.rebuildRouteCatalog()
        let stations = [a,b,c,d].enumerated().map { BikeStation(id:"bike-\($0.offset)",name:"站\($0.offset)",coordinate:$0.element,capacity:30) }
        let network = BikeNetwork(stations:stations)
        let counts = BikeAvailability(docks:Dictionary(uniqueKeysWithValues:stations.map {
            ($0.id,BikeDock(stationID:$0.id,rentable:8,returnable:8,capacity:30,active:true,observedAt:date))
        }),receivedAt:date)
        return (metadata,network,counts)
    }
    func testBikeAccessAndEgressParticipateBeforeWalkingRadiusRejectsTheBus() throws {
        let (metadata,bikes,counts) = fixture(), planner = MultimodalPlanner(metadata:metadata)
        XCTAssertTrue(planner.plan(from:a,to:d,maximumWalk:100,at:date).isEmpty)
        let trips = planner.plan(from:a,to:d,maximumWalk:100,limit:36,at:date,bikeNetwork:bikes,bikeAvailability:counts)
        let connected = try XCTUnwrap(trips.first { $0.bikeConnections[0] != nil && $0.bikeConnections[1] != nil })
        XCTAssertEqual(connected.rides.count,1)
        XCTAssertEqual(connected.rides[0].route.id,"bus")
        XCTAssertEqual(connected.planningWalkSeconds[0],try XCTUnwrap(connected.bikeConnections[0]).totalSeconds,accuracy:0.001)
        XCTAssertEqual(connected.withEndpointDistances(access:10,egress:20).bikeConnections.count,2)
        XCTAssertTrue(connected.id.contains("bikes-"))
    }
    func testUnknownEmptyOrStaleSupplyCannotCreateReachableConnections() {
        let (metadata,bikes,counts) = fixture(), planner = MultimodalPlanner(metadata:metadata)
        for availability in [Optional<BikeAvailability>.none, .some(.init()), .some(counts)] {
            let queryDate = availability?.isEmpty == false ? date.addingTimeInterval(1800) : date
            XCTAssertTrue(planner.plan(from:a,to:d,maximumWalk:100,at:queryDate,
                bikeNetwork:bikes,bikeAvailability:availability).isEmpty)
        }
    }
    func testIndexedTwoBusJourneyRetainsCyclingAtBothEnds() throws {
        var (metadata,bikes,counts) = fixture()
        let mid = Coordinate(latitude:25.05,longitude:121.57)
        let firstID = "stop-1"
        metadata.stops[firstID] = BusStop(id:firstID,routeID:"bus",stationID:"station-1",name:"轉車",direction:"0",sequence:1,coordinate:mid)
        metadata.stations["station-1"] = Station(id:"station-1",name:"轉車",coordinate:mid,address:"",bearing:"E",stopIDs:[firstID])
        let route = BusRoute(id:"second",parentID:"second",name:"第二班",variantName:"",departure:"轉車",destination:"下車")
        metadata.routes[route.id] = route
        for (index,point) in [mid,c].enumerated() {
            let id = "second-\(index)", station = "second-station-\(index)"
            metadata.stops[id] = BusStop(id:id,routeID:route.id,stationID:station,name:id,direction:"0",sequence:index,coordinate:point)
            metadata.paths[route.id,default:[]].append(StopReference(stopID:id,sequence:index))
            metadata.stations[station] = Station(id:station,name:station,coordinate:point,address:"",bearing:"E",stopIDs:[id])
        }
        metadata.rebuildRouteCatalog()
        let trips = MultimodalPlanner(metadata:metadata).plan(from:a,to:d,maximumWalk:100,limit:54,at:date,bikeNetwork:bikes,bikeAvailability:counts)
        let connected = try XCTUnwrap(trips.first { $0.rides.count == 2 && $0.bikeConnections[0] != nil && $0.bikeConnections[2] != nil })
        XCTAssertEqual(connected.rides.map { $0.route.id },["bus","second"])
        XCTAssertEqual(connected.planningWalkSeconds.count,3)
    }
    func testPerQueryDockLookupCachePreservesAllStationPairResults() {
        let (_,network,counts) = fixture(), preferences = LiveSettings.Planning()
        let cached = BikeConnectionSearch(network:network,availability:counts,preferences:preferences,at:date)
        for (start,end) in [(a,b),(c,d),(a,d),(a,b)] {
            let plain = BikeRouting.connections(from:start,to:end,network:network,availability:counts,preferences:preferences,at:date,limit:3)
            XCTAssertEqual(cached.connections(from:start,to:end,limit:3),plain)
        }
    }
    func testSeveralDockPairsSurviveUntilActualStreetVerification() {
        let (_,original,counts) = fixture()
        let extra = BikeStation(id:"alternative",name:"另一站",coordinate:Coordinate(latitude:a.latitude,longitude:a.longitude+0.001),capacity:30)
        let bikes = BikeNetwork(stations:original.stations+[extra])
        var docks = counts.docks
        docks[extra.id] = BikeDock(stationID:extra.id,rentable:8,returnable:8,capacity:30,active:true,observedAt:date)
        let result = BikeRouting.connections(from:a,to:b,network:bikes,availability:.init(docks:docks,receivedAt:date),at:date,limit:3)
        XCTAssertGreaterThanOrEqual(result.count,2)
        XCTAssertEqual(Set(result.map(BikeRouting.pairID)).count,result.count)
    }
    func testSparseFutureSupplyChangesPreferenceWithoutChangingRideTime() throws {
        let (_,bikes,counts) = fixture()
        let connection = try XCTUnwrap(BikeRouting.connection(from:a,to:b,network:bikes,availability:counts,at:date))
        var docks = counts.docks
        docks[connection.dropoff.id] = BikeDock(stationID:connection.dropoff.id,rentable:8,returnable:2,capacity:30,active:true,observedAt:date)
        let sparse = BikeAvailability(docks:docks,receivedAt:date)
        let now = BikeRouting.supplyPenalty(connection,availability:sparse,at:date)
        let later = BikeRouting.supplyPenalty(connection,availability:sparse,pickupAfter:1200,at:date)
        XCTAssertGreaterThan(later,now)
        XCTAssertGreaterThan(now,BikeRouting.supplyPenalty(connection,availability:counts,at:date))
        XCTAssertEqual(connection.totalSeconds,connection.accessSeconds+connection.rideSeconds+connection.egressSeconds+connection.handlingSeconds)
    }
    func testAllModesUseTheSameConvenienceAndElapsedComparison() {
        let choices = [
            JourneyChoice(id:"bus",group:"bus",elapsed:1200,walking:120,waiting:60,transfers:0,rentals:0,unknownWaits:0),
            JourneyChoice(id:"bike",group:"bike",elapsed:1170,walking:90,waiting:0,transfers:0,rentals:1,unknownWaits:0),
            JourneyChoice(id:"walk",group:"walk",elapsed:1800,walking:1800,waiting:0,transfers:0,rentals:0,unknownWaits:0)]
        XCTAssertEqual(JourneyChoiceRanking.recommended(choices).first,"bus")
        let fast = JourneyChoice(id:"bike-fast",group:"bike-fast",elapsed:900,walking:90,waiting:0,transfers:0,rentals:1,unknownWaits:0)
        XCTAssertEqual(JourneyChoiceRanking.recommended(choices+[fast]).first,"bike-fast")
        XCTAssertTrue(JourneyChoiceRanking.recommended(choices+[fast]).contains("bus"))
    }
    func testTransferMarginsReflectPlatformChangesAndUpstreamUncertainty() {
        XCTAssertEqual(ConnectionTiming.buffer(first:true,walking:0),0)
        XCTAssertEqual(ConnectionTiming.buffer(first:true,walking:300),60)
        let same = ConnectionTiming.buffer(first:false,walking:60,from:.metro,to:.metro,internalTransfer:true,samePlatform:true)
        let internalWalk = ConnectionTiming.buffer(first:false,walking:300,from:.metro,to:.metro,internalTransfer:true)
        let outside = ConnectionTiming.buffer(first:false,walking:300,from:.metro,to:.bus)
        XCTAssertLessThan(same,internalWalk);XCTAssertLessThan(internalWalk,outside)
        XCTAssertGreaterThan(ConnectionTiming.buffer(first:false,walking:300,previousSpread:300),outside)
    }
    func testAlternativeSuggestionsRequireMeaningfulSavingsOrAnUnavailableConnection() {
        XCTAssertFalse(JourneyRevisionPolicy.shouldOffer(current:1800,alternative:1740,currentUsable:true))
        XCTAssertTrue(JourneyRevisionPolicy.shouldOffer(current:1800,alternative:1500,currentUsable:true))
        XCTAssertTrue(JourneyRevisionPolicy.shouldOffer(current:1800,alternative:2000,currentUsable:false))
        XCTAssertFalse(JourneyRevisionPolicy.shouldOffer(current:1800,alternative:4000,currentUsable:false))
    }
    func testFrozenFullCityPlanningIncludesBikeCorridorsWithinInteractiveTime() throws {
        guard let directory = ProcessInfo.processInfo.environment["BUS_LIVE_FEEDS_DIRECTORY"] else {
            throw XCTSkip("Exact bundled catalog is exercised in the explicit catalog audit")
        }
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var feeds: [String:Data] = [:]
        for name in ["GetRoute","GetStop","GetPathDetail","GetBusShape"] {
            feeds[name] = try Data(contentsOf:URL(fileURLWithPath:directory).appendingPathComponent(name+".json"))
        }
        var metadata = try FeedDecoder.metadata(feeds:feeds)
        let metro = try MetroNetwork(data:Data(contentsOf:root.appendingPathComponent("TaipeiBus/MetroNetwork.json")))
        metro.attach(to:&metadata)
        let bikes = try BikeNetwork(data:Data(contentsOf:root.appendingPathComponent("TaipeiBus/BikeNetwork.json")))
        let counts = BikeAvailability(docks:Dictionary(uniqueKeysWithValues:bikes.stations.map {
            ($0.id,BikeDock(stationID:$0.id,rentable:8,returnable:8,capacity:$0.capacity,active:true,observedAt:date))
        }),receivedAt:date)
        let planner = MultimodalPlanner(metadata:metadata)
        for (start,end) in [(Coordinate(latitude:25.083,longitude:121.594),Coordinate(latitude:25.02036,longitude:121.53992)),
                            (Coordinate(latitude:25.0192,longitude:121.539),Coordinate(latitude:25.0434,longitude:121.5062))] {
            let started = ProcessInfo.processInfo.systemUptime
            let result = planner.plan(from:start,to:end,maximumWalk:1200,limit:54,at:date,bikeNetwork:bikes,bikeAvailability:counts)
            let elapsed = ProcessInfo.processInfo.systemUptime-started
            XCTAssertFalse(result.isEmpty)
            XCTAssertTrue(result.contains { !$0.bikeConnections.isEmpty })
            XCTAssertTrue(result.allSatisfy { $0.planningWalkSeconds.count == $0.rides.count+1 })
            print("INTEGRATED_CITY controlled_supply=true routes=\(metadata.routes.count) choices=\(result.count) cycling=\(result.filter { !$0.bikeConnections.isEmpty }.count) seconds=\(elapsed)")
#if !DEBUG
            XCTAssertLessThan(elapsed,8,"A city-wide search must remain interactive")
#endif
        }
    }
}
