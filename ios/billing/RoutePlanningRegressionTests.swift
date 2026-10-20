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
        XCTAssertEqual(p.options.first?.id,green.id,"A new recommendation belongs first even while another route is being inspected")
        XCTAssertEqual(p.featuredOptions.first?.id,green.id)
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
    func testVisibleFirstChoiceKeepsItsActionWhileLaterRoutesAreCompared() async {
        let bus = choice("18", rideSeconds: 2200), green = choice("G", rideSeconds: 900, metro: true)
        let p = planner([bus]); p.retainVisiblePreview()
        let revision = p.mapRevision
        p.auditVerifyAdditionalChoices([green])
        await waitForChoices(p)
        XCTAssertEqual(p.options.first?.id, green.id)
        XCTAssertEqual(p.selectedID, bus.id)
        XCTAssertEqual(p.mapRevision, revision)
        XCTAssertTrue(p.comparisonChanged); XCTAssertFalse(p.started)
        p.select(green); p.begin()
        XCTAssertEqual(p.selectedID, green.id); XCTAssertTrue(p.started)
    }
    func testStationAccessAndTransferAppearInTheBreakdownWithoutAddingTime() throws {
        var option = choice("G", rideSeconds: 900, metro: true)
        option.walks[0].duration = 420; option.walks[0].streetDuration = 240; option.walks[0].stationSeconds = 180
        option.walks[1].duration = 180; option.walks[1].streetDuration = 60; option.walks[1].stationSeconds = 120
        let p = planner([option]), time = try XCTUnwrap(p.duration(option, at: Date()))
        XCTAssertEqual(time.stationSeconds, 300)
        XCTAssertEqual(time.walkingSeconds, 600)
        XCTAssertEqual(time.components.first { $0.kind == .walking }?.seconds, 300)
        XCTAssertEqual(time.components.reduce(0) { $0 + $1.seconds }, time.totalSeconds, accuracy: 0.001)
    }
    func testInternalTransferAllowanceRemainsInsideItsExistingLeg() {
        let leg = WalkingLeg(from: start, to: end, duration: 180, internalTransfer: true)
        XCTAssertEqual(leg.stationAllowance, 180)
        let minimum = WalkingLeg(from: start, to: end, duration: 300, stationSeconds: 60, streetDuration: 120)
        XCTAssertEqual(minimum.stationAllowance, 180, "An official minimum transfer allowance is already part of this leg")
    }
    func testOfficialArrivalUpdateKeepsRecommendationFirstWithoutMovingTheInspectedRoute() throws {
        let one=choice("one",rideSeconds:900),two=choice("two",rideSeconds:900)
        let p=planner([one,two]), now=Date()
        var initial=TransitSnapshot()
        initial.estimates=EstimateFeed(seconds:["one:one-a":120,"two:two-a":600],updatedAt:now)
        p.updateSnapshot(initial);p.select(one)
        XCTAssertEqual(p.options.first?.id,one.id)
        let revision=p.mapRevision
        var next=TransitSnapshot()
        next.estimates=EstimateFeed(seconds:["one:one-a":600,"two:two-a":120],updatedAt:now)
        p.updateSnapshot(next)
        XCTAssertEqual(p.options.first?.id,two.id)
        XCTAssertEqual(p.optionLabels[two.id],"推薦")
        XCTAssertEqual(p.selectedID,one.id);XCTAssertEqual(p.mapRevision,revision)
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
    func testNeihuToNTUUsesRealCyclingTimeAndIncludesAccessAndHandling() async throws {
        let service=TransitService(), loaded=await service.offlineMetroMetadata()
        let metadata=try XCTUnwrap(loaded), bikes=await service.bikeNetwork(), now=Date()
        let neihu=try XCTUnwrap(metadata.metro.stations.first { $0.code == "BR19" })
        let target=try XCTUnwrap(bikes.station("500119071"))
        let date=try XCTUnwrap(ISO8601DateFormatter().date(from:"2026-10-16T01:23:00Z"))
        let trips=MultimodalPlanner(metadata:metadata).plan(from:neihu.coordinate,to:target.coordinate,maximumWalk:1200,limit:36,at:date)
        let trip=try XCTUnwrap(trips.first { $0.rides.count == 1 && $0.rides[0].boarding.stationID == neihu.id && $0.rides[0].alighting.stationID == "metro:TRTC:BR08" })
        let ride=trip.rides[0]
        let entry=try XCTUnwrap(metadata.metro.nearestExit(stationID:ride.boarding.stationID,to:neihu.coordinate))
        let exit=try XCTUnwrap(metadata.metro.nearestExit(stationID:ride.alighting.stationID,to:target.coordinate))
        let base=JourneyOption(id:trip.id,trip:trip,walks:[
            WalkingLeg(from:neihu.coordinate,to:entry.coordinate,stationSeconds:ride.boardingAccessSeconds),
            WalkingLeg(from:exit.coordinate,to:target.coordinate,stationSeconds:ride.alightingAccessSeconds)])
        let p=JourneyPlannerModel(), walked=try await p.auditEnrich(base,metadata:metadata)
        XCTAssertTrue(walked.verified);XCTAssertNil(walked.walkIssue)
        let counts=BikeAvailability(docks:Dictionary(uniqueKeysWithValues:bikes.stations.map {
            ($0.id,BikeDock(stationID:$0.id,rentable:8,returnable:8,capacity:$0.capacity,active:true,observedAt:now))
        }),receivedAt:now)
        p.updateBikes(network:bikes,availability:counts)
        let connector=try XCTUnwrap(BikeRouting.connection(from:exit.coordinate,to:target.coordinate,network:bikes,availability:counts,at:now))
        var input=base.walks[1];input.bike=BikeLeg(connector)
        let result=try await p.verifyCyclingLegForTest(input), bike=try XCTUnwrap(result.bike)
        XCTAssertTrue(result.verified);XCTAssertGreaterThan(bike.ride.count,2)
        XCTAssertLessThan(bike.rideSeconds,try XCTUnwrap(walked.walks[1].streetDuration))
        XCTAssertEqual(try XCTUnwrap(result.duration),bike.rideSeconds+bike.walkingSeconds+bike.handlingSeconds+input.stationSeconds,accuracy:0.001)
        print("NEIHU_NTU controlled_counts=true pickup=\(bike.pickup.name) dropoff=\(bike.dropoff.name) ride_meters=\(bike.rideMeters) pure_riding_seconds=\(bike.rideSeconds) on_foot_seconds=\(bike.walkingSeconds) handling_seconds=\(bike.handlingSeconds) station_seconds=\(input.stationSeconds) connector_seconds=\(result.duration ?? -1) all_walking_seconds=\(walked.walks[1].duration ?? -1)")
    }

}
