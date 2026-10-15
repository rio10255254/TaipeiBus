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
        await waitForChoices(p)
        XCTAssertFalse(p.started)
        XCTAssertEqual(p.selectedID,bus.id)
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
}
