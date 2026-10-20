import XCTest

final class LiveActivityUsabilityTests: JourneyUsabilityTestBase {
    func testAllIslandSizesShareTheSameMeaningInBothLanguages() {
        for english in [false, true] {
            launch(["--preview-island"] + (english ? ["--test-language", "en"] : []))
            let names = ["waiting", "riding", "alighting", "walking", "cycling", "transfer", "stale", "due", "long"]
            for (index, name) in names.enumerated() {
                if index > 0 { button("island-next").tap() }
                for id in ["island-compact", "island-minimal", "island-expanded", "island-lock"] {
                    XCTAssertTrue(app.descendants(matching: .any).matching(identifier: id).firstMatch.waitForExistence(timeout: 10))
                }
                if name == "stale" {
                    XCTAssertTrue(app.staticTexts[english ? "Tap to refresh" : "點一下更新"].firstMatch.exists)
                }
                if name == "due" {
                    XCTAssertTrue(app.staticTexts[english ? "Watch for arrival" : "留意來車"].firstMatch.exists)
                }
                sleep(2)
                capture("island-\(english ? "en" : "zh")-\(name)")
            }
        }
    }
    func testSystemCompactAndTwoActivityPresentationsAndEnd() {
        launch(["--preview-island"])
        let start = button("island-system-start")
        for _ in 0..<3 { if start.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(start.isHittable); start.tap()
        let status = app.staticTexts["island-system-status"]
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && status.label.hasPrefix("started:")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 15), .completed)
        XCUIDevice.shared.press(.home); sleep(3)
        capture("island-real-system-compact")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Use the physical screen coordinates, since SpringBoard is not the app's test window.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.2)
        sleep(3)
        capture("island-real-system-expanded")
        let companion = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus.IslandCompanion")
        companion.launchArguments = ["--preview-island", "--island-companion", "--test-language", "en"]
        companion.launch()
        let secondStart = companion.buttons["island-system-start"]
        for _ in 0..<3 { if secondStart.isHittable { break }; companion.swipeUp() }
        XCTAssertTrue(secondStart.isHittable); secondStart.tap()
        let secondStatus = companion.staticTexts["island-system-status"]
        let secondStarted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            secondStatus.exists && secondStatus.label == "started:cycling"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [secondStarted], timeout: 15), .completed)
        XCUIDevice.shared.press(.home); sleep(5)
        capture("island-real-system-two-activities")
        let tree = XCTAttachment(string: springboard.debugDescription)
        tree.name = "island-two-apps-springboard"; tree.lifetime = .keepAlways; add(tree)
        app.activate()
        button("island-system-end").tap()
        XCTAssertEqual(status.label, "ended")
        XCUIDevice.shared.press(.home); sleep(3)
        capture("island-ended-other-app-remains")
        companion.activate()
        companion.buttons["island-system-end"].tap()
        XCUIDevice.shared.press(.home); sleep(3)
        capture("island-real-system-ended")
        app.activate()
    }
}
