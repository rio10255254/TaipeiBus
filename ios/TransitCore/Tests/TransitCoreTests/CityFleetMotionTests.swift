import XCTest
@testable import TransitCore

final class CityFleetMotionTests: XCTestCase {
    func testLargeFleetKeepsEveryIdentityAndNeverMovesBeyondReceivedPositions() throws {
        let start = FeedDecoder.taipeiDate("2026/10/02 10:15:00")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var metadata = TransitMetadata()
        for row in 0..<50 {
            let latitude = 25.02 + Double(row) * 0.001
            metadata.lines["route:CITY-\(row)"] = RouteLine(coordinates: [
                Coordinate(latitude: latitude, longitude: 121.44), Coordinate(latitude: latitude, longitude: 121.56)])
        }
        func feed(at date: Date, offset: Double) throws -> Data {
            let time = formatter.string(from: date)
            let rows: [[String: Any]] = (0..<2500).map { i in
                ["BusID": "CITY-\(i)", "CarID": "CITY-\(i)", "RouteID": "CITY-\(i / 50)", "GoBack": "0", "DutyStatus": "1",
                 "Latitude": 25.02 + Double(i / 50) * 0.001, "Longitude": 121.45 + Double(i % 50) * 0.002 + offset,
                 "Speed": 10, "Azimuth": 90, "DataTime": time]
            }
            return try JSONSerialization.data(withJSONObject: ["EssentialInfo": ["UpdateTime": time], "BusInfo": rows])
        }
        let a = try FeedDecoder.vehicles(feed(at: start, offset: 0), metadata: metadata, previous: [], now: start).vehicles
        let end = start.addingTimeInterval(15)
        let b = try FeedDecoder.vehicles(feed(at: end, offset: 0.0003), metadata: metadata, previous: a, now: end).vehicles
        XCTAssertEqual(a.count, 2500); XCTAssertEqual(b.count, 2500)
        var motion = VehicleMotion()
        motion.ingest(a, time: 0, now: start); motion.ingest(b, time: 15, now: end)
        let halfway = motion.poses(time: 22.5, now: end)
        XCTAssertTrue(motion.isAnimating(time: 22.5, now: end))
        XCTAssertEqual(Set(halfway.map(\.id)).count, 2500)
        let previous = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0.coordinate) })
        let expected = Dictionary(uniqueKeysWithValues: b.map { ($0.id, $0.coordinate) })
        for pose in halfway {
            XCTAssertGreaterThan(pose.coordinate.longitude, previous[pose.id]!.longitude)
            XCTAssertLessThan(pose.coordinate.longitude, expected[pose.id]!.longitude)
        }
        XCTAssertFalse(motion.isAnimating(time: 30, now: end))
        for pose in motion.poses(time: 30, now: end) {
            XCTAssertLessThan(pose.coordinate.distance(to: expected[pose.id]!), 0.01, "Replay the received movement over its actual GPS interval")
        }
        for pose in motion.poses(time: 100, now: end.addingTimeInterval(60)) {
            XCTAssertLessThan(pose.coordinate.distance(to: expected[pose.id]!), 0.01)
        }
        let stale = motion.poses(time: 300, now: end.addingTimeInterval(180))
        XCTAssertEqual(stale.count, 2500); XCTAssertTrue(stale.allSatisfy(\.stale))
        for pose in stale { XCTAssertLessThan(pose.coordinate.distance(to: expected[pose.id]!), 0.01) }
    }
}
