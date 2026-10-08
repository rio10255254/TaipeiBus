import XCTest
@testable import TransitCore

final class RiderAnchorTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func point(_ meters: Double, north: Double = 0) -> Coordinate {
        Coordinate(latitude: 25.04 + north / 111_320, longitude: 121.55 + meters / 100_750)
    }
    private var line: RouteLine { RouteLine(coordinates: stride(from: 0.0, through: 3_000, by: 100).map { point($0) }) }
    private func bus(at meters: Double, seconds: Double = 0) -> BusVehicle {
        var vehicle = BusVehicle(id: "boarded", plate: "RIDE-01", routeID: "route", parentRouteID: "family", routeName: "284",
            direction: "0", destination: "終點", coordinate: point(meters), rawCoordinate: point(meters), heading: 90,
            speed: 20, observedAt: date.addingTimeInterval(seconds), status: "0", lowFloor: true, provider: nil,
            aligned: true, path: [point(meters)])
        vehicle.roadMatch = line.match(point(meters), heading: nil)
        vehicle.travelDirection = 1
        return vehicle
    }
    private func anchor(_ vehicle: BusVehicle, rider meters: Double, north: Double = 0, accuracy: Double = 10,
                        after seconds: Double = 20, previous: LineMatch? = nil) -> BusVehicle? {
        let fix = date.addingTimeInterval(seconds)
        return RiderAnchor.anchor(vehicle, rider: point(meters, north: north), accuracy: accuracy, fixedAt: fix,
                                  previous: previous, line: line, journey: nil, now: fix.addingTimeInterval(1))
    }

    func testRiderFixMovesTheConfirmedBusAheadOfTheDelayedFeed() throws {
        let anchored = try XCTUnwrap(anchor(bus(at: 500), rider: 760))
        XCTAssertLessThan(anchored.coordinate.distance(to: point(760)), 2)
        XCTAssertEqual(anchored.observedAt, date.addingTimeInterval(20))
        XCTAssertTrue(anchored.aligned)
        XCTAssertEqual(anchored.roadMatch?.along ?? 0, 760, accuracy: 2)
        XCTAssertLessThan(anchored.path.first?.distance(to: point(500)) ?? 99, 2, "Motion continues from the last report")
        XCTAssertLessThan(anchored.path.last?.distance(to: point(760)) ?? 99, 2)
        XCTAssertEqual(anchored.heading, 90, accuracy: 1)
    }

    func testImpreciseStaleOrOlderFixesAreIgnored() {
        XCTAssertNil(anchor(bus(at: 500), rider: 600, accuracy: 120))
        XCTAssertNil(anchor(bus(at: 500, seconds: 30), rider: 600, after: 20), "A fix older than the feed adds nothing")
        let fix = date.addingTimeInterval(20)
        XCTAssertNil(RiderAnchor.anchor(bus(at: 500), rider: point(600), accuracy: 10, fixedAt: fix, previous: nil,
                                        line: line, journey: nil, now: fix.addingTimeInterval(60)))
    }

    func testRiderOffTheRouteOrNotPlausiblyOnThisBusIsIgnored() {
        XCTAssertNil(anchor(bus(at: 500), rider: 700, north: 90), "A parallel street is not this bus")
        XCTAssertNil(anchor(bus(at: 500), rider: 2_500, after: 10), "Too far ahead for the elapsed time")
        XCTAssertNil(anchor(bus(at: 1_500), rider: 1_200), "Far behind the bus means a different vehicle")
    }

    func testSmallBackwardFixHoldsInsteadOfReversing() throws {
        let first = try XCTUnwrap(anchor(bus(at: 500), rider: 800))
        let second = try XCTUnwrap(anchor(bus(at: 500), rider: 790, after: 22, previous: first.roadMatch))
        XCTAssertLessThan(second.coordinate.distance(to: point(800)), 2)
        let third = try XCTUnwrap(anchor(bus(at: 500), rider: 860, after: 25, previous: second.roadMatch))
        XCTAssertLessThan(third.path.first?.distance(to: point(800)) ?? 99, 2, "Each step continues from the previous anchor")
        XCTAssertLessThan(third.coordinate.distance(to: point(860)), 2)
    }
}
