import XCTest
import MapKit
@testable import TransitCore
@testable import TaipeiBus

/// Regression tests for routing defects found in 1.8.1.
@MainActor
final class BikePlannerTests: XCTestCase {
    let start = Coordinate(latitude:25.04,longitude:121.54)
    let pickup = BikeStation(id:"pickup",name:"借車站",district:"大安",coordinate:Coordinate(latitude:25.04,longitude:121.541),capacity:30)
    let dropoff = BikeStation(id:"dropoff",name:"還車站",district:"大安",coordinate:Coordinate(latitude:25.04,longitude:121.554),capacity:30)
    let end = Coordinate(latitude:25.04,longitude:121.555)
    func counts(pickup bikes: Int = 8, dropoff docks: Int = 8) -> BikeAvailability {
        let now = Date()
        return BikeAvailability(docks:[
            pickup.id:BikeDock(stationID:pickup.id,rentable:bikes,returnable:10,capacity:30,active:true,observedAt:now),
            dropoff.id:BikeDock(stationID:dropoff.id,rentable:8,returnable:docks,capacity:30,active:true,observedAt:now)],receivedAt:now)
    }
    func cycling() -> JourneyOption {
        let access = start.distance(to:pickup.coordinate), ride = pickup.coordinate.distance(to:dropoff.coordinate), egress = dropoff.coordinate.distance(to:end)
        var bike = BikeLeg(BikeConnection(pickup:pickup,dropoff:dropoff,bikes:8,docks:8,
            accessMeters:access,rideMeters:ride,egressMeters:egress,
            accessSeconds:100,rideSeconds:700,egressSeconds:100,handlingSeconds:0))
        bike.toPickup=[start,pickup.coordinate];bike.ride=[pickup.coordinate,dropoff.coordinate];bike.fromDropoff=[dropoff.coordinate,end]
        var leg=WalkingLeg(from:start,to:end,coordinates:bike.coordinates,distance:bike.totalMeters,duration:900)
        leg.streetDuration=900;leg.bike=bike;leg.road=RouteLine(coordinates:bike.coordinates)
        return JourneyOption(id:"youbike",trip:nil,walks:[leg])
    }
    func planner(_ choices: [JourneyOption]) -> JourneyPlannerModel {
        let p=JourneyPlannerModel()
        p.updateBikes(network:BikeNetwork(stations:[pickup,dropoff]),availability:counts())
        p.auditLoadChoices(choices,from:TravelPlace(name:"起點",address:"",coordinate:start),to:TravelPlace(name:"終點",address:"",coordinate:end))
        return p
    }
    func testCyclingDoesNotLeadWhenTransitIsMuchFaster() throws {
        let route=BusRoute(id:"fast",parentID:"fast",name:"快車",variantName:"",departure:"起點",destination:"終點")
        let stops=[BusStop(id:"a",routeID:"fast",stationID:"a",name:"上車",direction:"0",sequence:1,coordinate:start),
                   BusStop(id:"b",routeID:"fast",stationID:"b",name:"下車",direction:"0",sequence:2,coordinate:end)]
        let ride=TransitRide(route:route,direction:"0",stops:stops,coordinates:[start,end])
        let trip=TransitTrip(rides:[ride],accessDistance:0,egressDistance:0,transferDistance:0,score:0,rideSeconds:[300])
        let transit=JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:start,to:start,duration:0),WalkingLeg(from:end,to:end,duration:0)])
        let foot=JourneyOption(id:"walking",trip:nil,walks:[WalkingLeg(from:start,to:end,distance:1500,duration:1500)])
        let p=planner([transit,cycling(),foot])
        var snapshot=TransitSnapshot();snapshot.estimates=EstimateFeed(seconds:["fast:a":120],updatedAt:Date())
        p.updateSnapshot(snapshot);p.refreshRecommendations()
        let busSeconds=try XCTUnwrap(p.duration(transit,at:Date())).totalSeconds
        let bikeSeconds=try XCTUnwrap(p.duration(cycling(),at:Date())).totalSeconds
        print("AUDIT181 ranking bus=\(busSeconds), bike=\(bikeSeconds), walking=1500, selected=\(p.selectedID ?? "nil")")
        XCTAssertLessThan(busSeconds,bikeSeconds-240)
        XCTAssertEqual(p.options.first?.id,trip.id,"A 15-minute bike option must not displace a 7-minute bus just because it beats walking")
    }
    func testEmptyPickupIsIgnoredAfterTheRiderHasTakenABike() throws {
        let p=planner([cycling()]);p.begin()
        let now=Date();p.updateWalking(index:0,coordinate:Coordinate(latitude:25.04,longitude:121.548),accuracy:4,timestamp:now,now:now)
        guard case .riding? = p.cyclingPhase(at:0) else { return XCTFail("Fixture must be in the riding phase") }
        p.updateBikes(network:BikeNetwork(stations:[pickup,dropoff]),availability:counts(pickup:0))
        print("AUDIT181 riding pickup_empty alert=\(String(describing:p.bikeAlert))")
        XCTAssertNil(p.bikeAlert,"Once riding, an empty original pickup must not tell the rider to borrow another bike")
    }
    func testSlightlyFasterWholeBikeStaysAvailableWithoutForcingTheRiderOffTransit() {
        let route=BusRoute(id:"reasonable",parentID:"reasonable",name:"公車",variantName:"",departure:"起點",destination:"終點")
        let stops=[BusStop(id:"ra",routeID:route.id,stationID:"ra",name:"上車",direction:"0",sequence:1,coordinate:start),
                   BusStop(id:"rb",routeID:route.id,stationID:"rb",name:"下車",direction:"0",sequence:2,coordinate:end)]
        let ride=TransitRide(route:route,direction:"0",stops:stops,coordinates:[start,end])
        let trip=TransitTrip(rides:[ride],accessDistance:0,egressDistance:0,transferDistance:0,score:0,rideSeconds:[900])
        let transit=JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:start,to:start,duration:0),WalkingLeg(from:end,to:end,duration:0)])
        let p=planner([transit,cycling()])
        var snapshot=TransitSnapshot();snapshot.estimates=EstimateFeed(seconds:["reasonable:ra":120],updatedAt:Date())
        p.updateSnapshot(snapshot);p.refreshRecommendations()
        XCTAssertEqual(p.selectedID,transit.id)
        XCTAssertTrue(p.options.contains { $0.bikeOnly },"A useful 2-minute saving should remain selectable")
    }
    func testFullDropoffStillWarnsWhileRiding() throws {
        let p=planner([cycling()]);p.begin()
        let now=Date();p.updateWalking(index:0,coordinate:Coordinate(latitude:25.04,longitude:121.548),accuracy:4,timestamp:now,now:now)
        p.updateBikes(network:BikeNetwork(stations:[pickup,dropoff]),availability:counts(dropoff:0))
        guard case .noDocks? = p.bikeAlert else { return XCTFail("A full upcoming return station must still warn") }
    }
    func testCompletedDockingDoesNotWarnAboutOldBikeStations() throws {
        let p=planner([cycling()]);p.begin()
        let now=Date();p.updateWalking(index:0,coordinate:Coordinate(latitude:25.04,longitude:121.5547),accuracy:4,timestamp:now,now:now)
        guard case .fromDropoff? = p.cyclingPhase(at:0) else { return XCTFail("Fixture must have passed the return station") }
        p.updateBikes(network:BikeNetwork(stations:[pickup,dropoff]),availability:counts(pickup:0,dropoff:0))
        print("AUDIT181 after_return alert=\(String(describing:p.bikeAlert))")
        XCTAssertNil(p.bikeAlert,"Past stations must not interrupt the final walk")
    }
    private func waitForStation(_ p: JourneyPlannerModel) async {
        for _ in 0..<200 {
            if !p.changingBikeStation { return }
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        XCTFail("Station verification did not finish")
    }
    func testUnverifiedReplacementKeepsTheConfirmedTripAndCanRetry() async throws {
        let p=planner([cycling()])
        let before=try XCTUnwrap(p.selected)
        p.testCycle = { leg in var result=leg; result.duration=nil; return result }
        p.moveBikeStation(to:dropoff,renting:true)
        XCTAssertEqual(p.selected?.walks[0].bike?.pickup.id,pickup.id)
        await waitForStation(p)
        XCTAssertEqual(p.selected?.walks[0].bike?.pickup.id,pickup.id)
        XCTAssertEqual(p.selected?.walks[0].duration,before.walks[0].duration)
        XCTAssertTrue(p.selected?.verified == true)
        XCTAssertNotNil(p.bikeStationUpdateMessage)
        p.testCycle = { leg in leg }
        p.moveBikeStation(to:pickup,renting:false)
        await waitForStation(p)
        XCTAssertEqual(p.selected?.walks[0].bike?.dropoff.id,pickup.id)
        XCTAssertNil(p.bikeStationUpdateMessage)
        p.refreshRecommendations()
        XCTAssertEqual(p.selected?.walks[0].bike?.dropoff.id,pickup.id,"Refreshed recommendations must retain the confirmed replacement")
    }
    func testThrownReplacementKeepsNavigationAndProgress() async {
        let p=planner([cycling()]);p.begin()
        let now=Date();p.updateWalking(index:0,coordinate:Coordinate(latitude:25.04,longitude:121.548),accuracy:4,timestamp:now,now:now)
        let remaining=p.walkingProgress?.remainingDistance
        p.testCycle = { _ in throw NSError(domain:"offline",code:1) }
        p.moveBikeStation(to:pickup,renting:false)
        await waitForStation(p)
        XCTAssertTrue(p.started)
        XCTAssertEqual(p.selected?.walks[0].bike?.dropoff.id,dropoff.id)
        XCTAssertEqual(p.walkingProgress?.remainingDistance,remaining)
        XCTAssertNotNil(p.bikeStationUpdateMessage)
    }
    func testClosingTripDiscardsLateStationResult() async {
        let p=planner([cycling()])
        p.testCycle = { leg in try? await Task.sleep(nanoseconds:100_000_000);return leg }
        p.moveBikeStation(to:pickup,renting:false)
        p.finish()
        try? await Task.sleep(nanoseconds:200_000_000)
        XCTAssertNil(p.selected)
        XCTAssertFalse(p.changingBikeStation)
        XCTAssertNil(p.bikeStationUpdateMessage)
    }

    private func longAccessTransit() -> JourneyOption {
        var route=BusRoute(id:"G",parentID:"G",name:"松山新店線",variantName:"",departure:"公館",destination:"西門")
        route.mode = .metro
        let destination=Coordinate(latitude:25.06,longitude:end.longitude)
        let stops=[BusStop(id:"G-a",routeID:"G",stationID:"G-a",name:"公館",direction:"0",sequence:1,coordinate:end),
                   BusStop(id:"G-b",routeID:"G",stationID:"G-b",name:"西門",direction:"0",sequence:2,coordinate:destination)]
        let ride=TransitRide(route:route,direction:"0",stops:stops,coordinates:[end,destination])
        let trip=TransitTrip(rides:[ride],accessDistance:1500,egressDistance:0,transferDistance:0,score:0,rideSeconds:[600])
        return JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:start,to:end,distance:1500,duration:1500),
            WalkingLeg(from:destination,to:destination,duration:0)])
    }
    func testLateBikeCountsAddMetroConnectorWithoutReplacingTheInspectedRoute() async throws {
        let base=longAccessTransit(), p=JourneyPlannerModel()
        p.auditLoadChoices([base],from:TravelPlace(name:"起點",address:"",coordinate:start),to:TravelPlace(name:"終點",address:"",coordinate:base.walks.last!.to))
        p.select(base)
        let revision=p.mapRevision
        p.testCycle = { _ in self.cycling().walks[0] }
        p.updateBikes(network:BikeNetwork(stations:[pickup,dropoff]),availability:counts())
        for _ in 0..<200 {
            if !p.checkingWalks { break }
            try? await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertFalse(p.checkingWalks)
        XCTAssertEqual(p.selectedID,base.id);XCTAssertEqual(p.mapRevision,revision)
        XCTAssertFalse(p.started)
        let bike=try XCTUnwrap(p.options.first { $0.cycles })
        XCTAssertEqual(bike.rides.first?.route.mode,.metro)
        XCTAssertTrue(bike.verified)
        p.refreshRecommendations();XCTAssertEqual(p.selectedID,bike.id)
    }
    func testLateCountsCannotReopenAClosedJourney() async {
        let base=longAccessTransit(), p=planner([base])
        p.testCycle = { _ in try? await Task.sleep(for:.milliseconds(100));return self.cycling().walks[0] }
        p.updateBikes(network:BikeNetwork(stations:[pickup,dropoff]),availability:counts())
        p.finish()
        try? await Task.sleep(for:.milliseconds(200))
        XCTAssertNil(p.selected);XCTAssertTrue(p.options.isEmpty);XCTAssertFalse(p.checkingWalks)
    }

    func testLiveTaipeiCyclingDirectionsBetweenUserStations() async throws {
        let p=JourneyPlannerModel()
        let a=BikeStation(id:"500110026",name:"八德路三段74巷口",district:"",coordinate:Coordinate(latitude:25.04459,longitude:121.55252),capacity:30)
        let b=BikeStation(id:"500107088",name:"南京伊通街口",district:"",coordinate:Coordinate(latitude:25.05189,longitude:121.53517),capacity:30)
        let connection=BikeConnection(pickup:a,dropoff:b,bikes:5,docks:5,accessMeters:0,rideMeters:2000,egressMeters:0,accessSeconds:0,rideSeconds:600,egressSeconds:0,handlingSeconds:150)
        var input=WalkingLeg(from:a.coordinate,to:b.coordinate);input.bike=BikeLeg(connection)
        let result=try await p.verifyCyclingLegForTest(input)
        XCTAssertTrue(result.verified,"Real cycling directions must be available for the user's Taipei route")
        let bike=try XCTUnwrap(result.bike)
        XCTAssertGreaterThan(bike.ride.count,2)
        XCTAssertGreaterThan(bike.rideSeconds,60)
        XCTAssertGreaterThan(bike.rideMeters,1000)
        XCTAssertFalse(result.instructions.isEmpty)
        // Compare the real requested-mode response, not MKRoute's misleading transport flag.
        // The reported Taipei example has distinct pedestrian and bicycle paths.
        let walkingRequest=MKDirections.Request()
        walkingRequest.source=TravelPlace(name:"借車",address:"",coordinate:a.coordinate).mapItem
        walkingRequest.destination=TravelPlace(name:"還車",address:"",coordinate:b.coordinate).mapItem
        walkingRequest.transportType = .walking
        let response=try await MKDirections(request:walkingRequest).calculate()
        let pedestrian=try XCTUnwrap(response.routes.compactMap { PedestrianPath.leg($0,from:a.coordinate,to:b.coordinate) }.first)
        XCTAssertNotEqual(bike.ride,pedestrian.coordinates,"Cycling must not reuse the pedestrian path with a faster speed")
        XCTAssertLessThan(bike.rideSeconds,try XCTUnwrap(pedestrian.duration)/2)
        print("LIVE_CYCLING meters=\(bike.rideMeters) seconds=\(bike.rideSeconds) points=\(bike.ride.count) instructions=\(result.instructions.count)")
    }

}
