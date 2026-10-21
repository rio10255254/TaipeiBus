import XCTest
import UIKit

final class LiveActivityUsabilityTests: JourneyUsabilityTestBase {
    override func tearDownWithError() throws {
        // Preserve the failed system frame before clearing either audit app.
        try super.tearDownWithError()
        let companion = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus.IslandCompanion")
        for target in [app, companion] where target.state != .notRunning {
            target.activate()
            let end = target.buttons["island-system-end"]
            for _ in 0..<3 { if end.isHittable { break }; target.swipeUp() }
            if end.exists && end.isHittable {
                end.tap()
                let status = target.staticTexts["island-system-status"]
                let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    status.exists && status.label == "ended"
                }, object: nil)
                _ = XCTWaiter.wait(for: [stopped], timeout: 10)
            }
        }
    }
    private func waitForSystemIsland(_ board: XCUIApplication) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.hasVisibleSystemIsland(board)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 15), .completed,
            "The compact system activity must be present before a long press can expand it")
    }
    private func endSystemActivity(_ target: XCUIApplication) {
        target.buttons["island-system-end"].tap()
        let status = target.staticTexts["island-system-status"]
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && status.label == "ended"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ended], timeout: 20), .completed,
            "The previous native activity must finish ending before the test terminates its app")
    }
    func testInitiallyStaleOrDueNavigationStillRendersGuidance() {
        for scenario in ["stale", "due"] {
            launch(["--preview-island", "--island-scenario", scenario])
            let start = button("island-system-start")
            for _ in 0..<3 { if start.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(start.isHittable); start.tap()
            let status = app.staticTexts["island-system-status"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                status.exists && status.label.hasPrefix("started:")
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            XCUIDevice.shared.press(.home); sleep(4)
            let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            waitForSystemIsland(board)
            board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.2)
            let headline = board.staticTexts["捷運內湖站"].firstMatch
            XCTAssertTrue(headline.waitForExistence(timeout: 20), "A past deadline must not leave a black shell")
            assertIslandPixels(headline)
            if scenario == "stale" {
                XCTAssertTrue(board.staticTexts["點一下更新"].firstMatch.exists)
            }
            capture("island-initial-" + scenario)
            app.activate(); endSystemActivity(app)
        }
    }
    func testWalkingGuidanceAppearsOnTheActualSystemIsland() {
        launch(["--preview-island", "--island-walking"])
        let start = button("island-system-start")
        for _ in 0..<3 { if start.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(start.isHittable); start.tap()
        let status = app.staticTexts["island-system-status"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && status.label == "started:walking"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCUIDevice.shared.press(.home); sleep(3)
        capture("walking-real-system-compact")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        waitForSystemIsland(board)
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.2)
        XCTAssertTrue(board.staticTexts["捷運內湖站"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(board.staticTexts["450 m"].firstMatch.exists,
            "The walking route must render its real guidance, not only create an activity shell")
        assertIslandPixels(board.staticTexts["捷運內湖站"].firstMatch)
        capture("walking-real-system-expanded")
        app.activate(); endSystemActivity(app)
    }
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
    func testNavigationIntroductionAutomaticallyUsesTheExpandedIsland() {
        launch(["--preview-island", "--island-auto-expand"])
        let start = button("island-system-start")
        for _ in 0..<3 { if start.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(start.isHittable); start.tap()
        let status = app.staticTexts["island-system-status"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.exists && status.label.hasPrefix("started:")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(board.staticTexts["捷運內湖站"].firstMatch.waitForExistence(timeout: 25),
            "Leaving the app should show the trip introduction in the expanded island without a long press")
        assertIslandPixels(board.staticTexts["捷運內湖站"].firstMatch)
        capture("central-island-automatic-introduction")

        // Another app may normally share the island. A fresh navigation step
        // should still request its full guidance, without a press on either circle.
        let companion = XCUIApplication(bundleIdentifier: "com.example.TaipeiBus.IslandCompanion")
        companion.launchArguments = ["--preview-island", "--island-companion", "--test-language", "en"]
        companion.launch()
        let secondStart = companion.buttons["island-system-start"]
        for _ in 0..<3 { if secondStart.isHittable { break }; companion.swipeUp() }
        XCTAssertTrue(secondStart.isHittable); secondStart.tap()
        let secondStatus = companion.staticTexts["island-system-status"]
        let secondReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            secondStatus.exists && secondStatus.label == "started:cycling"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [secondReady], timeout: 15), .completed)
        app.activate()
        for _ in 0..<3 { if button("island-next").isHittable { break }; app.swipeDown() }
        button("island-next").tap()
        sleep(13) // Deliberately exceed the quiet-step cooldown in this fixture.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(board.staticTexts["還有 5 站"].firstMatch.waitForExistence(timeout: 25),
            "Boarding should present full central guidance even while another app has an activity")
        assertIslandPixels(board.staticTexts["還有 5 站"].firstMatch)
        capture("central-island-automatic-with-other-activity")
        app.activate()
        for _ in 0..<3 { if button("island-system-end").isHittable { break }; app.swipeUp() }
        endSystemActivity(app)
        companion.activate(); endSystemActivity(companion)
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
        waitForSystemIsland(springboard)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.2)
        XCTAssertTrue(springboard.staticTexts["捷運內湖站"].firstMatch.waitForExistence(timeout: 20),
                      "An expanded black shell without trip content is not a successful expansion")
        assertIslandPixels(springboard.staticTexts["捷運內湖站"].firstMatch)
        sleep(2)
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
        let bus = springboard.otherElements.matching(NSPredicate(format: "identifier == 'minimal.view' AND label CONTAINS %@", "630")).firstMatch
        let bike = springboard.otherElements.matching(NSPredicate(format: "identifier == 'minimal.view' AND label CONTAINS %@", "Cycle to")).firstMatch
        XCTAssertTrue(bus.waitForExistence(timeout: 20), "The bus minimal view must contain trip content")
        XCTAssertTrue(bike.waitForExistence(timeout: 20), "The second app must render its content, not an empty circle")
        sleep(2)
        capture("island-real-system-two-activities")
        let tree = XCTAttachment(string: springboard.debugDescription)
        tree.name = "island-two-apps-springboard"; tree.lifetime = .keepAlways; add(tree)
        app.activate()
        endSystemActivity(app)
        XCTAssertEqual(status.label, "ended")
        XCUIDevice.shared.press(.home); sleep(3)
        capture("island-ended-other-app-remains")
        companion.activate()
        endSystemActivity(companion)
        XCUIDevice.shared.press(.home); sleep(3)
        capture("island-real-system-ended")
        app.activate()
    }
}
