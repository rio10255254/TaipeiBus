import XCTest
@testable import TransitCore
@testable import TaipeiBus

@MainActor final class ContinuousNavigationTests: XCTestCase {
    private func station(_ id: String, at coordinate: Coordinate) -> Station {
        Station(id:id,name:id,coordinate:coordinate,address:"",bearing:"N",stopIDs:[])
    }
    func testChangingWalkingStationStartsTheNewRouteImmediately() {
        let navigation = StationWalkingNavigation(), location = LocationService()
        location.auditLocation(.init(coordinate:point(0),accuracy:5,timestamp:Date()))
        navigation.begin(station("first",at:point(400)),location:location)
        XCTAssertTrue(navigation.calculating)
        navigation.begin(station("second",at:point(800)),location:location)
        XCTAssertEqual(navigation.target?.id,"second")
        XCTAssertTrue(navigation.calculating,"A different destination must not inherit the previous route's twenty-second retry delay")
        navigation.cancel()
    }
    func testRestartingStationWalkingDoesNotWaitForTheCancelledRequest() {
        let navigation = StationWalkingNavigation(), location = LocationService()
        location.auditLocation(.init(coordinate:point(0),accuracy:5,timestamp:Date()))
        let target = station("target",at:point(400))
        navigation.begin(target,location:location); navigation.cancel()
        navigation.begin(target,location:location)
        XCTAssertTrue(navigation.calculating)
        XCTAssertNil(navigation.issue)
        navigation.cancel()
    }
    func testRecoveredWalkingLocationRestoresGuidanceWithoutLosingTheRoute() throws {
        let navigation = StationWalkingNavigation(), location = LocationService(), now = Date()
        let target = station("target",at:point(400))
        let path = WalkingLeg(from:point(0),to:target.coordinate,coordinates:[point(0),target.coordinate],distance:400,duration:320)
        navigation.auditRoute(path,to:target)
        location.auditLocation(.init(coordinate:point(0),accuracy:5,timestamp:now.addingTimeInterval(-900)))
        navigation.update(location:location)
        XCTAssertNotNil(navigation.issue)
        location.auditLocation(.init(coordinate:point(100),accuracy:5,timestamp:now))
        navigation.update(location:location)
        XCTAssertNil(navigation.issue,"A recovered location must not leave the old warning hiding turn instructions")
        XCTAssertEqual(navigation.leg?.coordinates,path.coordinates)
        XCTAssertEqual(navigation.target?.id,target.id)
        XCTAssertTrue(navigation.locationConfirmed)
        XCTAssertFalse(navigation.calculating,"A valid retained route does not need another directions download")
        navigation.cancel()
    }
    func point(_ meters: Double) -> Coordinate {
        Coordinate(latitude:25.04,longitude:121.55+meters/100_750)
    }
    func fixture() -> (TransitMetadata,JourneyOption) {
        var metadata = TransitMetadata()
        let route = BusRoute(id:"route",parentID:"family",name:"284",variantName:"",departure:"起點",destination:"終點")
        metadata.routes[route.id] = route
        let points = stride(from:0.0,through:2_000,by:400).map { point($0) }
        metadata.lines["sub:route"] = RouteLine(coordinates:points)
        let stops = points.enumerated().map { index,point in
            BusStop(id:"s\(index)",routeID:"family",stationID:"station\(index)",name:"站\(index)",direction:"0",sequence:index,coordinate:point)
        }
        for stop in stops {
            metadata.stops[stop.id] = stop
            metadata.paths[route.id,default:[]].append(StopReference(stopID:stop.id,sequence:stop.sequence))
        }
        metadata.rebuildJourneys()
        let ride = TransitRide(route:route,direction:"0",stops:stops,coordinates:points)
        let trip = TransitTrip(rides:[ride],accessDistance:800,egressDistance:0,transferDistance:0,score:0,rideSeconds:[600])
        let walk = WalkingLeg(from:point(-800),to:point(0),coordinates:[point(-800),point(0)],distance:800,duration:600)
        return (metadata,JourneyOption(id:trip.id,trip:trip,walks:[walk,WalkingLeg(from:point(2_000),to:point(2_000),distance:0,duration:0)]))
    }
    func makeModel(at date: Date) -> (TransitAppModel,TransitMetadata,JourneyOption) {
        let (metadata,option) = fixture(), model = TransitAppModel()
        model.auditNavigation(metadata:metadata,snapshot:TransitSnapshot(estimates:EstimateFeed(seconds:["family:s0":900],updatedAt:date)),at:date)
        model.planner.auditLoadChoices([option],from:TravelPlace(name:"起點",address:"",coordinate:point(-800)),
            to:TravelPlace(name:"終點",address:"",coordinate:point(2_000)))
        model.planner.begin()
        return (model,metadata,option)
    }
    func testLiveActivityShowsCurrentAccessWalkBeforeWaitingAndThenRide() throws {
        let date = Date(), (model, _, _) = makeModel(at: date)
        defer { model.finishJourney() }
        let walk = try XCTUnwrap(model.rideActivityState(at: date))
        XCTAssertEqual(walk.phase, .walking)
        XCTAssertEqual(try XCTUnwrap(walk.target).timeIntervalSince(date), 600, accuracy: 1)
        XCTAssertEqual(walk.headline, "站0")
        model.planner.updateWalking(index: 0, coordinate: point(-10), accuracy: 5, timestamp: date, now: date)
        XCTAssertEqual(model.rideActivityState(at: date)?.phase, .waiting)
        model.boardCurrentRide(at: date)
        XCTAssertEqual(model.rideActivityState(at: date)?.phase, .riding)
        XCTAssertNotNil(model.rideActivityState(at: date)?.stopsLeft)
    }
    func testLiveActivityTracksAllThreeBikeConnectorPhasesBeforeTransit() throws {
        let date = Date(), model = TransitAppModel()
        defer { model.finishJourney() }
        var (metadata, option) = fixture()
        option.walks[0].bike = BikeLeg(pickup: BikeStation(id: "p", name: "借車站", coordinate: point(-600), capacity: 20),
            dropoff: BikeStation(id: "d", name: "還車站", coordinate: point(-100), capacity: 20), bikes: 5, docks: 8, handlingSeconds: 60,
            toPickupMeters: 200, toPickupSeconds: 150, rideMeters: 500, rideSeconds: 120, fromDropoffMeters: 100, fromDropoffSeconds: 80)
        model.auditNavigation(metadata: metadata, snapshot: TransitSnapshot(), at: date)
        model.planner.auditLoadChoices([option], from: TravelPlace(name: "起點", address: "", coordinate: point(-800)),
            to: TravelPlace(name: "終點", address: "", coordinate: point(2000)))
        model.planner.begin()
        XCTAssertEqual(model.rideActivityState(at: date)?.phase, .walking)
        XCTAssertEqual(model.rideActivityState(at: date)?.headline, "借車站")
        model.planner.updateWalking(index: 0, coordinate: point(-400), accuracy: 5, timestamp: date, now: date)
        let riding = try XCTUnwrap(model.rideActivityState(at: date))
        XCTAssertEqual(riding.phase, .cycling); XCTAssertEqual(riding.headline, "還車站")
        XCTAssertEqual(try XCTUnwrap(riding.target).timeIntervalSince(date), 72, accuracy: 3)
        let later = date.addingTimeInterval(60)
        model.planner.updateWalking(index: 0, coordinate: point(-50), accuracy: 5, timestamp: later, now: later)
        XCTAssertEqual(model.rideActivityState(at: later)?.phase, .walking)
        XCTAssertEqual(model.rideActivityState(at: later)?.headline, "站0")
    }
    func testLiveActivityIndoorTransferIsNotMistakenForWaitingOrCycling() throws {
        let date = Date(), model = TransitAppModel()
        defer { model.finishJourney() }
        var (metadata, option) = fixture()
        option.walks[0].internalTransfer = true
        option.walks[0].stationInstruction = "前往轉乘月台"
        model.auditNavigation(metadata: metadata, snapshot: TransitSnapshot(), at: date)
        model.planner.auditLoadChoices([option], from: TravelPlace(name: "起點", address: "", coordinate: point(-800)),
            to: TravelPlace(name: "終點", address: "", coordinate: point(2000)))
        model.planner.begin()
        let state = try XCTUnwrap(model.rideActivityState(at: date))
        XCTAssertEqual(state.phase, .transferring)
        XCTAssertEqual(state.detail, "前往轉乘月台")
    }
    func testStaleWalkingKeepsTheSameRemainingTimeAndClosingMapDoesNotResetIt() throws {
        let date = Date(), (model,_,option) = makeModel(at:date)
        model.planner.updateWalking(index:0,coordinate:point(-200),accuracy:5,timestamp:date,now:date)
        let remaining = try XCTUnwrap(model.journeyDuration(option,at:date)).walkingSeconds
        XCTAssertLessThan(remaining,200)
        model.planner.updateWalking(index:0,coordinate:point(-700),accuracy:180,timestamp:date.addingTimeInterval(5),now:date.addingTimeInterval(5))
        XCTAssertEqual(try XCTUnwrap(model.journeyDuration(option,at:date.addingTimeInterval(60))).walkingSeconds,remaining,accuracy:0.01)
        model.clearWalkingMap()
        XCTAssertEqual(model.planner.walkingProgress?.remainingSeconds ?? -1,remaining,accuracy:0.01)
        XCTAssertEqual(model.planner.currentStep,.walk(0)); model.finishJourney()
    }
    func testConfirmedRideUsesPhoneGPSWithoutAPlateAndAllSurfacesAgree() throws {
        let date = Date(), (model,_,option) = makeModel(at:date), ride = option.rides[0]
        model.boardCurrentRide(at:date)
        let moved = date.addingTimeInterval(80)
        model.location.auditLocation(LocationSample(coordinate:point(900),accuracy:5,timestamp:moved))
        model.anchorBoardedVehicle(at:moved)
        XCTAssertNil(model.boardedVehicle,"A phone fix must not invent a physical bus identity")
        XCTAssertTrue(model.snapshot.vehicles.isEmpty)
        XCTAssertEqual(model.onboardStops(for:ride,at:moved).map(\.id),["s3","s4","s5"])
        let duration = try XCTUnwrap(model.journeyDuration(option,at:moved))
        XCTAssertEqual(try XCTUnwrap(model.onboardSecondsToAlight(ride,at:moved)),duration.ridingSeconds,accuracy:0.01)
        XCTAssertTrue(duration.expectedArrivalLabel.contains(":"))
        XCTAssertNotNil(model.onboardStopTimeLabel(ride,stopID:"s3",at:moved).first(where:{ $0.isNumber }))
        XCTAssertEqual(model.onboardPositionSource(ride,at:moved),AppText.text("依你的定位即時更新"))
        let shortGap = try XCTUnwrap(model.onboardSecondsToAlight(ride,at:moved.addingTimeInterval(120)))
        let outage = moved.addingTimeInterval(400)
        XCTAssertEqual(try XCTUnwrap(model.onboardSecondsToAlight(ride,at:outage)),shortGap,accuracy:0.01,
            "A long outage cannot rewind time at the former five-minute cache boundary")
        XCTAssertEqual(model.onboardStops(for:ride,at:outage).map(\.id),["s3","s4","s5"])
        XCTAssertLessThan(try XCTUnwrap(model.journeyDuration(option,at:outage)).ridingSeconds,600)
        XCTAssertEqual(model.planner.currentStep,.ride(0),"A clock or GPS cannot confirm alighting")
        model.alight(); XCTAssertNil(model.onboardProgress); model.finishJourney()
    }
    func testMissingProviderBusDoesNotRemoveAnAlreadyConfirmedPhoneAnchoredBus() throws {
        let date = Date().addingTimeInterval(-200), (model,metadata,option) = makeModel(at:date), ride = option.rides[0]
        let raw = BusVehicle(id:"physical",plate:"TEST-01",routeID:"route",parentRouteID:"family",routeName:"284",direction:"0",
            destination:"終點",coordinate:point(0),rawCoordinate:point(0),heading:90,speed:20,observedAt:date,status:"0",lowFloor:true,provider:nil)
        let bus = VehicleTracker.accept(raw,previous:nil,metadata:metadata,now:date)
        model.auditNavigation(metadata:metadata,snapshot:TransitSnapshot(vehicles:[bus]),at:date)
        model.trackApproachingVehicle(bus,userInitiated:false)
        model.boardCurrentRide(at:date)
        XCTAssertEqual(model.boardedVehicle?.vehicleID,"physical")
        model.following = true
        model.auditReceiveSnapshot(TransitSnapshot())
        XCTAssertTrue(model.following,"A complete signal gap holds the user's confirmed follow choice")
        XCTAssertTrue(model.hasConfirmedOnboardFollow,"Returning from an itinerary during a gap must retain the same follow intent")
        XCTAssertTrue(model.snapshot.vehicles.isEmpty,"Holding a follow choice must not create a vehicle position")
        let moved = Date()
        let revision = model.anchorRevision
        model.location.auditLocation(LocationSample(coordinate:point(900),accuracy:5,timestamp:moved),notify:true)
        XCTAssertGreaterThan(model.anchorRevision,revision,"A phone fix must immediately publish the confirmed bus to the map, without waiting for another provider refresh")
        model.auditReceiveSnapshot(TransitSnapshot())
        let anchored = try XCTUnwrap(model.onboardVehicle(for:ride))
        XCTAssertTrue(model.following,"A provider miss must preserve an already active camera follow when the phone anchors that same confirmed bus")
        XCTAssertEqual(anchored.plate,"TEST-01")
        XCTAssertLessThan(anchored.coordinate.distance(to:point(900)),2)
        XCTAssertTrue(model.isRiderAnchored(anchored))
        XCTAssertTrue(model.hasConfirmedOnboardFollow)
        let later = moved.addingTimeInterval(180)
        model.anchorBoardedVehicle(at:later)
        XCTAssertFalse(model.onboardVehicle(for:ride)?.hasReliablePosition(at:later) ?? false,
            "A missing provider and expired phone fix must never look like fresh GPS")
        model.finishJourney()
    }
    func testAccessPromptChangesNearThePlatformAndNeverBoardsByItself() {
        let date = Date(), (model,_,option) = makeModel(at:date)
        XCTAssertEqual(model.planner.accessInstruction(at:0,date:date),AppText.text("步行至 %@","站0"))
        model.planner.updateWalking(index:0,coordinate:point(-10),accuracy:5,timestamp:date,now:date)
        XCTAssertNil(model.planner.accessInstruction(at:0,date:date))
        XCTAssertEqual(model.planner.currentStep,.walk(0))
        XCTAssertNil(model.onboardSecondsToAlight(option.rides[0],at:date))
        model.finishJourney()
    }
    func testLocationDeliveryAdvancesTheRideWithoutAnyRenderedView() {
        let date = Date().addingTimeInterval(-100), (model,_,option) = makeModel(at:date)
        model.boardCurrentRide(at:date)
        XCTAssertNil(model.onboardProgress?.confirmedAt)
        model.location.auditLocation(LocationSample(coordinate:point(900),accuracy:5,timestamp:Date()),notify:true)
        XCTAssertNotNil(model.onboardProgress?.confirmedAt)
        XCTAssertEqual(model.onboardStops(for:option.rides[0],at:Date()).map(\.id),["s3","s4","s5"])
        model.finishJourney()
    }
    func testProviderExpiryDoesNotJumpTheDisplayedRemainingTime() throws {
        let date = Date(), boardedAt = date.addingTimeInterval(-120)
        let (model,metadata,option) = makeModel(at:boardedAt), ride = option.rides[0]
        model.boardCurrentRide(at:boardedAt)
        let raw = BusVehicle(id:"physical",plate:"TEST-01",routeID:"route",parentRouteID:"family",routeName:"284",direction:"0",
            destination:"終點",coordinate:point(900),rawCoordinate:point(900),heading:90,speed:20,observedAt:date,status:"0",lowFloor:true,provider:nil)
        let bus = VehicleTracker.accept(raw,previous:nil,metadata:metadata,now:date)
        model.auditNavigation(metadata:metadata,snapshot:TransitSnapshot(vehicles:[bus]),at:date)
        model.confirmBoardedVehicle(bus,ride:ride); model.anchorBoardedVehicle(at:date)
        let before = try XCTUnwrap(model.onboardSecondsToAlight(ride,at:date.addingTimeInterval(89)))
        let after = try XCTUnwrap(model.onboardSecondsToAlight(ride,at:date.addingTimeInterval(91)))
        XCTAssertLessThanOrEqual(abs(after-before),5)
        XCTAssertEqual(try XCTUnwrap(model.onboardSecondsToAlight(ride,at:date.addingTimeInterval(400))),
            max(60,before-30),accuracy:0.01)
        XCTAssertEqual(model.planner.currentStep,.ride(0)); model.finishJourney()
    }
    func testPreviewingALaterWalkCannotReplaceTheCurrentWalkingProgress() throws {
        let date = Date(), (model,_,_) = makeModel(at:date)
        model.location.auditLocation(LocationSample(coordinate:point(-200),accuracy:5,timestamp:date))
        model.updateWalkingLocation()
        let remaining = try XCTUnwrap(model.planner.walkingProgress).remainingSeconds
        model.showWalkOnMap(1)
        XCTAssertEqual(model.walkingMapIndex,1,"The later leg can still be inspected on the map")
        XCTAssertEqual(model.planner.walkingLegIndex,0)
        XCTAssertEqual(try XCTUnwrap(model.planner.walkingProgress).remainingSeconds,remaining,accuracy:0.01)
        model.clearWalkingMap()
        XCTAssertEqual(model.planner.walkingLegIndex,0)
        model.boardCurrentRide(at:date)
        model.showWalkOnMap(1)
        XCTAssertNil(model.planner.walkingLegIndex,"An onboard passenger cannot be rerouted as a pedestrian by inspecting a future walk")
        XCTAssertEqual(model.planner.currentStep,.ride(0)); model.finishJourney()
    }
}
