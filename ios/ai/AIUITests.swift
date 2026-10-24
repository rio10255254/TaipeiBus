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
    func testWithoutTheModelOneSentenceStillWorks() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "--test-language", "zh-Hant",
            "--usability-fixture", "--test-ai-ui", "--test-ai-unavailable"]
        app.launch()
        XCTAssertTrue(app.buttons["home-destination-search"].waitForExistence(timeout: 60))
        app.buttons["home-destination-search"].tap()
        XCTAssertTrue(app.textFields["journey-search-field"].waitForExistence(timeout: 60))
        // Without Apple Intelligence the rules still read Chinese sentences, so the entry stays.
        XCTAssertTrue(app.buttons["journey-ai-assistant"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["journey-voice"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Without the model the sentence entry stays"; shot.lifetime = .keepAlways; add(shot)
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

    func testSentenceInTheOrdinarySearchBoxIsUnderstood() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "--test-language", "zh-Hant",
            "--usability-fixture", "--test-ai-ui", "--test-ai-review"]
        app.launch()
        XCTAssertTrue(app.buttons["home-destination-search"].waitForExistence(timeout: 60))
        app.buttons["home-destination-search"].tap()
        let field = app.textFields["journey-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["journey-voice"].exists, "One tap to speak from the search box")
        field.tap(); field.typeText("回家")
        XCTAssertTrue(app.buttons["journey-understand-sentence"].waitForExistence(timeout: 5))
        field.typeText("\n")
        // Return on a sentence opens the assistant, which starts understanding without another tap.
        XCTAssertTrue(app.buttons["ai-choice-0"].waitForExistence(timeout: 15))
    }


    func testHomeMicAsksInItsOwnWordsThenTypingTakesOver() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "--test-language", "zh-Hant",
            "--usability-fixture", "--test-ai-ui", "--test-ai-review"]
        app.launch()
        let mic = app.buttons["home-voice"]
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "The mic is on the home screen")
        XCTAssertTrue(mic.isHittable)
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        home.name = "Home mic"; home.lifetime = .keepAlways; add(home)
        mic.tap()
        // A fresh simulator has never been asked: the app explains first, before any system prompt.
        XCTAssertTrue(app.buttons["voice-allow"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["voice-close"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "The voice screen replaces the keyboard")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Edge glow asks for the microphone"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["voice-type"].tap()
        // The route panel opens with the typing sheet (a text field or a text view).
        let input = app.descendants(matching: .any).matching(identifier: "ai-request").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["voice-allow"].exists)
    }
    func testSearchVoiceCardOpensAndClosesTheFullScreenStyle() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
        // Settings › 語音助理樣式 › 全螢幕; the home mic test covers the default edge glow.
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "--test-language", "zh-Hant",
            "--usability-fixture", "--test-ai-ui", "--test-ai-review", "-voiceStyle.v1", "fullScreen"]
        app.launch()
        XCTAssertTrue(app.buttons["home-destination-search"].waitForExistence(timeout: 60))
        app.buttons["home-destination-search"].tap()
        let card = app.buttons["journey-voice"]
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        let close = app.buttons["voice-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertFalse(app.keyboards.firstMatch.exists, "The voice screen replaces the keyboard")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Full-screen voice style"; shot.lifetime = .keepAlways; add(shot)
        close.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        XCTAssertTrue(app.textFields["journey-search-field"].exists, "Closing returns to the search screen")
    }

}
