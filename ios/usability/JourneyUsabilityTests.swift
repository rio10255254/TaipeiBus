import XCTest

final class JourneyUsabilityTests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus")
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ args: [String] = []) {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"] + args
        app.launch()
    }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-elements"; tree.lifetime = .keepAlways; add(tree)
    }
    func testWaitingAndTrackingBaseline() throws {
        launch(["--preview-boarding-fixture"])
        let second = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "TEST-02")).firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 90), "A real waiting screen must load")
        capture("baseline-waiting")
        second.tap()
        XCTAssertTrue((second.value as? String)?.contains("追蹤中") == true)
        capture("baseline-track-second")
        app.buttons["方案"].firstMatch.tap()
        capture("baseline-options")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertFalse(app.buttons["已上車"].exists, "Record the missing boarding action in the current UI")
        capture("baseline-back-to-waiting")
        app.buttons["結束查詢"].firstMatch.tap()
        XCTAssertTrue(app.buttons["搜尋目的地"].waitForExistence(timeout: 5))
    }
    func testDestinationSearchBaseline() throws {
        launch()
        let entry = app.buttons["搜尋目的地"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let field = app.textFields["地點、地址或站名"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("內湖站")
        XCTAssertTrue(app.staticTexts["內湖站"].firstMatch.waitForExistence(timeout: 15))
        capture("baseline-search-neihu-keyboard")
        app.staticTexts["內湖站"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["搭車方案"].waitForExistence(timeout: 20))
        capture("baseline-first-options")
    }
}
