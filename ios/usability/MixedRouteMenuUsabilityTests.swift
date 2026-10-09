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
        XCTAssertTrue(button("搜尋目的地").waitForExistence(timeout:10) || button("Search destination").exists)
        XCTAssertFalse(button("journey-go-"+mixedID).exists)
        XCTAssertFalse(button("journey-board").exists)
        capture("mixed-menu-closed")
    }
    func testMixedRoutesShareOneMenuAndFillTheMap() { verifyMenu(english:false) }
    func testEnglishMixedRoutesKeepTheSameFlow() { verifyMenu(english:true) }
}
