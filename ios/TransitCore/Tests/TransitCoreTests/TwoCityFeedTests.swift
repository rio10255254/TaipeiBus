import XCTest
@testable import TransitCore

/// Taipei's and New Taipei's bus files read together.
final class TwoCityFeedTests: XCTestCase {
    private func feed(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["EssentialInfo": ["UpdateTime": "2026/10/02 10:15:30"], "BusInfo": rows])
    }
    private func city(route: Int, path: Int, name: String, stops: [(id: Int, location: Int, name: String, longitude: Double)]) throws -> [String: Data] {
        [
            "GetRoute": try feed([["Id": route, "pathAttributeId": path, "nameZh": name, "departureZh": "起點", "destinationZh": "終點"]]),
            "GetStop": try feed(stops.enumerated().map { index, stop in
                ["Id": stop.id, "routeId": route, "stopLocationId": stop.location, "nameZh": stop.name, "nameEn": "", "goBack": "0",
                 "seqNo": index + 1, "longitude": stop.longitude, "latitude": 25.04] }),
            "GetPathDetail": try feed(stops.enumerated().map { ["pathAttributeId": path, "stopId": $0.element.id, "sequenceNo": $0.offset + 1, "type": "0"] }),
            "GetProvider": try feed([["id": route * 10, "nameZn": name + "客運"]])
        ]
    }

    func testAStopLocationBothCitiesServeIsOneStationWithBothRoutes() throws {
        let taipei = try city(route: 100, path: 10, name: "307", stops: [(101, 5000, "西門", 121.508), (102, 5001, "台北車站", 121.517)])
        let newTaipei = try city(route: 200, path: 20, name: "99", stops: [(201, 5001, "臺北車站", 121.5171), (202, 6000, "板橋", 121.46)])
        let metadata = try FeedDecoder.metadata(sources: [taipei, newTaipei])
        XCTAssertEqual(Set(metadata.routes.keys), ["10", "20"])
        // The shared location keeps Taipei's name and position and lists both cities' stops.
        let shared = try XCTUnwrap(metadata.stations["5001"])
        XCTAssertEqual(shared.name, "台北車站")
        XCTAssertEqual(shared.coordinate.longitude, 121.517)
        XCTAssertEqual(shared.stopIDs, ["102", "201"])
        XCTAssertTrue(shared.searchNames.contains("臺北車站"), "New Taipei's spelling still finds the station")
        XCTAssertEqual(metadata.stations["6000"]?.stopIDs, ["202"])
        XCTAssertEqual(metadata.orderedStops(routeID: "20", direction: "0").map(\.stationID), ["5001", "6000"])
        XCTAssertEqual(Set(metadata.providers.values), ["307客運", "99客運"])
        XCTAssertEqual(Set(metadata.routeCatalog.groups.map(\.route.name)), ["307", "99"])
        XCTAssertFalse(metadata.stationSearch.search("板橋", near: .taipei).isEmpty)
        // Live rows from either city's files find their stop.
        let estimates = EstimateFeed(seconds: ["100:102": 300, "200:201": 120], updatedAt: Date())
        let rows = StationArrival.rows(station: shared, metadata: metadata, snapshot: TransitSnapshot(estimates: estimates), now: Date())
        XCTAssertEqual(rows.map(\.stop.routeID), ["200", "100"])
    }

    func testALaterCityNeverReplacesAnIdAndAnUnreadableOneIsLeftOut() throws {
        let taipei = try city(route: 100, path: 10, name: "307", stops: [(101, 5000, "西門", 121.508)])
        // Should the numbering ever overlap, the first city's route and stop stay as they were.
        let clash = try city(route: 100, path: 10, name: "冒名", stops: [(101, 5000, "冒名站", 121.6), (301, 7000, "新站", 121.47)])
        let merged = try FeedDecoder.metadata(sources: [taipei, clash])
        XCTAssertEqual(merged.routes["10"]?.name, "307")
        XCTAssertEqual(merged.stops["101"]?.name, "西門")
        XCTAssertEqual(merged.stations["5000"]?.stopIDs, ["101"])
        XCTAssertEqual(merged.stations["7000"]?.stopIDs, ["301"])
        // A second city without readable routes is skipped whole; without the first, nothing works.
        var broken = try city(route: 200, path: 20, name: "99", stops: [(201, 6000, "板橋", 121.46)])
        broken["GetRoute"] = Data("[]".utf8)
        let partial = try FeedDecoder.metadata(sources: [taipei, broken])
        XCTAssertEqual(Set(partial.routes.keys), ["10"])
        XCTAssertNil(partial.stops["201"]); XCTAssertNil(partial.stations["6000"]); XCTAssertNil(partial.providers["2000"])
        XCTAssertThrowsError(try FeedDecoder.metadata(sources: [broken, taipei]))
        // One source reads exactly as before.
        let single = try FeedDecoder.metadata(feeds: taipei)
        XCTAssertEqual(Set(single.stops.keys), Set(try FeedDecoder.metadata(sources: [taipei]).stops.keys))
    }

    func testEachCitysTravelTimesApplyToItsOwnRoutesOnceCombined() throws {
        func catalog(route: String, generated: String, seconds: Int) throws -> OfficialTravelTimes {
            try OfficialTravelTimes(data: JSONSerialization.data(withJSONObject: ["schema": 1, "generatedAt": generated, "routes": [
                ["route": route, "subroute": route + "0", "direction": "0", "updated": "2026-10-28T05:00:00+08:00",
                 "edges": [["a", "b"]], "periods": [["weekday": 4, "startHour": 9, "endHour": 10, "seconds": [seconds]]]]]]))
        }
        let taipei = try catalog(route: "100", generated: "2026-10-28T00:00:00Z", seconds: 90)
        let newTaipei = try catalog(route: "200", generated: "2026-10-29T00:00:00Z", seconds: 150)
        let both = OfficialTravelTimes.combining([taipei, newTaipei])
        let at = FeedDecoder.taipeiDate("2026/10/29 09:20:00")!
        XCTAssertEqual(both.patternCount, 2)
        XCTAssertEqual(both.seconds(route: "100", subroute: "1000", direction: "0", from: "a", to: "b", travellingAt: at, observedAt: at), 90)
        XCTAssertEqual(both.seconds(route: "200", subroute: "2000", direction: "0", from: "a", to: "b", travellingAt: at, observedAt: at), 150)
        XCTAssertNil(both.seconds(route: "100", subroute: "2000", direction: "0", from: "a", to: "b", travellingAt: at, observedAt: at))
        XCTAssertEqual(both.generatedAt, newTaipei.generatedAt)
        XCTAssertEqual(OfficialTravelTimes.combining([taipei]).patternCount, 1)
        XCTAssertEqual(OfficialTravelTimes.combining([]).patternCount, 0)
    }

    func testEstimatesFromTwoCitiesCountDownFromOneTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let taipei = EstimateFeed(seconds: ["1:a": 300, "1:b": -3], updatedAt: now)
        let newTaipei = EstimateFeed(seconds: ["2:c": 300, "2:d": 10, "2:e": -1], updatedAt: now.addingTimeInterval(-25))
        let combined = EstimateFeed.combining([taipei, newTaipei])
        XCTAssertEqual(combined.updatedAt, now)
        // New Taipei's file is 25 s older, so its 300 s is 275 s from Taipei's time; statuses stay statuses.
        XCTAssertEqual(combined.value(routeID: "2", stopID: "c", at: now.addingTimeInterval(5)), 270)
        XCTAssertEqual(combined.value(routeID: "1", stopID: "a", at: now.addingTimeInterval(5)), 295)
        XCTAssertEqual(combined.value(routeID: "2", stopID: "d", at: now), 0)
        XCTAssertEqual(combined.value(routeID: "2", stopID: "e", at: now), -1)
        XCTAssertEqual(combined.value(routeID: "1", stopID: "b", at: now), -3)
        // A city whose file stopped updating, or failed, drops out instead of showing stale countdowns.
        let stale = EstimateFeed(seconds: ["2:c": 300], updatedAt: now.addingTimeInterval(-200))
        XCTAssertNil(EstimateFeed.combining([taipei, stale]).value(routeID: "2", stopID: "c", at: now))
        var failed = newTaipei; failed.error = "到站預估來源連線中斷"
        let partial = EstimateFeed.combining([taipei, failed])
        XCTAssertNil(partial.error)
        XCTAssertNil(partial.value(routeID: "2", stopID: "c", at: now))
        XCTAssertEqual(partial.value(routeID: "1", stopID: "a", at: now), 300)
        // Only when every city fails does the feed fail, as a single city's does.
        var down = taipei; down.error = "到站預估來源連線中斷"
        XCTAssertEqual(EstimateFeed.combining([down, failed]).error, down.error)
        XCTAssertEqual(EstimateFeed.combining([down]).error, down.error)
        XCTAssertEqual(EstimateFeed.combining([taipei]).seconds, taipei.seconds)
        XCTAssertNil(EstimateFeed.combining([]).updatedAt)
    }
}
