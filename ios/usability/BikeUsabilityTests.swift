import XCTest

/// The YouBike flow on the phone: a cycling trip among the choices, its steps, the map, and
/// what the rider is told when the station they are heading to runs out of bikes.
/// Counts come from an explicitly simulated fixture, never from the live feed.
final class BikeUsabilityTests: JourneyUsabilityTestBase {
    @discardableResult
    private func openSteps() -> String {
        let all = button("journey-all-options")
        XCTAssertTrue(all.waitForExistence(timeout: 120))
        all.tap()
        let option = firstOption
        XCTAssertTrue(option.waitForExistence(timeout: 30), "A cycling trip is offered")
        let id = String(option.identifier.dropFirst("journey-option-".count))
        option.tap()
        let steps = button("journey-steps-" + id)
        XCTAssertTrue(steps.waitForExistence(timeout: 20)); steps.tap()
        XCTAssertTrue(button("journey-start-navigation").waitForExistence(timeout: 20))
        return id
    }

    func testCyclingTripShowsItsStationsCountsAndRouteOnTheMap() {
        launch(["--preview-youbike-planning", "--usability-fixture", "--test-journey-selection"])
        capture("youbike-options")
        openSteps()
        XCTAssertTrue(app.staticTexts["journey-bike-status-0"].waitForExistence(timeout: 20))
        // The itinerary names both ends of the ride, not just a distance.
        XCTAssertTrue(button("journey-bike-pickup-0").exists)
        XCTAssertTrue(button("journey-bike-dropoff-0").exists)
        capture("youbike-steps")
        let map = button("journey-in-app-bike-0")
        if map.exists { map.tap(); capture("youbike-map") }
    }

    func testAStationThatRunsOutOffersAnotherOneWithoutLosingTheTrip() {
        launch(["--preview-youbike-planning", "--preview-youbike-empty", "--usability-fixture", "--test-journey-selection"])
        openSteps()
        let alert = app.descendants(matching: .any).matching(identifier: "journey-bike-alert").firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "An empty station is called out")
        capture("youbike-empty-station")
        let switchStation = button("journey-bike-switch")
        XCTAssertTrue(switchStation.waitForExistence(timeout: 10))
        switchStation.tap()
        // The trip stays; only the station changes, and the warning goes with it.
        XCTAssertTrue(app.staticTexts["journey-bike-status-0"].waitForExistence(timeout: 20))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !alert.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 30), .completed, "The warning clears once another station is chosen")
        capture("youbike-switched-station")
    }

    private func state() -> [String: Any] {
        guard let data = app.staticTexts["journey-timing-state"].label.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private var stationCard: XCUIElement {
        app.descendants(matching: .any).matching(identifier:"bike-station-card").firstMatch
    }
    private func closeStation() {
        button("bike-station-close").tap()
        let closed = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !self.stationCard.exists },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[closed],timeout:12),.completed)
    }
    func testBikeStationsCanBeInspectedWithoutStartingOrLosingNavigation() {
        launch(["--preview-youbike-planning","--usability-fixture","--test-journey-selection","--test-map-controls"])
        openSteps()
        let selected = state()["selected"] as? String
        button("journey-bike-dropoff-0").tap()
        XCTAssertTrue(stationCard.waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["bike-station-return-status"].label.contains("目前可還"))
        XCTAssertTrue(app.staticTexts["bike-station-report"].exists)
        capture("bike-return-current-docks-preview")
        closeStation()
        XCTAssertEqual(state()["selected"] as? String,selected)
        XCTAssertEqual(state()["started"] as? Bool,false)
        button("journey-bike-pickup-0").tap()
        XCTAssertTrue(stationCard.waitForExistence(timeout:15))
        capture("bike-pickup-details-preview")
        closeStation()
        button("journey-start-navigation").tap()
        XCTAssertTrue(button("journey-arrive").waitForExistence(timeout:20))
        XCTAssertEqual(state()["started"] as? Bool,true)
        button("journey-bike-dropoff-0").tap()
        XCTAssertTrue(stationCard.waitForExistence(timeout:15))
        capture("bike-return-current-docks-during-navigation")
        closeStation()
        XCTAssertEqual(state()["selected"] as? String,selected)
        XCTAssertEqual(state()["started"] as? Bool,true)

        // Tap the actual return pin on the map, not a separate test-only control.
        let probe = app.staticTexts["map-camera-state"]
        let ready = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            guard let data=probe.label.data(using:.utf8), let camera=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return false }
            return camera["cameraMoving"] as? Bool == false && !(camera["plannedBikePins"] as? [[String:Any]] ?? []).isEmpty
        },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:25),.completed)
        let data = probe.label.data(using:.utf8)!
        let camera = try! JSONSerialization.jsonObject(with:data) as! [String:Any]
        let pin = (camera["plannedBikePins"] as! [[String:Any]]).first { $0["returning"] as? Bool == true }!
        let map = app.descendants(matching:.any).matching(identifier:"native-map").firstMatch
        map.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:pin["x"] as! Double,dy:pin["y"] as! Double)).tap()
        XCTAssertTrue(stationCard.waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["bike-station-return-status"].exists)
        capture("bike-map-return-pin-opens-current-docks")
        closeStation()
        XCTAssertEqual(state()["started"] as? Bool,true)
    }
    func testStaleReturnAvailabilityIsNotDisplayedAsConfirmedParking() {
        launch(["--preview-youbike-planning","--preview-youbike-stale","--usability-fixture","--test-journey-selection"])
        openSteps()
        XCTAssertTrue(button("journey-bike-dropoff-0").label.contains("空位待確認"))
        button("journey-bike-dropoff-0").tap()
        XCTAssertTrue(stationCard.waitForExistence(timeout:15))
        XCTAssertEqual(app.staticTexts["bike-station-return-status"].label,"空位待確認")
        XCTAssertEqual(app.staticTexts["bike-station-report"].label,"資料延遲")
        capture("bike-stale-docks-are-not-promised")
        closeStation()
        XCTAssertEqual(state()["started"] as? Bool,false)
    }
}
