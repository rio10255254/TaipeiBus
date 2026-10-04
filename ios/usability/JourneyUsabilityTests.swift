import XCTest

class JourneyUsabilityTestBase: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { capture("test-final-state") }
    func launch(_ args: [String] = []) {
        let english = args.firstIndex(of: "--test-language").map { args.indices.contains($0 + 1) && args[$0 + 1] == "en" } ?? false
        let language = args.contains("--test-language") || args.contains("--persist-language-preference") ? [] : ["--test-language", "zh-Hant"]
        app.launchArguments = ["-AppleLanguages", english ? "(en)" : "(zh-Hant)", "-AppleLocale", english ? "en_TW" : "zh_TW"] + language + args
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
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND enabled == true", "journey-option-")).firstMatch
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
        XCTAssertTrue(button("journey-board").isEnabled)
        XCTAssertTrue(button("journey-board").isHittable)
        // Wait for the initial bottom-dock insertion to finish before touching it.
        Thread.sleep(forTimeInterval: 1)
        button("journey-board").tap()
        XCTAssertTrue(button("journey-alight").waitForExistence(timeout: 10))
        button("journey-alight").tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 5))
        let secondRoute = app.staticTexts["boarding-route"].label
        XCTAssertNotEqual(firstRoute, secondRoute)
        capture("transfer-second-bus")
        button("journey-board").tap()
        XCTAssertTrue(button("journey-alight").waitForExistence(timeout: 10))
        button("journey-alight").tap()
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
        XCTAssertTrue((1...3).contains(options.count))
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

