import XCTest

/// What the interface's never-ending decoration costs on the system and iPhone this runs on, and
/// the trip interactions walked through there. Each piece is measured alone in the motion lab,
/// moving and held still, for main-thread CPU and frame pacing. Simulator figures compare a piece
/// with its own still state and with the others; they are not a phone's absolute numbers.
final class MotionPerformanceUsabilityTests: JourneyUsabilityTestBase {
    private func report() -> [String: Any] {
        let text = app.staticTexts["motion-cost-state"].label
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    /// Windows that began after `since`, so neither the launch nor a query of the screen is in them.
    private func quiet(_ report: [String: Any], since: TimeInterval) -> [[String: Any]] {
        (report["windows"] as? [[String: Any]] ?? []).filter { (($0["began"] as? NSNumber)?.doubleValue ?? 0) >= since }
    }
    private func summary(_ windows: [[String: Any]]) -> [String: Any] {
        func values(_ key: String) -> [Double] { windows.compactMap { ($0[key] as? NSNumber)?.doubleValue }.sorted() }
        func median(_ key: String) -> Double { let all = values(key); return all.isEmpty ? -1 : all[all.count / 2] }
        // Typed, so `last` is the property and not the `last(where:)` method boxed as Any.
        let longest: Double = values("longest_ms").last ?? -1
        return ["main_cpu_pct": median("main_cpu_pct"), "process_cpu_pct": median("process_cpu_pct"), "fps": median("fps"),
                "delayed_frames": Int(values("delayed").reduce(0, +)), "longest_ms": longest,
                "windows": windows.count]
    }
    /// One launch of the lab: wait until it shows, then leave it alone for `seconds` before one read.
    private func measure(_ component: String, still: Bool, seconds: Double = 27) -> (summary: [String: Any], report: [String: Any]) {
        launch(["--test-motion-lab", component] + (still ? ["--test-still-decor"] : []))
        XCTAssertTrue(app.staticTexts["motion-cost-state"].waitForExistence(timeout: 60))
        let since = Date().timeIntervalSince1970 + 0.5
        Thread.sleep(forTimeInterval: seconds)
        let value = report()
        if !still { capture("motion-lab-" + component) }
        app.terminate()
        let windows = quiet(value, since: since)
        XCTAssertGreaterThanOrEqual(windows.count, 3, "\(component): too few quiet windows in \(value)")
        return (summary(windows), value)
    }
    private func publish(_ name: String, _ value: [String: Any]) {
        // JSONSerialization raises (not throws) on a value it cannot write; check first.
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            XCTFail("Not JSON: \(value)"); return
        }
        let text = String(decoding: data, as: UTF8.self)
        print("MOTION-COST-RESULT " + name + " " + text)
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDecorationLeavesTheMainThreadFree() {
        var rows: [[String: Any]] = []
        var device: [String: Any] = [:]
        for component in ["idle", "pulse", "symbols", "loading", "orb", "orb-large", "glow", "preview"] {
            let moving = measure(component, still: false)
            let still = measure(component, still: true)
            if device.isEmpty {
                device = ["os": moving.report["os"] as? String ?? "", "device": moving.report["device"] as? String ?? "",
                          "model": moving.report["model"] as? String ?? "", "screen_hz": moving.report["screen_hz"] as? Int ?? 0]
            }
            XCTAssertEqual(still.report["still"] as? Bool, true)
            XCTAssertEqual(moving.report["still"] as? Bool, false)
            let extra = ((moving.summary["main_cpu_pct"] as? Double) ?? 0) - ((still.summary["main_cpu_pct"] as? Double) ?? 0)
            let row: [String: Any] = ["component": component, "moving": moving.summary, "still": still.summary,
                                      "main_cpu_extra_pct": (extra * 100).rounded() / 100]
            // Each piece is reported as soon as it is measured, so a later failure keeps it.
            publish("motion-cost-" + component, ["device": device, "result": row])
            rows.append(row)
        }
        publish("motion-cost", ["device": device, "results": rows])
        // Pieces animated by Core Animation run in the render server: moving costs the app's main
        // thread no more than holding still does, within measurement noise.
        for row in rows where ["pulse", "symbols", "orb", "orb-large", "glow", "preview"].contains(row["component"] as? String) {
            XCTAssertLessThanOrEqual(row["main_cpu_extra_pct"] as? Double ?? 99, 1.5, "\(row)")
        }
    }

    /// Which part of the trip sheet keeps iOS 17 laying it out without end: the itinerary opened
    /// once per variant, each leaving one part out. Nothing is asked of the app after the tap; the
    /// app's heartbeat log (--test-view-changes) tells whether its main thread came back.
    func testDiagnoseItineraryStall() {
        continueAfterFailure = true
        for variant in ["baseline", "no-nav", "no-itinerary", "no-detent-selection", "plain-sheet",
                        "no-panel-height", "no-type-env", "no-tint"] {
            launch(["--preview-boarding-fixture", "--usability-fixture", "--test-ai-ui", "--test-view-changes",
                    "--diag-variant", variant])
            guard button("journey-board").waitForExistence(timeout: 90) else {
                print("DIAG \(variant) no-board"); app.terminate(); continue
            }
            Thread.sleep(forTimeInterval: 2)
            let tapped = ProcessInfo.processInfo.systemUptime
            button("journey-options").tap()
            Thread.sleep(forTimeInterval: 15)
            print("DIAG \(variant) tapped \(tapped) ended \(ProcessInfo.processInfo.systemUptime)")
            app.terminate()
        }
    }

    /// The trip with the new feedback, walked through on this system and screen size: pages,
    /// tracking, the itinerary, boarding, the stops sheet, alighting, arriving and a favourite.
    func testTripInteractionsOnThisSystem() {
        // A fixed midday plan and no live poll: route 307 has no service after midnight in Taipei,
        // and the trip must be the same at any hour the workflow runs.
        launch(["--preview-boarding-fixture", "--usability-fixture", "--test-ai-ui", "--test-motion-cost", "--test-view-changes"])
        let board = button("journey-board")
        XCTAssertTrue(board.waitForExistence(timeout: 90))
        capture("motion-trip-waiting")
        let bus = button("boarding-vehicle-TEST-02")
        if bus.exists {
            // Tracking itself is held to its states by JourneyUsabilityTests; here it only has to animate.
            bus.tap(); capture("motion-trip-tracking")
        }
        button("journey-options").tap()
        XCTAssertTrue(button("返回地圖").waitForExistence(timeout: 10))
        capture("motion-trip-itinerary-waiting")
        button("返回地圖").tap()
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.tap()
        XCTAssertTrue(button("journey-alight").waitForExistence(timeout: 10))
        capture("motion-trip-on-board")
        button("journey-ride-stops").tap()
        XCTAssertTrue(button("journey-stops-done").waitForExistence(timeout: 10))
        capture("motion-trip-ride-stops")
        button("journey-stops-done").tap()
        XCTAssertTrue(button("journey-alight").waitForExistence(timeout: 10))
        button("journey-options").tap()
        XCTAssertTrue(button("返回地圖").waitForExistence(timeout: 10))
        capture("motion-trip-itinerary-riding")
        button("返回地圖").tap()
        button("返回等車").tap()
        XCTAssertTrue(board.waitForExistence(timeout: 10))
        board.tap()
        XCTAssertTrue(button("journey-alight").waitForExistence(timeout: 10))
        button("journey-alight").tap()
        XCTAssertTrue(button("journey-arrive").waitForExistence(timeout: 10))
        capture("motion-trip-last-walk")
        button("journey-arrive").tap()
        XCTAssertTrue(button("完成").waitForExistence(timeout: 10))
        capture("motion-trip-arrived")
        button("完成").tap()
        XCTAssertTrue(button("搜尋目的地").waitForExistence(timeout: 10))
        capture("motion-trip-home")
        let trip = report()
        publish("motion-trip-pacing", ["os": trip["os"] as? String ?? "", "device": trip["device"] as? String ?? "",
                                       "pacing": summary(trip["windows"] as? [[String: Any]] ?? [])])
        XCTAssertEqual(app.state, .runningForeground)
    }
}
