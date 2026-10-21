import XCTest
import UIKit

final class LiveActivityUsabilityTests: JourneyUsabilityTestBase {
    /// Accessibility can retain a label during a failed render or a collapsing
    /// transition. Require visible light text on the actual black island as well.
    private func assertIslandPixels(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let screenshot = XCUIScreen.main.screenshot()
        guard let full = UIImage(data: screenshot.pngRepresentation)?.cgImage else {
            XCTFail("System screenshot could not be decoded", file: file, line: line); return
        }
        let frame = element.frame, screen = UIScreen.main.bounds
        let scale = CGFloat(full.width) / screen.width
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale,
            width: frame.width * scale, height: frame.height * scale).integral
        guard frame.minY < screen.height * 0.3, !frame.isEmpty,
              let crop = full.cropping(to: rect), crop.width > 0, crop.height > 0 else {
            XCTFail("The expected guidance is not positioned inside the system island", file: file, line: line); return
        }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return true
        }
        XCTAssertTrue(decoded, file: file, line: line)
        var dark = 0, light = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i+1]), b = Int(pixels[i+2])
            if max(r, max(g, b)) < 55 { dark += 1 }
            if min(r, min(g, b)) > 135 { light += 1 }
        }
        let proof = XCTAttachment(screenshot: screenshot)
        proof.name = "island-pixel-proof"; proof.lifetime = .keepAlways; add(proof)
        XCTAssertGreaterThan(light, 8, "The island has labels but its text is visually blank", file: file, line: line)
        XCTAssertGreaterThan(Double(dark) / Double(crop.width * crop.height), 0.15,
            "The island collapsed before its guidance could be visually verified", file: file, line: line)
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
        board.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.2)
        XCTAssertTrue(board.staticTexts["捷運內湖站"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(board.staticTexts["450 m"].firstMatch.exists,
            "The walking route must render its real guidance, not only create an activity shell")
        assertIslandPixels(board.staticTexts["捷運內湖站"].firstMatch)
        capture("walking-real-system-expanded")
        app.activate(); button("island-system-end").tap()
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
        button("island-system-end").tap()
        companion.activate(); companion.buttons["island-system-end"].tap()
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
