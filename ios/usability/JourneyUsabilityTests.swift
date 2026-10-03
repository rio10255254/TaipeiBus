import XCTest

class JourneyUsabilityTestBase: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
    override func setUpWithError() throws { continueAfterFailure = false }
    func launch(_ args: [String] = []) {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"] + args
        app.launch()
    }
    func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        if app.state == .runningForeground {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + "-elements"; tree.lifetime = .keepAlways; add(tree)
        }
    }
    func button(_ id: String) -> XCUIElement { app.buttons[id] }
    func chooseNeihu() {
        let field = app.textFields["journey-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("內湖站")
        let place = app.staticTexts["內湖站"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 20)); capture("search-neihu-with-keyboard"); place.tap()
    }
    var firstOption: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journey-option-")).firstMatch
    }
}

final class MapAndSearchUsabilityTests: JourneyUsabilityTestBase {
    var nativeMap: XCUIElement { app.descendants(matching: .any).matching(identifier: "native-map").firstMatch }
    func camera() -> [String: Any] {
        guard let text = nativeMap.value as? String, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    func waitCamera(_ description: String, _ condition: @escaping ([String: Any]) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition(self.camera()) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed, description + ": " + String(describing: camera()))
    }
    var nearest: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nearby-station-")).firstMatch
    }
    var stationResult: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "station-result-")).firstMatch
    }
    func testNearestStopRecentersAfterZoomingAndPanning() {
        launch(["--test-map-controls"])
        XCTAssertTrue(nearest.waitForExistence(timeout: 90))
        nativeMap.pinch(withScale: 0.12, velocity: -2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.24))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.40)))
        capture("map-before-nearest-stop")
        let id = String(nearest.identifier.dropFirst("nearby-station-".count))
        nearest.tap()
        waitCamera("Nearest station must be centered at street scale") { state in
            state["station"] as? String == id && (state["stationDistance"] as? Double ?? 999) < 8 &&
            (state["zoom"] as? Double ?? 0) > 16 && (state["zoom"] as? Double ?? 99) < 19
        }
        capture("nearest-stop-focused")
        button("關閉選取").tap(); XCTAssertTrue(nearest.waitForExistence(timeout: 5)); nearest.tap()
        waitCamera("Selecting the same station must work again") { ($0["stationDistance"] as? Double ?? 999) >= 0 && ($0["stationDistance"] as? Double ?? 999) < 8 }
    }
    func testNorthAndPhoneDirectionSwitching() {
        launch(["--test-map-controls", "--test-device-heading"])
        XCTAssertTrue(nearest.waitForExistence(timeout: 90))
        button("map-location").tap()
        waitCamera("North up") { ($0["mode"] as? String) == "north" && abs($0["heading"] as? Double ?? 99) < 1 }
        button("map-location").tap()
        waitCamera("Controlled phone heading is east") { ($0["mode"] as? String) == "heading" && abs(($0["heading"] as? Double ?? 0) - 90) < 2 }
        capture("phone-heading-view")
        button("map-location").tap()
        waitCamera("Return north up") { ($0["mode"] as? String) == "north" && abs($0["heading"] as? Double ?? 99) < 1 }
        capture("north-up-view")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.24))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.34)))
        XCTAssertEqual(button("map-location").value as? String, "自由瀏覽")
        button("map-location").tap()
        waitCamera("A free map first recenters north") { ($0["mode"] as? String) == "north" && abs($0["heading"] as? Double ?? 99) < 1 }
    }
    func testStationListAndMapStayTogether() {
        launch(["--test-map-controls"])
        XCTAssertTrue(nearest.waitForExistence(timeout: 90))
        button("站牌").tap()
        XCTAssertTrue(stationResult.waitForExistence(timeout: 20))
        XCTAssertTrue(button("station-results-map").isHittable)
        capture("nearby-stations-and-map")
        stationResult.tap()
        waitCamera("Station detail map center") { ($0["stationDistance"] as? Double ?? -1) >= 0 && ($0["stationDistance"] as? Double ?? 999) < 8 }
        button("返回搜尋").tap()
        XCTAssertTrue(stationResult.waitForExistence(timeout: 10))
        let field = app.textFields["transit-search-field"]
        field.tap(); field.typeText("內湖")
        XCTAssertTrue(stationResult.waitForExistence(timeout: 20))
        button("station-results-map").tap()
        waitCamera("Search results are on the map") { ($0["browsing"] as? Bool) == true && ($0["queryMarkers"] as? Int ?? 0) > 0 }
        capture("station-search-results-on-map")
        stationResult.tap(); button("返回搜尋").tap()
        XCTAssertEqual(app.textFields["transit-search-field"].value as? String, "內湖")
    }
    func testDedicatedRouteKeypadAndHistory() {
        launch()
        XCTAssertTrue(button("路線").waitForExistence(timeout: 15)); button("路線").tap()
        XCTAssertTrue(button("route-key-藍").waitForExistence(timeout: 90))
        button("route-key-藍").tap(); button("route-key-2").tap(); button("route-key-7").tap()
        XCTAssertEqual(button("route-query").label, "藍27")
        let route = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "route-result-", "藍27")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 10)); capture("route-keypad-blue-27")
        route.tap(); button("返回搜尋").tap()
        XCTAssertEqual(button("route-query").label, "藍27")
        button("清除搜尋").tap(); capture("route-search-history")
        XCTAssertTrue(app.staticTexts["最近查看"].exists)
        button("route-key-幹線").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "route-result-", "幹線")).firstMatch.waitForExistence(timeout: 5))
        button("route-key-⌫").tap(); XCTAssertEqual(button("route-query").label, "幹")
        button("清除搜尋").tap(); button("route-text-keyboard").tap()
        let field = app.textFields["transit-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("南京")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "route-result-", "南京")).firstMatch.waitForExistence(timeout: 10))
        capture("route-text-search")
        button("路線專用鍵盤").tap()
        XCTAssertTrue(button("route-key-3").isHittable)
    }
}

