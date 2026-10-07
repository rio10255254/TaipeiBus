import XCTest
@testable import TransitCore

final class PlaceLabelBudgetTests: XCTestCase {
    func testDenseTileNeverEntersTheFrameUnbounded() {
        let points = (0..<10000).map { i in
            PlaceLabelCandidate(id: "p\(i)", x: Double(i % 100) * 8 - 100, y: Double(i / 100) * 10 - 100,
                                rank: Double(i % 258), landmark: i % 50 == 0)
        }
        let selected = PlaceLabelBudget.select(points, zoom: 19, width: 400, height: 650)
        XCTAssertLessThanOrEqual(selected.count, 96)
        XCTAssertGreaterThan(selected.count, 20)
        XCTAssertEqual(Set(selected).count, selected.count)
    }
    func testOffscreenAndInvalidPlacesDoNotConsumeBudget() {
        let points = [PlaceLabelCandidate(id: "near", x: 100, y: 100, rank: 150, landmark: false),
                      PlaceLabelCandidate(id: "far", x: 5000, y: 100, rank: 1, landmark: true),
                      PlaceLabelCandidate(id: "invalid", x: .nan, y: 50, rank: 1, landmark: true)]
        XCTAssertEqual(PlaceLabelBudget.select(points, zoom: 18, width: 400, height: 650), ["near"])
    }
    func testLandmarkAndRetainedLabelWinCrowdedCell() {
        let ordinary = PlaceLabelCandidate(id: "ordinary", x: 100, y: 100, rank: 1, landmark: false)
        let landmark = PlaceLabelCandidate(id: "landmark", x: 104, y: 100, rank: 3, landmark: true)
        XCTAssertEqual(PlaceLabelBudget.select([ordinary, landmark], zoom: 18, width: 400, height: 650), ["landmark"])
        let current = PlaceLabelCandidate(id: "current", x: 104, y: 100, rank: 12, landmark: false)
        let replacement = PlaceLabelCandidate(id: "new", x: 100, y: 100, rank: 10, landmark: false)
        XCTAssertEqual(PlaceLabelBudget.select([replacement, current], zoom: 18, width: 400, height: 650,
                                             previous: ["current"]), ["current"])
    }
    func testSelectionIsDeterministicAcrossSourceTileDuplicates() {
        let a = PlaceLabelCandidate(id: "a", x: 100, y: 100, rank: 3, landmark: false)
        let b = PlaceLabelCandidate(id: "b", x: 200, y: 200, rank: 3, landmark: false)
        XCTAssertEqual(PlaceLabelBudget.select([a,b,a], zoom: 18, width: 400, height: 650),
                       PlaceLabelBudget.select([b,a], zoom: 18, width: 400, height: 650))
    }
    func testZoomAndViewportBudgetsAreBounded() {
        XCTAssertEqual(PlaceLabelBudget.limit(zoom: 13.9, width: 400, height: 650), 0)
        XCTAssertEqual(PlaceLabelBudget.limit(zoom: 18, width: 0, height: 650), 0)
        XCTAssertEqual(PlaceLabelBudget.limit(zoom: .nan, width: 400, height: 650), 0)
        XCTAssertLessThan(PlaceLabelBudget.limit(zoom: 15, width: 400, height: 650),
                          PlaceLabelBudget.limit(zoom: 18, width: 400, height: 650))
        XCTAssertEqual(PlaceLabelBudget.limit(zoom: 22, width: 2000, height: 2000), 96)
    }
    func testOverscanRingIsSeparatelyBudgetedAndNeverDisplacesVisiblePlaces() {
        let visible = (0..<10000).map { i in
            PlaceLabelCandidate(id: "v\(i)", x: Double(i % 100) * 4, y: Double(i / 100) * 6.5, rank: 50, landmark: false)
        }
        let ring = (0..<400).map { i in
            PlaceLabelCandidate(id: "r\(i)", x: Double(i % 40) * 14 - 80, y: -60 - Double(i / 40) * 12, rank: 1, landmark: true)
        }
        let plain = PlaceLabelBudget.select(visible + ring, zoom: 18, width: 400, height: 650)
        let wide = PlaceLabelBudget.select(visible + ring, zoom: 18, width: 400, height: 650, overscan: 200)
        XCTAssertFalse(plain.contains { $0.hasPrefix("r") })
        XCTAssertEqual(wide.filter { $0.hasPrefix("v") }.count, plain.count, "Ring labels must not take visible slots")
        let outer = wide.filter { $0.hasPrefix("r") }.count
        XCTAssertGreaterThan(outer, 0)
        XCTAssertLessThanOrEqual(outer, PlaceLabelBudget.limit(zoom: 18, width: 400, height: 650) / 2)
        XCTAssertEqual(Set(wide).count, wide.count)
    }
}
