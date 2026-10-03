import Foundation
import XCTest
@testable import TransitCore

final class LiveSettingsTests: XCTestCase {
    private func document(_ revision: Int = 1, extra: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["schemaVersion": 1, "revision": revision, "minimumAppVersion": "0.4.2"]
        value.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testPartialContentKeepsShippedDefaultsAndUpdatesOnlyRequestedValues() throws {
        let value = try LiveSettings.decode(document(extra: ["copy": ["搜尋目的地": "想去哪裡"], "appearance": ["accentColor": "#A83B80"]]), appVersion: "0.4.2")
        XCTAssertEqual(value.text("搜尋目的地"), "想去哪裡")
        XCTAssertEqual(value.text("不在更新中的文字"), "不在更新中的文字")
        XCTAssertEqual(value.appearance.accentColor, "#A83B80")
        XCTAssertEqual(value.appearance.walkingColor, LiveSettings.defaults.appearance.walkingColor)
        XCTAssertEqual(value.planning, LiveSettings.defaults.planning)
    }
    func testInvalidFutureOrExecutablePayloadsDoNotBecomeLiveSettings() throws {
        for extra: [String: Any] in [
            ["schemaVersion": 2], ["revision": -1], ["minimumAppVersion": "0.5.0"],
            ["script": "arbitrary downloaded code"], ["appearance": ["unknownSetting": true]],
            ["appearance": ["accentColor": "#BAD"]], ["appearance": ["textScale": 10]],
            ["planning": ["firstWalkMeters": 1_100]], ["refresh": ["vehicleSeconds": 1]],
            ["copy": ["empty": ""]], ["display": ["nearbyStops": "yes"]]
        ] {
            XCTAssertThrowsError(try LiveSettings.decode(document(extra: extra), appVersion: "0.4.2"), "\(extra)")
        }
        XCTAssertThrowsError(try LiveSettings.decode(Data(repeating: 32, count: 131_073), appVersion: "0.4.2"))
    }
    func testAppVersionComparisonDoesNotUseAlphabeticalOrder() throws {
        let value = try LiveSettings.decode(document(extra: ["minimumAppVersion": "0.4.10"]), appVersion: "0.4.11")
        XCTAssertTrue(value.supports(appVersion: "0.5.0"))
        XCTAssertFalse(value.supports(appVersion: "0.4.9"))
    }
    func testDownloadedAliasUpdatesExistingIndexAndPreservesPhysicalPlatforms() throws {
        let point = Coordinate(latitude: 25.083, longitude: 121.594)
        var north = Station(id: "north", name: "捷運內湖站", coordinate: point, address: "成功路北側", bearing: "N", stopIDs: [])
        north.searchNames = ["MRT Neihu Sta."]
        let south = Station(id: "south", name: "捷運內湖站", coordinate: Coordinate(latitude: 25.0829, longitude: 121.594), address: "成功路南側", bearing: "S", stopIDs: [])
        let hospital = Station(id: "hospital", name: "三總內湖站", coordinate: point, address: "成功路", bearing: "", stopIDs: [])
        let index = StationSearchIndex(stations: [north, south, hospital])
        XCTAssertTrue(index.search("湖捷", near: point).isEmpty)
        let aliases = [["names": ["湖捷", "內湖捷運站"], "queries": ["捷運內湖站"]]]
        let value = try LiveSettings.decode(document(extra: ["search": ["aliases": aliases]]), appVersion: "0.4.2")
        let vocabulary = SearchVocabulary(aliases: value.search.aliases)
        let updated = index.search("湖捷", near: point, vocabulary: vocabulary)
        XCTAssertEqual(Set(updated.map(\.id)), Set(["north", "south"]))
        XCTAssertEqual(StationSearch.placeQueries("湖捷", vocabulary: vocabulary).first, "捷運內湖站")
        XCTAssertEqual(updated.first?.address, "成功路北側")
        XCTAssertEqual(index.search("Neihu Station", near: point).first?.id, "north")
        XCTAssertEqual(index.search("我要去內湖捷運站", near: point).first?.id, "north")
        XCTAssertEqual(index.search("內胡站", near: point).first?.id, "north")
        XCTAssertFalse(index.search("內", near: point).isEmpty)
        XCTAssertTrue(index.search("完全不存在的地方", near: point).isEmpty)
    }
    func testDuplicateRecentsCannotCrashStationSearch() {
        let station = Station(id: "one", name: "捷運內湖站", coordinate: .taipei, address: "", bearing: "", stopIDs: [])
        XCTAssertEqual(StationSearchIndex(stations: [station]).search("", near: .taipei, recent: ["one", "one"]).count, 1)
    }
    func testValidUpdateSurvivesNetworkFailuresAndRejectsOlderResponses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsProtocol.self]
        let session = URLSession(configuration: config)
        let url = URL(string: "https://settings.test/content.json")!
        let service = LiveSettingsService(url: url, appVersion: "0.4.2", cacheDirectory: directory, session: session)
        SettingsProtocol.set(document: try document(), status: 200)
        let first = await service.refresh(current: .defaults)
        XCTAssertEqual(first?.settings.revision, 1)
        let firstValue = try XCTUnwrap(first?.settings)
        SettingsProtocol.set(document: try document(2, extra: ["copy": ["搜尋目的地": "想去哪裡"]]), status: 200)
        let second = await service.refresh(current: firstValue)
        let good = try XCTUnwrap(second?.settings)
        XCTAssertEqual(good.text("搜尋目的地"), "想去哪裡")
        SettingsProtocol.set(document: try document(3, extra: ["appearance": ["textScale": 9]]), status: 200)
        let invalid = await service.refresh(current: good)
        XCTAssertNil(invalid)
        SettingsProtocol.set(document: try document(), status: 200)
        let older = await service.refresh(current: good)
        XCTAssertNil(older)
        SettingsProtocol.set(document: try document(4), status: 503)
        let unavailable = await service.refresh(current: good)
        XCTAssertNil(unavailable)
        let restarted = LiveSettingsService(url: url, appVersion: "0.4.2", cacheDirectory: directory, session: session)
        let cached = await restarted.cached()
        XCTAssertEqual(cached?.settings.revision, 2)
        XCTAssertEqual(cached?.settings.text("搜尋目的地"), "想去哪裡")
    }
    func testBrokenCacheDoesNotBlockShippedDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("last-good-settings.json"))
        let service = LiveSettingsService(appVersion: "0.4.2", cacheDirectory: directory)
        let value = await service.cached()
        XCTAssertNil(value)
        XCTAssertEqual(LiveSettings.defaults.text("搜尋目的地"), "搜尋目的地")
    }
}

private final class SettingsProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var document = Data()
    private static var status = 200
    static func set(document: Data, status: Int) {
        lock.lock(); defer { lock.unlock() }
        Self.document = document; Self.status = status
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let data = Self.document, status = Self.status
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
