import XCTest

final class MixedRouteMenuUsabilityTests: JourneyUsabilityTestBase {
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
    func testOtherReasonableRoutesRemainAvailableBeyondTheCompactCarousel() {
        launch(["--preview-mixed-planning","--preview-many-options","--usability-fixture","--test-journey-selection"])
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout:120))
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
    }
    func testTwoBikeConnectionsHaveSeparateInspectableStations() {
        launch(["--preview-youbike-planning","--preview-youbike-dual","--usability-fixture","--test-journey-selection","--test-language","en"])
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout:120))
        let id = state()["selected"] as? String ?? ""
        XCTAssertFalse(id.isEmpty)
        capture("mixed-two-bike-connections-compact")
        button("journey-steps-"+id).tap()
        XCTAssertTrue(button("journey-start-navigation").waitForExistence(timeout:10))
        XCTAssertTrue(button("journey-bike-pickup-0").exists)
        let options = state()["options"] as? [[String:Any]] ?? []
        let selected = options.first { $0["id"] as? String == id }
        let walkCount = (selected?["walks"] as? [[String:Any]])?.count ?? 2
        let lastIndex = walkCount - 1
        let dropoff = button("journey-bike-dropoff-\(lastIndex)")
        for _ in 0..<6 { if dropoff.isHittable { break };app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(dropoff.isHittable);capture("mixed-two-bike-connections-steps");dropoff.tap()
        XCTAssertTrue(button("bike-station-close").waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["bike-station-return-status"].exists)
        button("bike-station-close").tap()
        XCTAssertEqual(state()["selected"] as? String,id)
        XCTAssertEqual(state()["started"] as? Bool,false)
    }
}
