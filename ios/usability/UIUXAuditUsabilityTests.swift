import XCTest

/// A first-time rider's tour of every main screen, for a design and usability review.
/// Each screen keeps a screenshot, its element tree and a measured list of the controls
/// that are under Apple's 44-point touch minimum, unlabeled, cut off at the screen edge or
/// overlapping another control. Design findings never fail the run: a reviewer reads them.
/// Only a step that cannot be reached is logged, and the tour continues past it.
final class UIUXAuditUsabilityTests: JourneyUsabilityTestBase {
    private var steps: [[String: Any]] = []
    private var screens: [[String: Any]] = []
    private var began = Date()

    override func setUpWithError() throws {
        continueAfterFailure = true
        steps = []; screens = []; began = Date()
    }
    override func tearDownWithError() throws {
        let tag = name.components(separatedBy: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "]")) ?? "test"
        let report: [String: Any] = ["test": tag, "steps": steps, "screens": screens]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "audit-report-" + tag; attachment.lifetime = .keepAlways; add(attachment)
        }
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private var map: XCUIElement { app.descendants(matching: .any).matching(identifier: "native-map").firstMatch }
    private func camera() -> [String: Any] {
        guard let data = app.staticTexts["map-camera-state"].label.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private func timing() -> [String: Any] {
        guard let data = app.staticTexts["journey-timing-state"].label.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    @discardableResult
    private func waitUntil(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
    private func settle(_ seconds: TimeInterval = 1.2) { Thread.sleep(forTimeInterval: seconds) }
    private func note(_ step: String, _ ok: Bool, _ detail: String = "") {
        steps.append(["step": step, "ok": ok, "detail": detail, "seconds": (Date().timeIntervalSince(began) * 10).rounded() / 10])
        print("AUDIT_STEP \(ok ? "ok" : "GAP") \(step) \(detail)")
    }
    private func starting(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }
    /// Taps a control as a rider would and records whether it could be reached.
    @discardableResult
    private func tap(_ element: XCUIElement, _ step: String, timeout: TimeInterval = 10) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { note(step, false, "not found"); return false }
        if element.isHittable { element.tap(); note(step, true); return true }
        let frame = element.frame, screen = app.frame
        guard frame.width > 0, screen.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            note(step, false, "exists but not on screen \(frame)"); return false
        }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        note(step, true, "not hittable; tapped its centre \(frame)")
        return true
    }
    private func back() {
        let bar = app.navigationBars.firstMatch
        if bar.exists, bar.buttons.firstMatch.exists { bar.buttons.firstMatch.tap() }
        settle(1)
    }
    private func dismissAlert(_ labels: [String]) {
        let alert = app.alerts.firstMatch
        guard alert.waitForExistence(timeout: 4) else { return }
        for label in labels where alert.buttons[label].exists { alert.buttons[label].tap(); return }
        alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
    }
    private static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "button"
        case .link: return "link"
        case .switch: return "switch"
        case .textField: return "textField"
        case .searchField: return "searchField"
        case .slider: return "slider"
        case .stepper: return "stepper"
        case .segmentedControl: return "segmentedControl"
        case .menuButton: return "menuButton"
        case .picker: return "picker"
        case .pageIndicator: return "pageIndicator"
        case .tab: return "tab"
        default: return "other(\(type.rawValue))"
        }
    }
    private static let controlTypes: Set<XCUIElement.ElementType> = [.button, .link, .switch, .textField, .searchField,
        .secureTextField, .slider, .stepper, .segmentedControl, .menuButton, .picker, .pageIndicator, .tab]

    /// Screenshot, element tree and measured control problems for one screen.
    private func review(_ screen: String) {
        settle(0.8)
        capture(screen)
        guard app.state == .runningForeground, let root = try? app.snapshot() else { return }
        let bounds = app.frame
        var controls: [(type: XCUIElement.ElementType, label: String, id: String, enabled: Bool, frame: CGRect)] = []
        var texts: [String] = []
        var bars: [CGRect] = []
        func walk(_ node: XCUIElementSnapshot) {
            let frame = node.frame
            if node.elementType == .navigationBar || node.elementType == .toolbar { bars.append(frame) }
            if frame.width >= 2, frame.height >= 2, frame.intersects(bounds) {
                if Self.controlTypes.contains(node.elementType) {
                    let label = node.label.isEmpty ? (node.placeholderValue ?? node.title) : node.label
                    controls.append((node.elementType, label, node.identifier, node.isEnabled, frame))
                } else if node.elementType == .staticText, !node.label.isEmpty, node.label.count < 400 {
                    texts.append(node.label)
                }
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        func describe(_ control: (type: XCUIElement.ElementType, label: String, id: String, enabled: Bool, frame: CGRect)) -> [String: Any] {
            let frame = control.frame
            return ["type": Self.typeName(control.type), "label": control.label, "id": control.id, "enabled": control.enabled,
                    "inBar": bars.contains { $0.intersects(frame) },
                    "frame": [Int(frame.minX.rounded()), Int(frame.minY.rounded()), Int(frame.width.rounded()), Int(frame.height.rounded())]]
        }
        let visible = controls.filter { bounds.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        let small = visible.filter { ($0.frame.width < 44 || $0.frame.height < 44) && $0.type != .textField && $0.type != .searchField }
        let symbolName = try! NSRegularExpression(pattern: "^[a-z0-9]+(\\.[a-z0-9]+)+$")
        let unlabeled = visible.filter { control in
            let label = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty || symbolName.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
        }
        let clipped = controls.filter { $0.frame.intersects(bounds) && ($0.frame.minX < bounds.minX - 1 || $0.frame.maxX > bounds.maxX + 1) }
        var overlaps: [[String: Any]] = []
        for i in visible.indices {
            for j in visible.indices where j > i {
                let a = visible[i].frame, b = visible[j].frame
                let shared = a.intersection(b)
                guard !shared.isNull, !a.contains(b), !b.contains(a) else { continue }
                let smaller = min(a.width * a.height, b.width * b.height)
                if smaller > 0, shared.width * shared.height > 0.2 * smaller {
                    overlaps.append(["a": describe(visible[i]), "b": describe(visible[j])])
                }
            }
        }
        let record: [String: Any] = ["screen": screen, "size": [Int(bounds.width), Int(bounds.height)],
            "controls": visible.count, "small": small.map(describe), "unlabeled": unlabeled.map(describe),
            "clipped": clipped.map(describe), "overlaps": overlaps, "texts": texts]
        screens.append(record)
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = screen + "-measures"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    // MARK: Home and map

    func test01HomeMapAndControls() {
        launch(["--test-map-controls"])
        settle(1.5); capture("audit-01a-first-seconds")
        let nearest = starting("nearby-station-")
        note("home: nearby stops appear", nearest.waitForExistence(timeout: 90), "after \(Int(Date().timeIntervalSince(began))) s")
        settle(3); review("audit-01b-home-ready")
        tap(button("map-location"), "location: first tap"); settle(2.5)
        review("audit-01c-location-first-tap")
        note("location mode after one tap", true, button("map-location").value as? String ?? "")
        tap(button("map-location"), "location: second tap"); settle(2.5)
        capture("audit-01d-location-second-tap")
        note("location mode after two taps", true, button("map-location").value as? String ?? "")
        tap(button("map-location"), "location: third tap"); settle(1.5)
        if tap(button("city-fleet-toggle"), "city fleet on") {
            settle(6); review("audit-01e-city-fleet")
            let hit = camera()
            if let x = hit["busHitX"] as? Double, let y = hit["busHitY"] as? Double {
                map.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
                note("tap a bus in the city view", true)
                settle(4); review("audit-01f-bus-selected")
                if tap(button("車輛資訊"), "bus details", timeout: 5) {
                    settle(2.5); review("audit-01g-bus-details")
                    tap(button("transit-details-close"), "close bus details", timeout: 5); settle(1.5)
                }
                tap(button("關閉選取"), "close the bus", timeout: 5); settle(3)
            } else { note("tap a bus in the city view", false, "no bus hit point") }
            tap(button("city-fleet-toggle"), "city fleet off"); settle(4)
        }
        map.pinch(withScale: 2.6, velocity: 1.5); settle(4)
        review("audit-01h-street-zoom-places")
        map.pinch(withScale: 0.2, velocity: -2); settle(4)
        capture("audit-01i-zoomed-out")
        tap(button("map-location"), "recentre"); settle(3)
        if tap(nearest, "nearby stop shortcut", timeout: 30) {
            settle(3.5); review("audit-01j-nearby-stop-on-map")
            if tap(button("map-station-expand"), "station label: expand", timeout: 8) {
                settle(1.5); review("audit-01k-station-label-expanded")
                if tap(button("map-station-details"), "station label: details", timeout: 5) {
                    settle(3); review("audit-01l-station-details-sheet")
                    tap(button("transit-details-close"), "close station details", timeout: 5); settle(1.5)
                }
            }
            tap(button("關閉選取"), "close the station", timeout: 5); settle(2)
            capture("audit-01m-after-closing-station")
        }
    }

    // MARK: Destination search, route choices and navigation (live data)

    func test02DestinationSearchCompareAndNavigate() {
        launch(["--test-journey-selection"])
        guard tap(button("home-destination-search"), "home: destination search", timeout: 60) else { return }
        settle(1.5); review("audit-02a-destination-search-empty")
        let field = app.textFields["journey-search-field"]
        guard tap(field, "destination field") else { return }
        field.typeText("內湖"); settle(3)
        review("audit-02b-typing-suggestions")
        field.typeText("站")
        let place = app.staticTexts["內湖站"].firstMatch
        guard place.waitForExistence(timeout: 25) else { note("suggestion 內湖站", false); capture("audit-02x-no-suggestion"); return }
        let searched = Date()
        place.tap()
        settle(1); capture("audit-02c-planning-in-progress")
        let ready = waitUntil(160) { (self.timing()["checking"] as? Bool) == false && self.firstOption.exists }
        note("route choices ready", ready, String(format: "%.1f s after choosing the place", Date().timeIntervalSince(searched)))
        settle(2); review("audit-02d-route-preview")
        if tap(button("journey-plan-more"), "more trip options menu", timeout: 5) {
            settle(1); review("audit-02e-more-menu")
            if tap(app.buttons["推薦順序說明"].firstMatch, "recommendation order explanation", timeout: 3) {
                settle(1); capture("audit-02f-ranking-explanation")
                dismissAlert(["知道了"])
            } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap() }
            settle(1)
        }
        let pages = app.descendants(matching: .any).matching(identifier: "journey-preview-pages").firstMatch
        if pages.exists {
            pages.swipeLeft(); settle(3); review("audit-02g-second-route-page")
            pages.swipeRight(); settle(2)
        }
        if tap(button("journey-all-options"), "all route choices", timeout: 5) {
            settle(2); review("audit-02h-all-choices")
            app.swipeUp(); settle(1.2); capture("audit-02i-all-choices-scrolled"); app.swipeDown(); settle(1)
        }
        let option = firstOption
        guard option.waitForExistence(timeout: 10) else { note("a route choice", false); return }
        let id = String(option.identifier.dropFirst("journey-option-".count))
        option.tap(); settle(2.5); capture("audit-02j-choice-on-map")
        guard tap(button("journey-steps-" + id), "steps of the chosen route", timeout: 15) else { return }
        settle(2); review("audit-02k-itinerary")
        app.swipeUp(); settle(1.2); review("audit-02l-itinerary-scrolled")
        if tap(button("journey-time-info"), "how times are estimated", timeout: 4) {
            settle(1.2); review("audit-02m-time-explanation")
            if !tap(button("journey-time-close"), "close time explanation", timeout: 3) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.2)).tap()
            }
            settle(1)
        }
        app.swipeDown(); settle(1)
        guard tap(button("journey-start-navigation"), "start navigation") else { return }
        settle(3.5); review("audit-02n-navigation-walking")
        if tap(button("journey-options"), "trip during navigation", timeout: 8) {
            settle(2); review("audit-02o-trip-during-navigation")
            tap(button("journey-back"), "back to the map", timeout: 5); settle(2)
        }
        if tap(button("journey-end"), "end the trip", timeout: 8) {
            settle(1.2); capture("audit-02p-end-confirmation")
            dismissAlert(["結束行程"])
            settle(2.5); capture("audit-02q-after-ending")
        }
    }

    // MARK: Stops

    func test03StopsSearchAndStationDetails() {
        launch()
        guard tap(button("站牌"), "home: stops button", timeout: 60) else { return }
        let result = starting("station-result-")
        note("nearby stop list", result.waitForExistence(timeout: 30))
        settle(2.5); review("audit-03a-nearby-stops")
        let field = app.textFields["transit-search-field"]
        if tap(field, "stop search field") {
            settle(1); review("audit-03b-stop-search-focused")
            field.typeText("市政府"); settle(3)
            review("audit-03c-stop-search-results")
            if tap(button("station-results-map"), "show results on the map", timeout: 4) { settle(3); review("audit-03d-stop-results-on-map") }
        }
        guard tap(result, "first stop result", timeout: 15) else { return }
        settle(3.5); review("audit-03e-station-details")
        let close = button("transit-details-close")
        if close.waitForExistence(timeout: 5) {
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: app.frame.width / 2, dy: close.frame.minY - 24))
                .press(forDuration: 0.15, thenDragTo: origin.withOffset(CGVector(dx: app.frame.width / 2, dy: 100)))
            settle(1.5); review("audit-03f-station-details-full")
        }
        if tap(button("收藏站牌"), "favourite the stop", timeout: 4) { settle(1); capture("audit-03g-favourited") }
        let route = starting("station-route-")
        guard tap(route, "a route at this stop", timeout: 15) else { return }
        settle(3.5); review("audit-03h-route-at-the-stop")
        app.swipeUp(); settle(1.2); capture("audit-03i-route-at-the-stop-scrolled")
        if tap(starting("route-approaching-"), "an approaching bus", timeout: 6) {
            settle(4); review("audit-03j-following-a-bus")
            tap(button("返回路線"), "back to the route", timeout: 5); settle(2)
        }
        tap(close, "close details", timeout: 5); settle(3)
        review("audit-03k-route-on-the-map")
        tap(button("關閉選取"), "leave the route", timeout: 5); settle(1)
        tap(button("返回站牌"), "back to the stop", timeout: 3); settle(1)
    }

    // MARK: Routes

    func test04RouteKeypadAndRouteMap() {
        launch()
        guard tap(button("路線"), "home: routes button", timeout: 60) else { return }
        note("route keypad", button("route-key-3").waitForExistence(timeout: 90))
        settle(1); review("audit-04a-route-keypad")
        for key in ["3", "0", "7"] { tap(button("route-key-" + key), "key " + key, timeout: 5) }
        settle(1.5); review("audit-04b-route-results")
        let route = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "route-result-", "307")).firstMatch
        guard tap(route, "route 307") else { return }
        settle(4.5); review("audit-04c-route-details")
        if tap(button("route-boarding-selector"), "choose the boarding stop", timeout: 5) {
            settle(1.2); capture("audit-04d-boarding-stop-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap(); settle(1)
        }
        app.swipeUp(); settle(1.2); review("audit-04e-route-details-scrolled")
        tap(button("transit-details-close"), "close route details", timeout: 5); settle(3.5)
        review("audit-04f-route-on-the-map")
        if tap(button("切換路線方向"), "switch direction", timeout: 4) { settle(3); review("audit-04g-other-direction") }
        if tap(button("route-map-vehicles"), "buses on this route", timeout: 4) {
            settle(2.5); review("audit-04h-route-buses")
            tap(button("transit-details-close"), "close buses", timeout: 5); settle(2)
        }
        tap(button("關閉選取"), "leave the route", timeout: 5); settle(2)
        guard tap(button("路線"), "routes again", timeout: 10) else { return }
        settle(1.5); review("audit-04i-route-history")
        if tap(button("route-text-keyboard"), "type a route name", timeout: 5) {
            let field = app.textFields["transit-search-field"]
            if field.waitForExistence(timeout: 5) { field.typeText("南京"); settle(2.5); review("audit-04j-route-text-search") }
        }
    }

    // MARK: Riding: waiting, boarding, onboard and arrival (fixture vehicles)

    func test05WaitingBoardingAndArrival() {
        launch(["--preview-boarding-fixture", "--usability-fixture"])
        guard button("journey-board").waitForExistence(timeout: 90) else { note("waiting screen", false); return }
        settle(2); review("audit-05a-waiting-for-the-bus")
        if tap(button("boarding-vehicle-TEST-02"), "track the second bus") { settle(2.5); review("audit-05b-tracking-a-bus") }
        if tap(button("journey-all-vehicles"), "all arriving buses") {
            settle(1.5); review("audit-05c-all-arriving-buses")
            tap(button("journey-vehicles-done"), "close arriving buses", timeout: 5); settle(1)
        }
        if tap(button("journey-options"), "trip while waiting") {
            settle(2); review("audit-05d-trip-while-waiting")
            tap(button("返回地圖"), "back to map", timeout: 5); settle(1.5)
        }
        if tap(button("journey-walk-to-stop"), "walk to the stop", timeout: 5) { settle(3); review("audit-05e-walk-to-the-stop") }
        guard tap(button("journey-board"), "on board") else { return }
        settle(2.5); review("audit-05f-on-board")
        if tap(button("journey-onboard-vehicle"), "which bus am I on", timeout: 5) {
            settle(1.5); review("audit-05g-choose-my-bus")
            if !tap(starting("onboard-choose-"), "choose a plate", timeout: 4) { back() }
            settle(1.5)
        }
        if tap(button("journey-ride-stops"), "stops along the ride") {
            settle(2); review("audit-05h-stops-along-the-ride")
            tap(button("journey-stops-done"), "close stops", timeout: 5); settle(1)
        }
        guard tap(button("journey-alight"), "got off") else { return }
        settle(2.5); review("audit-05i-last-walk")
        guard tap(button("journey-arrive"), "arrived") else { return }
        settle(2); review("audit-05j-arrived")
        tap(button("完成"), "finish", timeout: 5); settle(2)
        capture("audit-05k-home-after-trip")
    }

    func test06TransferAndMetro() {
        launch(["--preview-boarding-fixture", "--preview-transfer-fixture", "--usability-fixture"])
        if button("journey-board").waitForExistence(timeout: 90) {
            settle(2); review("audit-06a-transfer-first-bus")
            Thread.sleep(forTimeInterval: 1)
            button("journey-board").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if tap(button("journey-alight"), "got off the first bus") {
                settle(2.5); review("audit-06b-transfer-second-bus")
            }
        } else { note("transfer waiting screen", false) }
        app.terminate()
        launch(["--preview-metro-fixture", "--usability-fixture"])
        guard button("journey-board").waitForExistence(timeout: 100) else { note("metro waiting screen", false); return }
        settle(2.5); review("audit-06c-metro-waiting")
        if tap(button("live-trains-trial"), "live trains trial chip", timeout: 4) { settle(3); review("audit-06d-live-trains") }
        Thread.sleep(forTimeInterval: 1)
        button("journey-board").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if button("journey-alight").waitForExistence(timeout: 10) {
            settle(2.5); review("audit-06e-metro-on-board")
            button("journey-alight").tap(); settle(2.5); review("audit-06f-metro-exit")
        } else { note("metro on board", false) }
    }

    // MARK: Mixed choices and YouBike (fixtures)

    func test07MixedChoicesAndYouBike() {
        launch(["--preview-mixed-planning", "--usability-fixture", "--test-journey-selection"])
        if button("journey-all-options").waitForExistence(timeout: 120) {
            settle(2.5); review("audit-07a-mixed-preview")
            let selected = timing()["selected"] as? String ?? ""
            let compare = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (identifier ENDSWITH %@)", "journey-compare-", selected)).firstMatch
            if tap(compare, "compare another choice", timeout: 4) { settle(2.5); review("audit-07b-compared-choice") }
            if tap(button("journey-all-options"), "all mixed choices") {
                settle(2); review("audit-07c-mixed-choices")
                app.swipeUp(); settle(1); capture("audit-07d-mixed-choices-scrolled")
            }
        } else { note("mixed choices", false) }
        app.terminate()
        launch(["--preview-youbike-planning", "--usability-fixture", "--test-journey-selection"])
        guard tap(button("journey-all-options"), "YouBike choices", timeout: 120) else { return }
        settle(2); review("audit-07e-youbike-choices")
        let option = firstOption
        guard option.waitForExistence(timeout: 20) else { return }
        let id = String(option.identifier.dropFirst("journey-option-".count))
        option.tap(); settle(2)
        guard tap(button("journey-steps-" + id), "YouBike steps", timeout: 20) else { return }
        settle(2); review("audit-07f-youbike-steps")
        if tap(button("journey-bike-pickup-0"), "pickup station", timeout: 6) {
            settle(2.5); review("audit-07g-youbike-station-card")
            tap(button("bike-station-close"), "close station card", timeout: 5); settle(1.5)
        }
        if tap(button("journey-in-app-bike-0"), "ride on the map", timeout: 6) { settle(3.5); review("audit-07h-youbike-on-the-map") }
    }

    // MARK: Settings, Pro and information

    func test08SettingsProAndInformation() {
        launch()
        guard tap(button("資料來源與地圖設定"), "map: settings button", timeout: 60) else { return }
        _ = app.navigationBars["資訊與設定"].waitForExistence(timeout: 10)
        settle(1.5); review("audit-08a-settings")
        app.swipeUp(); settle(1); review("audit-08b-settings-bottom"); app.swipeDown(); settle(1)
        let pages = [("settings-pro", "pro"), ("settings-map", "map"), ("settings-fares", "fares"), ("settings-commute", "commute"),
                     ("official-service-notices", "notices"), ("settings-sources", "sources"), ("settings-privacy", "privacy")]
        for (index, page) in pages.enumerated() {
            let link = button(page.0)
            for _ in 0..<3 where link.exists && !link.isHittable { app.swipeUp(); settle(0.5) }
            guard tap(link, "settings: " + page.1) else { continue }
            settle(page.1 == "notices" ? 7 : 2)
            review("audit-08c\(index)-\(page.1)")
            switch page.1 {
            case "pro":
                if tap(button("pro-open-plans"), "Pro plans", timeout: 5) {
                    settle(5); review("audit-08d-pro-plans")
                    app.swipeUp(); settle(1.2); review("audit-08e-pro-plans-scrolled")
                    if !tap(button("pro-close"), "close Pro plans", timeout: 5) { app.swipeDown(velocity: .fast) }
                    settle(1.5)
                }
            case "fares":
                if tap(button("fare-class-picker"), "ticket type", timeout: 4) {
                    settle(1.2); capture("audit-08f-ticket-type-menu")
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap(); settle(1)
                }
            case "notices":
                let first = app.cells.firstMatch
                if first.exists, first.isHittable {
                    first.tap(); settle(4); review("audit-08g-notice-detail")
                    app.swipeUp(); settle(1); capture("audit-08h-notice-detail-scrolled")
                    back()
                }
            case "sources":
                app.swipeUp(); settle(1); capture("audit-08i-sources-scrolled")
            default: break
            }
            back(); settle(0.8)
        }
        let english = app.switches["app-language-toggle"]
        for _ in 0..<3 where english.exists && !english.isHittable { app.swipeDown(); settle(0.5) }
        if english.waitForExistence(timeout: 5) {
            english.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap(); settle(2)
            review("audit-08j-settings-in-english")
            english.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap(); settle(2)
            note("language switched back", true, english.value as? String ?? "")
        }
        let done = app.navigationBars.buttons["完成"].exists ? app.navigationBars.buttons["完成"] : app.navigationBars.buttons["Done"]
        tap(done, "close settings", timeout: 5); settle(1.5)
    }

    // MARK: English interface

    func test09EnglishInterface() {
        launch(["--test-language", "en"])
        let nearest = starting("nearby-station-")
        _ = nearest.waitForExistence(timeout: 90)
        settle(3); review("audit-09a-home-english")
        if tap(button("Stops"), "Stops", timeout: 10) {
            settle(3); review("audit-09b-stops-english")
            if tap(starting("station-result-"), "first stop", timeout: 15) { settle(3.5); review("audit-09c-station-english") }
            tap(button("transit-details-close"), "close", timeout: 5); settle(1.5)
            tap(button("Close selection"), "close the stop", timeout: 4); settle(1.5)
        }
        if tap(button("Routes"), "Routes", timeout: 10) {
            _ = button("route-key-3").waitForExistence(timeout: 30)
            for key in ["3", "0", "7"] { tap(button("route-key-" + key), "key " + key, timeout: 5) }
            let route = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "route-result-", "307")).firstMatch
            if tap(route, "route 307") { settle(4.5); review("audit-09d-route-english") }
            tap(button("transit-details-close"), "close", timeout: 5); settle(2)
            tap(button("Close selection"), "leave the route", timeout: 4); settle(1.5)
        }
        app.terminate()
        launch(["--test-language", "en", "--preview-boarding-fixture", "--usability-fixture"])
        guard button("journey-board").waitForExistence(timeout: 90) else { return }
        settle(2); review("audit-09e-waiting-english")
        Thread.sleep(forTimeInterval: 1)
        button("journey-board").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if button("journey-alight").waitForExistence(timeout: 10) { settle(2); review("audit-09f-on-board-english") }
    }

    // MARK: Accessibility text size

    func test10LargestAccessibilityText() {
        let size = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        launch(size)
        _ = starting("nearby-station-").waitForExistence(timeout: 90)
        settle(3); review("audit-10a-home-large-text")
        if tap(button("home-destination-search"), "destination search", timeout: 10) {
            settle(2); review("audit-10b-search-large-text")
            if !tap(button("journey-back"), "cancel search", timeout: 3) { app.swipeDown(velocity: .fast) }
            settle(1.5)
        }
        if tap(button("站牌"), "stops", timeout: 10) {
            settle(3); review("audit-10c-stops-large-text")
            if tap(starting("station-result-"), "first stop", timeout: 15) { settle(3.5); review("audit-10d-station-large-text") }
            tap(button("transit-details-close"), "close", timeout: 5); settle(1.5)
            tap(button("關閉選取"), "close the stop", timeout: 4); settle(1.5)
        }
        if tap(button("資料來源與地圖設定"), "settings", timeout: 10) {
            settle(2); review("audit-10e-settings-large-text")
            tap(app.navigationBars.buttons["完成"], "close settings", timeout: 5); settle(1)
        }
        app.terminate()
        launch(["--preview-boarding-fixture", "--usability-fixture"] + size)
        guard button("journey-board").waitForExistence(timeout: 90) else { return }
        settle(2); review("audit-10f-waiting-large-text")
        app.swipeUp(); settle(1); capture("audit-10g-waiting-large-text-scrolled")
        Thread.sleep(forTimeInterval: 1)
        button("journey-board").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if button("journey-alight").waitForExistence(timeout: 10) { settle(2); review("audit-10h-on-board-large-text") }
    }

    // MARK: Map taps: stops, YouBike and places

    func test11MapTaps() {
        launch(["--test-map-controls"])
        _ = starting("nearby-station-").waitForExistence(timeout: 90)
        map.pinch(withScale: 2.2, velocity: 1.5)
        let settled = waitUntil(30) { (self.camera()["cameraMoving"] as? Bool) == false && (self.camera()["markerID"] as? String) != nil }
        note("a stop marker on screen", settled)
        if settled {
            let marker = camera()
            map.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: marker["markerX"] as? Double ?? 0, dy: marker["markerY"] as? Double ?? 0)).tap()
            settle(3); review("audit-11a-tapped-stop-marker")
            tap(button("關閉選取"), "close the stop", timeout: 5); settle(2.5)
        }
        let bikes = waitUntil(20) { !(self.camera()["visibleBikePins"] as? [[String: Any]] ?? []).isEmpty }
        note("YouBike pins at street scale", bikes)
        if bikes {
            let card = app.descendants(matching: .any).matching(identifier: "bike-station-card").firstMatch
            for pin in camera()["visibleBikePins"] as? [[String: Any]] ?? [] {
                guard let x = pin["x"] as? Double, let y = pin["y"] as? Double,
                      x > 25, x < map.frame.width - 80, y > 110, y < map.frame.height - 210 else { continue }
                map.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
                if card.waitForExistence(timeout: 4) { break }
            }
            if card.exists {
                settle(1.5); review("audit-11b-youbike-station")
                tap(button("bike-station-close"), "close YouBike station", timeout: 5); settle(1.5)
            } else { note("open a YouBike station", false) }
        }
        // Places: tap labelled points of interest until a place card opens.
        let placeCard = app.descendants(matching: .any).matching(identifier: "place-card").firstMatch
        for point in [CGVector(dx: 0.3, dy: 0.35), CGVector(dx: 0.65, dy: 0.42), CGVector(dx: 0.4, dy: 0.55), CGVector(dx: 0.7, dy: 0.3)] {
            app.coordinate(withNormalizedOffset: point).tap()
            if placeCard.waitForExistence(timeout: 2.5) { break }
            if button("關閉選取").exists { button("關閉選取").tap(); settle(1.5) }
        }
        if placeCard.exists {
            settle(1); review("audit-11c-place-card")
            if tap(button("place-card-route"), "route to the place", timeout: 4) { settle(6); review("audit-11d-route-to-place") }
        } else { note("open a place card", false, "no labelled place under the probed points") }
    }

    // MARK: No location permission (runs last; resets the location permission)

    func test99WithoutLocationPermission() {
        app.resetAuthorizationStatus(for: .location)
        launch()
        settle(6); review("audit-99a-home-before-asking")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        tap(button("map-location"), "location button without permission", timeout: 20)
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 8) {
            settle(1); capture("audit-99b-location-permission-prompt")
            note("permission prompt text", true, alert.label)
            let deny = alert.buttons.matching(NSPredicate(format: "label IN %@", ["不允許", "Don’t Allow", "Don't Allow"])).firstMatch
            if deny.exists { deny.tap() } else { alert.buttons.element(boundBy: alert.buttons.count - 1).tap() }
        } else { note("permission prompt", false) }
        settle(3); review("audit-99c-home-location-denied")
        tap(button("map-location"), "location button after denial", timeout: 10); settle(2.5)
        review("audit-99d-location-tap-after-denial")
        if tap(button("home-destination-search"), "destination search without location", timeout: 10) {
            settle(2.5); review("audit-99e-search-without-location")
        }
    }
}