final class AnimationUsabilityTests: JourneyUsabilityTestBase {
    var map: XCUIElement { app.descendants(matching: .any).matching(identifier: "native-map").firstMatch }
    func camera() -> [String: Any] {
        let value = app.staticTexts["map-camera-state"].label
        guard let data = value.data(using: .utf8), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return state
    }
    func wait(_ description: String, _ condition: @escaping ([String: Any]) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition(self.camera()) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 90), .completed, description + String(describing: camera()))
    }
    func assertContinuousCamera(_ state: [String: Any]) {
        let traces = state["transitions"] as? [[String: Any]] ?? []
        let moving = traces.filter { trace in
            let samples = trace["samples"] as? [[String: Double]] ?? []
            let target = trace["targetZoom"] as? Double ?? 0
            return (trace["duration"] as? Double ?? 0) > 0 && abs((samples.first?["zoom"] ?? 0) - target) > 1 &&
                abs((samples.last?["zoom"] ?? 99) - target) < 0.03
        }
        XCTAssertFalse(moving.isEmpty, "A zoom-changing camera transition must be measured.")
        for trace in moving {
            let samples = trace["samples"] as? [[String: Double]] ?? []
            let start = samples.first?["zoom"] ?? 0, target = trace["targetZoom"] as? Double ?? 0
            let span = target - start
            let intermediate = samples.filter { sample in
                let progress = ((sample["zoom"] ?? start) - start) / span
                return progress > 0.05 && progress < 0.95
            }
            XCTAssertGreaterThanOrEqual(intermediate.count, 3, "The map must render intermediate viewpoints, not jump straight to the end.")
        }
        let attachment = XCTAttachment(string: String(describing: traces))
        attachment.name = "measured-camera-transition-frames"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testCityCameraMovesContinuouslyAndReturnsToTheSameView() {
        launch(["--test-map-controls", "--test-transitions", "--city-fleet-fixture", "--usability-fixture"])
        wait("Controlled fleet is ready") { ($0["fleetInput"] as? Int) == 2500 }
        let local = camera()
        button("city-fleet-toggle").tap()
        wait("City framing settles") { state in
            let trace = (state["transitions"] as? [[String: Any]])?.last
            let samples = trace?["samples"] as? [[String: Double]] ?? []
            return state["cityMode"] as? Bool == true && abs((state["zoom"] as? Double ?? 99) - (trace?["targetZoom"] as? Double ?? 0)) < 0.03 &&
                samples.count >= 3 && (samples.last?["t"] ?? 0) >= (trace?["duration"] as? Double ?? 99)
        }
        let overview = camera(); assertContinuousCamera(overview); capture("continuous-city-camera-and-subtle-controls")
        XCTAssertNotNil(overview["busHitID"])
        map.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: overview["busHitX"] as? Double ?? -10,
            dy: overview["busHitY"] as? Double ?? -10)).tap()
        wait("The selected bus remains centered") { ($0["pitch"] as? Double ?? 0) > 56 && !($0["selectedVehicle"] as? String ?? "").isEmpty }
        button("關閉選取").tap()
        wait("Returning restores the city overview") {
            ($0["selectedVehicle"] as? String ?? "") == "" && abs(($0["zoom"] as? Double ?? 99) - (overview["zoom"] as? Double ?? 0)) < 0.03
        }
        assertContinuousCamera(camera())
        button("city-fleet-toggle").tap()
        wait("Leaving restores the original local view") {
            ($0["cityMode"] as? Bool) == false && abs(($0["zoom"] as? Double ?? 99) - (local["zoom"] as? Double ?? 0)) < 0.03
        }
        assertContinuousCamera(camera()); capture("local-view-restored-after-city-animation")
    }
    func testReduceMotionPreservesFramingWithoutAnimatedTravel() {
        launch(["--test-map-controls", "--test-transitions", "--test-reduce-motion", "--city-fleet-fixture", "--usability-fixture"])
        wait("Controlled fleet is ready") { ($0["fleetInput"] as? Int) == 2500 && ($0["reduceMotion"] as? Bool) == true }
        let local = camera()
        button("city-fleet-toggle").tap()
        wait("City appears at its target without animated travel") { state in
            let trace = (state["transitions"] as? [[String: Any]])?.last
            return state["cityMode"] as? Bool == true && (trace?["duration"] as? Double) == 0 &&
                abs((state["zoom"] as? Double ?? 99) - (trace?["targetZoom"] as? Double ?? 0)) < 0.03
        }
        capture("reduce-motion-city-view")
        button("city-fleet-toggle").tap()
        wait("Reduce Motion also restores the local view") {
            ($0["cityMode"] as? Bool) == false && abs(($0["zoom"] as? Double ?? 99) - (local["zoom"] as? Double ?? 0)) < 0.03
        }
        let traces = camera()["transitions"] as? [[String: Any]] ?? []
        XCTAssertTrue(traces.allSatisfy { ($0["duration"] as? Double) == 0 })
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

final class NavigationOptimizationUsabilityTests: JourneyUsabilityTestBase {
    private func timing() -> [String: Any] {
        guard let bytes = app.staticTexts["journey-timing-state"].label.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        return value
    }
    private func waitTiming(_ condition: @escaping ([String: Any]) -> Bool) {
        let test = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.staticTexts["journey-timing-state"].exists && condition(self.timing())
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [test], timeout: 150), .completed)
    }
    func testRealNeihuOptionsHaveVerifiedWalkingSeparateWaitsAndArrivalClocks() {
        launch(["--test-journey-selection", "--test-map-controls", "--preview-neihu-planning"])
        waitTiming { ($0["checking"] as? Bool) == false && ($0["options"] as? [[String: Any]] ?? []).count > 0 }
        XCTAssertTrue(button("journey-options").waitForExistence(timeout: 10))
        button("journey-options").tap()
        XCTAssertTrue(app.navigationBars["忠孝復興站"].waitForExistence(timeout: 10))
        let state = timing(), records = state["options"] as? [[String: Any]] ?? []
        XCTAssertTrue((1...3).contains(records.count))
        for record in records {
            XCTAssertEqual(record["verified"] as? Bool, true)
            XCTAssertNotEqual(record["label"] as? String, "少轉乘", "A one-transfer option cannot claim fewer transfers than a direct bus")
            let total = record["total"] as? Double ?? -1
            let walking = record["walking"] as? Double ?? -1, waiting = record["waiting"] as? Double ?? -1, riding = record["riding"] as? Double ?? -1
            XCTAssertEqual(total, walking + waiting + riding, accuracy: 0.01)
            XCTAssertFalse((record["arrival_label"] as? String ?? "").isEmpty)
            if (record["unknown"] as? Int ?? 0) > 0 { XCTAssertEqual(record["arrival_label"] as? String, "抵達待確認") }
            let choice = button("journey-option-" + (record["id"] as? String ?? ""))
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertTrue(choice.isEnabled)
            XCTAssertTrue(choice.isHittable, "All verified choices must be visible without scrolling")
            XCTAssertTrue(choice.label.contains("候車") || choice.label.contains("步行即可"))
        }
        Thread.sleep(forTimeInterval: 17)
        XCTAssertEqual((timing()["options"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String },
                       records.compactMap { $0["id"] as? String }, "Live updates must not move or replace choices while comparing")
        capture("optimized-neihu-options-and-times")
        let report = XCTAttachment(string: String(describing: state))
        report.name = "navigation-optimized-timing-report"; report.lifetime = .keepAlways; add(report)
        XCTAssertTrue(button("journey-other-transit").exists)
        if button("journey-refresh-options").exists {
            button("journey-refresh-options").tap()
            let refreshed = timing()
            XCTAssertEqual(refreshed["selected"] as? String, (refreshed["options"] as? [[String: Any]])?.first?["id"] as? String)
            XCTAssertEqual(refreshed["checking"] as? Bool, false, "Refreshing verified choices should reuse their pedestrian routes")
            capture("optimized-explicitly-refreshed-options")
        }
        let choice = firstOption
        let identity = choice.identifier
        choice.tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 10))
        capture("optimized-neihu-waiting-and-arrival")
        button("journey-options").tap(); button("返回地圖").tap()
        XCTAssertEqual(timing()["selected"] as? String, String(identity.dropFirst("journey-option-".count)))
    }
    func testBoardingUsesRemainingTravelAndPreservesTheConfirmedPlate() {
        launch(["--test-journey-selection", "--preview-boarding-fixture", "--preview-cooperated-fixture", "--usability-fixture"])
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 90))
        let first = timing()
        let before = (first["options"] as? [[String: Any]])?.first?["total"] as? Double ?? -1
        XCTAssertGreaterThan(before, 0)
        button("boarding-vehicle-TEST-01").tap(); button("journey-board").tap()
        XCTAssertTrue(button("journey-onboard-vehicle").waitForExistence(timeout: 10))
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("TEST-01"))
        let current = timing()
        let rideCount = (current["options"] as? [[String: Any]])?.first?["ride_stop_count"] as? Int ?? 0
        let boarding = (current["options"] as? [[String: Any]])?.first?["boarding_name"] as? String ?? ""
        XCTAssertGreaterThan(rideCount, 0)
        XCTAssertFalse(app.staticTexts["journey-next-stop"].label.contains("下一站 · " + boarding))
        XCTAssertTrue(app.staticTexts["journey-alighting-time"].label.contains("還有 \(rideCount) 站"), "A GPS fix before boarding must not add the already-boarded stop")
        let after = (current["options"] as? [[String: Any]])?.first?["total"] as? Double ?? before
        XCTAssertLessThan(after, before, "Already spent access/wait time must not remain in the destination clock")
        XCTAssertTrue(app.staticTexts["journey-total-duration"].label.contains("剩餘"))
        capture("optimized-onboard-remaining-time")
        button("journey-options").tap()
        XCTAssertTrue(app.staticTexts["journey-duration-breakdown"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["journey-duration-breakdown"].label.contains("剩餘"))
        XCTAssertTrue(app.staticTexts["journey-walk-status-0"].label.hasPrefix("已走到"))
        XCTAssertTrue(app.staticTexts["journey-ride-status-0"].label.contains("搭乘中 · TEST-01"))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "路線到站：")).firstMatch.exists)
        capture("optimized-onboard-itinerary-remaining-time")
        button("返回地圖").tap()
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("TEST-01"))
        button("返回等車").tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 10))
    }
}

