import XCTest
import MapKit
@testable import TransitCore
@testable import TaipeiBus

@MainActor final class PlanningEngineTests: XCTestCase {
    let a = Coordinate(latitude:25.04,longitude:121.54)
    let b = Coordinate(latitude:25.04,longitude:121.555)
    func transit(_ id: String = "bus", seconds: Double = 1000) -> JourneyOption {
        let route = BusRoute(id:id,parentID:id,name:id,variantName:"",departure:"上車",destination:"下車")
        let stops = [BusStop(id:id+"a",routeID:id,stationID:id+"a",name:"上車",direction:"0",sequence:1,coordinate:a),
                     BusStop(id:id+"b",routeID:id,stationID:id+"b",name:"下車",direction:"0",sequence:2,coordinate:b)]
        let ride = TransitRide(route:route,direction:"0",stops:stops,coordinates:[a,b])
        let trip = TransitTrip(rides:[ride],accessDistance:0,egressDistance:0,transferDistance:0,score:0,rideSeconds:[seconds])
        return JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:a,to:a,duration:0),WalkingLeg(from:b,to:b,duration:0)])
    }
    func bicycle() -> JourneyOption {
        let pickup = BikeStation(id:"pickup",name:"借車",coordinate:a,capacity:30)
        let dropoff = BikeStation(id:"dropoff",name:"還車",coordinate:b,capacity:30)
        var bike = BikeLeg(pickup:pickup,dropoff:dropoff,bikes:8,docks:8,handlingSeconds:150)
        bike.rideSeconds = 700; bike.rideMeters = a.distance(to:b); bike.ride = [a,b]
        var leg = WalkingLeg(from:a,to:b,coordinates:[a,b],distance:bike.totalMeters,duration:bike.totalSeconds)
        leg.bike = bike; leg.road = RouteLine(coordinates:leg.coordinates)
        return JourneyOption(id:"youbike",trip:nil,walks:[leg])
    }
    func counts(_ stations: [BikeStation], empty: Set<String> = []) -> BikeAvailability {
        let now = Date()
        return BikeAvailability(docks:Dictionary(uniqueKeysWithValues:stations.map {
            ($0.id,BikeDock(stationID:$0.id,rentable:empty.contains($0.id) ? 0 : 8,returnable:8,capacity:30,active:true,observedAt:now))
        }),receivedAt:now)
    }
    func planner(_ choices: [JourneyOption]) -> JourneyPlannerModel {
        let p = JourneyPlannerModel(), stations = choices.flatMap { $0.walks.compactMap(\.bike).flatMap { [$0.pickup,$0.dropoff] } }
        let unique = Array(Dictionary(stations.map { ($0.id,$0) },uniquingKeysWith:{ first,_ in first }).values)
        p.updateBikes(network:BikeNetwork(stations:unique),availability:counts(unique))
        var snapshot = TransitSnapshot()
        snapshot.estimates = EstimateFeed(seconds:Dictionary(uniqueKeysWithValues:choices.flatMap { $0.rides.map {
            ($0.route.parentID+":"+$0.boarding.id,0)
        } }),updatedAt:Date())
        p.updateSnapshot(snapshot)
        p.auditLoadChoices(choices,from:TravelPlace(name:"起點",address:"",coordinate:a),to:TravelPlace(name:"終點",address:"",coordinate:b))
        return p
    }
    func testTransitLeadsAndWholeCyclingRemainsAvailableWithItsRealTime() throws {
        let bus = transit(), bike = bicycle(), p = planner([bus,bike])
        XCTAssertEqual(try XCTUnwrap(p.duration(bus,at:Date())).totalSeconds,1000,accuracy:1)
        XCTAssertEqual(try XCTUnwrap(p.duration(bike,at:Date())).totalSeconds,850,accuracy:0.001)
        XCTAssertEqual(p.options.first?.id,bus.id,"A small whole-trip cycling saving does not replace the transit recommendation")
        XCTAssertTrue(p.options.contains { $0.id == bike.id },"The faster cycling choice remains available")
        XCTAssertTrue(p.options.contains { $0.id == bus.id },"The convenient no-rental choice remains available")
    }

    func testFirstChoiceChecksBothWalkingEndsTogether() async throws {
        let p = JourneyPlannerModel()
        var option = transit()
        option.walks = [WalkingLeg(from:a,to:.init(latitude:a.latitude+0.001,longitude:a.longitude)),
            WalkingLeg(from:b,to:.init(latitude:b.latitude+0.001,longitude:b.longitude))]
        var active = 0, peak = 0
        p.testStreet = { input, _ in
            active += 1; peak = max(peak,active)
            try await Task.sleep(for:.milliseconds(80)); active -= 1
            return WalkingLeg(from:input.from,to:input.to,coordinates:[input.from,input.to],distance:120,duration:100)
        }
        let result = try await p.auditEnrich(option,metadata:TransitMetadata())
        XCTAssertEqual(peak,2)
        XCTAssertTrue(result.verified); XCTAssertEqual(result.walks.map(\.duration),[100,100])
    }

    func testAnotherOfficialEntranceRescuesAnUnreachableEntrance() async throws {
        let p = JourneyPlannerModel(), next = Coordinate(latitude:a.latitude+0.001,longitude:a.longitude)
        var option = transit()
        var leg = WalkingLeg(from:a,to:b,stationSeconds:120,stationInstruction:"入口 1")
        leg.entranceAlternatives = [WalkingEntrance(from:a,to:next,instruction:"入口 2")]
        option.walks[0] = leg
        p.testStreet = { input, _ in
            if input.from == input.to { return WalkingLeg(from:input.from,to:input.to,distance:0,duration:0) }
            if input.to == self.b { return WalkingLeg(from:input.from,to:input.to) }
            return WalkingLeg(from:input.from,to:input.to,coordinates:[input.from,input.to],distance:100,duration:90)
        }
        let result = try await p.auditEnrich(option,metadata:TransitMetadata())
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.walks[0].to,next)
        XCTAssertEqual(result.walks[0].stationInstruction,"入口 2")
        XCTAssertEqual(result.walks[0].duration,210)
    }

    func testLongerStraightLineExitCanWinByActualWalkingTime() async throws {
        let next = Coordinate(latitude:a.latitude+0.001,longitude:a.longitude)
        let near = Coordinate(latitude:a.latitude+0.0003,longitude:a.longitude)
        var option = transit()
        option.walks[0] = WalkingLeg(from:a,to:near,coordinates:[a,near],distance:500,duration:420,
            stationSeconds:120,stationInstruction:"入口 1",streetDuration:300)
        option.walks[0].entranceAlternatives = [WalkingEntrance(from:a,to:next,instruction:"入口 2")]
        let p = planner([option])
        p.testStreet = { input, _ in
            WalkingLeg(from:input.from,to:input.to,coordinates:[input.from,input.to],distance:100,duration:90)
        }
        await p.auditRefineEntrances()
        XCTAssertEqual(p.selected?.walks[0].to,next)
        XCTAssertEqual(p.selected?.walks[0].duration,210)
        XCTAssertEqual(p.selected?.walks[0].stationInstruction,"入口 2")
        XCTAssertGreaterThan(a.distance(to:next),a.distance(to:near))
        XCTAssertFalse(p.started)
        // Once a person is inspecting the route, background refinement is quiet.
        p.select(try XCTUnwrap(p.selected))
        let revision = p.mapRevision
        await p.auditRefineEntrances()
        XCTAssertEqual(p.mapRevision,revision)
    }
    func testEmptyPickupReordersTheRecommendationWithoutMovingTheInspectedMap() {
        let bus = transit(), bike = bicycle(), p = planner([bus,bike])
        p.select(bike); let revision = p.mapRevision
        let stations = bike.walks.compactMap(\.bike).flatMap { [$0.pickup,$0.dropoff] }
        p.updateBikes(network:BikeNetwork(stations:stations),availability:counts(stations,empty:["pickup"]))
        XCTAssertEqual(p.options.first?.id,bus.id);XCTAssertEqual(p.selectedID,bike.id)
        XCTAssertEqual(p.mapRevision,revision);XCTAssertFalse(p.canUse(bike));p.begin()
        XCTAssertFalse(p.started,"A known-empty pickup cannot start navigation");p.finish()
    }
    func testRemainingRouteCanOnlyReplaceAnActiveWalkingStep() throws {
        let original = transit(), alternative = transit("other",seconds:700), p = planner([original,alternative])
        let start = TravelPlace(name:"目前位置",address:"",coordinate:a)
        p.select(original)
        XCTAssertNotNil(p.selected,"A checked route remains selectable after a better recommendation removes its row")
        XCTAssertFalse(p.adoptRemaining(alternative,from:start));XCTAssertEqual(p.selectedID,original.id)
        p.begin();XCTAssertTrue(p.started);let destination = p.destination?.coordinate
        XCTAssertTrue(p.adoptRemaining(alternative,from:start))
        XCTAssertTrue(p.started);XCTAssertEqual(p.currentStep,.walk(0));XCTAssertEqual(p.selectedID,alternative.id)
        XCTAssertEqual(p.destination?.coordinate,destination);XCTAssertEqual(p.origin?.coordinate,a)
        p.boardCurrentRide();XCTAssertFalse(p.adoptRemaining(original,from:start))
        XCTAssertEqual(p.selectedID,alternative.id);XCTAssertEqual(p.currentStep,.ride(0));p.finish()
    }
    func testAnUnrecognizedStaleChoiceCannotClearTheCurrentRoute() {
        let active = transit(), p = planner([active]), unknown = transit("removed")
        let revision = p.mapRevision
        p.select(unknown)
        XCTAssertEqual(p.selectedID,active.id);XCTAssertNotNil(p.selected);XCTAssertEqual(p.mapRevision,revision)
        p.finish()
    }
    func testUnconfirmedCyclingProgressCannotBeMistakenForAnUnborrowedBicycle() {
        let bike = bicycle(), alternate = transit(), p = planner([bike,alternate])
        p.select(bike);p.begin();XCTAssertTrue(p.started)
        XCTAssertNil(p.walkingProgress)
        XCTAssertFalse(p.adoptRemaining(alternate,from:TravelPlace(name:"目前位置",address:"",coordinate:a)),
            "An uncertain GPS phase must not replace a journey while the rider may already have the bicycle")
        XCTAssertEqual(p.selectedID,bike.id);XCTAssertTrue(p.started);p.finish()
    }
    func testCompletedBikeAndClosedPastBoardingDoNotInvalidateTheRemainingJourney() throws {
        let bus = transit(), bike = bicycle(), p = planner([bus,bike])
        var mixed = bus; mixed.walks[0] = bike.walks[0]
        p.auditLoadChoices([mixed],from:TravelPlace(name:"起點",address:"",coordinate:a),to:TravelPlace(name:"終點",address:"",coordinate:b))
        p.begin();p.boardCurrentRide()
        let stations = bike.walks.compactMap(\.bike).flatMap { [$0.pickup,$0.dropoff] }
        p.updateBikes(network:BikeNetwork(stations:stations),availability:counts(stations,empty:["pickup"]))
        var closed = TransitSnapshot();closed.estimates = EstimateFeed(seconds:["bus:busa":-3],updatedAt:Date())
        p.updateSnapshot(closed)
        XCTAssertTrue(p.canContinueSelected(),"Borrowed bikes and completed boarding must not force an onboard passenger to change route")
        p.finish()
    }
    func testBicycleRemainingTimeChangesWithTheActualPhase() {
        var bike = bicycle().walks[0].bike!
        bike.toPickupMeters = 100;bike.toPickupSeconds = 60
        bike.rideMeters = 1000;bike.rideSeconds = 300
        bike.fromDropoffMeters = 100;bike.fromDropoffSeconds = 60
        for (meters,total,cycled,handling) in [(1150.0,540.0,450.0,150.0),(700,315,255,75),(50,30,0,0)] {
            let remaining = bike.remaining(meters:meters)
            XCTAssertEqual(remaining.total,total,accuracy:0.001)
            XCTAssertEqual(remaining.cycling,cycled,accuracy:0.001)
            XCTAssertEqual(remaining.handling,handling,accuracy:0.001)
        }
        XCTAssertEqual(bike.remaining(meters:.nan).total,bike.totalSeconds)
        XCTAssertEqual(bike.remaining(meters:-1).total,0)
    }
    func testClosedServicesCannotLeaveAnEmptyRouteSheetWithoutANextStep() {
        let option = transit(), p = planner([option])
        XCTAssertFalse(p.options.isEmpty)
        XCTAssertNil(p.emptyOptionsMessage)
        var closed = TransitSnapshot()
        closed.estimates = EstimateFeed(seconds:["bus:busa":-3],updatedAt:Date())
        p.updateSnapshot(closed); p.refreshRecommendations()
        XCTAssertTrue(p.options.isEmpty)
        XCTAssertNotNil(p.emptyOptionsMessage)
        p.finish()
        XCTAssertNil(p.emptyOptionsMessage, "Finishing a trip must not show an empty-result message on the home screen")
    }
    func testStreetCacheExpiresAndWalkingAndCyclingRemainSeparate() async throws {
        let p = JourneyPlannerModel(), leg = WalkingLeg(from:a,to:b)
        var calls = 0
        p.testStreet = { input,mode in
            calls += 1;var result = input;result.duration = mode == .walking ? 900 : 300;return result
        }
        _ = try await p.auditStreet(leg);_ = try await p.auditStreet(leg)
        XCTAssertEqual(calls,1)
        _ = try await p.auditStreet(leg,cycling:true);XCTAssertEqual(calls,2)
        p.auditAgeStreetCache(901)
        _ = try await p.auditStreet(leg);XCTAssertEqual(calls,3)
    }
    func testUnavailableSharedAccessDoesNotExhaustRequestsForEveryRoute() async throws {
        let p = JourneyPlannerModel(), option = transit()
        var calls = 0
        p.testStreet = { input,_ in calls += 1; return WalkingLeg(from:input.from,to:input.to) }
        let unavailable = try await p.auditEnrich(option,metadata:TransitMetadata())
        XCTAssertFalse(unavailable.verified)
        XCTAssertEqual(calls,2,"At most the leading choice's two parallel walking checks are sent")
        _ = try await p.auditEnrich(option,metadata:TransitMetadata())
        XCTAssertEqual(calls,2,"The same unavailable connections must not be downloaded once per route")
        p.finish()
        _ = try await p.auditEnrich(option,metadata:TransitMetadata())
        XCTAssertEqual(calls,4,"Starting a new search permits both endpoints to recover")
    }
    func testASecondDockPairCanWinAfterActualStreetVerificationWithoutChangingThePreview() async throws {
        var original = bicycle()
        original.walks[0].bike!.rideSeconds = 1000;original.walks[0].duration = 1150
        let p = planner([original]), pickup = original.walks[0].bike!.pickup, dropoff = original.walks[0].bike!.dropoff
        let extra = BikeStation(id:"second",name:"另一借車站",coordinate:Coordinate(latitude:a.latitude+0.0005,longitude:a.longitude),capacity:30)
        let stations = [pickup,dropoff,extra]
        p.finish();p.updateBikes(network:BikeNetwork(stations:stations),availability:counts(stations))
        p.auditLoadChoices([original],from:TravelPlace(name:"起點",address:"",coordinate:a),to:TravelPlace(name:"終點",address:"",coordinate:b))
        p.select(original);let revision = p.mapRevision
        p.testStreet = { input,mode in
            var result = input;result.coordinates = [input.from,input.to];result.distance = input.from.distance(to:input.to)
            result.road = RouteLine(coordinates:result.coordinates)
            result.duration = mode == .walking ? result.distance! / 1.2 : input.from == pickup.coordinate ? 1000 : 200
            return result
        }
        await p.auditRefineStations()
        XCTAssertEqual(p.options.first?.walks[0].bike?.pickup.id,extra.id)
        XCTAssertEqual(p.selectedID,original.id);XCTAssertEqual(p.mapRevision,revision)
        XCTAssertLessThan(try XCTUnwrap(p.duration(p.options[0],at:Date())).totalSeconds,1150)
        p.finish()
    }
    func testVerifiedLongAccessCannotCatchAMissedLastTrainOnAnyRailLine() async throws {
        let service = TransitService(), loaded = await service.offlineMetroMetadata()
        let metadata = try XCTUnwrap(loaded)
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = TimeZone(identifier:"Asia/Taipei")!
        let day = calendar.startOfDay(for:Date())
        for line in metadata.metro.lines {
            let pattern = try XCTUnwrap(metadata.metro.patterns.first { $0.lineID == line.id })
            let stops = metadata.orderedStops(routeID:pattern.id,direction:pattern.direction)
            let route = try XCTUnwrap(metadata.routes[pattern.id])
            let ride = TransitRide(route:route,direction:pattern.direction,stops:Array(stops.prefix(2)),coordinates:[])
            let window = try XCTUnwrap(metadata.metro.boardingWindow(routeID:pattern.id,direction:pattern.direction,stationID:ride.boarding.stationID))
            let date = day.addingTimeInterval(Double(window.lastMinute * 60)-600)
            let trip = TransitTrip(rides:[ride],accessDistance:0,egressDistance:0,transferDistance:0,score:0,rideSeconds:[120])
            var option = JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:a,to:a,duration:30),WalkingLeg(from:b,to:b,duration:0)])
            let p = JourneyPlannerModel();p.auditMetadata(metadata)
            XCTAssertNil(p.unavailableBoarding(option,at:date),line.id)
            option.walks[0].duration = 1800
            XCTAssertNotNil(p.unavailableBoarding(option,at:date),line.id)
            var live = TransitSnapshot()
            live.estimates = EstimateFeed(seconds:[ride.route.parentID+":"+ride.boarding.id:2000],updatedAt:date)
            p.updateSnapshot(live)
            XCTAssertNil(p.unavailableBoarding(option,at:date),"A reachable official departure overrides the published window: "+line.id)
        }
    }
    func testRemainingJourneySearchRunsIndependentlyAndCancelsItsUnfinishedRequests() async throws {
        let active = transit("active"), p = planner([active]);p.begin()
        let alternative = transit("shadow",seconds:300), ride = alternative.rides[0]
        var metadata = TransitMetadata();metadata.routes[ride.route.id] = ride.route
        for stop in ride.stops {
            metadata.stops[stop.id] = stop
            metadata.paths[ride.route.id,default:[]].append(StopReference(stopID:stop.id,sequence:stop.sequence))
            metadata.stations[stop.stationID] = Station(id:stop.stationID,name:stop.name,coordinate:stop.coordinate,address:"",bearing:"E",stopIDs:[stop.id])
        }
        metadata.rebuildRouteCatalog()
        var snapshot = TransitSnapshot();snapshot.estimates = EstimateFeed(seconds:["shadow:shadowa":0],updatedAt:Date())
        let independent = JourneyPlannerModel()
        independent.testStreet = { input,_ in
            var result = input;result.coordinates = [input.from,input.to];result.distance = input.from.distance(to:input.to)
            result.duration = result.distance! / 1.2;result.road = RouteLine(coordinates:result.coordinates);return result
        }
        let result = await independent.resolveRemaining(metadata:metadata,
            from:TravelPlace(name:"目前位置",address:"",coordinate:a),to:TravelPlace(name:"目的地",address:"",coordinate:b),
            settings:LiveSettings(),snapshot:snapshot,forecast:VehicleArrivalForecast(),bikes:.empty,availability:nil,cacheFrom:p,maximumWait:5)
        XCTAssertNotNil(result);XCTAssertEqual(result?.rides.first?.route.id,"shadow")
        XCTAssertFalse(independent.planning);XCTAssertFalse(independent.checkingWalks)
        XCTAssertEqual(p.selectedID,active.id);XCTAssertTrue(p.started);XCTAssertEqual(p.stepIndex,0)
        XCTAssertEqual(p.destination?.coordinate,b);p.finish();independent.finish()
    }
    func testAnAlternativeIsReassessedWhenTheOriginalBusArrivesOrTheBikeStationRunsDry() {
        let model = TransitAppModel(), active = transit(), p = model.planner
        var alternative = bicycle()
        alternative.walks[0].bike!.rideSeconds = 300;alternative.walks[0].duration = 450
        let stations = alternative.walks.compactMap(\.bike).flatMap { [$0.pickup,$0.dropoff] }
        p.updateBikes(network:BikeNetwork(stations:stations),availability:counts(stations))
        p.auditLoadChoices([active],from:TravelPlace(name:"出發",address:"",coordinate:a),to:TravelPlace(name:"目的地",address:"",coordinate:b))
        p.begin();XCTAssertTrue(p.started)
        func snapshot(_ seconds: Int) -> TransitSnapshot {
            var result = TransitSnapshot();result.estimates = EstimateFeed(seconds:["bus:busa":seconds],updatedAt:Date());return result
        }
        XCTAssertTrue(model.auditAlternative(alternative,snapshot:snapshot(700)))
        XCTAssertFalse(model.auditAlternative(alternative,snapshot:snapshot(0)),"The now-arriving bus is preferable to the old cycling suggestion")
        p.updateBikes(network:BikeNetwork(stations:stations),availability:counts(stations,empty:["pickup"]))
        XCTAssertFalse(model.auditAlternative(alternative,snapshot:snapshot(700)),"A once-valid proposal cannot ignore updated station counts")
        XCTAssertEqual(p.selectedID,active.id);XCTAssertTrue(p.started);p.finish()
    }
}
