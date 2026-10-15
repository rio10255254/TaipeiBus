import XCTest
@testable import TransitCore
@testable import TaipeiBus

/// Desired-behavior assertions against 1.8.1. Failures are retained as audit evidence.
@MainActor
final class Audit181Tests: XCTestCase {
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
}