final class EnglishModeUsabilityTests: JourneyUsabilityTestBase {
    private func probe(_ id: String) -> [String: Any] {
        guard let data = app.staticTexts[id].label.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private func waitProbe(_ id: String, _ condition: @escaping ([String: Any]) -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.staticTexts[id].exists && condition(self.probe(id))
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 160), .completed)
    }
    func testEnglishBrowsingShowsOfficialTimesWithBilingualStops() {
        launch(["--test-language", "en", "--preview-browse-fixture", "--preview-cooperated-fixture", "--preview-details", "--usability-fixture"])
        XCTAssertTrue(app.staticTexts["browse-hero-official-arrival"].waitForExistence(timeout: 90))
        XCTAssertTrue(app.staticTexts["browse-hero-official-arrival"].isHittable, "The official time should be visible before scrolling")
        let official = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browse-official-arrival-")).firstMatch
        XCTAssertTrue(official.waitForExistence(timeout: 90))
        for _ in 0..<3 { if official.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(official.isHittable)
        XCTAssertTrue(official.label.contains("min") || official.label == "Time unavailable")
        XCTAssertTrue(app.staticTexts["Official arrival times"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "stops left")).firstMatch.exists)
        capture("english-official-browse-and-bilingual-stops")
    }
    func testLanguageSwitchPreservesFollowingAndPersistsAfterRelaunch() {
        let flags = ["--test-map-controls", "--test-journey-selection", "--preview-boarding-fixture", "--preview-cooperated-fixture", "--usability-fixture"]
        launch(flags)
        XCTAssertTrue(button("boarding-vehicle-TEST-01").waitForExistence(timeout: 90)); button("boarding-vehicle-TEST-01").tap()
        waitProbe("map-camera-state") { ($0["following"] as? Bool) == true }
        let before = probe("map-camera-state")
        button("資料來源與地圖設定").tap()
        let toggle = app.switches["app-language-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let nativeSwitch = toggle.descendants(matching: .switch).firstMatch
        XCTAssertTrue(nativeSwitch.waitForExistence(timeout: 5)); nativeSwitch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.navigationBars["Information & settings"].waitForExistence(timeout: 5))
        capture("english-settings-switch")
        button("Done").tap()
        waitProbe("map-camera-state") { ($0["language"] as? String) == "en" && ($0["following"] as? Bool) == true }
        let after = probe("map-camera-state")
        XCTAssertEqual(after["selectedVehicle"] as? String, before["selectedVehicle"] as? String)
        XCTAssertEqual(after["selectedJourney"] as? String, before["selectedJourney"] as? String)
        XCTAssertEqual(after["zoom"] as? Double ?? 0, before["zoom"] as? Double ?? 0, accuracy: 0.15)
        XCTAssertTrue(button("journey-board").label.contains("on board"))
        capture("english-switch-preserves-followed-bus")
        app.terminate(); launch(flags + ["--persist-language-preference"])
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 90))
        XCTAssertTrue(button("journey-board").label.contains("on board"))
        button("Information and settings").tap()
        app.switches["app-language-toggle"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        button("完成").tap()
        XCTAssertEqual(button("journey-board").label, "已上車")
    }
    func testEnglishRouteAndStopSearch() {
        launch(["--test-language", "en", "--test-map-controls"])
        XCTAssertTrue(button("Routes").waitForExistence(timeout: 90)); button("Routes").tap()
        XCTAssertTrue(button("route-key-藍").waitForExistence(timeout: 10))
        XCTAssertEqual(button("route-key-藍").label, "Blue")
        button("route-key-藍").tap(); button("route-key-2").tap(); button("route-key-7").tap()
        let route = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "route-result-")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 15))
        XCTAssertTrue(route.label.lowercased().contains("bl27") || route.label.lowercased().contains("blue27"))
        capture("english-route-keypad-and-endpoints")
        button("Stops").tap()
        let field = app.textFields["transit-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        if button("Clear search").exists { button("Clear search").tap() }
        field.typeText("Neihu Station")
        let stop = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "station-result-")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 20)); XCTAssertTrue(stop.label.lowercased().contains("neihu")); XCTAssertTrue(stop.label.contains("內湖"))
        capture("english-neihu-search-with-chinese-comparison")
    }
    func testEnglishNavigationHasAlightingTimeAndStopCount() {
        launch(["--test-language", "en", "--test-map-controls", "--preview-boarding-fixture", "--preview-cooperated-fixture", "--preview-onboard-time-fixture", "--usability-fixture"])
        XCTAssertTrue(button("boarding-vehicle-TEST-01").waitForExistence(timeout: 90))
        capture("english-before-following")
        button("boarding-vehicle-TEST-01").tap()
        waitProbe("map-camera-state") { !($0["selectedVehicle"] as? String ?? "").isEmpty && ($0["following"] as? Bool) == true }
        XCTAssertEqual(button("boarding-vehicle-TEST-01").value as? String, "Following")
        capture("english-following-before-boarding")
        button("journey-board").tap()
        let summary = app.staticTexts["journey-alighting-time"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.label.contains("stops left")); XCTAssertTrue(summary.label.contains("min"))
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("TEST-01"))
        capture("english-onboard-bilingual-count-and-time")
        button("journey-ride-stops").tap()
        XCTAssertTrue(app.navigationBars["Upcoming stops"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alight here"].exists)
        capture("english-upcoming-stops-with-chinese-signs")
        button("journey-stops-done").tap()
        XCTAssertTrue(app.navigationBars["Upcoming stops"].waitForNonExistence(timeout: 10))
        button("journey-options").tap()
        XCTAssertTrue(app.staticTexts["journey-duration-breakdown"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["journey-duration-breakdown"].label.contains("Remaining"))
        capture("english-onboard-trip-details")
    }
    func testEnglishBoardingWithoutSelectedPlateKeepsChineseAlightingName() {
        launch(["--test-language", "en", "--preview-boarding-fixture", "--preview-cooperated-fixture", "--usability-fixture"])
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 90)); button("journey-board").tap()
        XCTAssertTrue(button("journey-onboard-vehicle").waitForExistence(timeout: 10))
        XCTAssertTrue(button("journey-onboard-vehicle").label.contains("Choose"))
        XCTAssertTrue(app.staticTexts["市民敦化路口"].exists)
        XCTAssertTrue(button("journey-options").isHittable); XCTAssertTrue(button("journey-ride-stops").isHittable)
        capture("english-no-selected-bus-still-has-chinese-alighting-sign")
    }
    func testEnglishRealNeihuOptionsFitAndShowTravelWaitAndArrival() {
        launch(["--test-language", "en", "--test-map-controls", "--test-journey-selection", "--preview-neihu-planning"])
        waitProbe("journey-timing-state") { ($0["checking"] as? Bool) == false && ($0["options"] as? [[String: Any]] ?? []).count > 0 }
        button("journey-options").tap()
        XCTAssertTrue(firstOption.waitForExistence(timeout: 10))
        let options = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journey-option-"))
        XCTAssertTrue((1...3).contains(options.count))
        for index in 0..<options.count {
            let item = options.element(boundBy: index)
            XCTAssertTrue(item.isHittable)
            let label = item.label.lowercased()
            XCTAssertTrue(label.contains("travel") && label.contains("wait") && label.contains("arriv"))
            XCTAssertFalse(item.label.contains("候車"))
            XCTAssertNotNil(item.label.range(of: "[\\u3400-\\u9fff]", options: .regularExpression), "Every boarding/alighting pair keeps Chinese sign names")
        }
        capture("english-real-neihu-compact-options")
        firstOption.tap()
        XCTAssertTrue(button("journey-board").waitForExistence(timeout: 10))
        capture("english-real-neihu-waiting-and-arrival")
    }
}

