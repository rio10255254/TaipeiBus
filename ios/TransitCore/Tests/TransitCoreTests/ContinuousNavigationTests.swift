import XCTest
@testable import TransitCore

final class ContinuousNavigationTests: XCTestCase {
    let date = Date(timeIntervalSince1970:1_800_000_000)
    func point(_ metres: Double, north: Double = 0) -> Coordinate {
        Coordinate(latitude:25.04+north/111_320,longitude:121.55+metres/100_750)
    }
    func fixture() -> (TransitMetadata,TransitRide) {
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
        return (metadata,TransitRide(route:route,direction:"0",stops:stops,coordinates:points))
    }
    func testPoorFixKeepsWalkingProgressAndLongGapCanRejoinTheRoute() {
        var progress = WalkingProgress(coordinates:[point(0),point(2_000)],distance:2_000,seconds:1_600)
        XCTAssertTrue(progress.update(coordinate:point(300),accuracy:5,timestamp:date,now:date))
        let remaining = progress.remainingSeconds
        XCTAssertFalse(progress.update(coordinate:point(1_800,north:200),accuracy:200,timestamp:date.addingTimeInterval(5),now:date.addingTimeInterval(5)))
        XCTAssertFalse(progress.locationConfirmed); XCTAssertTrue(progress.hasConfirmedProgress)
        XCTAssertEqual(progress.remainingSeconds,remaining,accuracy:0.001)
        XCTAssertFalse(progress.isFresh(at:date.addingTimeInterval(60)))
        XCTAssertTrue(progress.update(coordinate:point(650),accuracy:5,timestamp:date.addingTimeInterval(150),now:date.addingTimeInterval(150)))
        XCTAssertLessThan(progress.remainingSeconds,remaining-200)
        XCTAssertFalse(progress.needsReroute)
    }
    func testCyclingCanRecoverBeyondTheOldWalkingDistanceLimit() {
        var progress = WalkingProgress(coordinates:[point(0),point(2_000)],distance:2_000,seconds:600,learnsWalkingPace:false)
        XCTAssertTrue(progress.update(coordinate:point(100),accuracy:5,timestamp:date,now:date))
        XCTAssertTrue(progress.update(coordinate:point(1_300),accuracy:5,timestamp:date.addingTimeInterval(180),now:date.addingTimeInterval(180)))
        XCTAssertLessThan(progress.remainingDistance,710)
        XCTAssertNil(progress.observedWalkingSpeed)
    }
    func testPhoneProgressWorksWithoutAVehicleFeedAndKeepsPassedStopsAcrossAnOutage() throws {
        let (metadata,ride) = fixture()
        var progress = try XCTUnwrap(OnboardProgress(ride:ride,metadata:metadata))
        XCTAssertTrue(progress.update(coordinate:point(900),accuracy:8,timestamp:date.addingTimeInterval(80),boardedAt:date,now:date.addingTimeInterval(80)))
        XCTAssertEqual(progress.upcomingStops.map(\.id),["s3","s4","s5"])
        XCTAssertEqual(progress.source,.phone)
        let forecast = VehicleArrivalForecast()
        let full = forecast.ridingEstimate(ride,metadata:metadata,at:date).seconds
        let remaining = forecast.ridingEstimate(ride,metadata:metadata,at:date,progress:progress).seconds
        XCTAssertGreaterThan(remaining,full*0.5); XCTAssertLessThan(remaining,full*0.6)
        let next = forecast.ridingEstimate(ride,metadata:metadata,at:date,progress:progress,to:"s3").seconds
        let following = forecast.ridingEstimate(ride,metadata:metadata,at:date,progress:progress,to:"s4").seconds
        XCTAssertGreaterThan(next,0); XCTAssertLessThan(next,following); XCTAssertLessThan(following,remaining)
        XCTAssertFalse(progress.update(coordinate:point(1_200,north:90),accuracy:100,timestamp:date.addingTimeInterval(90),boardedAt:date,now:date.addingTimeInterval(90)))
        XCTAssertEqual(progress.upcomingStops.map(\.id),["s3","s4","s5"])
        XCTAssertFalse(progress.isFresh(at:date.addingTimeInterval(120)))
        XCTAssertTrue(progress.update(coordinate:point(1_700),accuracy:8,timestamp:date.addingTimeInterval(180),boardedAt:date,now:date.addingTimeInterval(180)))
        XCTAssertEqual(progress.upcomingStops.map(\.id),["s5"])
    }
    func testOnboardRejectsParallelRoadJumpBackwardsAndOldReadings() throws {
        let (metadata,ride) = fixture()
        var progress = try XCTUnwrap(OnboardProgress(ride:ride,metadata:metadata))
        XCTAssertFalse(progress.update(coordinate:point(1_800),accuracy:5,timestamp:date.addingTimeInterval(5),boardedAt:date,now:date.addingTimeInterval(5)))
        XCTAssertFalse(progress.update(coordinate:point(100,north:70),accuracy:5,timestamp:date,boardedAt:date,now:date))
        XCTAssertTrue(progress.update(coordinate:point(700),accuracy:5,timestamp:date.addingTimeInterval(50),boardedAt:date,now:date.addingTimeInterval(50)))
        let fraction = progress.remainingFraction
        XCTAssertTrue(progress.update(coordinate:point(690),accuracy:5,timestamp:date.addingTimeInterval(52),boardedAt:date,now:date.addingTimeInterval(52)))
        XCTAssertEqual(progress.remainingFraction,fraction,accuracy:0.001)
        XCTAssertFalse(progress.update(coordinate:point(1_000),accuracy:5,timestamp:date.addingTimeInterval(55),boardedAt:date,now:date.addingTimeInterval(90)))
        XCTAssertFalse(progress.update(coordinate:point(1_000),accuracy:.nan,timestamp:date.addingTimeInterval(90),boardedAt:date,now:date.addingTimeInterval(90)))
    }
    func testEstimatedPositionKeepsAnApproximateClockButUnknownDepartureDoesNot() {
        var ride = JourneyDuration(riding:[600],walking:[0,60],arrivals:[0],at:date)
        ride.positionUncertain = true
        XCTAssertTrue(ride.expectedArrivalLabel.contains(":"))
        XCTAssertFalse(ride.arrivalLabel.contains("待確認"))
        var unknown = JourneyDuration(riding:[600,300],walking:[0,60,60],arrivals:[0,nil],at:date)
        unknown.positionUncertain = true
        XCTAssertFalse(unknown.expectedArrivalLabel.contains(":"))
    }
    func testTimingFeedbackImprovesAHeldOutPredictionWithoutLearningDuplicatesOrOtherRoutes() {
        var feedback = ArrivalTimingFeedback()
        for id in ["a","b","c"] {
            feedback.begin(vehicle:id,key:"route:0:segment",stopID:"s1",seconds:100,at:date)
            feedback.crossed(vehicle:id,key:"route:0:segment",stopID:"s1",at:date.addingTimeInterval(130))
        }
        let before = abs(100.0-130), after = abs(100*feedback.factor(for:"route:0:segment",at:date.addingTimeInterval(131))-130)
        XCTAssertLessThan(after,before)
        XCTAssertEqual(feedback.factor(for:"route:1:segment",at:date),1)
        XCTAssertEqual(feedback.factor(for:"other:0:segment",at:date),1)
        XCTAssertEqual(feedback.factor(for:"route:0:segment",at:date.addingTimeInterval(1_400)),1)
        var duplicate = ArrivalTimingFeedback()
        for _ in 0..<8 {
            duplicate.begin(vehicle:"same",key:"segment",stopID:"s1",seconds:100,at:date)
            duplicate.crossed(vehicle:"same",key:"segment",stopID:"s1",at:date.addingTimeInterval(180))
        }
        XCTAssertEqual(duplicate.factor(for:"segment",at:date.addingTimeInterval(181)),1)
    }
    func testOneHourOfWalkingGapsAndResumptionsPreservesCompletedDistance() {
        var progress = WalkingProgress(coordinates:[point(0),point(8_000)],distance:8_000,seconds:6_400)
        var last = 8_000.0
        for elapsed in stride(from:0.0,through:3_600,by:5) {
            let at = date.addingTimeInterval(elapsed), bad = Int(elapsed) % 300 >= 240
            _ = progress.update(coordinate:point(elapsed),accuracy:bad ? 200 : 5,timestamp:at,now:at)
            XCTAssertLessThanOrEqual(progress.remainingDistance,last+0.1)
            last = progress.remainingDistance
        }
        XCTAssertLessThan(last,4_410)
    }
    func testPublicFleetCrossingsActuallyCalibrateANewVehiclesFallback() throws {
        // Isolate the session calibration from the measured hourly pace factors, which would
        // otherwise already close most of this fixture's gap before calibration is tested.
        defer { ForecastTuning.current = ForecastTuning() }
        var neutral = ForecastTuning()
        neutral.workdayPaceFactors = Array(repeating:1,count:24); neutral.holidayPaceFactors = Array(repeating:1,count:24)
        ForecastTuning.current = neutral
        let (metadata,ride) = fixture()
        func vehicle(_ id: String, meters: Double, at time: Date) -> BusVehicle {
            let raw = BusVehicle(id:id,plate:id,routeID:"route",parentRouteID:"family",routeName:"284",direction:"0",
                destination:"終點",coordinate:point(meters),rawCoordinate:point(meters),heading:90,speed:40,
                observedAt:time,status:"0",lowFloor:true,provider:nil)
            return VehicleTracker.accept(raw,previous:nil,metadata:metadata,now:time)
        }
        var forecast = VehicleArrivalForecast()
        for elapsed in stride(from:0.0,through:80,by:20) {
            let time = date.addingTimeInterval(elapsed)
            forecast.ingest(["a","b","c"].map { vehicle($0,meters:50+elapsed*5,at:time) },metadata:metadata,at:time)
        }
        let time = date.addingTimeInterval(90), heldOut = vehicle("new",meters:50,at:time)
        let original = try XCTUnwrap(forecast.prediction(heldOut,stopID:ride.stops[1].id,metadata:metadata,at:time,applyCalibration:false))
        let corrected = try XCTUnwrap(forecast.prediction(heldOut,stopID:ride.stops[1].id,metadata:metadata,at:time))
        XCTAssertGreaterThan(corrected.seconds,original.seconds)
        XCTAssertLessThan(abs(corrected.seconds-70),abs(original.seconds-70),"Compare against a later actual crossing, not another prediction")
        XCTAssertLessThanOrEqual(corrected.seconds,original.seconds*1.201)
    }
    func testMissingBoardingAnchorFallsBackToTheVerifiedRideGeometry() throws {
        var (metadata,ride) = fixture()
        metadata.lines["sub:route"] = RouteLine(coordinates:[point(200),point(2_000)])
        metadata.rebuildJourneys()
        var progress = try XCTUnwrap(OnboardProgress(ride:ride,metadata:metadata))
        XCTAssertTrue(progress.update(coordinate:point(600),accuracy:5,timestamp:date.addingTimeInterval(40),boardedAt:date,now:date.addingTimeInterval(40)))
        XCTAssertTrue(progress.passedStopIDs.contains("s1"))
        XCTAssertLessThan(VehicleArrivalForecast().ridingEstimate(ride,metadata:metadata,at:date,progress:progress).seconds,
            VehicleArrivalForecast().ridingEstimate(ride,metadata:metadata,at:date).seconds)
    }
}
