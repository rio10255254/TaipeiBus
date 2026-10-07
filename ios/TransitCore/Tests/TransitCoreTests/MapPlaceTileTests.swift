import XCTest
@testable import TransitCore

final class MapPlaceTileTests: XCTestCase {
    private func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        repeat { var byte = UInt8(value & 127); value >>= 7; if value != 0 { byte |= 128 }; result.append(byte) } while value != 0
        return result
    }
    private func bytes(_ number: UInt64, _ value: Data) -> Data { varint(number << 3 | 2) + varint(UInt64(value.count)) + value }
    private func number(_ field: UInt64, _ value: UInt64) -> Data { varint(field << 3) + varint(value) }
    private func string(_ field: UInt64, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    private func fixture() -> Data {
        let tags = [0,0,1,1,2,2,3,3,4,4].reduce(Data()) { $0 + varint(UInt64($1)) }
        let geometry = varint(9) + varint(4096) + varint(4096)
        let feature = number(1, 123) + bytes(2, tags) + number(3, 1) + bytes(4, geometry)
        var layer = string(1, "poi") + bytes(2, feature)
        for key in ["class", "name", "rank", "name:zh", "name:en"] { layer += string(3, key) }
        for value in [string(1, "cafe"), string(1, "Test Cafe"), number(4, 150), string(1, "測試咖啡"), string(1, "Test Cafe")] { layer += bytes(4, value) }
        layer += number(5, 4096) + number(15, 2)
        return bytes(3, layer)
    }
    func testCoordinatesNamesAndRankSurviveTheVectorTile() throws {
        let points = try MapPlaceTile.decode(fixture(), zoom: 14, x: 13724, y: 7014)
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].kind, "cafe")
        XCTAssertEqual(points[0].rank, 150)
        XCTAssertEqual(points[0].names["name:zh"], "測試咖啡")
        XCTAssertEqual(points[0].names["name:en"], "Test Cafe")
        XCTAssertGreaterThan(points[0].coordinate.latitude, 25)
        XCTAssertLessThan(points[0].coordinate.latitude, 25.1)
        XCTAssertGreaterThan(points[0].coordinate.longitude, 121.5)
        XCTAssertLessThan(points[0].coordinate.longitude, 121.6)
    }
    func testTruncationAndWrongTileAddressAreRejected() {
        XCTAssertThrowsError(try MapPlaceTile.decode(Data(fixture().dropLast()), zoom: 14, x: 13724, y: 7014))
        XCTAssertThrowsError(try MapPlaceTile.decode(fixture(), zoom: 14, x: 999999, y: 7014))
        XCTAssertThrowsError(try MapPlaceTile.decode(Data([0x1a, 0xff, 0xff, 0xff]), zoom: 14, x: 13724, y: 7014))
    }
    func testActualPublishedPoiTileMatchesIndependentCount() throws {
        guard let path = ProcessInfo.processInfo.environment["BUS_PLACE_TILE_FIXTURE"] else { throw XCTSkip("Explicit real-tile fixture required") }
        let points = try MapPlaceTile.decode(Data(contentsOf: URL(fileURLWithPath: path)), zoom: 14, x: 13724, y: 7014)
        XCTAssertGreaterThan(points.count, 3300)
        XCTAssertTrue(points.contains { $0.names["name"]?.contains("Outing") == true })
        XCTAssertTrue(points.allSatisfy { $0.coordinate.latitude > 25 && $0.coordinate.latitude < 25.1 && $0.coordinate.longitude > 121.5 && $0.coordinate.longitude < 121.6 })
    }
}
