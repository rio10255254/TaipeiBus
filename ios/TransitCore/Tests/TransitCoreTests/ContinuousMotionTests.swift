import XCTest
@testable import TransitCore

final class ContinuousMotionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func point(_ meters: Double) -> Coordinate {
        Coordinate(latitude: 25.04, longitude: 121.55 + meters / 100_750)
    }
    private func bus(_ from: Double, _ to: Double, at seconds: Double, speed: Double = 18,
                     aligned: Bool = true) -> BusVehicle {
        BusVehicle(id: "physical", plate: "GPS-01", routeID: "route", parentRouteID: "family", routeName: "630",
            direction: "0", destination: "目的地", coordinate: point(to), rawCoordinate: point(to), heading: 90,
            speed: speed, observedAt: date.addingTimeInterval(seconds), status: "0", lowFloor: true, provider: nil,
            aligned: aligned, path: aligned ? [point(from), point(to)] : [point(to)])
    }

    func testFiveSecondGPSPacketsMoveThroughoutTheIntervalAtReceivedPace() throws {
        var motion = VehicleMotion()
        motion.ingest([bus(0, 0, at: 0)], time: 0, now: date)
        var previous = point(0)
        for step in 1...8 {
            let seconds = Double(step * 5), end = Double(step * 25)
            let now = date.addingTimeInterval(seconds)
            let before = try XCTUnwrap(motion.pose(id: "physical", time: seconds, now: now))
            motion.ingest([bus(end - 25, end, at: seconds)], time: seconds, now: now)
            let after = try XCTUnwrap(motion.pose(id: "physical", time: seconds, now: now))
            XCTAssertLessThan(before.coordinate.distance(to: after.coordinate), 0.001)
            for frame in 1..<300 {
                let time = seconds + Double(frame) / 60
                let pose = try XCTUnwrap(motion.pose(id: "physical", time: time, now: date.addingTimeInterval(time)))
                let distance = previous.distance(to: pose.coordinate)
                XCTAssertGreaterThan(distance, 0.04, "Continuous GPS movement must not sprint then hold for most of the interval")
                XCTAssertLessThan(distance, 0.12, "Received 5 m/s motion must not be replayed as a high-speed catch-up")
                XCTAssertLessThanOrEqual(pose.coordinate.longitude, point(end).longitude + 0.00000001)
                XCTAssertLessThanOrEqual(pose.observedAt, date.addingTimeInterval(seconds))
                previous = pose.coordinate
            }
            // Sample the exact join as well; ingestion of the next packet must preserve that point.
            previous = try XCTUnwrap(motion.pose(id: "physical", time: seconds + 5, now: now)).coordinate
        }
    }

    func testEarlyPacketQueuesWithoutAcceleratingOrDroppingTheCurrentCorner() throws {
        var motion = VehicleMotion()
        motion.ingest([bus(0, 0, at: 0)], time: 0, now: date)
        motion.ingest([bus(0, 50, at: 10)], time: 10, now: date.addingTimeInterval(10))
        let before = try XCTUnwrap(motion.pose(id: "physical", time: 15, now: date.addingTimeInterval(15)))
        motion.ingest([bus(50, 75, at: 15)], time: 15, now: date.addingTimeInterval(15))
        let after = try XCTUnwrap(motion.pose(id: "physical", time: 15, now: date.addingTimeInterval(15)))
        XCTAssertEqual(before.coordinate, after.coordinate)
        XCTAssertEqual(before.traveledDistance, after.traveledDistance, accuracy: 0.001)
        XCTAssertLessThan(try XCTUnwrap(motion.pose(id: "physical", time: 20, now: date.addingTimeInterval(20))).coordinate.distance(to: point(50)), 0.01)
        XCTAssertLessThan(try XCTUnwrap(motion.pose(id: "physical", time: 25, now: date.addingTimeInterval(25))).coordinate.distance(to: point(75)), 0.01)
        XCTAssertFalse(motion.isAnimating(time: 25, now: date.addingTimeInterval(25)))
    }

    func testStoppedPacketAtKnownEndpointDoesNotTeleportThePlayingBus() throws {
        var motion = VehicleMotion()
        motion.ingest([bus(0, 0, at: 0)], time: 0, now: date)
        motion.ingest([bus(0, 50, at: 10)], time: 10, now: date.addingTimeInterval(10))
        let before = try XCTUnwrap(motion.pose(id: "physical", time: 15, now: date.addingTimeInterval(15)))
        motion.ingest([bus(50, 50, at: 15, speed: 0)], time: 15, now: date.addingTimeInterval(15))
        XCTAssertEqual(before.coordinate, try XCTUnwrap(motion.pose(id: "physical", time: 15, now: date.addingTimeInterval(15))).coordinate)
        let atStop = try XCTUnwrap(motion.pose(id: "physical", time: 20, now: date.addingTimeInterval(20)))
        XCTAssertLessThan(atStop.coordinate.distance(to: point(50)), 0.01)
        XCTAssertEqual(atStop.coordinate, try XCTUnwrap(motion.pose(id: "physical", time: 60, now: date.addingTimeInterval(60))).coordinate)
        XCTAssertFalse(motion.isAnimating(time: 60, now: date.addingTimeInterval(60)))
    }

    func testUnmatchedButAcceptedGPSPointsMoveSmoothlyWithoutClaimingARoadOrExtrapolating() throws {
        var motion = VehicleMotion()
        motion.ingest([bus(0, 0, at: 0, aligned: false)], time: 0, now: date)
        motion.ingest([bus(0, 25, at: 5, aligned: false)], time: 5, now: date.addingTimeInterval(5))
        let mid = try XCTUnwrap(motion.pose(id: "physical", time: 7.5, now: date.addingTimeInterval(7.5)))
        XCTAssertGreaterThan(mid.coordinate.longitude, point(0).longitude)
        XCTAssertLessThan(mid.coordinate.longitude, point(25).longitude)
        let end = try XCTUnwrap(motion.pose(id: "physical", time: 10, now: date.addingTimeInterval(10)))
        XCTAssertEqual(end.coordinate, try XCTUnwrap(motion.pose(id: "physical", time: 100, now: date.addingTimeInterval(100))).coordinate)
    }

    func testBurstBacklogIsBoundedWhilePositionAndWheelsRemainContinuous() throws {
        var motion = VehicleMotion()
        motion.ingest([bus(0, 0, at: 0)], time: 0, now: date)
        for step in 1...5 {
            let time = Double(step), observation = Double(step * 10)
            let before = try XCTUnwrap(motion.pose(id: "physical", time: time, now: date.addingTimeInterval(observation)))
            motion.ingest([bus(Double((step - 1) * 50), Double(step * 50), at: observation)], time: time, now: date.addingTimeInterval(observation))
            let after = try XCTUnwrap(motion.pose(id: "physical", time: time, now: date.addingTimeInterval(observation)))
            XCTAssertLessThan(before.coordinate.distance(to: after.coordinate), 0.001)
            XCTAssertEqual(before.traveledDistance, after.traveledDistance, accuracy: 0.001)
        }
        XCTAssertFalse(motion.isAnimating(time: 25, now: date.addingTimeInterval(50)))
        XCTAssertLessThan(try XCTUnwrap(motion.pose(id: "physical", time: 25, now: date.addingTimeInterval(50))).coordinate.distance(to: point(250)), 0.01)
    }

    func testRecordedOfficialFiveSecondFeedReplaysWithoutPacketJumpsOrFuturePositions() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ContinuousGPS", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rawMetadata = try XCTUnwrap(object["metadata"] as? [String: Any])
        let feeds = try rawMetadata.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        let metadata = try FeedDecoder.metadata(feeds: feeds)
        var previous: [BusVehicle] = [], motion = VehicleMotion(), origin: Date?, checked = 0, movingFrames = 0
        for entry in try XCTUnwrap(object["snapshots"] as? [[String: Any]]) {
            let bytes = try JSONSerialization.data(withJSONObject: entry["vehicles"]!)
            let now = try XCTUnwrap(FeedDecoder.rows(bytes).1)
            if origin == nil { origin = now }
            let time = now.timeIntervalSince(origin!)
            let vehicles = try FeedDecoder.vehicles(bytes, metadata: metadata, previous: previous, now: now).vehicles
            let prior = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let before = Dictionary(uniqueKeysWithValues: motion.poses(time: time, now: now).map { ($0.id, $0) })
            motion.ingest(vehicles, time: time, now: now)
            for bus in vehicles {
                guard let old = prior[bus.id], let before = before[bus.id],
                      old.routeID == bus.routeID, old.direction == bus.direction,
                      old.hasReliablePosition(at: now), bus.hasReliablePosition(at: now),
                      bus.path.count >= 2, bus.path.first!.distance(to: old.coordinate) < 2 else { continue }
                let after = try XCTUnwrap(motion.pose(id: bus.id, time: time, now: now))
                XCTAssertLessThan(before.coordinate.distance(to: after.coordinate), 0.001, bus.plate)
                XCTAssertEqual(before.traveledDistance, after.traveledDistance, accuracy: 0.001)
                checked += 1
                var last = after
                for frame in 1...240 {
                    let pose = try XCTUnwrap(motion.pose(id: bus.id, time: time + Double(frame) / 60, now: now))
                    if last.coordinate.distance(to: pose.coordinate) > 0.001 { movingFrames += 1 }
                    XCTAssertLessThan(last.coordinate.distance(to: pose.coordinate), 2, "A real GPS packet must not create a visible position jump")
                    XCTAssertLessThanOrEqual(pose.observedAt, bus.observedAt)
                    if let line = metadata.line(bus.routeID, direction: bus.direction), bus.aligned {
                        XCTAssertLessThan(try XCTUnwrap(line.match(pose.coordinate, heading: nil)).distance, 0.1, bus.plate)
                    }
                    last = pose
                }
            }
            previous = vehicles
        }
        XCTAssertGreaterThan(checked, 10); XCTAssertGreaterThan(movingFrames, 2_000)
        print("Recorded GPS playback: \(checked) continuous packet joins, \(movingFrames) moving frames on published road geometry.")
    }
}
