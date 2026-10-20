import XCTest
@testable import TransitCore

final class CompactRouteOverviewTests: XCTestCase {
    private func assertFits(_ points: [Coordinate], width: Double, height: Double, file: StaticString = #filePath, line: UInt = #line) throws -> RouteOverview {
        let padding = RouteOverview.previewPadding(width: width, height: height)
        let view = try XCTUnwrap(RouteOverview(coordinates: points, viewportWidth: width, viewportHeight: height, pitch: 0, padding: padding), file: file, line: line)
        let center = view.center.mercator, scale = 512 * pow(2, view.zoom)
        for point in points {
            XCTAssertLessThan(abs(point.mercator.x - center.x) * scale, width / 2, file: file, line: line)
            XCTAssertLessThan(abs(point.mercator.y - center.y) * scale, height / 2, file: file, line: line)
        }
        let xs = points.map { $0.mercator.x }, ys = points.map { $0.mercator.y }
        let utilization = max((xs.max()! - xs.min()!) * scale / width, (ys.max()! - ys.min()!) * scale / height)
        XCTAssertGreaterThan(utilization, 0.72, file: file, line: line)
        return view
    }
    func testRouteUsesTheMapLeftAboveBothCompactSheetSizes() throws {
        let points = [Coordinate(latitude: 25.083, longitude: 121.595), Coordinate(latitude: 25.044, longitude: 121.516)]
        for height in [139.0, 180.0, 270.0] {
            _ = try assertFits(points, width: 378, height: height)
        }
    }
    func testLongRegionalRouteIsNotClippedByThePreviousZoomFloor() throws {
        let points = [Coordinate(latitude: 25.33, longitude: 121.45), Coordinate(latitude: 24.91, longitude: 121.54)]
        let view = try assertFits(points, width: 296, height: 139)
        XCTAssertLessThan(view.zoom, 9)
        XCTAssertGreaterThanOrEqual(view.zoom, RouteOverview.minimumZoom)
    }
    func testPreviewPaddingRemainsBoundedForLargeAndInvalidViewports() {
        XCTAssertEqual(RouteOverview.previewPadding(width: 390, height: 700), 32)
        XCTAssertEqual(RouteOverview.previewPadding(width: 378, height: 180), 18)
        XCTAssertEqual(RouteOverview.previewPadding(width: .nan, height: 180), 0)
    }
}
