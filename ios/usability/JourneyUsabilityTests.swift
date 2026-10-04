import XCTest

class JourneyUsabilityTestBase: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { capture("test-final-state") }
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
        if !field.waitForExistence(timeout: 10), button("搜尋目的地").isHittable {
            capture("destination-entry-before-retry")
            button("搜尋目的地").tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("內湖站")
        let place = app.staticTexts["內湖站"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 20)); capture("search-neihu-with-keyboard"); place.tap()
    }
    var firstOption: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journey-option-")).firstMatch
    }
}

final class MapAndSearchUsabilityTests: JourneyUsabilityTestBase {
    func testInstalledAppIconOnTheHomeScreen() {
        launch()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons.matching(NSPredicate(format: "label IN %@", ["台北公車", "臺北公車", "TaipeiBus"])).firstMatch
        for _ in 0..<3 {
            if icon.exists && icon.isHittable { break }
            springboard.swipeLeft()
        }
        XCTAssertTrue(icon.isHittable)
        capture("app-icon-on-home-screen")
        icon.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }
    var nativeMap: XCUIElement { app.descendants(matching: .any).matching(identifier: "native-map").firstMatch }
    func camera() -> [String: Any] {
        let probe = app.staticTexts["map-camera-state"]
        let text = probe.exists ? probe.label : nativeMap.value as? String ?? ""
        guard let data = text.data(using: .utf8),
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
        waitCamera("The device fan remains visible while the map faces north") {
            ($0["userMarkerVisible"] as? Bool) == true && ($0["userHeadingVisible"] as? Bool) == true &&
            ($0["stationSymbol"] as? Bool) == true && abs(($0["userFanAngle"] as? Double ?? 0) - .pi / 2) < 0.15
        }
        capture("blue-location-dot-and-direction-fan")
        button("map-location").tap()
        waitCamera("Controlled phone heading is east") { ($0["mode"] as? String) == "heading" && abs(($0["heading"] as? Double ?? 0) - 90) < 2 }
        capture("phone-heading-view")
        button("map-location").tap()
        waitCamera("Return north up") { ($0["mode"] as? String) == "north" && abs($0["heading"] as? Double ?? 99) < 1 }
        capture("north-up-view")
        button("map-location").tap()
        waitCamera("Phone direction before resetting the compass") { abs(($0["heading"] as? Double ?? 0) - 90) < 2 }
        app.descendants(matching: .any).matching(identifier: "map-compass").firstMatch.tap()
        waitCamera("Compass stops heading tracking and stays north") { ($0["mode"] as? String) == "free" && abs($0["heading"] as? Double ?? 99) < 1 }
        button("map-location").tap()
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
        waitCamera("Visible rendered station marker") { ($0["markerID"] as? String) != nil }
        let marker = camera()
        nativeMap.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: marker["markerX"] as? Double ?? 0,
            dy: marker["markerY"] as? Double ?? 0)).tap()
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
        button("內科").tap(); button("route-key-2").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "route-result-", "內科通勤專車2")).firstMatch.waitForExistence(timeout: 5))
        capture("route-keypad-commuter")
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
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("TEST-02"))
        button("返回等車").tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 5))
        button("journey-board").tap(); button("journey-alight").tap()
        XCTAssertTrue(button("journey-arrive").waitForExistence(timeout: 5)); capture("walk-last-leg")
        button("journey-arrive").tap(); capture("arrived")
        button("完成").tap()
        XCTAssertTrue(button("搜尋目的地").waitForExistence(timeout: 5))
    }
    func testAllArrivingVehiclesAndOnboardStopsKeepTheConfirmedPlate() throws {
        launch(["--preview-boarding-fixture", "--usability-fixture"])
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 90))
        XCTAssertTrue(app.staticTexts["journey-total-duration"].label.contains("全程約"))
        button("journey-all-vehicles").tap()
        XCTAssertTrue(button("journey-vehicles-done").waitForExistence(timeout: 5))
        capture("all-departed-before-scroll")
        if !button("boarding-vehicle-TEST-04").exists { app.swipeUp() }
        XCTAssertTrue(button("boarding-vehicle-TEST-04").waitForExistence(timeout: 10))
        if !button("boarding-vehicle-TEST-04").isHittable { app.swipeUp() }
        XCTAssertTrue(button("boarding-vehicle-TEST-04").isHittable)
        capture("all-departed-arriving-vehicles")
        button("journey-vehicles-done").tap()
        button("journey-board").tap()
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("選擇搭乘車牌"))
        button("journey-onboard-vehicle").tap()
        let pick = button("onboard-choose-TEST-03")
        XCTAssertTrue(pick.waitForExistence(timeout: 5)); pick.tap()
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("TEST-03"))
        XCTAssertTrue(app.staticTexts["journey-next-stop"].label.contains("下一站"))
        let alighting = app.staticTexts["journey-alighting-time"].label
        XCTAssertTrue(alighting.contains("還有") || alighting.contains("位置更新中"),
            "A single GPS fix must show stop progress or a delayed-position status instead of a fabricated time")
        capture("onboard-next-stop-and-alighting-time")
        button("journey-ride-stops").tap()
        XCTAssertTrue(app.staticTexts["onboard-confirmed-plate"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboard-confirmed-plate"].label, "TEST-03")
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "onboard-stop-")).count, 1)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "暫時裁撤")).firstMatch.exists)
        capture("confirmed-bus-times-at-upcoming-stops")
        button("journey-stops-done").tap()
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("TEST-03"))
        button("journey-options").tap(); button("返回地圖").tap()
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("TEST-03"))
        XCTAssertTrue(button("journey-alight").isHittable)
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
        launch(["--test-journey-selection"])
        XCTAssertTrue(button("搜尋目的地").waitForExistence(timeout: 10)); button("搜尋目的地").tap()
        chooseNeihu()
        XCTAssertTrue(firstOption.waitForExistence(timeout: 60))
        XCTAssertTrue(app.navigationBars["內湖站"].exists)
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journey-option-"))
        XCTAssertEqual(options.count, 3)
        capture("choose-a-route-before-fit-check")
        for index in 0..<options.count { XCTAssertTrue(options.element(boundBy: index).isHittable, "All options must fit without scrolling") }
        for index in 0..<options.count {
            XCTAssertFalse(options.element(boundBy: index).label.contains("今日未營運"))
        }
        capture("choose-a-route")
        let selectedID = String(firstOption.identifier.dropFirst("journey-option-".count))
        // Walking verification may reorder recommendations before confirmation.
        // Select the captured itinerary, rather than whatever later occupies its old row.
        button("journey-option-" + selectedID).tap()
        XCTAssertTrue(button("journey-walk-to-stop").waitForExistence(timeout: 10))
        XCTAssertTrue(button("journey-options").waitForExistence(timeout: 5))
        capture("selected-neihu-route")
        XCTAssertEqual(app.staticTexts["journey-selected-state"].label, selectedID)
        button("journey-walk-to-stop").tap()
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(button("journey-board").isHittable); capture("walking-on-the-same-map")
        button("journey-options").tap(); button("更多行程選項").tap(); button("查看行程").tap()
        capture("full-itinerary")
        XCTAssertTrue(app.navigationBars["行程"].waitForExistence(timeout: 10))
        let externalWalk = button("journey-external-walk-0")
        XCTAssertTrue(externalWalk.waitForExistence(timeout: 10)); externalWalk.tap()
        let maps = XCUIApplication(bundleIdentifier: "com.apple.Maps")
        XCTAssertTrue(maps.wait(for: .runningForeground, timeout: 15))
        capture("walking-in-apple-maps")
        app.activate()
        button("返回地圖").tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["journey-selected-state"].label, selectedID)
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
        button("boarding-vehicle-TEST-01").tap(); button("journey-board").tap()
        XCTAssertTrue(button("journey-alight").waitForExistence(timeout: 5))
        XCTAssertTrue(button("journey-alight").isHittable)
        XCTAssertTrue(button("journey-ride-stops").isHittable)
        capture("onboard-larger-text")
    }
}

