import XCTest
@testable import TransitCore

final class AppUpdateTests: XCTestCase {
    private func policy(_ json: String) throws -> AppUpdatePolicy { try AppUpdatePolicy.decode(Data(json.utf8)) }
    private let store = AppStoreRelease(version: "1.7.0", minimumOSVersion: "17.0")

    func testVersionsCompareNumerically() {
        XCTAssertLessThan(AppVersion("1.6.9")!, AppVersion("1.6.10")!)
        XCTAssertEqual(AppVersion("1.7"), AppVersion("1.7.0"))
        XCTAssertNil(AppVersion("1.7.0-beta")); XCTAssertNil(AppVersion("")); XCTAssertNil(AppVersion("1..2"))
    }

    func testMinimumBlocksOnlyWhenTheStoreOffersIt() throws {
        let value = try policy(#"{"schemaVersion":1,"minimumVersion":"1.7.0"}"#)
        XCTAssertEqual(value.requirement(appVersion: "1.6.1", store: store, systemVersion: "18.1"), .required)
        XCTAssertEqual(value.requirement(appVersion: "1.7.0", store: store, systemVersion: "18.1"), AppUpdateRequirement.none)
        // Not yet released in the store, unknown store version, or an iOS too old for it: never lock people out.
        XCTAssertEqual(value.requirement(appVersion: "1.6.1", store: AppStoreRelease(version: "1.6.5", minimumOSVersion: nil), systemVersion: "18.1"), AppUpdateRequirement.none)
        XCTAssertEqual(value.requirement(appVersion: "1.6.1", store: nil, systemVersion: "18.1"), AppUpdateRequirement.none)
        XCTAssertEqual(value.requirement(appVersion: "1.6.1", store: AppStoreRelease(version: "1.7.0", minimumOSVersion: "19.0"), systemVersion: "18.1"), AppUpdateRequirement.none)
    }

    func testRecommendedVersionNamesTheStoreVersion() throws {
        let value = try policy(#"{"schemaVersion":1,"minimumVersion":"1.0.0","recommendedVersion":"1.6.5","message":"請更新","englishMessage":"Please update"}"#)
        XCTAssertEqual(value.requirement(appVersion: "1.6.1", store: store, systemVersion: "17.0"), .recommended("1.7.0"))
        XCTAssertEqual(value.requirement(appVersion: "1.6.5", store: store, systemVersion: "17.0"), AppUpdateRequirement.none)
        XCTAssertEqual(value.message, "請更新")
    }

    func testInvalidPoliciesAreRejected() {
        for json in [#"{"schemaVersion":2,"minimumVersion":"1.0.0"}"#, #"{"schemaVersion":1,"minimumVersion":"latest"}"#,
                     #"{"schemaVersion":1,"minimumVersion":"1.0.0","recommendedVersion":"x"}"#,
                     #"{"schemaVersion":1,"minimumVersion":"1.0.0","message":""}"#, #"{"schemaVersion":1}"#] {
            XCTAssertThrowsError(try policy(json), json)
        }
    }

    func testAppStoreLookupIsParsed() {
        let data = Data(#"{"resultCount":1,"results":[{"version":"1.6.1","minimumOsVersion":"17.0","trackName":"台北公車"}]}"#.utf8)
        XCTAssertEqual(AppStoreRelease.lookup(data), AppStoreRelease(version: "1.6.1", minimumOSVersion: "17.0"))
        XCTAssertNil(AppStoreRelease.lookup(Data(#"{"resultCount":0,"results":[]}"#.utf8)))
    }
}