final class ContinuousGpsUsabilityTests: JourneyUsabilityTestBase {
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
    func testDenseFleetMovesAcrossWholeGPSIntervalsWithoutCatchUpBursts() {
        launch(["--test-map-controls", "--city-fleet-fixture", "--continuous-gps-fixture", "--usability-fixture"])
        waitState { ($0["fleetInput"] as? Int) == 2500 }
        button("city-fleet-toggle").tap()
        waitState {
            ($0["fleetModels"] as? Int) == 2500 &&
            ($0["fleetProbeSourceLongitude"] as? Double ?? 0) - ($0["fleetProbeLongitude"] as? Double ?? 0) > 0.000002
        }
        capture("continuous-2500-gps-before")
        var samples: [[String: Any]] = []
        for _ in 0..<14 {
            samples.append(state())
            Thread.sleep(forTimeInterval: 0.7)
        }
        let identity = samples.first?["fleetProbeID"] as? String
        var moving = 0, measured = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertEqual(b["fleetProbeID"] as? String, identity)
            let interval = (b["fleetProbeFrameTime"] as? Double ?? 0) - (a["fleetProbeFrameTime"] as? Double ?? 0)
            guard interval > 0 else { continue }
            let rate = ((b["fleetProbeLongitude"] as? Double ?? 0) - (a["fleetProbeLongitude"] as? Double ?? 0)) / interval
            XCTAssertGreaterThanOrEqual(rate, -0.0000001)
            XCTAssertLessThan(rate, 0.00004, "Received walking-pace GPS must not be replayed as a fast jump")
            if rate > 0.000001 { moving += 1 }
            measured += 1
            XCTAssertLessThanOrEqual(b["fleetProbeLongitude"] as? Double ?? 0, (b["fleetProbeSourceLongitude"] as? Double ?? 0) + 0.00000001)
            XCTAssertLessThanOrEqual(b["fleetProbeObservedAt"] as? Double ?? 0, b["fleetProbeSourceObservedAt"] as? Double ?? 0)
        }
        XCTAssertGreaterThan(measured, 8)
        XCTAssertGreaterThanOrEqual(Double(moving) / Double(max(1, measured)), 0.7,
            "The fleet should keep moving across the reporting interval rather than finish early and sit still")
        XCTAssertLessThan(state()["fleetEncodeP95Ms"] as? Double ?? 1000, 25)
        let data = try! JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
        let trace = XCTAttachment(string: String(decoding: data, as: UTF8.self))
        trace.name = "continuous-gps-frame-samples"; trace.lifetime = .keepAlways; add(trace)
        capture("continuous-2500-gps-after")
    }
    func testActualOfficialFleetRefreshesWhileFollowingTheSamePhysicalBus() {
        launch(["--test-map-controls", "--preview-vehicle-route", "__live__"])
        waitState { ($0["pitch"] as? Double ?? 0) > 50 && !($0["vehicle"] as? String ?? "").isEmpty }
        let initial = state()
        XCTAssertEqual(initial["vehicleRefreshSeconds"] as? Double, 5)
        XCTAssertFalse(app.staticTexts["2500 輛壓力測試資料"].exists)
        capture("continuous-official-following-before")
        waitState {
            ($0["gpsSourceUpdatedAt"] as? Double ?? 0) > (initial["gpsSourceUpdatedAt"] as? Double ?? 0) &&
            $0["vehicle"] as? String == initial["vehicle"] as? String && ($0["fleetModels"] as? Int ?? 0) > 0
        }
        capture("continuous-official-following-after")
        let update = XCTAttachment(string: String(describing: state()))
        update.name = "continuous-official-source-update"; update.lifetime = .keepAlways; add(update)
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
        // The underlying waiting screen contains the same vehicle. Scope to the presented List.
        let supported = app.collectionViews.buttons["boarding-vehicle-TEST-03"]
        if !supported.isHittable { app.collectionViews.firstMatch.swipeUp() }
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