// Marketing images use the actual interface and official live data. No vehicle,
// ETA or journey fixtures are permitted in this class.
final class AppStoreScreenshotTests: JourneyUsabilityTestBase {
    func waitRenderedMap(_ condition: @escaping ([String: Any]) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let probe = self.app.staticTexts["map-camera-state"]
            guard probe.exists else { return false }
            let text = probe.label
            guard let data = text.data(using: .utf8),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return condition(state)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 60), .completed)
    }
    func testStoreLiveBusIn3D() {
        let route = ProcessInfo.processInfo.environment["BUS_STORE_VEHICLE_ROUTE"] ?? "307"
        launch(["--preview-vehicle-route", route, "--test-map-controls"])
        XCTAssertTrue(button("停止跟車").waitForExistence(timeout: 90))
        waitRenderedMap { ($0["pitch"] as? Double ?? 0) >= 50 && ($0["zoom"] as? Double ?? 0) >= 17 }
        capture("store-07-live-bus-in-3d")
        // Opening vehicle details changes the map inset; 3D framing must remain.
        button("車輛資訊").tap()
        XCTAssertTrue(button("跟隨公車").waitForExistence(timeout: 10))
        waitRenderedMap { ($0["pitch"] as? Double ?? 0) >= 50 && ($0["zoom"] as? Double ?? 0) >= 17 }
        capture("store-07-live-bus-with-details")
    }
    var nearest: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "nearby-station-")).firstMatch
    }
    func testStoreHomeAndRouteSearch() {
        launch()
        XCTAssertTrue(nearest.waitForExistence(timeout: 90))
        capture("store-01-nearby-map")
        button("路線").tap()
        XCTAssertTrue(button("route-key-藍").waitForExistence(timeout: 15))
        button("route-key-藍").tap(); button("route-key-2").tap(); button("route-key-7").tap()
        let route = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "route-result-", "藍27")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 10))
        capture("store-03-route-keypad")
        route.tap()
        XCTAssertTrue(button("返回搜尋").waitForExistence(timeout: 10))
        capture("store-04-route-map")
    }
    func testStoreRealDestinationAndItinerary() {
        launch(["--test-map-controls"])
        XCTAssertTrue(nearest.waitForExistence(timeout: 90))
        button("搜尋目的地").tap(); chooseNeihu()
        XCTAssertTrue(firstOption.waitForExistence(timeout: 60))
        capture("store-02-trip-choices")
        let selectedID = String(firstOption.identifier.dropFirst("journey-option-".count))
        button("journey-option-" + selectedID).tap()
        XCTAssertTrue(button("journey-walk-to-stop").waitForExistence(timeout: 10))
        waitRenderedMap { ($0["zoom"] as? Double ?? 0) >= 10 && ($0["zoom"] as? Double ?? 99) < 16 }
        capture("store-05-boarding-map")
        button("journey-options").tap(); button("更多行程選項").tap(); button("查看行程").tap()
        XCTAssertTrue(app.navigationBars["行程"].waitForExistence(timeout: 10))
        capture("store-06-full-itinerary")
        button("返回地圖").tap()
        let approach = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "boarding-vehicle-")).firstMatch
        XCTAssertTrue(approach.waitForExistence(timeout: 30), "A real, already-departed bus is required for the screenshot")
        let plate = String(approach.identifier.dropFirst("boarding-vehicle-".count))
        button("boarding-vehicle-" + plate).tap()
        waitRenderedMap { ($0["pitch"] as? Double ?? 0) >= 50 && ($0["zoom"] as? Double ?? 0) >= 17 }
        capture("store-08-bus-first-navigation")
        button("journey-board").tap()
        XCTAssertTrue(button("journey-ride-stops").waitForExistence(timeout: 10))
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains(plate))
        capture("store-09-onboard-live-guidance")
        button("journey-ride-stops").tap()
        XCTAssertTrue(app.staticTexts["onboard-confirmed-plate"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["onboard-confirmed-plate"].label, plate)
        XCTAssertGreaterThan(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "onboard-stop-")).count, 1)
        capture("store-10-time-at-each-stop")
    }
    func testPrivacyAndSupportAreAccessible() {
        launch()
        XCTAssertTrue(button("資料來源與地圖設定").waitForExistence(timeout: 20))
        button("資料來源與地圖設定").tap()
        XCTAssertTrue(app.navigationBars["資訊與設定"].waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if button("app-privacy-policy").isHittable && button("app-support").isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(button("app-privacy-policy").isHittable)
        XCTAssertTrue(button("app-support").isHittable)
        capture("store-private-links-verification")
    }
}

