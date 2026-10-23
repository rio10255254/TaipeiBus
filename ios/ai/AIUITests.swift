import XCTest

final class AIUITests: XCTestCase {
    func testSimulatorCameraFallbackReturnsToManualPlateSelection() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "--test-language", "zh-Hant",
            "--preview-boarding-fixture", "--usability-fixture", "--test-ai-ui"]
        app.launch()
        XCTAssertTrue(app.buttons["journey-board"].waitForExistence(timeout: 90))
        app.buttons["journey-board"].tap()
        XCTAssertTrue(app.buttons["journey-onboard-vehicle"].waitForExistence(timeout: 10))
        app.buttons["journey-onboard-vehicle"].tap()
        XCTAssertTrue(app.buttons["boarding-scan-plate"].waitForExistence(timeout: 10))
        app.buttons["boarding-scan-plate"].tap()
        XCTAssertTrue(app.buttons["plate-manual-fallback"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Camera unavailable fallback"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["plate-manual-fallback"].tap()
        XCTAssertTrue(app.buttons["onboard-choose-TEST-03"].waitForExistence(timeout: 10))
        app.buttons["onboard-choose-TEST-03"].tap()
        XCTAssertTrue(app.buttons["journey-onboard-vehicle"].label.contains("TEST-03"))
    }
    func testUnavailableModelPreservesManualSearch() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "--test-language", "zh-Hant",
            "--usability-fixture", "--test-ai-ui", "--test-ai-unavailable"]
        app.launch()
        XCTAssertTrue(app.buttons["home-destination-search"].waitForExistence(timeout: 60))
        app.buttons["home-destination-search"].tap()
        XCTAssertTrue(app.textFields["journey-search-field"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["journey-ai-assistant"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Unavailable model hides assistant entry"; shot.lifetime = .keepAlways; add(shot)
    }
    func testChoiceThenPlansRightAway() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "--test-language", "zh-Hant",
            "--usability-fixture", "--test-ai-ui", "--test-ai-review"]
        app.launch()
        XCTAssertTrue(app.buttons["home-destination-search"].waitForExistence(timeout: 60))
        app.buttons["home-destination-search"].tap()
        XCTAssertTrue(app.buttons["journey-ai-assistant"].waitForExistence(timeout: 60))
        app.buttons["journey-ai-assistant"].tap()
        let input = app.textFields["ai-request"].exists ? app.textFields["ai-request"] : app.textViews["ai-request"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("回家")
        app.buttons["ai-extract"].tap()
        XCTAssertTrue(app.buttons["ai-choice-0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["ai-choice-2"].exists)
        XCTAssertFalse(app.buttons["ai-choice-3"].exists)
        app.buttons["ai-choice-0"].tap()
        // Once the choice resolves the trip, planning starts without another confirmation screen.
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 15), .completed)
    }

    func testTesterBenchmarkPageOpensFromSettingsWithoutRunningOnSimulator() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "--test-language", "zh-Hant",
            "--usability-fixture", "--test-ai-ui", "--test-ai-unavailable"]
        app.launch()
        let settings = app.buttons["map"]
        XCTAssertTrue(settings.waitForExistence(timeout: 60)); settings.tap()
        XCTAssertTrue(app.buttons["settings-pro"].waitForExistence(timeout: 15))
        let entry = app.buttons["settings-ai-benchmark"]
        for _ in 0..<10 where !(entry.exists && entry.isHittable) { app.swipeUp() }
        XCTAssertTrue(entry.isHittable); entry.tap()
        let start = app.buttons["ai-benchmark-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        // The corpus is bundled (the button only appears once it loads), but there is no model to run.
        XCTAssertFalse(start.isEnabled)
    }

}
