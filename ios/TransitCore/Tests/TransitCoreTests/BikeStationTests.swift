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
        // Both cities' stations, which never share a number (Taipei's 5001…, New Taipei's 5002…).
        XCTAssertTrue(network.stations.allSatisfy { $0.district.hasSuffix("區") })
        XCTAssertGreaterThan(network.stations.filter { $0.id.hasPrefix("5001") }.count, 1_200)
        XCTAssertGreaterThan(network.stations.filter { $0.id.hasPrefix("5002") }.count, 1_000)
        XCTAssertNotNil(network.stations.first { $0.district == "板橋區" })
    }

    func testNewTaipeiCountsReadAlongsideTaipeisAsOneSnapshot() throws {
        let now = FeedDecoder.taipeiDate("2026/10/29 00:39:00")!
        let network = BikeNetwork(stations: sampleNetwork().stations + [
            BikeStation(id: "500201001", name: "下庄市場", district: "八里區", coordinate: Coordinate(latitude: 25.14678, longitude: 121.3999), capacity: 20)])
        // New Taipei's own field names and compact time, as published.
        let newTaipei = try BikeAvailability(data: feed([
            ["sno": "500201001", "sna": "YouBike2.0_下庄市場", "tot_quantity": "20", "sbi_quantity": "11", "bemp": "9",
             "mday": "20261029T003403", "lat": "25.14678", "lng": "121.3999", "act": "1"],
            ["sno": "500201001x", "sbi_quantity": "1", "bemp": "1", "mday": "20261029T003403"],
            ["sno": "500101002", "sbi_quantity": "2", "bemp": "3", "mday": "2026-10-29T003403"]]), network: network, at: now)
        let dock = try XCTUnwrap(newTaipei.dock("500201001"))
        XCTAssertEqual(dock.rentable, 11); XCTAssertEqual(dock.returnable, 9); XCTAssertEqual(dock.capacity, 20)
        XCTAssertEqual(dock.observedAt, FeedDecoder.taipeiDate("2026/10/29 00:34:03"))
        XCTAssertTrue(dock.active)
        XCTAssertNil(newTaipei.dock("500101002"), "a stamp that is neither shape is not read as a time")
        let taipei = try BikeAvailability(data: feed([["sno": "500101001", "available_rent_bikes": 5, "available_return_bikes": 23,
            "Quantity": 28, "act": "1", "infoTime": "2026-10-29 00:38:04"]]), network: network, at: now.addingTimeInterval(-30))
        let both = try XCTUnwrap(BikeAvailability.combining([taipei, newTaipei]))
        XCTAssertEqual(Set(both.docks.keys), ["500101001", "500201001"])
        XCTAssertEqual(both.receivedAt, now, "the newer city's receipt marks the change")
        XCTAssertEqual(BikeAvailability.combining([taipei]), taipei)
        XCTAssertNil(BikeAvailability.combining([]))
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
    func testCityPublicationCannotReviveAnOldStationReport() throws {
        let now=Date(), network=sampleNetwork()
        let bytes=try feed([["sno":"500101001","available_rent_bikes":8,"available_return_bikes":8,
            "infoTime":stamp(now.addingTimeInterval(-1800)),"srcUpdateTime":stamp(now),"updateTime":stamp(now)]])
        let packet=try BikeAvailability(data:bytes,network:network,at:now)
        let dock=try XCTUnwrap(packet.dock("500101001"))
        XCTAssertFalse(dock.isFresh(at:now))
        XCTAssertEqual(BikeSupply.level(dock,at:now),.unknown)
    }
    func testWholeCityCountsDecodePromptlyWithRepeatedAndFallbackTimestamps() throws {
        let now=Date(), network=try bundledNetwork(), old=stamp(now.addingTimeInterval(-60)), current=stamp(now)
        let rows=network.stations.enumerated().map { index,station -> [String:Any] in
            ["sno":station.id,"available_rent_bikes":8,"available_return_bikes":8,
             "infoTime":index % 2 == 0 ? old : "unavailable","srcUpdateTime":current,"updateTime":current,"mday":"bad"]
        }
        let bytes=try feed(rows), started=ProcessInfo.processInfo.systemUptime
        let packet=try BikeAvailability(data:bytes,network:network,at:now)
        let elapsed=ProcessInfo.processInfo.systemUptime-started
        XCTAssertEqual(packet.docks.count,network.stations.count)
        XCTAssertEqual(packet.dock(network.stations[0].id)?.observedAt,FeedDecoder.taipeiDate(old))
        XCTAssertEqual(packet.dock(network.stations[1].id)?.observedAt,FeedDecoder.taipeiDate(current))
        XCTAssertLessThan(elapsed,2,"A whole-city report must not spend seconds re-parsing duplicate timestamps")
        print("BIKE_CITY_DECODE stations=\(network.stations.count) seconds=\(elapsed)")
    }
}
