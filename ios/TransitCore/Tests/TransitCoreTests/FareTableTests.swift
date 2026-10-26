import XCTest
@testable import TransitCore

final class FareTableTests: XCTestCase {
    private func stop(_ id: String, _ name: String, route: String, sequence: Int, station: String = "", mode: TransportMode = .bus) -> BusStop {
        var stop = BusStop(id: id, routeID: route, stationID: station.isEmpty ? id : station, name: name, direction: "0",
                           sequence: sequence, coordinate: Coordinate(latitude: 25.04, longitude: 121.5))
        stop.mode = mode
        return stop
    }

    func testTheMetroFareIsTheOfficialOneBetweenStations() {
        XCTAssertEqual(FareTable.shared.metroFare(from: "metro:TRTC:BL01", to: "metro:TRTC:R28"), 65)
        XCTAssertNil(FareTable.shared.metroFare(from: "metro:TRTC:BL01", to: "metro:NTMC:Y07"))
        XCTAssertFalse(FareTable.shared.updated.isEmpty)
    }

    func testMetroRidesInARowAreOneJourneyThroughTheGates() {
        var line = BusRoute(id: "metro:TRTC:BL:0", parentID: "metro:TRTC:BL", name: "板南線", variantName: "", departure: "", destination: "")
        line.mode = .metro
        var red = BusRoute(id: "metro:TRTC:R:0", parentID: "metro:TRTC:R", name: "淡水信義線", variantName: "", departure: "", destination: "")
        red.mode = .metro
        let first = TransitRide(route: line, direction: "0", stops: [
            stop("a", "頂埔", route: "metro:TRTC:BL", sequence: 0, station: "metro:TRTC:BL01", mode: .metro),
            stop("b", "台北車站", route: "metro:TRTC:BL", sequence: 11, station: "metro:TRTC:BL12", mode: .metro)], coordinates: [])
        let second = TransitRide(route: red, direction: "0", stops: [
            stop("c", "台北車站", route: "metro:TRTC:R", sequence: 0, station: "metro:TRTC:R10", mode: .metro),
            stop("d", "淡水", route: "metro:TRTC:R", sequence: 18, station: "metro:TRTC:R28", mode: .metro)], coordinates: [])
        XCTAssertEqual(FareTable.shared.estimate([first, second], metadata: TransitMetadata()), FareTable.Estimate(total: 65, complete: true))
    }

    func testABusRideThroughAFareZonePaysAnotherSection() {
        // Route 205 has a buffer zone from 玉成國小 to 饒河街觀光夜市(八德) in direction 0.
        let route = BusRoute(id: "10181", parentID: "10181", name: "205", variantName: "", departure: "", destination: "")
        let names = ["起點", "玉成國小", "中間", "饒河街觀光夜市(八德)", "終點"]
        let stops = names.enumerated().map { stop("s\($0.offset)", $0.element, route: "10181", sequence: $0.offset) }
        var metadata = TransitMetadata()
        for item in stops { metadata.stops[item.id] = item }
        func fare(_ from: Int, _ to: Int) -> FareTable.Estimate? {
            FareTable.shared.estimate([TransitRide(route: route, direction: "0", stops: Array(stops[from...to]), coordinates: [])], metadata: metadata)
        }
        XCTAssertEqual(fare(0, 4), FareTable.Estimate(total: 30, complete: true))
        XCTAssertEqual(fare(0, 2), FareTable.Estimate(total: 15, complete: true))
        XCTAssertEqual(fare(2, 4), FareTable.Estimate(total: 15, complete: true))
    }

    func testAnUnknownRouteLeavesTheTotalIncomplete() {
        let unknown = BusRoute(id: "x", parentID: "x", name: "不明", variantName: "", departure: "", destination: "")
        let known = BusRoute(id: "10132", parentID: "10132", name: "234", variantName: "", departure: "", destination: "")
        let rides = [unknown, known].map { TransitRide(route: $0, direction: "0", stops: [stop("1", "甲", route: $0.id, sequence: 0), stop("2", "乙", route: $0.id, sequence: 3)], coordinates: []) }
        XCTAssertEqual(FareTable.shared.estimate(rides, metadata: TransitMetadata()), FareTable.Estimate(total: 15, complete: false))
        XCTAssertNil(FareTable.shared.estimate([rides[0]], metadata: TransitMetadata()))
    }

    func testAMetroToBusTransferTakesOffTheDiscountUnlessCycled() {
        var line = BusRoute(id: "metro:TRTC:BL:0", parentID: "metro:TRTC:BL", name: "板南線", variantName: "", departure: "", destination: "")
        line.mode = .metro
        let metro = TransitRide(route: line, direction: "0", stops: [
            stop("a", "頂埔", route: "metro:TRTC:BL", sequence: 0, station: "metro:TRTC:BL01", mode: .metro),
            stop("b", "台北車站", route: "metro:TRTC:BL", sequence: 11, station: "metro:TRTC:BL12", mode: .metro)], coordinates: [])
        let bus = BusRoute(id: "10132", parentID: "10132", name: "234", variantName: "", departure: "", destination: "")
        let ride = TransitRide(route: bus, direction: "0", stops: [stop("1", "甲", route: "10132", sequence: 0), stop("2", "乙", route: "10132", sequence: 3)], coordinates: [])
        let metroFare = FareTable.shared.metroFare(from: "metro:TRTC:BL01", to: "metro:TRTC:BL12")!
        XCTAssertEqual(FareTable.shared.estimate([metro, ride], metadata: TransitMetadata()), FareTable.Estimate(total: metroFare + 15 - 8, complete: true))
        XCTAssertEqual(FareTable.shared.estimate([ride, metro], metadata: TransitMetadata()), FareTable.Estimate(total: 15 + metroFare - 8, complete: true))
        XCTAssertEqual(FareTable.shared.estimate([metro, ride], metadata: TransitMetadata(), cycledAfter: [0]), FareTable.Estimate(total: metroFare + 15, complete: true))
        // Bus to bus has no metro transfer discount.
        XCTAssertEqual(FareTable.shared.estimate([ride, ride], metadata: TransitMetadata()), FareTable.Estimate(total: 30, complete: true))
    }
}
