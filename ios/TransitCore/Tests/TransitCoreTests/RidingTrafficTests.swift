import XCTest
@testable import TransitCore

final class RidingTrafficTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func source() -> (TransitMetadata, TransitRide) {
        var m = TransitMetadata()
        let route = BusRoute(id: "observed", parentID: "family", name: "630", variantName: "", departure: "起點", destination: "終點")
        m.routes[route.id] = route
        let line = RouteLine(coordinates: (0...4).map { Coordinate(latitude: 25.04, longitude: 121.55 + Double($0) * 0.0105) })
        m.lines["sub:observed"] = line
        for i in 0...4 {
            let stop = BusStop(id: "s\(i)", routeID: "family", stationID: "p\(i)", name: "站\(i)", direction: "0", sequence: i, coordinate: line.coordinates[i])
            m.stops[stop.id] = stop; m.paths[route.id, default: []].append(StopReference(stopID: stop.id, sequence: i))
        }
        m.rebuildJourneys()
        let stops = m.orderedStops(routeID: route.id, direction: "0")
        return (m, TransitRide(route: route, direction: "0", stops: stops, coordinates: stops.map(\.coordinate)))
    }
    func replay(starts: [Double], rates: [Double], metadata: TransitMetadata) -> VehicleArrivalForecast {
        var forecast = VehicleArrivalForecast()
        let line = metadata.line("observed", direction: "0")!
        for t in stride(from: 0.0, through: 90.0, by: 30) {
            let date = now.addingTimeInterval(t - 90)
            let buses = starts.enumerated().map { index, start in
                let point = line.sample(fraction: (start + rates[index] * t) / line.length).0
                let raw = BusVehicle(id: "physical-\(index)", plate: "physical-\(index)", routeID: "observed", parentRouteID: "family", routeName: "630", direction: "0", destination: "終點", coordinate: point, rawCoordinate: point, heading: 90, speed: rates[index] * 3.6, observedAt: date, status: "0", lowFloor: true, provider: nil)
                return VehicleTracker.accept(raw, previous: nil, metadata: metadata, now: date)
            }
            forecast.ingest(buses, metadata: metadata, at: date)
        }
        return forecast
    }
    func testColdRideKeepsTheBaselineAndIdentifiesItsSource() {
        let (m, ride) = source(); let estimate = VehicleArrivalForecast().ridingEstimate(ride, metadata: m, at: now)
        XCTAssertEqual(estimate.evidence, .typical)
        XCTAssertEqual(estimate.seconds, m.line("observed", direction: "0")!.length / 4.5 + Double(ride.stopCount) * 20, accuracy: 1)
    }
    func testDistributedObservedTrafficIncludesDwellOnlyOnce() {
        let (m, ride) = source(), f = replay(starts: [250, 1500, 3000], rates: [5, 5, 5], metadata: m)
        let estimate = f.ridingEstimate(ride, metadata: m, at: now)
        XCTAssertEqual(estimate.evidence, .recentTraffic); XCTAssertEqual(estimate.observedVehicles, 3)
        XCTAssertEqual(estimate.seconds, m.line("observed", direction: "0")!.length / 5, accuracy: 1)
        XCTAssertLessThan(estimate.seconds, VehicleArrivalForecast().ridingSeconds(ride, metadata: m, at: now))
    }
    func testCongestionAndStoppedVehiclesDoNotProduceAnOptimisticSpeed() {
        let (m, ride) = source(), f = replay(starts: [700, 1600, 3000], rates: [0, 5, 5], metadata: m)
        let estimate = f.ridingEstimate(ride, metadata: m, at: now)
        XCTAssertEqual(estimate.evidence, .recentTraffic)
        XCTAssertEqual(estimate.seconds, m.line("observed", direction: "0")!.length / (10.0 / 3), accuracy: 1)
        XCTAssertGreaterThan(estimate.seconds, VehicleArrivalForecast().ridingSeconds(ride, metadata: m, at: now))
    }
    func testOneJunctionOrOnlyTwoBusesCannotRepresentTheWholeRide() {
        let (m, ride) = source()
        for starts in [[250.0, 280, 310], [250, 3000]] {
            let estimate = replay(starts: starts, rates: starts.map { _ in 5 }, metadata: m).ridingEstimate(ride, metadata: m, at: now)
            XCTAssertEqual(estimate.evidence, .typical)
        }
    }
    func testExpiredReportsAndTerminalLayoversAreNotTrafficSamples() {
        let (m, ride) = source()
        let expired = replay(starts: [250, 1500, 3000], rates: [5, 5, 5], metadata: m)
        XCTAssertEqual(expired.ridingEstimate(ride, metadata: m, at: now.addingTimeInterval(31)).evidence, .typical)
        let terminal = replay(starts: [0, 1500, 3000], rates: [0, 5, 5], metadata: m)
        XCTAssertEqual(terminal.ridingEstimate(ride, metadata: m, at: now).evidence, .typical)
    }
    func testPhotographedTimingDifferenceIsNotAReasonToReassignAnAppleETA() {
        let walking = 10.0 * 60
        let ours = TripRanking.assess(riding: [37 * 60], walking: [walking / 2, walking / 2], arrivals: [11 * 60], at: now)
        XCTAssertEqual(ours.elapsedSeconds, 53 * 60)
        XCTAssertEqual(ours.waitingSeconds, 6 * 60)
        XCTAssertEqual(ours.walkingSeconds, walking)
        let appleStyleRide = 29.0 * 60
        XCTAssertEqual(37 * 60 - appleStyleRide, 8 * 60)
        // Apple route identity, actual source time and walking position are not
        // supplied by the whole-trip ETA response, so it cannot replace this ride.
    }
}
