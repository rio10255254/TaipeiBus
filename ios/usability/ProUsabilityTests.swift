import XCTest
import StoreKitTest

final class ProUsabilityTests: JourneyUsabilityTestBase {
    private var session: SKTestSession!
    override func setUpWithError() throws {
        try super.setUpWithError()
        let file = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"ProProducts",withExtension:"storekit"))
        session = try SKTestSession(contentsOf:file)
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        session.storefront = "TWN"; session.locale = Locale(identifier:"zh_TW"); session.timeRate = .realTime
    }
    override func tearDownWithError() throws { try super.tearDownWithError(); session.clearTransactions(); session = nil }
    private func tapVisible(_ id: String) {
        let item = button(id)
        for _ in 0..<5 { if item.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(item.isHittable,id); item.tap()
    }
    private func openPlans(english: Bool = false) {
        launch(english ? ["--test-language","en"] : [])
        let settings = english ? button("Information and settings") : button("資料來源與地圖設定")
        XCTAssertTrue(settings.waitForExistence(timeout:25))
        settings.tap(); XCTAssertTrue(button("settings-pro").waitForExistence(timeout:10)); button("settings-pro").tap()
        XCTAssertTrue(button("pro-open-plans").waitForExistence(timeout:10)); button("pro-open-plans").tap()
        XCTAssertTrue(button("pro-plan-monthly").waitForExistence(timeout:15))
    }
    func testTrialPricesAndExitKeepTheFreeAppAvailable() {
        openPlans()
        XCTAssertTrue(app.staticTexts["先免費試用 7 天"].firstMatch.waitForExistence(timeout:20))
        button("pro-plan-monthly").tap()
        capture("pro-monthly-seven-day-trial")
        button("pro-plan-yearly").tap()
        XCTAssertTrue(button("pro-purchase").label.contains("7")); XCTAssertTrue(app.staticTexts["pro-trial-terms"].label.contains("290"))
        capture("pro-annual-seven-day-trial")
        XCTAssertTrue(button("pro-restore").exists); XCTAssertTrue(button("pro-manage").exists)
        button("pro-close").tap()
        app.swipeDown()
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout:5) { back.tap() }
        let done = button("完成"); if done.exists { done.tap() }
        XCTAssertTrue(button("home-destination-search").waitForExistence(timeout:10))
        XCTAssertTrue(app.descendants(matching:.any).matching(identifier:"native-map").firstMatch.exists)
        capture("pro-dismiss-keeps-free-map")
    }
    func testActualTrialUnlocksSavedJourneyAndPreviewDoesNotStartNavigation() {
        openPlans(); tapVisible("pro-purchase")
        XCTAssertTrue(app.staticTexts["正在免費試用 Pro"].waitForExistence(timeout:20))
        capture("pro-active-trial")
        button("pro-close").tap()
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout:5) { back.tap() }
        if button("完成").exists { button("完成").tap() }
        button("home-destination-search").tap(); chooseNeihu()
        let more = button("journey-plan-more")
        XCTAssertTrue(more.waitForExistence(timeout:30)); more.tap()
        let saveAction = button("journey-save-pro")
        XCTAssertTrue(saveAction.waitForExistence(timeout:10))
        // The system menu reports an invalid activation point while presented
        // above a detented sheet. Use the visible row's actual centre.
        saveAction.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        capture("pro-save-action-selected")
        let title = app.textFields["commute-title"]
        XCTAssertTrue(title.waitForExistence(timeout:10)); title.tap()
        if let text = title.value as? String { title.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:text.count)) }
        title.typeText("回家")
        button("commute-save").tap()
        capture("pro-saved-commute-preview")
        button("journey-close").tap()
        let shortcut = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@", "commute-shortcut-")).firstMatch
        XCTAssertTrue(shortcut.waitForExistence(timeout:10)); shortcut.tap()
        XCTAssertTrue(button("journey-close").waitForExistence(timeout:10))
        XCTAssertTrue(firstOption.waitForExistence(timeout:150),"The saved trip must produce a visible route result")
        // The result can appear as the map preview (one start button) or as the option list.
        let start = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@ OR identifier == %@", "journey-go-", "journey-start-navigation")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout:15))
        XCTAssertFalse(button("journey-board").exists)
        capture("pro-shortcut-opens-preview")
    }
    func testWidgetAndLiveActivityLayouts() {
        for english in [false, true] {
            launch(["--preview-widgets"] + (english ? ["--test-language","en"] : []))
            for id in ["widget-preview-small","widget-preview-locked","widget-preview-medium","widget-preview-lock",
                       "live-activity-preview-waiting","live-activity-preview-riding","live-activity-preview-island"] {
                XCTAssertTrue(app.descendants(matching:.any).matching(identifier:id).firstMatch.waitForExistence(timeout:15), id)
            }
            XCTAssertTrue(app.staticTexts[english ? "Leave in 7 min" : "7 分後出門"].exists)
            capture(english ? "pro-widgets-english" : "pro-widgets")
        }
    }
    func testEnglishTrialAndRenewalTermsAreClear() {
        openPlans(english:true)
        XCTAssertTrue(app.staticTexts["7 days free first"].firstMatch.waitForExistence(timeout:20))
        tapVisible("pro-purchase")
        XCTAssertTrue(app.staticTexts["Pro free trial is active"].waitForExistence(timeout:20))
        XCTAssertTrue(app.staticTexts["pro-period-end"].exists)
        capture("pro-english-trial-active")
    }
}