final class JourneyUsabilityTests: JourneyUsabilityTestBase {
    func testWaitingTrackingAndCompleteTrip() throws {
        launch(["--preview-boarding-fixture", "--usability-fixture"])
        let second = button("boarding-vehicle-TEST-02")
        XCTAssertTrue(second.waitForExistence(timeout: 90))
        XCTAssertTrue(button("boarding-vehicle-TEST-01").isHittable)
        XCTAssertTrue(button("boarding-vehicle-TEST-03").isHittable)
        XCTAssertTrue(button("journey-board").isHittable)
        capture("waiting-clean")
        second.tap()
        XCTAssertEqual(second.value as? String, "追蹤中"); capture("track-second")
        second.tap(); XCTAssertEqual(second.value as? String, "已選擇")
        second.tap(); XCTAssertEqual(second.value as? String, "追蹤中")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.26))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.31)))
        XCTAssertEqual(second.value as? String, "已選擇"); capture("pan-without-losing-the-bus")
        second.tap(); XCTAssertEqual(second.value as? String, "追蹤中")
        button("journey-options").tap(); button("返回地圖").tap()
        XCTAssertEqual(second.value as? String, "追蹤中"); capture("tracking-after-options-return")
        button("journey-board").tap()
        XCTAssertTrue(button("journey-alight").waitForExistence(timeout: 5)); capture("on-board")
        button("返回等車").tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 5))
        button("journey-board").tap(); button("journey-alight").tap()
        XCTAssertTrue(button("journey-arrive").waitForExistence(timeout: 5)); capture("walk-last-leg")
        button("journey-arrive").tap(); capture("arrived")
        button("完成").tap()
        XCTAssertTrue(button("搜尋目的地").waitForExistence(timeout: 5))
    }
    func testTransferShowsTheNextBus() throws {
        launch(["--preview-boarding-fixture", "--preview-transfer-fixture", "--usability-fixture"])
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 90))
        let firstRoute = app.staticTexts["boarding-route"].label
        capture("transfer-first-bus")
        button("journey-board").tap(); button("journey-alight").tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 5))
        let secondRoute = app.staticTexts["boarding-route"].label
        XCTAssertNotEqual(firstRoute, secondRoute)
        capture("transfer-second-bus")
        button("journey-board").tap(); button("journey-alight").tap()
        XCTAssertTrue(button("journey-arrive").waitForExistence(timeout: 5))
        button("journey-arrive").tap(); button("完成").tap()
        XCTAssertTrue(button("搜尋目的地").waitForExistence(timeout: 5))
    }
    func testSearchCompareCancelAndReturnFromWalkingMap() throws {
        launch()
        XCTAssertTrue(button("搜尋目的地").waitForExistence(timeout: 10)); button("搜尋目的地").tap()
        chooseNeihu()
        XCTAssertTrue(firstOption.waitForExistence(timeout: 60))
        XCTAssertTrue(app.navigationBars["內湖站"].exists)
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journey-option-"))
        XCTAssertEqual(options.count, 3)
        for index in 0..<options.count { XCTAssertTrue(options.element(boundBy: index).isHittable, "All options must fit without scrolling") }
        for index in 0..<options.count {
            XCTAssertFalse(options.element(boundBy: index).label.contains("今日未營運"))
        }
        capture("choose-a-route")
        firstOption.tap()
        XCTAssertTrue(button("journey-walk-to-stop").waitForExistence(timeout: 10))
        XCTAssertTrue(button("journey-options").waitForExistence(timeout: 5))
        capture("selected-neihu-route")
        button("journey-walk-to-stop").tap()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(button("journey-board").isHittable); capture("walking-on-the-same-map")
        button("journey-options").tap(); button("更多行程選項").tap(); button("查看行程").tap()
        let externalWalk = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "步行導航到")).firstMatch
        XCTAssertTrue(externalWalk.waitForExistence(timeout: 5)); externalWalk.tap()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 15))
        capture("walking-in-apple-maps")
        app.activate()
        button("返回地圖").tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 10))
        button("journey-options").tap(); button("更改").tap()
        XCTAssertTrue(app.textFields["journey-search-field"].waitForExistence(timeout: 5))
        app.textFields["journey-search-field"].tap(); app.textFields["journey-search-field"].typeText("xyzqzz")
        capture("edit-destination")
        button("取消").tap()
        XCTAssertTrue(app.navigationBars["內湖站"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["內湖站"].exists)
        button("更改").tap()
        let field = app.textFields["journey-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("西門町")
        let west = app.staticTexts["西門町"].firstMatch
        XCTAssertTrue(west.waitForExistence(timeout: 20)); west.tap()
        XCTAssertTrue(firstOption.waitForExistence(timeout: 60))
        XCTAssertTrue(app.navigationBars["西門町"].exists); capture("changed-destination")
    }
    func testLargerTextKeepsTheMainActionsVisible() throws {
        launch(["--preview-boarding-fixture", "--usability-fixture",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 90))
        XCTAssertTrue(button("journey-board").isHittable)
        XCTAssertTrue(button("journey-walk-to-stop").isHittable)
        XCTAssertTrue(button("boarding-vehicle-TEST-03").isHittable)
        capture("waiting-larger-text")
    }
}

final class NoLocationUsabilityTests: JourneyUsabilityTestBase {
    func testManualOriginStillWorksWhenLocationIsDenied() throws {
        launch()
        XCTAssertTrue(button("搜尋目的地").waitForExistence(timeout: 10)); button("搜尋目的地").tap()
        chooseNeihu()
        XCTAssertTrue(app.navigationBars["出發地"].waitForExistence(timeout: 20))
        capture("no-location-choose-origin")
        let field = app.textFields["journey-search-field"]
        field.tap(); field.typeText("臺北車站")
        let station = app.buttons.matching(NSPredicate(format:
            "(label BEGINSWITH %@ OR label BEGINSWITH %@) AND NOT (identifier BEGINSWITH %@)",
            "臺北車站", "台北車站", "journey-stations-")).firstMatch
        XCTAssertTrue(station.waitForExistence(timeout: 20)); station.tap()
        XCTAssertTrue(firstOption.waitForExistence(timeout: 60)); capture("manual-origin-routes")
        firstOption.tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 5))
    }
}
