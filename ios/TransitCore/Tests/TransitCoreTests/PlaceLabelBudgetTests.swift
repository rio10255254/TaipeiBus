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
}
