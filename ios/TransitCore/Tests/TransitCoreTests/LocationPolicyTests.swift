import XCTest
@testable import TransitCore

final class LocationPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(accuracy: Double = 15, age: Double = 0) -> LocationSample {
        LocationSample(coordinate: .taipei, accuracy: accuracy, timestamp: now.addingTimeInterval(-age))
    }
    func testCoarsePositionCanShowMapWhilePrecisionIsStillBeingImproved() {
        XCTAssertTrue(sample(accuracy: 700).canDisplay(at: now))
        XCTAssertFalse(sample(accuracy: 700).canPlan(at: now))
        XCTAssertTrue(sample(accuracy: 30).canPlan(at: now))
        XCTAssertTrue(sample(accuracy: 30).shouldReplace(sample(accuracy: 700), at: now))
    }
    func testRecentPositionIsImmediateButOldPositionCannotBecomeCurrentOrigin() {
        XCTAssertTrue(sample(age: 5).canPlan(at: now))
        XCTAssertTrue(sample(age: 90).canDisplay(at: now))
        XCTAssertFalse(sample(age: 90).canPlan(at: now))
        XCTAssertFalse(sample(age: 181).canDisplay(at: now))
        XCTAssertFalse(sample(age: -30).canDisplay(at: now))
    }
    func testPoorNewReportDoesNotReplaceARecentGoodPosition() {
        XCTAssertFalse(sample(accuracy: 700).shouldReplace(sample(accuracy: 15, age: 5), at: now))
        XCTAssertTrue(sample(accuracy: 700).shouldReplace(sample(accuracy: 15, age: 40), at: now))
        XCTAssertFalse(sample(age: 10).shouldReplace(sample(age: 1), at: now))
    }
    func testInvalidCoordinatesAndAccuracyAreNeverUsable() {
        for point in [Coordinate(latitude: .nan, longitude: 121.5), Coordinate(latitude: 91, longitude: 121.5), Coordinate(latitude: 0, longitude: 0)] {
            XCTAssertFalse(LocationSample(coordinate: point, accuracy: 10, timestamp: now).canDisplay(at: now))
        }
        XCTAssertFalse(sample(accuracy: -1).canDisplay(at: now))
        XCTAssertFalse(sample(accuracy: .infinity).canDisplay(at: now))
    }
}
