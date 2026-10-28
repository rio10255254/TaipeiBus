import XCTest
@testable import TransitCore

final class RegionCatalogTests: XCTestCase {
    private func catalog(_ json: String) throws -> RegionCatalog { try RegionCatalog(data: Data(json.utf8)) }
    private let sources = #"[{"id":"tpe","name":"臺北市公車","kind":"bus","feed":"https://tcgbusfs.blob.core.windows.net/blobbus/"}]"#

    func testBundledRegionsMatchTheBuiltInFallback() throws {
        let bundled = try XCTUnwrap(RegionCatalog.bundled, "Regions/regions.json ships with the package and decodes")
        // The fallback only matters if the file is damaged; it must then serve the same area and feeds.
        XCTAssertEqual(bundled.home, RegionCatalog.builtIn.home)
        XCTAssertEqual(bundled.sources, RegionCatalog.builtIn.sources)
        XCTAssertEqual(RegionCatalog.shared.home, bundled.home)
        XCTAssertEqual(bundled.source(.bus)?.feed.absoluteString, "https://tcgbusfs.blob.core.windows.net/blobbus/")
        XCTAssertEqual(bundled.source(.bus)?.idPrefix, "", "Taipei ids stay unprefixed so saved stops need no migration")
        XCTAssertEqual(bundled.source(.bike)?.kind, .bike)
    }
    func testServiceAreaIsTheSameBoxAsBefore() {
        // The box the app served before regions existed, edges included.
        for (latitude, longitude, inside) in [(24.90, 121.27, true), (25.25, 121.72, true), (25.0377, 121.56, true),
                                              (24.8999, 121.5, false), (25.2501, 121.5, false), (25.0, 121.2699, false),
                                              (25.0, 121.7201, false), (Double.nan, 121.5, false), (25.0, Double.infinity, false)] {
            XCTAssertEqual(Coordinate(latitude: latitude, longitude: longitude).isInServiceArea, inside, "\(latitude), \(longitude)")
        }
        XCTAssertEqual(Coordinate.serviceCenter, Coordinate.taipei)
    }
    func testRegionsAreAUnionOfBoxesAndKnowTheirSources() throws {
        let value = try catalog(#"""
        {"home":"a","regions":[
          {"id":"a","name":"甲","center":[25.0,121.5],"bounds":[[24.9,121.4,25.1,121.6],[25.1,121.5,25.2,121.7]],"sources":["tpe"]},
          {"id":"b","name":"乙","center":[25.1,121.75],"bounds":[[25.05,121.7,25.2,121.8]],"sources":["tpe","bike-b"]}],
         "sources":[{"id":"tpe","name":"臺北市公車","kind":"bus","feed":"https://tcgbusfs.blob.core.windows.net/blobbus/"},
                    {"id":"bike-b","name":"乙 YouBike","kind":"bike","feed":"https://example.org/bike.json","idPrefix":"b:"}]}
        """#)
        XCTAssertEqual(value.region(at: Coordinate(latitude: 25.15, longitude: 121.65))?.id, "a", "the second box of a")
        XCTAssertEqual(value.region(at: Coordinate(latitude: 25.15, longitude: 121.78))?.id, "b")
        XCTAssertNil(value.region(at: Coordinate(latitude: 25.15, longitude: 121.45)))
        XCTAssertFalse(value.contains(Coordinate(latitude: 25.15, longitude: 121.45)))
        XCTAssertNil(value.source(.bike), "the home region has no YouBike")
        XCTAssertEqual(value.source(.bike, in: value.regions[1])?.idPrefix, "b:")
        XCTAssertEqual(value.regions[0].englishName, "甲", "the Chinese name stands in for a missing English one")
    }
    func testBrokenCatalogsAreRefused() {
        let region = #"{"id":"a","name":"甲","center":[25.0,121.5],"bounds":[[24.9,121.4,25.1,121.6]],"sources":["tpe"]}"#
        XCTAssertNoThrow(try catalog(#"{"home":"a","regions":[\#(region)],"sources":\#(sources)}"#))
        // An unknown home, a source nobody defined, and boxes that are not boxes.
        XCTAssertThrowsError(try catalog(#"{"home":"x","regions":[\#(region)],"sources":\#(sources)}"#))
        XCTAssertThrowsError(try catalog(#"{"home":"a","regions":[\#(region.replacingOccurrences(of: #"["tpe"]"#, with: #"["tpe","nope"]"#))],"sources":\#(sources)}"#))
        XCTAssertThrowsError(try catalog(#"{"home":"a","regions":[\#(region.replacingOccurrences(of: "[24.9,121.4,25.1,121.6]", with: "[25.1,121.4,24.9,121.6]"))],"sources":\#(sources)}"#))
        XCTAssertThrowsError(try catalog(#"{"home":"a","regions":[\#(region.replacingOccurrences(of: #""bounds":[[24.9,121.4,25.1,121.6]]"#, with: #""bounds":[]"#))],"sources":\#(sources)}"#))
        // Feeds are https only, and the home region needs buses.
        XCTAssertThrowsError(try catalog(#"{"home":"a","regions":[\#(region)],"sources":\#(sources.replacingOccurrences(of: "https://", with: "http://"))}"#))
        XCTAssertThrowsError(try catalog(#"{"home":"a","regions":[\#(region)],"sources":\#(sources.replacingOccurrences(of: #""bus""#, with: #""bike""#))}"#))
        XCTAssertThrowsError(try catalog("[]"))
    }
}
