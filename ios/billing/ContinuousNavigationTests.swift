import XCTest
@testable import TransitCore
@testable import TaipeiBus

@MainActor final class ContinuousNavigationTests: XCTestCase {
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
        XCTAssertTrue(model.onboardStopTimeLabel(ride,stopID:"s3",at:moved).contains("分"))
        XCTAssertTrue(model.onboardPositionSource(ride,at:moved).contains("你的定位"))
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
        let date = Date(), (model,metadata,option) = makeModel(at:date), ride = option.rides[0]
        let raw = BusVehicle(id:"physical",plate:"TEST-01",routeID:"route",parentRouteID:"family",routeName:"284",direction:"0",
            destination:"終點",coordinate:point(0),rawCoordinate:point(0),heading:90,speed:20,observedAt:date,status:"0",lowFloor:true,provider:nil)
        let bus = VehicleTracker.accept(raw,previous:nil,metadata:metadata,now:date)
        model.auditNavigation(metadata:metadata,snapshot:TransitSnapshot(vehicles:[bus]),at:date)
        model.trackApproachingVehicle(bus,userInitiated:false)
        model.boardCurrentRide(at:date)
        XCTAssertEqual(model.boardedVehicle?.vehicleID,"physical")
        let moved = date.addingTimeInterval(80)
        model.auditNavigation(metadata:metadata,snapshot:TransitSnapshot(),at:moved)
        model.location.auditLocation(LocationSample(coordinate:point(900),accuracy:5,timestamp:moved))
        model.anchorBoardedVehicle(at:moved)
        let anchored = try XCTUnwrap(model.onboardVehicle(for:ride))
        XCTAssertEqual(anchored.plate,"TEST-01")
        XCTAssertLessThan(anchored.coordinate.distance(to:point(900)),2)
        XCTAssertTrue(model.isRiderAnchored(anchored))
        let later = moved.addingTimeInterval(180)
        model.anchorBoardedVehicle(at:later)
        XCTAssertFalse(model.onboardVehicle(for:ride)?.hasReliablePosition(at:later) ?? false,
            "A missing provider and expired phone fix must never look like fresh GPS")
        model.finishJourney()
    }
    func testAccessPromptChangesNearThePlatformAndNeverBoardsByItself() {
        let date = Date(), (model,_,option) = makeModel(at:date)
        XCTAssertEqual(model.planner.accessInstruction(at:0,date:date),"步行至 站0")
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
}
