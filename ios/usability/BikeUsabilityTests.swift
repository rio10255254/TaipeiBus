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
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "借車")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "還車")).firstMatch.exists)
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
}
