import XCTest

final class AIUITests: XCTestCase {
    func testSimulatorCameraFallbackReturnsToManualPlateSelection() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
        app.launchArguments = ["--test-language", "zh-Hant", "--preview-boarding-fixture", "--usability-fixture"]
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
            "--preview-journey-search", "--usability-fixture", "--test-ai-unavailable"]
        app.launch()
        let assistant = app.buttons["journey-ai-assistant"]
        XCTAssertTrue(assistant.waitForExistence(timeout: 60))
        assistant.tap()
        XCTAssertTrue(app.staticTexts["ai-unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["ai-extract"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "AI unavailable fallback"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["ai-manual-search"].tap()
        XCTAssertTrue(app.textFields["journey-search-field"].waitForExistence(timeout: 10))
    }
}
