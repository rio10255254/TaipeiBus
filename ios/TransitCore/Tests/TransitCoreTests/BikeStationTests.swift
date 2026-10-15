import XCTest
@testable import TransitCore

final class BikeStationTests: XCTestCase {
    private func bundledNetwork() throws -> BikeNetwork {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TaipeiBus")
        return try BikeNetwork(data: Data(contentsOf: root.appendingPathComponent("BikeNetwork.json")))
    }
    private func sampleNetwork() -> BikeNetwork {
        BikeNetwork(schema: 1, generatedAt: "2026-10-15T00:00:00Z", source: "test", stations: [
            BikeStation(id: "500101001", name: "捷運科技大樓站", englishName: "MRT Technology Bldg. Sta.",
                        district: "大安區", englishDistrict: "Daan Dist.", address: "復興南路二段235號前",
                        coordinate: Coordinate(latitude: 25.02605, longitude: 121.5436), capacity: 28),
            BikeStation(id: "500101002", name: "復興南路二段273號前", district: "大安區",
                        coordinate: Coordinate(latitude: 25.02465, longitude: 121.54366), capacity: 21),
            BikeStation(id: "500109007", name: "關渡宮", englishName: "Guandu Temple", district: "北投區",
                        coordinate: Coordinate(latitude: 25.11739, longitude: 121.46288), capacity: 62),
        ])
    }
    private func feed(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows)
    }
    private let taipei: TimeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = taipei
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    func testBundledStationsAreUniqueNamedAndInsideTheServiceArea() throws {
        let network = try bundledNetwork()
        XCTAssertGreaterThan(network.stations.count, 1_200)
        XCTAssertEqual(Set(network.stations.map(\.id)).count, network.stations.count)
        for station in network.stations {
            XCTAssertTrue(station.coordinate.isInServiceArea, station.id)
            XCTAssertFalse(station.name.isEmpty, station.id)
            // The operator's "YouBike2.0_" prefix is stripped when the list is built.
            XCTAssertFalse(station.name.hasPrefix("YouBike"), station.name)
            XCTAssertGreaterThan(station.capacity, 0, station.id)
            XCTAssertLessThanOrEqual(station.capacity, 200, station.id)
        }
        // Every station is in Taipei City; New Taipei is not part of this list yet.
        XCTAssertTrue(network.stations.allSatisfy { $0.district.hasSuffix("區") })
    }

    func testMalformedStationFilesAreRejectedInsteadOfPartlyLoaded() throws {
        func network(_ json: String) throws -> BikeNetwork { try BikeNetwork(data: Data(json.utf8)) }
        let station = """
        {"id":"1","name":"測試站","englishName":"","district":"","englishDistrict":"","address":"","englishAddress":"",\
        "coordinate":{"latitude":25.03,"longitude":121.55},"capacity":20}
        """
        XCTAssertNoThrow(try network("{\"schema\":1,\"generatedAt\":\"\",\"source\":\"\",\"stations\":[\(station)]}"))
        XCTAssertThrowsError(try network("{\"schema\":2,\"generatedAt\":\"\",\"source\":\"\",\"stations\":[\(station)]}"))
        XCTAssertThrowsError(try network("{\"schema\":1,\"generatedAt\":\"\",\"source\":\"\",\"stations\":[]}"))
        XCTAssertThrowsError(try network("{\"schema\":1,\"generatedAt\":\"\",\"source\":\"\",\"stations\":[\(station),\(station)]}"))
        let faraway = station.replacingOccurrences(of: "\"latitude\":25.03", with: "\"latitude\":22.63")
        XCTAssertThrowsError(try network("{\"schema\":1,\"generatedAt\":\"\",\"source\":\"\",\"stations\":[\(faraway)]}"))
        XCTAssertThrowsError(try network("[]"))
    }

    func testNearbyLookupKeepsOrderAndRespectsRadiusAndLimit() {
        let network = sampleNetwork()
        let point = Coordinate(latitude: 25.0261, longitude: 121.5437)
        let near = network.stations(near: point, radius: 400)
        XCTAssertEqual(near.map(\.id), ["500101001", "500101002"])
        XCTAssertEqual(network.stations(near: point, radius: 400, limit: 1).map(\.id), ["500101001"])
        XCTAssertEqual(network.stations(near: point, radius: 60).map(\.id), ["500101001"])
        // Guandu is kilometres away and never appears for a Daan query.
        XCTAssertTrue(network.stations(near: point, radius: 1_000).allSatisfy { $0.id != "500109007" })
        XCTAssertEqual(network.station("500109007")?.name, "關渡宮")
        XCTAssertNil(network.station("nope"))
        XCTAssertEqual(BikeNetwork.empty.stations(near: point, radius: 400).count, 0)
    }

    func testLiveCountsAreReadFromTheOfficialShapeAndDoubtfulRowsDropped() throws {
        let network = sampleNetwork()
        let now = Date()
        let rows: [[String: Any]] = [
            ["sno": "500101001", "sna": "YouBike2.0_捷運科技大樓站", "available_rent_bikes": 12,
             "available_return_bikes": 16, "Quantity": 28, "act": "1", "infoTime": stamp(now.addingTimeInterval(-70)),
             "latitude": 25.02605, "longitude": 121.5436],
            // The same feed publishes some fields as text; both forms are accepted.
            ["sno": "500101002", "available_rent_bikes": "0", "available_return_bikes": "21",
             "Quantity": "21", "act": "0", "infoTime": stamp(now.addingTimeInterval(-120))],
            // A station this build does not know about, a row without counts, and a count
            // stamped in the future are all left out rather than shown as current.
            ["sno": "600000001", "available_rent_bikes": 5, "available_return_bikes": 5, "infoTime": stamp(now)],
            ["sno": "500109007", "act": "1", "infoTime": stamp(now)],
            ["sno": "500109007", "available_rent_bikes": 4, "available_return_bikes": 4,
             "infoTime": stamp(now.addingTimeInterval(3_600))],
        ]
        let availability = try BikeAvailability(data: feed(rows), network: network, at: now)
        XCTAssertEqual(availability.docks.count, 2)
        let first = try XCTUnwrap(availability.dock("500101001"))
        XCTAssertEqual(first.rentable, 12)
        XCTAssertEqual(first.returnable, 16)
        XCTAssertEqual(first.capacity, 28)
        XCTAssertTrue(first.active)
        XCTAssertTrue(first.isFresh(at: now))
        let suspended = try XCTUnwrap(availability.dock("500101002"))
        XCTAssertFalse(suspended.active)
        XCTAssertEqual(suspended.rentable, 0)
        XCTAssertNil(availability.dock("500109007"))
        XCTAssertNil(availability.dock("600000001"))
        XCTAssertThrowsError(try BikeAvailability(data: feed([]), network: network, at: now))
        XCTAssertThrowsError(try BikeAvailability(data: Data("not json".utf8), network: network, at: now))
        // Nothing recognizable in the file leaves the app on its last good counts.
        XCTAssertThrowsError(try BikeAvailability(data: feed([["sno": "600000001"]]), network: network, at: now))
    }

    func testSupplyLevelsSeparateStockedEmptyStaleAndSuspendedStations() {
        let now = Date()
        func dock(rentable: Int, returnable: Int = 10, active: Bool = true, age: TimeInterval = 60) -> BikeDock {
            BikeDock(stationID: "1", rentable: rentable, returnable: returnable, capacity: 20,
                     active: active, observedAt: now.addingTimeInterval(-age))
        }
        XCTAssertEqual(BikeSupply.level(dock(rentable: 12), at: now), .plenty)
        XCTAssertEqual(BikeSupply.level(dock(rentable: 3), at: now), .few)
        XCTAssertEqual(BikeSupply.level(dock(rentable: 0), at: now), .empty)
        XCTAssertEqual(BikeSupply.level(dock(rentable: 0, returnable: 20), at: now, returning: true), .plenty)
        XCTAssertEqual(BikeSupply.level(dock(rentable: 9, active: false), at: now), .suspended)
        XCTAssertEqual(BikeSupply.level(nil, at: now), .unknown)
        // A station that stopped reporting half an hour ago says nothing about now.
        XCTAssertEqual(BikeSupply.level(dock(rentable: 9, age: 1_800), at: now), .unknown)
        XCTAssertFalse(dock(rentable: 9, age: 1_800).isFresh(at: now))
        XCTAssertTrue(dock(rentable: 9, age: 240).isFresh(at: now))
    }
}
