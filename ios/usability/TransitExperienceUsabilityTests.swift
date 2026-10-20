import XCTest

final class TransitExperienceUsabilityTests: JourneyUsabilityTestBase {
    private var viewport: CGRect { app.windows.firstMatch.frame }
    private func state() -> [String: Any] {
        let element = app.staticTexts["journey-timing-state"]
        guard element.exists, let data = element.label.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private func camera() -> [String: Any] {
        guard let data = app.staticTexts["map-camera-state"].label.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private func waitFor(_ description: String, _ condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 25), .completed, description + ": \(state())")
    }
    private func tapSettled(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        print("TOUCH_BOUNDS target=\(element.frame) application=\(app.frame) window=\(viewport)")
        var prior = CGRect.zero, since = Date()
        waitFor("The visible action has finished its sheet transition") {
            let frame = element.frame
            guard frame.width >= 20, frame.height >= 20, element.isEnabled,
                  self.viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) else { since = Date(); return false }
            if abs(frame.midX - prior.midX) > 1 || abs(frame.midY - prior.midY) > 1 { prior = frame; since = Date(); return false }
            return Date().timeIntervalSince(since) >= 0.6
        }
        if element.isHittable { element.tap() }
        else {
            let frame = element.frame, window = viewport
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX-window.minX, dy: frame.midY-window.minY)).tap()
        }
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists, viewport.insetBy(dx: 8, dy: 60).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) { return }
            app.scrollViews.firstMatch.swipeUp()
        }
    }
    private func comparison(_ english: Bool) {
        launch(["--preview-mixed-planning", "--usability-fixture", "--test-journey-selection", "--test-map-controls"] + (english ? ["--test-language", "en"] : []))
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout: 120))
        let options = state()["options"] as? [[String: Any]] ?? []
        XCTAssertEqual(options.count, 3)
        let original = state()["selected"] as? String ?? ""
        let alternative = options.first { $0["id"] as? String != original }?["id"] as? String ?? ""
        let compare = button("journey-compare-" + alternative)
        XCTAssertTrue(compare.isHittable, "A meaningful alternative is visible without paging or opening a list")
        XCTAssertGreaterThanOrEqual(compare.frame.height, 44)
        XCTAssertTrue(button("journey-go-" + original).isHittable)
        capture("experience-\(english ? "en" : "zh")-comparison")
        tapSettled(compare)
        waitFor("Tapping an alternative only previews that exact trip") {
            self.state()["selected"] as? String == alternative && self.state()["started"] as? Bool == false
        }
        tapSettled(button("journey-steps-" + alternative))
        XCTAssertTrue(button("journey-start-navigation").waitForExistence(timeout: 15))
        XCTAssertEqual(state()["started"] as? Bool, false)
        tapSettled(button("journey-time-info"))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "journey-time-component-transit").firstMatch.waitForExistence(timeout: 10))
        capture("experience-\(english ? "en" : "zh")-time-explanation")
        tapSettled(button("journey-time-close"))
        tapSettled(button("journey-back"))
        XCTAssertTrue(button("journey-go-" + alternative).waitForExistence(timeout: 10))
        XCTAssertEqual(state()["selected"] as? String, alternative)
        XCTAssertEqual(state()["started"] as? Bool, false)
        capture("experience-\(english ? "en" : "zh")-returned")
        tapSettled(button("journey-go-" + alternative))
        waitFor("Only Go starts the currently shown trip") { self.state()["started"] as? Bool == true }
        XCTAssertEqual(state()["selected"] as? String, alternative)
    }
    func testChineseComparisonAndTimingKeepPreviewSeparateFromNavigation() { comparison(false) }
    func testEnglishComparisonAndTimingKeepPreviewSeparateFromNavigation() { comparison(true) }
    func testAccessibilityTextAndReducedMotionKeepPrimaryActionsReadable() {
        launch(["--preview-mixed-planning", "--usability-fixture", "--test-journey-selection", "--test-map-controls",
                "--test-language", "en", "--test-accessibility-text", "--test-reduce-motion"])
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout: 120))
        let selected = state()["selected"] as? String ?? ""
        capture("experience-accessibility-top")
        let time = app.staticTexts.matching(NSPredicate(format: "identifier == %@", "journey-preview-duration-" + selected)).firstMatch
        XCTAssertGreaterThan(time.frame.height, 32, "Accessibility text must propagate into the presented route sheet")
        let steps = button("journey-steps-" + selected), go = button("journey-go-" + selected)
        reveal(go)
        XCTAssertGreaterThanOrEqual(go.frame.height, 44)
        XCTAssertGreaterThanOrEqual(steps.frame.height, 44)
        XCTAssertEqual(state()["selected"] as? String, selected)
        XCTAssertEqual(state()["started"] as? Bool, false)
        capture("experience-accessibility-actions")
        tapSettled(steps)
        XCTAssertTrue(button("journey-start-navigation").waitForExistence(timeout: 15))
        let destination = app.staticTexts["journey-destination-title"]
        waitFor("The details open at their destination summary, even after scrolling the preview") {
            destination.exists && destination.frame.minY >= self.app.navigationBars.firstMatch.frame.maxY - 1 &&
                destination.frame.maxY < self.viewport.minY + self.viewport.height * 0.65
        }
        capture("experience-accessibility-steps")
        tapSettled(button("journey-back"))
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout: 15))
        XCTAssertEqual(state()["selected"] as? String, selected)
        XCTAssertEqual(state()["started"] as? Bool, false)
    }
    func testCompactViewportKeepsMapAndRouteActionsUsable() {
        launch(["--preview-mixed-planning", "--usability-fixture", "--test-journey-selection", "--test-map-controls"])
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout: 120))
        let selected = state()["selected"] as? String ?? ""
        let go = button("journey-go-" + selected)
        reveal(go)
        XCTAssertGreaterThanOrEqual(go.frame.height, 44)
        let options = state()["options"] as? [[String: Any]] ?? []
        let other = options.first { $0["id"] as? String != selected }?["id"] as? String ?? ""
        let compare = button("journey-compare-" + other)
        reveal(compare); capture("experience-compact-viewport")
        tapSettled(compare)
        waitFor("An alternative remains a preview on a compact display") {
            self.state()["selected"] as? String == other && self.state()["started"] as? Bool == false
        }
        waitFor("The newly selected route fills the settled, unobstructed map on a compact display") {
            let value = self.camera()
            guard value["cameraMoving"] as? Bool == false,
                  let viewport = value["routeViewport"] as? [String: Any],
                  let framing = value["routeFraming"] as? [String: Any] else { return false }
            return (viewport["height"] as? Double ?? 0) > 80 && framing["inside"] as? Bool == true &&
                max(framing["heightUsage"] as? Double ?? 0, framing["widthUsage"] as? Double ?? 0) > 0.72
        }
        capture("experience-compact-alternative")
    }
}
