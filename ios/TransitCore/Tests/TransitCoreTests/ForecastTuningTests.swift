import Foundation
import XCTest
@testable import TransitCore

final class ForecastTuningTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func tearDown() { ForecastTuning.current = ForecastTuning() }

    func testPublishedFileAndSchemaMatchTheApp() throws {
        let published = try Data(contentsOf: repository.appendingPathComponent("runtime/tuning.json"))
        XCTAssertNoThrow(try ForecastTuning.decode(published))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: repository.appendingPathComponent("runtime/tuning.schema.json"))) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(properties.keys), Set(ForecastTuning.fields.map(\.key) + ForecastTuning.tables.map(\.key) + ["schemaVersion", "note"]))
        let defaults = ForecastTuning()
        for field in ForecastTuning.fields {
            let rule = try XCTUnwrap(properties[field.key], field.key)
            XCTAssertEqual(rule["minimum"] as? Double, field.range.lowerBound, field.key)
            XCTAssertEqual(rule["maximum"] as? Double, field.range.upperBound, field.key)
            XCTAssertEqual(rule["default"] as? Double, defaults[keyPath: field.path], field.key)
        }
        for table in ForecastTuning.tables {
            let rule = try XCTUnwrap(properties[table.key], table.key)
            let items = try XCTUnwrap(rule["items"] as? [String: Any], table.key)
            XCTAssertEqual(rule["minItems"] as? Int, 24, table.key); XCTAssertEqual(rule["maxItems"] as? Int, 24, table.key)
            XCTAssertEqual(items["minimum"] as? Double, table.range.lowerBound, table.key)
            XCTAssertEqual(items["maximum"] as? Double, table.range.upperBound, table.key)
            // The shipped measurements must themselves be a valid remote file.
            XCTAssertEqual(defaults[keyPath: table.path].count, 24, table.key)
            XCTAssertTrue(defaults[keyPath: table.path].allSatisfy(table.range.contains), table.key)
        }
    }

    func testHourlyTablesReplaceTheShippedFactors() throws {
        let hours = (0..<24).map { $0 == 8 ? "1.2" : "1" }.joined(separator: ",")
        let value = try ForecastTuning.decode(Data(#"{"schemaVersion":1,"workdayPaceFactors":[\#(hours)],"rangeLateScale":2}"#.utf8))
        XCTAssertEqual(value.workdayPaceFactors[8], 1.2); XCTAssertEqual(value.workdayPaceFactors[9], 1)
        XCTAssertEqual(value.holidayPaceFactors, ForecastTuning().holidayPaceFactors)
        XCTAssertEqual(value.rangeLateScale, 2)
        // Tuesday 2027-01-12 08:30 and Saturday 2027-01-16 08:30 in Taipei; 2027-02-08 is a Lunar New Year holiday.
        let tuesday = Date(timeIntervalSince1970: 1_799_713_800), saturday = tuesday.addingTimeInterval(4 * 86_400)
        XCTAssertEqual(value.paceFactor(at: tuesday), 1.2)
        XCTAssertEqual(value.paceFactor(at: tuesday.addingTimeInterval(3_600)), 1)
        XCTAssertEqual(value.paceFactor(at: saturday), value.holidayPaceFactors[8])
        XCTAssertEqual(value.paceFactor(at: tuesday.addingTimeInterval(27 * 86_400)), value.holidayPaceFactors[8])
    }

    func testMalformedHourlyTableRejectsTheWholeFile() {
        let short = (0..<23).map { _ in "1" }.joined(separator: ",")
        let high = (0..<24).map { $0 == 3 ? "2" : "1" }.joined(separator: ",")
        let flag = (0..<24).map { $0 == 3 ? "true" : "1" }.joined(separator: ",")
        for text in [#"{"schemaVersion":1,"workdayPaceFactors":[\#(short)]}"#, #"{"schemaVersion":1,"holidayPaceFactors":[\#(high)]}"#,
                     #"{"schemaVersion":1,"holidayPaceFactors":[\#(flag)]}"#, #"{"schemaVersion":1,"workdayPaceFactors":1.1}"#] {
            XCTAssertThrowsError(try ForecastTuning.decode(Data(text.utf8)), text)
        }
    }

    func testOnlyListedValuesChange() throws {
        let value = try ForecastTuning.decode(Data(#"{"schemaVersion":1,"typicalSpeed":5.2,"typicalSpread":0.3,"note":"10/29 校正"}"#.utf8))
        var expected = ForecastTuning(); expected.typicalSpeed = 5.2; expected.typicalSpread = 0.3
        XCTAssertEqual(value, expected)
        ForecastTuning.current = value
        XCTAssertEqual(RidingTimeEstimate.Evidence.typical.spreadFraction, 0.3)
        XCTAssertEqual(RidingTimeEstimate.Evidence.railProfile.spreadFraction, 0.05)
    }

    func testAnyMistakeRejectsTheWholeFile() {
        for text in [#"{"typicalSpeed":5}"#, #"{"schemaVersion":2}"#, #"{"schemaVersion":1,"typicalSped":5}"#,
                     #"{"schemaVersion":1,"typicalSpeed":40}"#, #"{"schemaVersion":1,"typicalSpeed":"5"}"#,
                     #"{"schemaVersion":1,"typicalSpeed":true}"#, #"{"schemaVersion":1,"note":3}"#, "[]", "not json"] {
            XCTAssertThrowsError(try ForecastTuning.decode(Data(text.utf8)), text)
        }
    }

    func testServiceUsesMirrorAndKeepsLastGoodValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TuningProtocol.self]
        let session = URLSession(configuration: config)
        let sources = [URL(string: "https://github.test/tuning.json")!, URL(string: "https://mirror.test/tuning.json")!]
        TuningProtocol.answers = ["github.test": (503, Data()), "mirror.test": (200, Data(#"{"schemaVersion":1,"stopSeconds":30}"#.utf8))]
        let service = ForecastTuningService(cacheDirectory: directory, sources: sources, session: session)
        let first = await service.refresh(now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(first.stopSeconds, 30)
        // A broken file on GitHub is a publishing mistake: keep the last good values.
        TuningProtocol.answers = ["github.test": (200, Data(#"{"schemaVersion":1,"stopSeconds":900}"#.utf8)),
                                  "mirror.test": (200, Data(#"{"schemaVersion":1}"#.utf8))]
        let second = await service.refresh(now: Date(timeIntervalSince1970: 3_600))
        XCTAssertEqual(second.stopSeconds, 30)
        // The cached file applies at the next launch, before any network answer.
        ForecastTuning.current = ForecastTuning()
        _ = ForecastTuningService(cacheDirectory: directory, sources: sources, session: session)
        XCTAssertEqual(ForecastTuning.current.stopSeconds, 30)
    }
}

private final class TuningProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var stored: [String: (Int, Data)] = [:]
    static var answers: [String: (Int, Data)] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.answers[request.url?.host ?? ""] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
