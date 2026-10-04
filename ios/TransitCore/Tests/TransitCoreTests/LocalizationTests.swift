import XCTest
@testable import TransitCore

final class LocalizationTests: XCTestCase {
    private func withEnglish(_ operation: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: AppLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        try operation()
    }
    func testDeviceDefaultsAndFormattingPreserveUserInput() {
        XCTAssertEqual(AppLanguage.deviceDefault(["en-US", "zh-Hant"]), .english)
        XCTAssertEqual(AppLanguage.deviceDefault(["zh-Hant-TW"]), .traditionalChinese)
        XCTAssertEqual(AppText.text("搜尋「%@」", "100% %@ Neihu", language: .english), "Search for “100% %@ Neihu”")
        XCTAssertEqual(AppText.remainingStops(1, language: .english), "1 stop left")
        XCTAssertEqual(AppText.remainingStops(4, language: .english), "4 stops left")
    }
    func testEveryEnglishTemplateKeepsItsArgumentsAndContainsNoChineseUI() {
        XCTAssertGreaterThan(AppText.english.count, 350)
        for (key, value) in AppText.english {
            XCTAssertEqual(key.components(separatedBy: "%@").count, value.components(separatedBy: "%@").count, key)
            XCTAssertNil(value.range(of: "[\\p{Han}]", options: .regularExpression), key)
        }
    }
    func testEnglishNamesKeepChineseIdentityAndSearchAliases() throws {
        try withEnglish {
            var stop = BusStop(id: "a", routeID: "r", stationID: "s", name: "捷運內湖站", direction: "0", sequence: 1, coordinate: .taipei)
            stop.englishName = "MRT Neihu Sta."
            XCTAssertEqual(stop.localizedName, "MRT Neihu Sta.")
            XCTAssertEqual(stop.bilingualName, "MRT Neihu Sta.\n捷運內湖站")
            XCTAssertEqual(stop.id, "a"); XCTAssertEqual(stop.name, "捷運內湖站")
            var station = Station(id: "s", name: stop.name, coordinate: .taipei, address: "", bearing: "E", stopIDs: ["a"])
            station.englishName = stop.englishName; station.searchNames = StationSearch.englishNames(stop.englishName)
            let index = StationSearchIndex(stations: [station])
            XCTAssertEqual(index.search("Neihu Station", near: .taipei).first?.id, "s")
            XCTAssertEqual(index.search("Neihu", near: .taipei).first?.id, "s")
            XCTAssertEqual(station.localizedBearing, "Eastbound")
        }
    }
    func testOfficialTimesAndRemainingTripTimeTranslateWithoutChangingNumbers() throws {
        try withEnglish {
            XCTAssertEqual(EstimateFeed.label(125), "2 min")
            XCTAssertEqual(EstimateFeed.label(30), "≤1 min")
            XCTAssertEqual(EstimateFeed.label(-4), "No service today")
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-04T04:00:00Z"))
            let duration = JourneyDuration(riding: [600], walking: [60, 60], arrivals: [300], at: date)
            XCTAssertEqual(duration.summaryLabel(), "Total ~16 min")
            XCTAssertEqual(duration.summaryLabel(remaining: true), "Remaining ~16 min")
            XCTAssertEqual(duration.waitingLabel, "Wait ~4 min")
            XCTAssertEqual(duration.arrivalLabel, "Arrive ~12:16")
            let unknown = JourneyDuration(riding: [600], walking: [60, 60], arrivals: [nil], at: date)
            XCTAssertEqual(unknown.arrivalLabel, "Arrival unconfirmed")
        }
    }
    func testEnglishCopyAndEndpointsAreIndependentFromChineseSettings() throws {
        var settings = LiveSettings(); settings.language = .english
        settings.copy = ["搜尋目的地": "你想去哪裡", "en:搜尋目的地": "Destination"]
        XCTAssertEqual(settings.text("搜尋目的地"), "Destination")
        settings.language = .traditionalChinese
        XCTAssertEqual(settings.text("搜尋目的地"), "你想去哪裡")
        let bytes = try JSONEncoder().encode(settings)
        XCTAssertNil((try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["language"])
        var route = BusRoute(id: "1", parentID: "1", name: "藍27", variantName: "", departure: "內湖", destination: "市政府")
        route.englishName = "Blue27"; route.englishDeparture = "Neihu"; route.englishDestination = "Taipei City Hall"
        XCTAssertEqual(RouteCatalog(routes: [route]).search("Taipei City Hall").first?.route.id, "1")
    }
}