final class CityFleetUsabilityTests: JourneyUsabilityTestBase {
    var map: XCUIElement { app.descendants(matching: .any).matching(identifier: "native-map").firstMatch }
    func camera() -> [String: Any] {
        let probe = app.staticTexts["map-camera-state"]
        let text = probe.exists ? probe.label : map.value as? String ?? ""
        guard let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    func wait(_ description: String, _ condition: @escaping ([String: Any]) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition(self.camera()) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 90), .completed, description + String(describing: camera()))
    }
    func testDenseFleetZoomTrackingAndReturn() {
        launch(["--test-map-controls", "--city-fleet-fixture", "--usability-fixture"])
        wait("Fixture was received") { ($0["fleetInput"] as? Int) == 2500 }
        let local = camera()
        button("city-fleet-toggle").tap()
        wait("All 2500 vehicles fit without the old 240-vehicle cutoff") {
            ($0["cityMode"] as? Bool) == true && ($0["fleetVisible"] as? Int) == 2500 &&
            ($0["fleetCompactModels"] as? Int) == 2500 && ($0["fleetModels"] as? Int) == 2500 &&
            ($0["fleetDetailedModels"] as? Int) == 0
        }
        capture("city-2500-gray-buses-stress")
        let firstMotion = camera()
        wait("The dense fleet continues rendering fresh GPS positions") {
            ($0["fleetDenseFrames"] as? Int ?? 0) >= 120 &&
            $0["fleetProbeID"] as? String == firstMotion["fleetProbeID"] as? String &&
            ($0["fleetProbeLongitude"] as? Double ?? 0) - (firstMotion["fleetProbeLongitude"] as? Double ?? 0) > 0.00002
        }
        capture("city-2500-gray-buses-moving")
        let profile = camera()
        XCTAssertLessThan(profile["fleetEncodeP95Ms"] as? Double ?? 1000, 25)
        let performance = XCTAttachment(string: String(describing: profile))
        performance.name = "city-2500-gray-buses-performance"; performance.lifetime = .keepAlways; add(performance)
        let overview = camera()
        XCTAssertNotNil(overview["busHitID"])
        map.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: overview["busHitX"] as? Double ?? -10,
            dy: overview["busHitY"] as? Double ?? -10)).tap()
        wait("Selecting a gray bus focuses the same 3D body while keeping the entire fleet available") {
            !($0["vehicle"] as? String ?? "").isEmpty && ($0["pitch"] as? Double ?? 0) > 50 &&
            ($0["fleetModels"] as? Int ?? 0) > 0 && ($0["fleetInput"] as? Int) == 2500
        }
        capture("city-selected-3d-bus-stress")
        button("關閉選取").tap()
        wait("Return to the exact previous city view") {
            ($0["vehicle"] as? String ?? "") == "" &&
            abs(($0["zoom"] as? Double ?? 99) - (overview["zoom"] as? Double ?? 0)) < 0.1 &&
            abs(($0["latitude"] as? Double ?? 99) - (overview["latitude"] as? Double ?? 0)) < 0.0001 &&
            abs(($0["longitude"] as? Double ?? 99) - (overview["longitude"] as? Double ?? 0)) < 0.0001
        }
        capture("city-returned-to-overview-stress")
        button("city-fleet-toggle").tap()
        wait("Leaving the city restores the local viewport") {
            ($0["cityMode"] as? Bool) == false && abs(($0["zoom"] as? Double ?? 99) - (local["zoom"] as? Double ?? 0)) < 0.1
        }
    }
    func testActualOfficialFleetInTheCityView() {
        launch(["--test-map-controls"])
        wait("Actual official fleet is ready") { ($0["fleetInput"] as? Int ?? 0) > 0 }
        button("city-fleet-toggle").tap()
        wait("Actual city fleet retains gray bus bodies") {
            ($0["cityMode"] as? Bool) == true && ($0["fleetCompactModels"] as? Int ?? 0) > 0 && ($0["zoom"] as? Double ?? 99) < 15
        }
        capture("city-official-live-fleet")
        XCTAssertFalse(app.staticTexts["2500 輛壓力測試資料"].exists)
        let details = XCTAttachment(string: String(describing: camera()))
        details.name = "city-render-counts-and-encode-cost"; details.lifetime = .keepAlways; add(details)
    }
    func testGrayBusBodiesRemainVisibleAcrossZoomAndPan() {
        launch(["--test-map-controls", "--city-fleet-fixture", "--usability-fixture"])
        wait("Dense fixture is ready") { ($0["fleetInput"] as? Int) == 2500 }
        button("city-fleet-toggle").tap()
        wait("Gray overview models are visible") { ($0["fleetCompactModels"] as? Int) == 2500 }
        let wideZoom = camera()["zoom"] as? Double ?? 0
        map.pinch(withScale: 8, velocity: 2)
        wait("Zooming keeps every visible bus a bus model") {
            ($0["zoom"] as? Double ?? 0) > wideZoom + 1.5 && ($0["fleetCompactModels"] as? Int ?? 0) > 0 &&
            ($0["fleetVisible"] as? Int ?? 0) == ($0["fleetModels"] as? Int ?? -1)
        }
        capture("city-gray-buses-mid-distance")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)))
        wait("Panning keeps the received fleet and visible bodies") {
            ($0["fleetInput"] as? Int) == 2500 && ($0["fleetModels"] as? Int ?? 0) > 0
        }
        capture("city-gray-buses-after-pan")
    }
}

