import XCTest

final class MixedRouteMenuUsabilityTests: JourneyUsabilityTestBase {
    override func tearDownWithError() throws {
        let shot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        shot.name = "mixed-menu-final-screen";shot.lifetime = .keepAlways;add(shot)
    }
    private func requireRouteMenu() -> Bool {
        if button("journey-all-options").waitForExistence(timeout:120) { return true }
        let probe = app.staticTexts["journey-timing-state"]
        print("ROUTE_MENU_START_STATE " + (probe.exists ? probe.label : "state unavailable"))
        let shot = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        shot.name = "mixed-menu-entry-missing";shot.lifetime = .keepAlways;add(shot)
        XCTFail("Route menu was not presented after the fixture loaded")
        return false
    }
    private func state() -> [String:Any] {
        guard let data = app.staticTexts["journey-timing-state"].label.data(using:.utf8),
              let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return [:] }
        return value
    }
    private func camera() -> [String:Any] {
        guard let data = app.staticTexts["map-camera-state"].label.data(using:.utf8),
              let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return [:] }
        return value
    }
    private func waitFor(_ description: String, _ condition: @escaping () -> Bool) {
        let item = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in condition() }, object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[item],timeout:30),.completed,description)
    }
    private func readySuggestionState() -> [String:Any] {
        // The debug timeline can still show the preceding frame when the new button
        // first becomes accessible. Read one coherent, started journey before saving IDs.
        var ready: [String:Any] = [:]
        waitFor("The proposed and active routes are both ready") {
            let value = self.state()
            guard value["started"] as? Bool == true, !(value["selected"] as? String ?? "").isEmpty,
                  !(value["suggestion"] as? String ?? "").isEmpty else { return false }
            ready = value; return true
        }
        return ready
    }
    private func verifyMenu(english: Bool) {
        var args = ["--preview-mixed-planning","--usability-fixture","--test-map-controls","--test-journey-selection"]
        if english { args += ["--test-language","en"] }
        launch(args)
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout:120))
        XCTAssertFalse(app.buttons["返回地圖"].exists)
        XCTAssertFalse(app.buttons["Back to map"].exists)
        XCTAssertFalse(button("journey-options").exists)
        let initial = state(), options = initial["options"] as? [[String:Any]] ?? []
        XCTAssertEqual(options.count,3)
        XCTAssertTrue(options.contains { Set($0["modes"] as? [String] ?? []) == Set(["bus","metro"]) })
        XCTAssertTrue(options.contains { Set($0["modes"] as? [String] ?? []) == Set(["metro"]) })
        XCTAssertTrue(options.contains { Set($0["modes"] as? [String] ?? []) == Set(["bus"]) })
        for index in options.indices {
            button("journey-page-\(index)").tap()
            let id = options[index]["id"] as? String ?? ""
            waitFor("Map selection follows the route page") { self.state()["selected"] as? String == id }
            waitFor("The complete route fills the unobstructed map") {
                guard let frame = self.camera()["routeFraming"] as? [String:Any] else { return false }
                return self.camera()["cameraMoving"] as? Bool == false && frame["inside"] as? Bool == true &&
                    max(frame["widthUsage"] as? Double ?? 0, frame["heightUsage"] as? Double ?? 0) > 0.72
            }
            XCTAssertEqual(state()["started"] as? Bool,false)
            XCTAssertTrue(button("journey-go-"+id).isHittable)
            XCTAssertTrue(button("journey-steps-"+id).isHittable)
            XCTAssertLessThan(button("journey-go-"+id).frame.maxY, button("journey-all-options").frame.minY,
                              "Go belongs to the visible route card, above the comparison footer")
            capture("mixed-menu-\(english ? "en" : "zh")-option-\(index)")
        }
        button("journey-page-0").tap()
        let mixedID = options[0]["id"] as? String ?? ""
        waitFor("Mixed route remains selected") { self.state()["selected"] as? String == mixedID }
        button("journey-steps-"+mixedID).tap()
        XCTAssertTrue(button("journey-start-navigation").waitForExistence(timeout:10))
        XCTAssertTrue(app.staticTexts["journey-ride-time-0"].exists)
        XCTAssertTrue(app.staticTexts["journey-ride-time-1"].exists)
        XCTAssertEqual(state()["started"] as? Bool,false)
        capture("mixed-menu-\(english ? "en" : "zh")-steps")
        button("journey-back").tap()
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout:10))
        XCTAssertEqual(state()["selected"] as? String,mixedID)
        XCTAssertEqual(state()["started"] as? Bool,false)
        button("journey-all-options").tap()
        let row = button("journey-option-"+(options[1]["id"] as? String ?? ""))
        XCTAssertTrue(row.waitForExistence(timeout:10)); row.tap()
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout:10))
        XCTAssertFalse(button("journey-start-navigation").exists)
        XCTAssertEqual(state()["started"] as? Bool,false)
        button("journey-close").tap()
        XCTAssertTrue(button("home-destination-search").waitForExistence(timeout:10))
        XCTAssertFalse(button("journey-go-"+mixedID).exists)
        XCTAssertFalse(button("journey-board").exists)
        capture("mixed-menu-closed")
    }
    func testMixedRoutesShareOneMenuAndFillTheMap() { verifyMenu(english:false) }
    func testEnglishMixedRoutesKeepTheSameFlow() { verifyMenu(english:true) }
    func testJourneyAlternativeIsOptionalAndBoardingKeepsTheChosenRoute() {
        launch(["--preview-mixed-planning","--preview-journey-suggestion","--usability-fixture","--test-journey-selection","--test-map-controls"])
        let dismiss = button("journey-alternative-dismiss")
        XCTAssertTrue(dismiss.waitForExistence(timeout:120))
        let initial = readySuggestionState(), selected = initial["selected"] as? String
        XCTAssertEqual(initial["route_panel_open"] as? Bool,false)
        XCTAssertGreaterThanOrEqual(dismiss.frame.width,44);XCTAssertGreaterThanOrEqual(dismiss.frame.height,44)
        capture("journey-alternative-optional")
        dismiss.tap()
        waitFor("Dismiss keeps navigation and the selected route") {
            let value = self.state()
            return value["suggestion"] as? String == "" && value["selected"] as? String == selected &&
                value["started"] as? Bool == true
        }
        XCTAssertFalse(button("journey-alternative-accept").exists)
        XCTAssertTrue(button("journey-board").isHittable);button("journey-board").tap()
        waitFor("Boarding proceeds with the original route") {
            self.state()["step"] as? Int == 1 && self.state()["selected"] as? String == selected
        }
        capture("journey-alternative-dismissed-boarded")
    }
    func testEnglishJourneyAlternativeChangesOnlyAfterSwitchIsTapped() {
        launch(["--preview-mixed-planning","--preview-journey-suggestion","--usability-fixture","--test-journey-selection","--test-language","en"])
        let accept = button("journey-alternative-accept")
        XCTAssertTrue(accept.waitForExistence(timeout:120))
        let initial = readySuggestionState(), proposed = initial["suggestion"] as? String ?? ""
        XCTAssertFalse(proposed.isEmpty);XCTAssertNotEqual(initial["selected"] as? String,proposed)
        XCTAssertEqual(accept.label,"Switch");XCTAssertTrue(accept.isHittable)
        capture("journey-alternative-en-before-switch")
        accept.tap()
        waitFor("Only an explicit tap replaces the remaining trip") {
            let value = self.state()
            return value["selected"] as? String == proposed && value["started"] as? Bool == true &&
                value["suggestion"] as? String == "" && value["step"] as? Int == 0
        }
        XCTAssertEqual(state()["route_panel_open"] as? Bool,false)
        XCTAssertFalse(button("journey-alternative-accept").exists)
        capture("journey-alternative-en-after-switch")
    }
    func testLateRecommendationMovesFirstWhileTheInspectedPageAndMapRemainSelected() {
        launch(["--preview-mixed-planning","--preview-late-recommendation","--usability-fixture","--test-journey-selection","--test-map-controls"])
        guard requireRouteMenu() else { return }
        let inspected=state()["selected"] as? String ?? ""
        XCTAssertFalse(inspected.isEmpty)
        waitFor("Later recommendation belongs first in the comparison") {
            let choices=self.state()["options"] as? [[String:Any]] ?? []
            return choices.count > 1 && choices.first?["label"] as? String == "推薦"
                && choices.first?["id"] as? String != inspected
        }
        let choices=state()["options"] as? [[String:Any]] ?? []
        let recommended=choices.first?["id"] as? String ?? ""
        XCTAssertEqual(state()["selected"] as? String,inspected)
        XCTAssertEqual(state()["started"] as? Bool,false)
        XCTAssertTrue(button("journey-go-"+inspected).isHittable,"Reordering cannot switch the visible card under the reader")
        capture("mixed-late-recommendation-keeps-preview")
        button("journey-page-0").tap()
        waitFor("First page selects the recommendation") { self.state()["selected"] as? String == recommended }
        XCTAssertTrue(button("journey-go-"+recommended).isHittable)
        XCTAssertEqual(state()["started"] as? Bool,false)
        capture("mixed-late-recommendation-first")
    }
    func testOtherReasonableRoutesRemainAvailableBeyondTheCompactCarousel() {
        launch(["--preview-mixed-planning","--preview-many-options","--usability-fixture","--test-journey-selection"])
        guard requireRouteMenu() else { return }
        let options = state()["options"] as? [[String:Any]] ?? []
        XCTAssertGreaterThan(options.count,5)
        XCTAssertFalse(button("journey-page-5").exists)
        capture("mixed-more-options-compact")
        button("journey-all-options").tap()
        let last = options.last?["id"] as? String ?? ""
        let row = button("journey-option-"+last)
        for _ in 0..<8 {
            if row.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(row.isHittable);capture("mixed-more-options-full-list");row.tap()
        XCTAssertTrue(button("journey-go-"+last).waitForExistence(timeout:10))
        XCTAssertEqual(state()["selected"] as? String,last)
        XCTAssertEqual(state()["started"] as? Bool,false)
        XCTAssertFalse(button("journey-page-5").exists)
        capture("mixed-more-options-selected")
        button("journey-go-"+last).tap()
        waitFor("Go starts the explicitly shown route") { self.state()["started"] as? Bool == true }
        XCTAssertEqual(state()["selected"] as? String,last)
    }
    func testTwoBikeConnectionsHaveSeparateInspectableStations() {
        launch(["--preview-youbike-planning","--preview-youbike-dual","--usability-fixture","--test-journey-selection","--test-map-controls","--test-language","en"])
        guard requireRouteMenu() else { return }
        let id = state()["selected"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        var readySince: Date?
        waitFor("Both bike connections fit the completed map") {
            let value = self.camera()
            guard value["cameraMoving"] as? Bool == false, value["fullyRendered"] as? Bool == true,
                  let frame = value["routeFraming"] as? [String:Any], frame["inside"] as? Bool == true else {
                readySince = nil;return false
            }
            if readySince == nil { readySince = Date() }
            return Date().timeIntervalSince(readySince!) >= 1
        }
        capture("mixed-two-bike-connections-compact")
        let record=(state()["options"] as? [[String:Any]])?.first { $0["id"] as? String == id }
        let legs=record?["bike_legs"] as? [Int] ?? []
        let minutes=record?["bike_ride_minutes"] as? [Int] ?? []
        for (position,index) in legs.enumerated() {
            let chain=app.descendants(matching:.any).matching(identifier:"journey-chain-bike-\(index)").firstMatch
            XCTAssertTrue(chain.exists)
            if minutes.indices.contains(position) { XCTAssertEqual(chain.label,"Ride \(minutes[position]) min") }
        }
        XCTAssertTrue(button("journey-steps-"+id).isEnabled)
        button("journey-steps-"+id).tap()
        XCTAssertTrue(button("journey-start-navigation").waitForExistence(timeout:10))
        XCTAssertTrue(button("journey-bike-pickup-0").exists)
        let options = state()["options"] as? [[String:Any]] ?? []
        let selected = options.first { $0["id"] as? String == id }
        let bikeLegs = selected?["bike_legs"] as? [Int] ?? []
        XCTAssertEqual(bikeLegs.count,2)
        let lastIndex = bikeLegs.last ?? -1
        let dropoff = button("journey-bike-dropoff-\(lastIndex)")
        for _ in 0..<6 { if dropoff.isHittable { break };app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(dropoff.isHittable);capture("mixed-two-bike-connections-steps");dropoff.tap()
        XCTAssertTrue(button("bike-station-close").waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["bike-station-return-status"].exists)
        button("bike-station-close").tap()
        XCTAssertEqual(state()["selected"] as? String,id)
        XCTAssertEqual(state()["started"] as? Bool,false)
        // Single taps only: retries would hide the paging collection swallowing an action.
        // Repeated round trips also exercise actions after the live time labels redraw.
        for _ in 0..<2 {
            button("journey-back").tap()
            XCTAssertTrue(button("journey-all-options").waitForExistence(timeout:10))
            XCTAssertEqual(state()["selected"] as? String,id)
            XCTAssertTrue(button("journey-steps-"+id).isHittable)
            button("journey-steps-"+id).tap()
            XCTAssertTrue(button("journey-start-navigation").waitForExistence(timeout:10))
            XCTAssertEqual(state()["started"] as? Bool,false)
        }
    }
    func testUnavailablePickupStillAllowsPreviewButCannotStartNavigation() {
        launch(["--preview-youbike-planning","--preview-youbike-empty","--usability-fixture","--test-journey-selection","--test-language","en"])
        guard requireRouteMenu() else { return }
        let id = state()["selected"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        XCTAssertFalse(button("journey-go-"+id).isEnabled)
        let steps = button("journey-steps-"+id)
        XCTAssertTrue(steps.isEnabled,"The rider must be able to inspect and adjust an unavailable pickup")
        steps.tap()
        XCTAssertTrue(button("journey-start-navigation").waitForExistence(timeout:10))
        XCTAssertFalse(button("journey-start-navigation").isEnabled)
        XCTAssertTrue(button("journey-bike-pickup-0").exists)
        XCTAssertEqual(state()["started"] as? Bool,false)
        capture("mixed-empty-pickup-still-inspectable")
    }
}
