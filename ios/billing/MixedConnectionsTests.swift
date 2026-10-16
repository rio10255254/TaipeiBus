import XCTest
@testable import TransitCore
@testable import TaipeiBus

@MainActor final class MixedConnectionsTests: XCTestCase {
    let a = Coordinate(latitude:25.04,longitude:121.54)
    let b = Coordinate(latitude:25.04,longitude:121.555)
    let c = Coordinate(latitude:25.06,longitude:121.57)
    let d = Coordinate(latitude:25.06,longitude:121.585)

    func route(_ code: String, _ from: Coordinate, _ to: Coordinate, mode: TransportMode) -> TransitRide {
        var r = BusRoute(id:code,parentID:code,name:code,variantName:"",departure:"起點",destination:"終點")
        r.mode = mode; r.lineCode = code
        let stops = [BusStop(id:code+"a",routeID:code,stationID:code+"a",name:"上車",direction:"0",sequence:1,coordinate:from),
                     BusStop(id:code+"b",routeID:code,stationID:code+"b",name:"下車",direction:"0",sequence:2,coordinate:to)]
        return TransitRide(route:r,direction:"0",stops:stops,coordinates:[from,to])
    }
    func base(_ code: String = "G", mode: TransportMode = .metro) -> JourneyOption {
        let ride = route(code,b,c,mode:mode)
        let trip = TransitTrip(rides:[ride],accessDistance:a.distance(to:b),egressDistance:c.distance(to:d),transferDistance:0,score:0,rideSeconds:[600])
        return JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:a,to:b,distance:1500,duration:1500),WalkingLeg(from:c,to:d,distance:1500,duration:1500)])
    }
    func transfer(internalWalk: Bool) -> JourneyOption {
        let rides = [route("bus",a,b,mode:.bus), route("R",c,d,mode:.metro)]
        let trip = TransitTrip(rides:rides,accessDistance:0,egressDistance:0,transferDistance:b.distance(to:c),score:0,rideSeconds:[600,600])
        var middle = WalkingLeg(from:b,to:c,distance:2500,duration:2500)
        middle.internalTransfer = internalWalk
        return JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:a,to:a,distance:0,duration:0),middle,WalkingLeg(from:d,to:d,distance:0,duration:0)])
    }
    func network(_ option: JourneyOption) -> BikeNetwork {
        let stations = option.walks.enumerated().flatMap { index, leg -> [BikeStation] in
            guard leg.from.distance(to:leg.to) >= 500 else { return [] }
            return [BikeStation(id:"\(index)-pickup",name:"借車\(index)",coordinate:leg.from,capacity:30),
                    BikeStation(id:"\(index)-dropoff",name:"還車\(index)",coordinate:leg.to,capacity:30)]
        }
        return BikeNetwork(stations:stations)
    }
    func counts(_ network: BikeNetwork, empty: Set<String> = [], full: Set<String> = [], age: Double = 0) -> BikeAvailability {
        let now = Date()
        return BikeAvailability(docks:Dictionary(uniqueKeysWithValues:network.stations.map {
            ($0.id,BikeDock(stationID:$0.id,rentable:empty.contains($0.id) ? 0 : 8,returnable:full.contains($0.id) ? 0 : 8,
                capacity:30,active:true,observedAt:now.addingTimeInterval(-age)))
        }),receivedAt:now)
    }
    func planner(_ option: JourneyOption, availability: BikeAvailability? = nil) -> JourneyPlannerModel {
        let p = JourneyPlannerModel(), bikes = network(option)
        p.updateBikes(network:bikes,availability:availability ?? counts(bikes))
        p.auditLoadChoices([option],from:TravelPlace(name:"出發",address:"",coordinate:option.walks[0].from),
                          to:TravelPlace(name:"目的地",address:"",coordinate:option.walks.last!.to))
        p.testCycle = { leg in
            var result = leg
            guard var bike = leg.bike else { return result }
            bike.toPickup = [leg.from,bike.pickup.coordinate]
            bike.ride = [bike.pickup.coordinate,bike.dropoff.coordinate]
            // This controlled fixture has a direct street. Replace the rough
            // candidate detour exactly as a successful cycling response would.
            bike.rideMeters = bike.pickup.coordinate.distance(to:bike.dropoff.coordinate)
            bike.rideSeconds = bike.rideMeters / 3.3
            bike.fromDropoff = [bike.dropoff.coordinate,leg.to]
            result.bike = bike; result.duration = bike.totalSeconds + leg.stationSeconds
            result.coordinates = bike.coordinates; result.distance = bike.totalMeters
            result.road = RouteLine(coordinates:bike.coordinates)
            return result
        }
        return p
    }
    func settle(_ p: JourneyPlannerModel) async {
        for _ in 0..<200 {
            if !p.checkingWalks { return }
            try? await Task.sleep(for:.milliseconds(10))
        }
        XCTFail("Connector verification did not finish")
    }
    func testSingleFeederLeadsAndTwoEndedRentalRemainsInspectableOnEverySupportedLine() async throws {
        for code in ["bus","BR","R","G","O","BL","Y","LB","lightRail"] {
            let mode: TransportMode = code == "bus" ? .bus : code == "lightRail" ? .lightRail : .metro
            let original = base(code,mode:mode), p = planner(original), bikes = network(original)
            p.updateBikes(network:bikes,availability:counts(bikes))
            await settle(p)
            let selected = try XCTUnwrap(p.selected, code)
            XCTAssertEqual(selected.walks.filter { $0.bike != nil }.count,1,code)
            XCTAssertTrue(p.options.contains { $0.walks.filter { $0.bike != nil }.count == 2 },
                "A faster two-rental choice remains available without becoming the default: "+code)
            XCTAssertLessThan(try XCTUnwrap(p.duration(selected,at:Date())).totalSeconds,
                              try XCTUnwrap(p.duration(original,at:Date())).totalSeconds,code)
            XCTAssertFalse(p.started,"Recommendation must still wait for Go: "+code)
            XCTAssertEqual(selected.rides[0].route.lineCode,code)
        }
    }
    func testBothSingleAndCombinedConnectionsAreCheckedBeforeCollapsingTheTransitFamily() {
        let original = base(), p = planner(original)
        let choices = p.auditBikeConnections([original])
        XCTAssertTrue(choices.contains { $0.walks.filter { $0.bike != nil }.count == 2 })
        XCTAssertTrue(choices.contains { $0.walks.filter { $0.bike != nil }.count == 1 })
        XCTAssertTrue(choices.allSatisfy { !$0.verified },"Known walks must not mark new bike routes verified")
    }
    func testReasonablySlowerTripWithoutBikeRemainsAnExplicitChoice() async throws {
        var original = base()
        original.walks[0].duration = 1000;original.walks[1].duration = 1000
        let p = planner(original), bikes = network(original)
        p.updateBikes(network:bikes,availability:counts(bikes));await settle(p)
        XCTAssertTrue(try XCTUnwrap(p.selected).cycles)
        XCTAssertTrue(p.options.contains { $0.id == original.id && !$0.cycles })
        XCTAssertEqual(p.optionLabels[original.id],"免騎車")
    }
    func testAdditionalTimeWalkingTradeoffsStayInTheFullListAndCanBePreviewed() throws {
        let choices = (0..<16).map { index -> JourneyOption in
            let ride = route("route-\(index)",b,c,mode:.bus)
            let trip = TransitTrip(rides:[ride],accessDistance:0,egressDistance:0,transferDistance:0,score:0,
                rideSeconds:[1800-Double(index)*90])
            return JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:a,to:b,distance:100,duration:Double(index)*60),
                WalkingLeg(from:c,to:d,distance:0,duration:0)])
        }
        let p = JourneyPlannerModel()
        p.auditLoadChoices(choices,from:TravelPlace(name:"出發",address:"",coordinate:a),to:TravelPlace(name:"目的地",address:"",coordinate:d))
        XCTAssertEqual(p.options.count,16)
        XCTAssertEqual(p.featuredOptions.count,5)
        let other = try XCTUnwrap(p.options.last)
        XCTAssertFalse(p.featuredOptions.contains { $0.id == other.id })
        p.select(other)
        XCTAssertTrue(p.featuredOptions.contains { $0.id == other.id })
        XCTAssertEqual(p.featuredOptions.count,5);XCTAssertFalse(p.started)
    }
    func testSameRouteKeepsDifferentBoardingTradeoffsButMergesNearDuplicates() {
        func choice(_ index: Int, walk: Double, ride: Double) -> JourneyOption {
            let r = BusRoute(id:"same-route",parentID:"same-route",name:"同路線",variantName:"",departure:"起點",destination:"終點")
            let boarding = Coordinate(latitude:25.04,longitude:121.545 + Double(index)*0.003)
            let stops = [BusStop(id:"board-\(index)",routeID:r.id,stationID:"board-\(index)",name:"上車\(index)",direction:"0",sequence:1,coordinate:boarding),
                         BusStop(id:"end",routeID:r.id,stationID:"end",name:"下車",direction:"0",sequence:2,coordinate:c)]
            let segment = TransitRide(route:r,direction:"0",stops:stops,coordinates:[boarding,c])
            let trip = TransitTrip(rides:[segment],accessDistance:500,egressDistance:0,transferDistance:0,score:0,rideSeconds:[ride])
            return JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:a,to:boarding,distance:500,duration:walk),WalkingLeg(from:c,to:c,distance:0,duration:0)])
        }
        let nearby = choice(0,walk:600,ride:1000), faster = choice(1,walk:900,ride:500), duplicate = choice(2,walk:920,ride:480)
        let p = JourneyPlannerModel()
        p.auditLoadChoices([nearby,faster,duplicate],from:TravelPlace(name:"出發",address:"",coordinate:a),to:TravelPlace(name:"目的地",address:"",coordinate:c))
        XCTAssertTrue(p.options.contains { $0.id == nearby.id })
        XCTAssertTrue(p.options.contains { $0.id == faster.id })
        XCTAssertFalse(p.options.contains { $0.id == duplicate.id })
    }
    func testStreetTransferCanUseABikeButIndoorPlatformChangeCannot() {
        let outdoor = transfer(internalWalk:false), p = planner(outdoor)
        XCTAssertTrue(p.auditBikeConnections([outdoor]).contains { $0.walks[1].bike != nil })
        let indoor = transfer(internalWalk:true)
        XCTAssertTrue(planner(indoor).auditBikeConnections([indoor]).isEmpty)
    }
    func testMissingBikeOrDockPreventsTheCombinedTripWithoutHidingTheOtherEnd() {
        let original = base(), bikes = network(original)
        for unavailable in [counts(bikes,empty:["0-pickup"]),counts(bikes,full:["0-dropoff"])] {
            let p = planner(original,availability:unavailable)
            let choices = p.auditBikeConnections([original])
            XCTAssertFalse(choices.isEmpty)
            XCTAssertTrue(choices.allSatisfy { $0.walks[0].bike == nil && $0.walks[1].bike != nil })
        }
        XCTAssertTrue(planner(original,availability:counts(bikes,age:1800)).auditBikeConnections([original]).isEmpty)
    }
    func testSecondRentalChecksItsOwnStationsAfterTheFirstRentalIsFinished() async throws {
        let original = base(), p = planner(original), bikes = network(original)
        p.updateBikes(network:bikes,availability:counts(bikes)); await settle(p)
        let before = try XCTUnwrap(p.selected)
        XCTAssertEqual(p.plannedPickupStations.count,2)
        p.begin();p.advance();p.advance()
        XCTAssertEqual(p.upcomingBikeLegIndex,1)
        let alternate = BikeStation(id:"1-alternate",name:"第二段其他借車站",coordinate:Coordinate(latitude:c.latitude,longitude:c.longitude+0.0001),capacity:30)
        let updatedNetwork = BikeNetwork(stations:bikes.stations + [alternate])
        p.updateBikes(network:updatedNetwork,availability:counts(updatedNetwork,empty:["0-pickup","1-pickup"]))
        guard case .noBikes(let station, _)? = p.bikeAlert else { return XCTFail("The upcoming second rental must warn") }
        XCTAssertEqual(station.id,"1-pickup")
        p.moveBikeStation(to:alternate,renting:true)
        for _ in 0..<200 {
            if !p.changingBikeStation { break }
            try? await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertEqual(p.selected?.walks[0].bike?.pickup.id,before.walks[0].bike?.pickup.id)
        XCTAssertEqual(p.selected?.walks[1].bike?.pickup.id,"1-alternate")
    }
    func testLateCountsAlsoOfferAnEntireBikeTrip() async throws {
        let original = base(), p = JourneyPlannerModel()
        let end = original.walks[0].to
        let walking = JourneyOption(id:"walking",trip:nil,walks:[WalkingLeg(from:a,to:end,distance:1500,duration:1500)])
        p.auditLoadChoices([walking],from:TravelPlace(name:"出發",address:"",coordinate:a),to:TravelPlace(name:"目的地",address:"",coordinate:end))
        p.testCycle = planner(original).testCycle
        let bikes = network(original)
        p.updateBikes(network:bikes,availability:counts(bikes));await settle(p)
        XCTAssertTrue(try XCTUnwrap(p.selected).bikeOnly)
        XCTAssertFalse(p.started)
    }
    func testBikeReachableRailCorridorsAreComparedAtEitherOrBothEnds() async throws {
        let service = TransitService(), loaded = await service.offlineMetroMetadata()
        let metadata = try XCTUnwrap(loaded)
        let from = Coordinate(latitude:25.012,longitude:121.55), to = Coordinate(latitude:25.0434,longitude:121.49)
        var stations = [BikeStation(id:"origin",name:"出發借車",coordinate:from,capacity:30),
                        BikeStation(id:"destination",name:"目的地還車",coordinate:to,capacity:30)]
        var seen = Set<String>()
        for station in metadata.metro.stations {
            for point in [from,to] {
                guard let exit = metadata.metro.nearestExit(stationID:station.id,to:point), seen.insert(exit.id).inserted else { continue }
                stations.append(BikeStation(id:exit.id,name:exit.name,coordinate:exit.coordinate,capacity:30))
            }
        }
        let bikes = BikeNetwork(stations:stations), p = JourneyPlannerModel()
        p.updateBikes(network:bikes,availability:counts(bikes))
        let probes = p.auditBikeGatewayProbes(metadata:metadata,from:from,to:to)
        XCTAssertTrue(probes.contains { $0.0 != from && $0.1 == to },"Compare riding to a farther rail station")
        XCTAssertTrue(probes.contains { $0.0 == from && $0.1 != to },"Compare riding after alighting")
        XCTAssertTrue(probes.contains { $0.0 != from && $0.1 != to },"Compare biking at both ends")
        XCTAssertLessThanOrEqual(probes.count,8)
        let stale = JourneyPlannerModel();stale.updateBikes(network:bikes,availability:counts(bikes,age:1800))
        XCTAssertTrue(stale.auditBikeGatewayProbes(metadata:metadata,from:from,to:to).isEmpty)
    }
}
