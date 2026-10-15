import XCTest
@testable import TransitCore

final class TripRankingTests: XCTestCase {
    func testExplicitFewerTransferPreferenceChangesRankingWithoutAddingTravelTime() throws {
        let baseline = LiveSettings.Planning()
        var personal = baseline; personal.personalTransferPenaltySeconds = 900
        let direct = TripRanking.assess(riding:[1800],walking:[0,0],arrivals:[0],preferences:baseline)
        let transfer = TripRanking.assess(riding:[500,500],walking:[0,0,0],arrivals:[0,900],preferences:baseline)
        let preferred = TripRanking.assess(riding:[500,500],walking:[0,0,0],arrivals:[0,900],preferences:personal)
        XCTAssertLessThan(transfer.score,direct.score)
        XCTAssertGreaterThan(preferred.score,direct.score)
        XCTAssertEqual(preferred.elapsedSeconds,transfer.elapsedSeconds)
        XCTAssertEqual(baseline.effectiveTransferPenaltySeconds,300)
        let shared = try JSONDecoder().decode(LiveSettings.Planning.self,from:JSONEncoder().encode(personal))
        XCTAssertNil(shared.personalTransferPenaltySeconds)
        XCTAssertEqual(shared.effectiveTransferPenaltySeconds,baseline.effectiveTransferPenaltySeconds)
    }
    func testCyclingConnectorIsNotPenalizedAsFifteenMinutesOfWalking() {
        let a=Coordinate(latitude:25.02,longitude:121.54), b=Coordinate(latitude:25.04,longitude:121.51)
        func trip(_ id: String, seconds: Double) -> TransitTrip {
            let route=BusRoute(id:id,parentID:id,name:id,variantName:"",departure:"起點",destination:"終點")
            let stops=[BusStop(id:id+"a",routeID:id,stationID:id+"a",name:"起點",direction:"0",sequence:1,coordinate:a),
                       BusStop(id:id+"b",routeID:id,stationID:id+"b",name:"終點",direction:"0",sequence:2,coordinate:b)]
            let ride=TransitRide(route:route,direction:"0",stops:stops,coordinates:[a,b])
            return TransitTrip(rides:[ride],accessDistance:0,egressDistance:0,transferDistance:0,score:0,rideSeconds:[seconds])
        }
        let bus=trip("bus",seconds:1400), bikeRail=trip("bike-rail",seconds:600)
        var preference=LiveSettings.Planning();preference.walkingWeight=2.8
        let connectors:[String:[Double?]]=[bus.id:[300,0],bikeRail.id:[900,0]]
        let now=Date()
        let withoutMode=TripRanking.recommended([bus,bikeRail],estimates:.init(),at:now,preferences:preference,walkingDurations:connectors)
        XCTAssertEqual(withoutMode.first?.id,bus.id)
        let accurate=TripRanking.recommended([bus,bikeRail],estimates:.init(),at:now,preferences:preference,
            walkingDurations:connectors,cyclingDurations:[bikeRail.id:700])
        XCTAssertEqual(accurate.first?.id,bikeRail.id,"The connector only has 200 seconds on foot, not 900")
        let timing=TripRanking.assessment(bikeRail,estimates:.init(),at:now,preferences:preference,walkingDurations:connectors[bikeRail.id])
        XCTAssertEqual(timing.elapsedSeconds-timing.waitingSeconds,1500,accuracy:0.001,"All 900 connector seconds still count towards reaching the platform")
        let aligned = bikeRail.asVariant("bike").withEndpointDistances(access:900,egress:300)
        XCTAssertEqual(aligned.rides.map(\.id),bikeRail.rides.map(\.id))
        XCTAssertEqual(aligned.rideSeconds,bikeRail.rideSeconds)
        XCTAssertEqual(aligned.variant,"bike")
        XCTAssertEqual(aligned.accessDistance,900);XCTAssertEqual(aligned.egressDistance,300)
    }
    func testNightServiceDoesNotLookLikeAnEightMinuteWaitInTheAfternoon() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-03T06:00:00Z"))
        XCTAssertEqual(BusServiceWindow.secondsOfDay(at: date), 14 * 3_600)
        let window = try XCTUnwrap(BusServiceWindow(first: "2100", last: "0100"))
        let wait = window.waitBeforeOpening(secondsOfDay: 14 * 3_600, fullRouteSeconds: 3_600)
        XCTAssertEqual(wait, 7 * 3_600)
        let pending = TripRanking.assess(riding: [300], walking: [0, 0], arrivals: [-1], minimumServiceWaits: [wait])
        XCTAssertEqual(pending.waitingSeconds, wait)
        let reportedBus = TripRanking.assess(riding: [300], walking: [0, 0], arrivals: [120], minimumServiceWaits: [wait])
        XCTAssertEqual(reportedBus.waitingSeconds, 120, "A live arriving bus overrides an outdated service window")
    }
    func testOvernightLastBusAndMissingWindowsArePreserved() throws {
        let night = try XCTUnwrap(BusServiceWindow(first: "2100", last: "0100"))
        XCTAssertEqual(night.waitBeforeOpening(secondsOfDay: 30 * 60, fullRouteSeconds: 3_600), 0)
        let daytime = try XCTUnwrap(BusServiceWindow(first: "0530", last: "2330"))
        XCTAssertEqual(daytime.waitBeforeOpening(secondsOfDay: 30 * 60, fullRouteSeconds: 7_200), 0)
        XCTAssertNil(BusServiceWindow(first: "", last: "2330"))
        XCTAssertNil(BusServiceWindow(first: "9900", last: "2330"))
    }
    func testRouteKeypadShortNamesMatchTheOfficialCommuterName() {
        let catalog = RouteCatalog(routes: [
            BusRoute(id: "12", parentID: "12", name: "內科通勤專車12", variantName: "", departure: "甲", destination: "乙"),
            BusRoute(id: "2", parentID: "2", name: "內科通勤專車2", variantName: "", departure: "甲", destination: "乙")
        ])
        XCTAssertEqual(catalog.search("內科2").first?.route.id, "2")
        XCTAssertEqual(catalog.search("內科12").first?.route.id, "12")
        XCTAssertEqual(catalog.search("通勤").count, 2)
    }
    func testNearbyTimesFavorDirectOverAnExtraConnection() {
        let direct = TripRanking.assess(riding: [1_200], walking: [60, 60], arrivals: [300])
        let transfer = TripRanking.assess(riding: [450, 450], walking: [60, 90, 60], arrivals: [180, 960])
        XCTAssertLessThan(transfer.elapsedSeconds, direct.elapsedSeconds)
        XCTAssertLessThan(direct.score, transfer.score, "A small time saving should not outweigh a transfer")
    }
    func testAMuchFasterTransferCanStillBeRecommendedFirst() {
        let direct = TripRanking.assess(riding: [2_400], walking: [60, 60], arrivals: [600])
        let transfer = TripRanking.assess(riding: [450, 450], walking: [60, 90, 60], arrivals: [180, 960])
        XCTAssertLessThan(transfer.score, direct.score)
    }
    func testUnknownDirectArrivalIsNotAutomaticallyWorseThanAKnownTransfer() {
        let direct = TripRanking.assess(riding: [900], walking: [0, 0], arrivals: [nil])
        let transfer = TripRanking.assess(riding: [500, 400], walking: [0, 90, 0], arrivals: [60, nil])
        XCTAssertLessThan(direct.score, transfer.score)
        XCTAssertEqual(direct.uncertainWaits, 1)
    }
    func testAWalkingRouteThatMissesTheFirstBusDoesNotGetAFreeWait() {
        let missed = TripRanking.assess(riding: [600], walking: [420, 60], arrivals: [60])
        let catchable = TripRanking.assess(riding: [600], walking: [60, 60], arrivals: [240])
        XCTAssertTrue(missed.missedFirstArrival)
        XCTAssertGreaterThan(missed.waitingSeconds, 0)
        XCTAssertGreaterThan(missed.score, catchable.score)
        XCTAssertFalse(catchable.missedFirstArrival)
    }
    func testTransferArrivalIsComparedWithWhenThePassengerReachesIt() {
        let missed = TripRanking.assess(riding: [300, 300], walking: [0, 60, 0], arrivals: [60, 120])
        let reachable = TripRanking.assess(riding: [300, 300], walking: [0, 60, 0], arrivals: [60, 600])
        XCTAssertEqual(missed.uncertainWaits, 1)
        XCTAssertEqual(reachable.uncertainWaits, 0)
        XCTAssertEqual(reachable.waitingSeconds, 240)
        XCTAssertGreaterThan(missed.score, reachable.score)
    }
    func testClosedAndNotDepartedAreDifferent() {
        let closed = TripRanking.assess(riding: [300], walking: [0, 0], arrivals: [-4])
        let pending = TripRanking.assess(riding: [300], walking: [0, 0], arrivals: [-1])
        XCTAssertTrue(closed.unavailable)
        XCTAssertTrue(closed.score.isInfinite)
        XCTAssertFalse(pending.unavailable)
        XCTAssertGreaterThan(pending.waitingSeconds, 0)
    }
}
