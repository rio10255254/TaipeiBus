import XCTest
@testable import TransitCore

final class MapAndWalkingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func point(_ x: Double, _ y: Double = 0) -> Coordinate {
        Coordinate(latitude: 25.04 + y / 111_320, longitude: 121.55 + x / (111_320 * cos(25.04 * .pi / 180)))
    }
    func bus(_ id: Int, _ from: Coordinate, _ to: Coordinate, seconds: Double) -> BusVehicle {
        BusVehicle(id: String(id), plate: "TEST-\(id)", routeID: "route", parentRouteID: "family", routeName: "630",
            direction: "0", destination: "stop", coordinate: to, rawCoordinate: to, heading: 90, speed: 18,
            observedAt: now.addingTimeInterval(seconds), status: "0", lowFloor: true, provider: nil,
            aligned: true, path: [from, to])
    }
    func testViewportCullingPreservesReceivedMotionAndCrossingTrajectories() throws {
        var motion = VehicleMotion()
        let first = (0..<2500).map { bus($0, point(Double($0)*20), point(Double($0)*20), seconds: 0) }
        motion.ingest(first, time: 0, now: now)
        let second = (0..<2500).map { bus($0, point(Double($0)*20), point(Double($0)*20+50), seconds: 10) }
        motion.ingest(second, time: 10, now: now.addingTimeInterval(10))
        let bounds = GeoBounds([point(20,-20), point(40,20)])
        for time in [10.0, 12, 16, 20] {
            let date = now.addingTimeInterval(time)
            let all = Dictionary(uniqueKeysWithValues: motion.poses(time: time, now: date).map { ($0.id, $0) })
            let subset = motion.poses(time: time, now: date, in: bounds, including: "2499")
            XCTAssertLessThan(subset.count, 10)
            XCTAssertTrue(subset.contains { $0.id == "0" }, "A trajectory crossing the view remains eligible even when its received endpoint is outside.")
            XCTAssertTrue(subset.contains { $0.id == "2499" }, "The selected physical bus stays available during camera travel.")
            for pose in subset {
                let original = try XCTUnwrap(all[pose.id])
                XCTAssertLessThan(pose.coordinate.distance(to: original.coordinate), 0.001)
                XCTAssertEqual(pose.observedAt, original.observedAt); XCTAssertEqual(pose.heading, original.heading)
            }
        }
    }
    func testWalkingProgressFollowsVerifiedRoadAndRejectsPoorFixes() {
        var progress = WalkingProgress(coordinates: [point(0),point(100)], distance: 100, seconds: 80)
        XCTAssertTrue(progress.update(coordinate: point(10,2), accuracy: 5, timestamp: now, now: now))
        XCTAssertEqual(progress.remainingDistance, 90, accuracy: 1)
        XCTAssertTrue(progress.update(coordinate: point(20), accuracy: 5, timestamp: now.addingTimeInterval(5), now: now.addingTimeInterval(5)))
        XCTAssertEqual(progress.remainingSeconds, 64, accuracy: 1)
        XCTAssertFalse(progress.update(coordinate: point(95), accuracy: 150, timestamp: now.addingTimeInterval(6), now: now.addingTimeInterval(6)))
        XCTAssertEqual(progress.remainingDistance, 80, accuracy: 1)
        XCTAssertFalse(progress.locationConfirmed)
        XCTAssertFalse(progress.update(coordinate: point(90), accuracy: 3, timestamp: now, now: now.addingTimeInterval(30)))
        XCTAssertEqual(progress.remainingCoordinates.last, point(100))
    }
    func testWalkingDoesNotJumpAcrossParallelReturnPaths() {
        var progress = WalkingProgress(coordinates: [point(0),point(100),point(100,5),point(0,5)], distance: 205, seconds: 170)
        XCTAssertTrue(progress.update(coordinate: point(10), accuracy: 5, timestamp: now, now: now))
        XCTAssertTrue(progress.update(coordinate: point(12,4), accuracy: 5, timestamp: now.addingTimeInterval(3), now: now.addingTimeInterval(3)))
        XCTAssertGreaterThan(progress.remainingDistance, 180, "GPS drift onto a nearby parallel leg must not jump to the destination.")
    }
    func testOffRouteRequiresRepeatedFreshEvidenceAndResetsAfterRecovery() {
        var progress = WalkingProgress(coordinates: [point(0),point(100)], distance: 100, seconds: 80)
        _ = progress.update(coordinate: point(10), accuracy: 5, timestamp: now, now: now)
        for t in [1.0, 5, 9, 13, 17] {
            _ = progress.update(coordinate: point(20,60), accuracy: 5, timestamp: now.addingTimeInterval(t), now: now.addingTimeInterval(t))
            if t < 17 { XCTAssertFalse(progress.needsReroute) }
        }
        XCTAssertTrue(progress.needsReroute)
        _ = progress.update(coordinate: point(20), accuracy: 5, timestamp: now.addingTimeInterval(20), now: now.addingTimeInterval(20))
        XCTAssertFalse(progress.needsReroute); XCTAssertTrue(progress.locationConfirmed)
    }
    func testCameraChoosesClearDirectionAndFallsBackToOverhead() {
        let target = point(0)
        let south = MapBuilding(rings: [[point(-12,-35),point(12,-35),point(12,-12),point(-12,-12)]], height: 90)
        XCTAssertTrue(CameraVisibility.isBlocked(target: target, altitude: 245, heading: 0, pitch: 57, buildings: [south]))
        let angle = CameraVisibility.clearAngle(target: target, altitude: 245, heading: 0, pitch: 57, buildings: [south])
        XCTAssertNotEqual(angle.heading, 0)
        XCTAssertFalse(CameraVisibility.isBlocked(target: target, altitude: 245, heading: angle.heading, pitch: angle.pitch, buildings: [south]))
        let surrounded = MapBuilding(rings: [[point(-100,-100),point(100,-100),point(100,100),point(-100,100)]], height: 300)
        XCTAssertEqual(CameraVisibility.clearAngle(target: target, altitude: 245, heading: 0, pitch: 57, buildings: [surrounded]).pitch, 0)
        let bridge = MapBuilding(rings: south.rings, height: 120, baseHeight: 80)
        XCTAssertFalse(CameraVisibility.isBlocked(target: target, altitude: 245, heading: 0, pitch: 57, buildings: [bridge]))
    }
}
