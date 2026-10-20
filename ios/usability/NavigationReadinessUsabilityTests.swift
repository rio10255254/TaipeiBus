import XCTest
import StoreKitTest

final class NavigationReadinessUsabilityTests: JourneyUsabilityTestBase {
    private var session: SKTestSession!
    override func setUpWithError() throws {
        try super.setUpWithError()
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ProProducts", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: file)
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        session.storefront = "TWN"; session.locale = Locale(identifier: "zh_TW"); session.timeRate = .realTime
    }
    override func tearDownWithError() throws {
        try super.tearDownWithError(); session.clearTransactions(); session = nil
    }
    private func probe() -> [String: Any] {
        let element = app.staticTexts["navigation-readiness-state"]
        guard element.exists, let data = element.label.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private func waitState(_ description: String, _ condition: @escaping ([String: Any]) -> Bool) {
        let match = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition(self.probe()) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 20), .completed, description + ": " + String(describing: probe()))
    }
    private func openPro(_ english: Bool) {
        launch(["--test-navigation-readiness",
                "-alightReminderOn", "YES", "-rideActivityOn", "YES"] + (english ? ["--test-language", "en"] : []))
        let information = button(english ? "Information and settings" : "資料來源與地圖設定")
        XCTAssertTrue(information.waitForExistence(timeout: 30)); information.tap()
        XCTAssertTrue(button("settings-pro").waitForExistence(timeout: 15)); button("settings-pro").tap()
        XCTAssertTrue(button("pro-open-plans").waitForExistence(timeout: 10)); button("pro-open-plans").tap()
        if !button("pro-plan-monthly").waitForExistence(timeout: 8), button("pro-open-plans").isHittable { button("pro-open-plans").tap() }
        let purchase = button("pro-purchase")
        XCTAssertTrue(purchase.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: purchase)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        purchase.tap()
        let active = app.staticTexts[english ? "Pro free trial is active" : "正在免費試用 Pro"]
        if !active.waitForExistence(timeout: 20), purchase.isHittable && purchase.isEnabled { purchase.tap() }
        XCTAssertTrue(active.waitForExistence(timeout: 20)); button("pro-close").tap()
        XCTAssertTrue(app.staticTexts["pro-alight-readiness"].waitForExistence(timeout: 15))
    }
    private func backToJourney(_ english: Bool) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        XCTAssertTrue(button(english ? "Done" : "完成").waitForExistence(timeout: 10))
        button(english ? "Done" : "完成").tap()
        XCTAssertTrue(button("home-destination-search").waitForExistence(timeout: 15))
        // Open the planning fixture after leaving Settings: two sibling sheets cannot
        // present over one another. The real StoreKit purchase survives this relaunch.
        launch(["--preview-metro-fixture", "--preview-route-only", "--usability-fixture", "--test-navigation-readiness",
                "-alightReminderOn", "YES", "-rideActivityOn", "YES"] + (english ? ["--test-language", "en"] : []))
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout: 80))
        waitState("The purchased account opens a preview", { $0["started"] as? Bool == false && $0["pro"] as? Bool == true })
    }
    func testEnglishDeniedNotificationsAndNavigationLifecycle() {
        openPro(true)
        let permission = button("pro-authorize-notifications")
        XCTAssertTrue(permission.waitForExistence(timeout: 10))
        if permission.label == "Allow notifications" {
            permission.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deny = springboard.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Don’t Allow", "Don't Allow", "不允許"])).firstMatch
            XCTAssertTrue(deny.waitForExistence(timeout: 10)); deny.tap()
        }
        let status = app.staticTexts["pro-alight-readiness"]
        XCTAssertEqual(status.label, "Notifications need permission")
        XCTAssertEqual(permission.label, "Open Settings")
        capture("navigation-notification-permission-needed")
        backToJourney(true)
        waitState("Denied permission stays inactive", { $0["notifications"] as? String == "denied" && $0["reminderReady"] as? Bool == false })
        XCTAssertFalse(probe()["started"] as? Bool ?? true)
        tripLifecycle(english: true)
    }
    func testPreviewBackgroundReturnAndEndConfirmation() { lifecycle(english: false) }
    private func lifecycle(english: Bool) {
        openPro(english); capture(english ? "navigation-readiness-english" : "navigation-readiness-chinese")
        backToJourney(english)
        tripLifecycle(english: english)
    }
    private func tripLifecycle(english: Bool) {
        let steps = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journey-steps-")).firstMatch
        XCTAssertTrue(steps.waitForExistence(timeout: 10))
        var lastFrame = CGRect.null, settledAt = Date()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard steps.exists, steps.isEnabled else { return false }
            let frame = steps.frame
            guard frame.width > 20, frame.height > 20,
                  self.app.windows.firstMatch.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
            if lastFrame.isNull || abs(frame.midX - lastFrame.midX) > 1 || abs(frame.midY - lastFrame.midY) > 1 {
                lastFrame = frame; settledAt = Date(); return false
            }
            return Date().timeIntervalSince(settledAt) >= 0.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        func tapSteps() {
            let frame = steps.frame
            let window = app.windows.firstMatch
            XCTAssertTrue(window.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
            if steps.isHittable { steps.tap() }
            else {
                window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX-window.frame.minX, dy: frame.midY-window.frame.minY)).tap()
            }
        }
        // XCTest's hittability result can be false for a visible control inside a
        // transformed native sheet. Send a real touch at its current screen bounds.
        tapSteps()
        let start = button("journey-start-navigation")
        // The hosted simulator may drop a tap while the native sheet settles.
        // Retry only when the same preview action remains visible and no trip began.
        if !start.waitForExistence(timeout: 5), steps.exists, steps.isEnabled,
           probe()["started"] as? Bool == false { tapSteps() }
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(probe()["started"] as? Bool ?? true)
        button("journey-back").tap()
        XCTAssertTrue(button("journey-all-options").waitForExistence(timeout: 10))
        XCTAssertFalse(probe()["started"] as? Bool ?? true)
        let go = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journey-go-")).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 10)); go.tap()
        XCTAssertTrue(button("journey-end").waitForExistence(timeout: 10))
        waitState("An explicit departure begins the trip", { $0["started"] as? Bool == true })
        let phase = probe()["step"] as? Int
        XCTAssertNotNil(phase)
        XCUIDevice.shared.press(.home)
        capture(english ? "navigation-background-english" : "navigation-background-chinese")
        app.activate()
        waitState("Returning keeps the same step", { $0["started"] as? Bool == true && $0["step"] as? Int == phase })
        button("journey-end").tap()
        let keep = button(english ? "Continue navigation" : "繼續導航")
        XCTAssertTrue(keep.waitForExistence(timeout: 10)); keep.tap()
        waitState("Cancelling end keeps navigation", { $0["started"] as? Bool == true })
        button("journey-end").tap()
        capture(english ? "navigation-confirm-end-english" : "navigation-confirm-end-chinese")
        let confirm = app.buttons.matching(identifier: "journey-confirm-end").firstMatch
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }
        else {
            let end = app.buttons.matching(NSPredicate(format: "label == %@", english ? "End trip" : "結束行程"))
                .allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(end); end?.tap()
        }
        waitState("Ending clears the trip and its background work", {
            $0["started"] as? Bool == false && $0["background"] as? Bool == false && $0["liveActivity"] as? Bool == false
        })
        XCTAssertTrue(button("home-destination-search").waitForExistence(timeout: 10))
        capture(english ? "navigation-ended-english" : "navigation-ended-chinese")
    }
}