final class AppearanceUsabilityTests: JourneyUsabilityTestBase {
    private var expectedDark: Bool { ProcessInfo.processInfo.environment["BUS_TEST_DARK"] == "true" }
    private func state() -> [String: Any] {
        guard let bytes = app.staticTexts["map-camera-state"].label.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        return value
    }
    private func waitState(_ predicate: @escaping ([String: Any]) -> Bool) {
        let test = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.staticTexts["map-camera-state"].exists && predicate(self.state())
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [test], timeout: 90), .completed)
    }
    func testSystemAppearanceHomeRouteKeyboardAndStops() {
        launch(["--test-map-controls"])
        waitState { ($0["darkMode"] as? Bool) == self.expectedDark && ($0["fleetInput"] as? Int ?? 0) > 0 }
        capture("appearance-home")
        button("city-fleet-toggle").tap()
        waitState { ($0["cityMode"] as? Bool) == true && ($0["fleetModels"] as? Int ?? 0) > 0 }
        capture("appearance-city-flow")
        button("city-fleet-toggle").tap()
        button("路線").tap()
        XCTAssertTrue(button("route-key-3").waitForExistence(timeout: 20))
        button("route-key-3").tap(); button("route-key-0").tap(); button("route-key-7").tap()
        capture("appearance-route-keypad")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "route-result-", "307")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15)); result.tap()
        capture("appearance-route-stops")
    }
    func testInterchangeableVehicleTrackingAndOnboardFlow() {
        launch(["--test-map-controls", "--preview-boarding-fixture", "--preview-cooperated-fixture", "--usability-fixture"])
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 90))
        waitState { ($0["darkMode"] as? Bool) == self.expectedDark }
        let bus = button("boarding-vehicle-TEST-01")
        XCTAssertTrue(bus.waitForExistence(timeout: 20))
        capture("appearance-boarding-compatible-vehicles")
        bus.tap()
        waitState { ($0["pitch"] as? Double ?? 0) > 50 && !($0["vehicle"] as? String ?? "").isEmpty }
        capture("appearance-3d-following")
        button("journey-board").tap()
        XCTAssertTrue(button("journey-onboard-vehicle").waitForExistence(timeout: 15))
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("TEST-01"))
        capture("appearance-onboard")
        button("journey-ride-stops").tap()
        XCTAssertTrue(app.staticTexts["onboard-confirmed-plate"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["onboard-confirmed-plate"].label, "TEST-01")
        capture("appearance-onboard-stop-times")
    }
    func testConflictingTimesKeepOfficialArrivalAndTrackableVehiclePositions() {
        launch(["--test-map-controls", "--preview-boarding-fixture", "--preview-cooperated-fixture",
            "--preview-arrival-integrity", "--usability-fixture"])
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 90))
        waitState { ($0["darkMode"] as? Bool) == self.expectedDark }
        let uncertain = button("boarding-vehicle-TEST-01")
        XCTAssertTrue(uncertain.waitForExistence(timeout: 10))
        XCTAssertTrue(uncertain.label.contains("時間待確認"))
        XCTAssertFalse(uncertain.label.contains("約 1 分"))
        XCTAssertTrue(app.staticTexts["boarding-official-arrival"].label.contains("12 分"))
        XCTAssertTrue(app.staticTexts["官方下一班"].exists)
        capture("arrival-conflict-waiting")
        button("journey-all-vehicles").tap()
        XCTAssertTrue(button("journey-vehicles-done").waitForExistence(timeout: 10))
        capture("arrival-confidence-vehicle-list")
        let supported = button("boarding-vehicle-TEST-03")
        if !supported.isHittable { app.swipeUp() }
        XCTAssertTrue(supported.isHittable)
        XCTAssertTrue(supported.label.contains("約") && supported.label.contains("分"),
            "A bus with continuous observed movement retains an individual arrival estimate")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "54 分")).firstMatch.exists)
        supported.tap()
        button("journey-vehicles-done").tap()
        waitState { ($0["pitch"] as? Double ?? 0) > 50 && !($0["vehicle"] as? String ?? "").isEmpty }
        capture("arrival-confidence-tracking")
        button("journey-board").tap()
        XCTAssertTrue(button("journey-onboard-vehicle").waitForExistence(timeout: 10))
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("TEST-03"))
        button("journey-ride-stops").tap()
        XCTAssertTrue(app.staticTexts["onboard-confirmed-plate"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["onboard-confirmed-plate"].label, "TEST-03")
        capture("arrival-confidence-onboard-stops")
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
