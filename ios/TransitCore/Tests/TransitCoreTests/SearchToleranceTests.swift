import XCTest
@testable import TransitCore

final class SearchToleranceTests: XCTestCase {
    func testChineseNumeralsInAddressesMatchDigits() {
        XCTAssertEqual(StationSearch.normalize("羅斯福路四段一號"), StationSearch.normalize("羅斯福路4段1號"))
        XCTAssertEqual(StationSearch.normalize("中山北路二段十二巷三弄"), StationSearch.normalize("中山北路2段12巷3弄"))
        XCTAssertEqual(StationSearch.chineseNumber("一百零五"), 105)
        XCTAssertEqual(StationSearch.chineseNumber("二十"), 20)
        XCTAssertEqual(StationSearch.chineseNumber("三五"), 35)
        // Numbers that are part of a name stay as they are.
        XCTAssertEqual(StationSearch.normalize("三重"), "三重")
        XCTAssertEqual(StationSearch.placeRank(name: "路口", address: "臺北市大安區羅斯福路4段1號", query: "台北市大安區羅斯福路四段一號"), 4)
    }
    func testAddressQueriesDropPostalCodeAndFloor() {
        let queries = StationSearch.placeQueries("106台北市大安區羅斯福路四段1號3樓")
        XCTAssertEqual(queries.first, "台北市大安區羅斯福路4段1號")
        XCTAssertFalse(StationSearch.placeQueries("忠孝東路四段100號5F").first?.contains("5F") ?? true)
        XCTAssertEqual(StationSearch.placeQueries("民權西路站").first, "捷運民權西路站", "A station named after its road stays a station")
    }
    func testBuildingAndCampusNamesAreTriedBothWays() {
        // 「台大機械館」 found nothing on a phone, while 「台大機械系館」 did.
        let queries = StationSearch.placeQueries("台大機械館")
        XCTAssertEqual(queries.first, "台大機械館")
        XCTAssertTrue(queries.contains("台大機械系館"))
        XCTAssertTrue(queries.contains("國立台灣大學 機械館"))
        XCTAssertNotNil(StationSearch.placeRank(name: "國立臺灣大學機械工程學系館", address: "", query: "台大機械館"))
        XCTAssertNotNil(StationSearch.placeRank(name: "國立臺灣大學機械工程學系館", address: "", query: "國立臺灣大學機械館"))
        XCTAssertNil(StationSearch.placeRank(name: "國立臺灣大學圖書館", address: "臺北市大安區羅斯福路四段1號", query: "台大機械館"),
                     "The library is not the mechanical engineering building")
        XCTAssertEqual(StationSearch.placeQueries("台大醫院"), ["台大醫院"], "A familiar place is not split into 台大 + 醫院")
        XCTAssertFalse(StationSearch.placeQueries("故宮博物館").contains("故宮博物系館"))
    }
}
