import XCTest
@testable import TransitCore
@testable import TaipeiBus

@MainActor final class RoutePlanningRegressionTests: XCTestCase {
    let start=Coordinate(latitude:25.0192,longitude:121.5390)
    let end=Coordinate(latitude:25.0434,longitude:121.5062)
    func choice(_ id: String, rideSeconds: Double, metro: Bool=false) -> JourneyOption {
        var route=BusRoute(id:id,parentID:id,name:id,variantName:"",departure:"起點",destination:"終點")
        route.mode=metro ? .metro : .bus;route.lineCode=metro ? "G" : ""
        let stops=[BusStop(id:id+"-a",routeID:id,stationID:id+"-a",name:"上車",direction:"0",sequence:1,coordinate:start),BusStop(id:id+"-b",routeID:id,stationID:id+"-b",name:"下車",direction:"0",sequence:2,coordinate:end)]
        let ride=TransitRide(route:route,direction:"0",stops:stops,coordinates:[start,end])
        let trip=TransitTrip(rides:[ride],accessDistance:0,egressDistance:0,transferDistance:0,score:0,rideSeconds:[rideSeconds])
        return JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:start,to:start,duration:0),WalkingLeg(from:end,to:end,duration:0)])
    }
    func planner(_ options:[JourneyOption]) -> JourneyPlannerModel {
        let p=JourneyPlannerModel()
        p.auditLoadChoices(options,from:TravelPlace(name:"臺大",address:"",coordinate:start),to:TravelPlace(name:"西門",address:"",coordinate:end))
        return p
    }
    func waitForChoices(_ p: JourneyPlannerModel) async {
        for _ in 0..<100 { if !p.checkingWalks { return };try? await Task.sleep(for:.milliseconds(20)) }
        XCTFail("Later candidates did not finish")
    }
    func testPreviewKeepsSearchingAndRetainsTheInspectedRoute() async {
        let bus=choice("18",rideSeconds:2200), green=choice("G",rideSeconds:900,metro:true)
        let p=planner([bus]);p.auditVerifyAdditionalChoices([green]);p.select(bus)
        XCTAssertTrue(p.checkingWalks,"Preview must not cancel the search")
        let mapRevision=p.mapRevision
        await waitForChoices(p)
        XCTAssertFalse(p.started)
        XCTAssertEqual(p.selectedID,bus.id)
        XCTAssertEqual(p.mapRevision,mapRevision,"New alternatives must not refocus the inspected route")
        XCTAssertTrue(p.options.contains { $0.id==green.id })
        XCTAssertTrue(p.options.contains { $0.id==bus.id })
        XCTAssertEqual(p.optionLabels[green.id],"推薦")
        p.refreshRecommendations()
        XCTAssertEqual(p.selectedID,green.id)
    }
    func testUnselectedPreviewAutomaticallyPromotesTheLaterBetterRoute() async {
        let bus=choice("18",rideSeconds:2200), green=choice("G",rideSeconds:900,metro:true)
        let p=planner([bus]);p.auditVerifyAdditionalChoices([green])
        await waitForChoices(p)
        XCTAssertEqual(p.selectedID,green.id)
        XCTAssertFalse(p.started)
    }
    func testStartingNavigationStopsLaterCandidatesFromChangingTheTrip() async {
        let bus=choice("18",rideSeconds:2200), green=choice("G",rideSeconds:900,metro:true)
        let p=planner([bus]);p.auditVerifyAdditionalChoices([green]);p.select(bus);p.begin()
        try? await Task.sleep(for:.milliseconds(250))
        XCTAssertTrue(p.started);XCTAssertFalse(p.checkingWalks)
        XCTAssertEqual(p.selectedID,bus.id)
        XCTAssertFalse(p.options.contains { $0.id==green.id })
    }
    func testBoardingAlsoStopsLaterCandidatesFromChangingTheRide() async {
        let bus=choice("18",rideSeconds:2200), green=choice("G",rideSeconds:900,metro:true)
        let p=planner([bus]);p.auditVerifyAdditionalChoices([green]);p.select(bus);p.boardCurrentRide()
        try? await Task.sleep(for:.milliseconds(250))
        XCTAssertTrue(p.started);XCTAssertFalse(p.checkingWalks)
        XCTAssertEqual(p.selectedID,bus.id)
        XCTAssertFalse(p.options.contains { $0.id==green.id })
    }
    func testPersonalPreferencesChangeRankingWithoutInflatingTravelTime() throws {
        var bus=choice("18",rideSeconds:1800), green=choice("G",rideSeconds:900,metro:true)
        bus.walks[0].duration=120;green.walks[0].duration=600
        let p=planner([bus,green])
        let date=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-10-15T08:25:00Z"))
        let baseline=try XCTUnwrap(p.duration(green,at:date))
        XCTAssertEqual(p.selectedID,green.id)
        for preference in RoutePreference.allCases {
            var settings=LiveSettings.defaults
            settings.planning=preference.applying(to:settings.planning)
            p.updateSettings(settings);p.refreshRecommendations()
            let timing=try XCTUnwrap(p.duration(green,at:date))
            XCTAssertEqual(timing.totalSeconds,baseline.totalSeconds,accuracy:0.001)
            if preference == .lessWalking { XCTAssertEqual(p.selectedID,bus.id) }
        }
    }
    func testRealGongguanXimenTripSurvivesPedestrianVerification() async throws {
        let service=TransitService()
        let loaded=await service.offlineMetroMetadata()
        let metadata=try XCTUnwrap(loaded)
        let date=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-10-15T08:25:00Z"))
        let trips=MultimodalPlanner(metadata:metadata).plan(from:start,to:end,maximumWalk:1200,limit:36,at:date)
        let trip=try XCTUnwrap(trips.first { $0.rides.count==1 && $0.rides[0].boarding.stationID=="metro:TRTC:G07" && $0.rides[0].alighting.stationID=="metro:TRTC:G12" })
        let entry=try XCTUnwrap(metadata.metro.nearestExit(stationID:trip.rides[0].boarding.stationID,to:start))
        let exit=try XCTUnwrap(metadata.metro.nearestExit(stationID:trip.rides[0].alighting.stationID,to:end))
        let option=JourneyOption(id:trip.id,trip:trip,walks:[
            WalkingLeg(from:start,to:entry.coordinate,stationSeconds:trip.rides[0].boardingAccessSeconds,stationInstruction:entry.name),
            WalkingLeg(from:exit.coordinate,to:end,stationSeconds:trip.rides[0].alightingAccessSeconds,stationInstruction:exit.name)])
        let p=JourneyPlannerModel(), verified=try await p.auditEnrich(option,metadata:metadata)
        XCTAssertTrue(verified.verified);XCTAssertNil(verified.walkIssue)
        let timing=try XCTUnwrap(p.duration(verified,at:date))
        XCTAssertLessThan(timing.totalSeconds,2400.0)
        XCTAssertEqual(timing.totalSeconds,timing.walkingSeconds+timing.waitingSeconds+timing.ridingSeconds,accuracy:0.001)
        print("GONGGUAN_VERIFIED entry=\(entry.name) exit=\(exit.name) walking=\(timing.walkingSeconds/60) waiting=\(timing.waitingSeconds/60) riding=\(timing.ridingSeconds/60) total=\(timing.totalSeconds/60) arrival=\(timing.arrivalLabel)")
        // Known station geometry and real cycling directions, with explicitly controlled
        // availability. This does not claim the same bikes were available in the user's photo.
        let bikes = await service.bikeNetwork(), now = Date()
        let counts = BikeAvailability(docks: Dictionary(uniqueKeysWithValues: bikes.stations.map {
            ($0.id, BikeDock(stationID: $0.id, rentable: 8, returnable: 8, capacity: $0.capacity, active: true, observedAt: now))
        }), receivedAt: now)
        p.updateBikes(network: bikes, availability: counts)
        let connector = try XCTUnwrap(p.auditBikeConnections([verified], at: now).first { $0.trip?.variant == "youbike-access" })
        let cycled = try await p.auditEnrich(connector, metadata: metadata)
        XCTAssertTrue(cycled.verified); XCTAssertNil(cycled.walkIssue)
        let bike = try XCTUnwrap(cycled.walks.first?.bike)
        XCTAssertGreaterThan(bike.ride.count, 2)
        let cycledTiming = try XCTUnwrap(p.duration(cycled, at: date))
        XCTAssertLessThan(cycledTiming.totalSeconds, timing.totalSeconds)
        print("GONGGUAN_CYCLING controlled_counts=true pickup=\(bike.pickup.name) dropoff=\(bike.dropoff.name) access_seconds=\(cycled.walks[0].duration ?? -1) bike_seconds=\(bike.rideSeconds) total_minutes=\(cycledTiming.totalSeconds/60) saved_minutes=\((timing.totalSeconds-cycledTiming.totalSeconds)/60)")
    }

}
