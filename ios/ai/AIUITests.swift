import XCTest

final class AIUITests: XCTestCase {
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
