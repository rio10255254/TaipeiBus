import XCTest
@testable import TransitCore

final class RegionCatalogTests: XCTestCase {
    private func catalog(_ json: String) throws -> RegionCatalog { try RegionCatalog(data: Data(json.utf8)) }
    private let sources = #"[{"id":"tpe","name":"臺北市公車","kind":"bus","feed":"https://tcgbusfs.blob.core.windows.net/blobbus/"}]"#

    func testBundledRegionsCoverTheBuiltInFallback() throws {
        let bundled = try XCTUnwrap(RegionCatalog.bundled, "Regions/regions.json ships with the package and decodes")
        // The fallback only matters if the file is damaged; it must then serve nothing the file does not.
        XCTAssertEqual(bundled.home.id, RegionCatalog.builtIn.home.id)
        XCTAssertEqual(bundled.home.center, RegionCatalog.builtIn.home.center)
        for (id, source) in RegionCatalog.builtIn.sources { XCTAssertEqual(bundled.sources[id], source) }
        for box in RegionCatalog.builtIn.home.bounds {
            for latitude in stride(from: box.south, through: box.north, by: 0.01) {
                for longitude in stride(from: box.west, through: box.east, by: 0.01) {
                    XCTAssertTrue(bundled.contains(Coordinate(latitude: latitude, longitude: longitude)), "\(latitude), \(longitude)")
                }
            }
        }
        XCTAssertEqual(RegionCatalog.shared.home.id, bundled.home.id)
        // Taipei's buses come first: the app cannot work without them.
        XCTAssertEqual(bundled.sources(.bus).map(\.id), ["tpe", "ntpc"])
        XCTAssertEqual(bundled.source(.bus)?.feed.absoluteString, "https://tcgbusfs.blob.core.windows.net/blobbus/")
        XCTAssertTrue(bundled.sources(.bus).allSatisfy { $0.idPrefix.isEmpty }, "one numbering: saved stops need no migration")
        XCTAssertEqual(bundled.source(.bike)?.kind, .bike)
    }
    func testServiceAreaKeepsTaipeisBoxAndAddsNewTaipei() {
        // The box the app served before New Taipei, edges included, and New Taipei's far districts.
        let served = [(24.90, 121.27), (25.25, 121.72), (25.0377, 121.56), (25.0617, 121.3676), (24.8650, 121.5500),
                      (25.0161, 121.9447), (25.2900, 121.5680), (25.2222, 121.6370), (24.9343, 121.3690), (25.1092, 121.8442),
                      (24.9367, 121.7113), (25.1470, 121.4000)]
        for (latitude, longitude) in served {
            XCTAssertTrue(Coordinate(latitude: latitude, longitude: longitude).isInServiceArea, "\(latitude), \(longitude)")
        }
        // Keelung's centre and Yilan wait for their own sources; nonsense coordinates are never served.
        for (latitude, longitude) in [(25.1318, 121.7397), (24.8590, 121.8230), (24.5, 121.5), (Double.nan, 121.5), (25.0, Double.infinity)] {
            XCTAssertFalse(Coordinate(latitude: latitude, longitude: longitude).isInServiceArea, "\(latitude), \(longitude)")
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
