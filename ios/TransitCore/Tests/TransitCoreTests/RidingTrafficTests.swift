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
    func replay(starts: [Double], rates: [Double], metadata: TransitMetadata, estimates: EstimateFeed? = nil) -> VehicleArrivalForecast {
        var forecast = VehicleArrivalForecast()
        let line = metadata.line("observed", direction: "0")!
        for t in stride(from: 0.0, through: 90.0, by: 30) {
            let date = now.addingTimeInterval(t - 90)
            let buses = starts.enumerated().map { index, start in
                let point = line.sample(fraction: (start + rates[index] * t) / line.length).0
                let raw = BusVehicle(id: "physical-\(index)", plate: "physical-\(index)", routeID: "observed", parentRouteID: "family", routeName: "630", direction: "0", destination: "終點", coordinate: point, rawCoordinate: point, heading: 90, speed: rates[index] * 3.6, observedAt: date, status: "0", lowFloor: true, provider: nil)
                return VehicleTracker.accept(raw, previous: nil, metadata: metadata, now: date)
            }
            forecast.ingest(buses, metadata: metadata, at: date, estimates: estimates)
        }
        return forecast
    }
    private func withOfficialProfile(_ metadata: TransitMetadata, seconds: Int) throws -> TransitMetadata {
        // `now` is Friday 2027-01-15 16:00 in Taipei.
        var m = metadata
        let periods: [[String: Any]] = [16, 17].map { ["weekday": 5, "startHour": $0, "endHour": $0 + 1, "seconds": [seconds, seconds, seconds, seconds]] }
        m.officialTravelTimes = try OfficialTravelTimes(data: JSONSerialization.data(withJSONObject: ["schema": 1, "routes": [
            ["route": "family", "subroute": "observed", "direction": "0", "updated": "2027-01-12T05:00:00+08:00",
             "edges": (0..<4).map { ["s\($0)", "s\($0 + 1)"] }, "periods": periods]]]))
        return m
    }
    private func lastReport(start: Double, rate: Double, metadata: TransitMetadata) -> BusVehicle {
        let line = metadata.line("observed", direction: "0")!, point = line.sample(fraction: (start + rate * 90) / line.length).0
        let raw = BusVehicle(id: "physical-0", plate: "physical-0", routeID: "observed", parentRouteID: "family", routeName: "630", direction: "0", destination: "終點", coordinate: point, rawCoordinate: point, heading: 90, speed: rate * 3.6, observedAt: now, status: "0", lowFloor: true, provider: nil)
        return VehicleTracker.accept(raw, previous: nil, metadata: metadata, now: now)
    }
    func testOfficialProfileGivesALoneBusAUsableArrivalTime() throws {
        let m = try withOfficialProfile(source().0, seconds: 200)
        let forecast = replay(starts: [250], rates: [5], metadata: m), bus = lastReport(start: 250, rate: 5, metadata: m)
        let journey = try XCTUnwrap(m.journey(routeID: "observed", direction: "0"))
        let span = journey.anchors[1].match.along - journey.anchors[0].match.along
        let prediction = try XCTUnwrap(forecast.prediction(bus, stopID: "s3", metadata: m, at: now))
        XCTAssertEqual(prediction.evidence, .officialProfile)
        XCTAssertEqual(prediction.seconds, (400 + 200 * (span - 700) / span) * ForecastTuning.current.paceFactor(at: now), accuracy: 5)
        XCTAssertTrue(prediction.hasUsableTime)
        // Without a profile, fresh GPS can still offer a short approximate time,
        // clearly distinguished from the official hour profile.
        let plain = try XCTUnwrap(forecast.prediction(bus, stopID: "s3", metadata: source().0, at: now))
        XCTAssertEqual(plain.evidence, .routeProgress)
        XCTAssertTrue(plain.hasUsableTime)
    }
    func testMeasuredPaceFactorScalesTheOfficialProfile() throws {
        defer { ForecastTuning.current = ForecastTuning() }
        let m = try withOfficialProfile(source().0, seconds: 200)
        let forecast = replay(starts: [250], rates: [5], metadata: m), bus = lastReport(start: 250, rate: 5, metadata: m)
        var neutral = ForecastTuning(); neutral.workdayPaceFactors = Array(repeating: 1, count: 24)
        ForecastTuning.current = neutral
        let base = try XCTUnwrap(forecast.prediction(bus, stopID: "s3", metadata: m, at: now)).seconds
        // `now` is a Friday 16:00 in Taipei: only that hour's workday factor applies.
        var busy = neutral; busy.workdayPaceFactors[16] = 1.25; busy.holidayPaceFactors[16] = 0.8
        ForecastTuning.current = busy
        let scaled = try XCTUnwrap(forecast.prediction(bus, stopID: "s3", metadata: m, at: now))
        XCTAssertEqual(scaled.seconds, base * 1.25, accuracy: 2)
        XCTAssertEqual(scaled.evidence, .officialProfile)
    }
    func testLabelsUseTheNearestMinuteAndAWiderLateSide() {
        defer { ForecastTuning.current = ForecastTuning() }
        var tuning = ForecastTuning(); tuning.rangeEarlyScale = 1; tuning.rangeLateScale = 2
        ForecastTuning.current = tuning
        XCTAssertEqual(VehicleArrivalPrediction(seconds: 140, uncertaintySeconds: 30, evidence: .officialProfile, nearStop: false).label, "約 2 分")
        XCTAssertEqual(VehicleArrivalPrediction(seconds: 160, uncertaintySeconds: 30, evidence: .officialProfile, nearStop: false).label, "約 3 分")
        // 600 s ± 120 s: 480 s → 8 minutes before, 600 + 240 s → 14 minutes after.
        XCTAssertEqual(VehicleArrivalPrediction(seconds: 600, uncertaintySeconds: 120, evidence: .officialProfile, nearStop: false).rangeLabel, "參考範圍 8–14 分")
    }
    func testWithoutAProfileTheCountdownFollowsTheOfficialEstimates() throws {
        // New Taipei: no station-to-station profile. The bus is the next to reach s1 (60 s), and the estimates
        // at s1–s3 time the segments after it (200 s each).
        let m = source().0
        let feed = EstimateFeed(seconds: ["family:s0": 900, "family:s1": 60, "family:s2": 260, "family:s3": 460], updatedAt: now)
        let forecast = replay(starts: [250], rates: [5], metadata: m, estimates: feed), bus = lastReport(start: 250, rate: 5, metadata: m)
        let prediction = try XCTUnwrap(forecast.prediction(bus, stopID: "s3", metadata: m, at: now))
        XCTAssertEqual(prediction.evidence, .officialEstimates)
        XCTAssertEqual(prediction.seconds, 460, accuracy: 1)
        XCTAssertTrue(prediction.hasUsableTime)
        // A bus just ahead on the same segment is the one s1's estimate counts down to, so it is not borrowed.
        let bunched = replay(starts: [250, 400], rates: [5, 5], metadata: m, estimates: feed)
        let behind = try XCTUnwrap(bunched.prediction(bus, stopID: "s3", metadata: m, at: now))
        XCTAssertNotEqual(behind.evidence, .officialEstimates)
        // Without estimates, the bus's own pace as before.
        XCTAssertNotEqual(replay(starts: [250], rates: [5], metadata: m).prediction(bus, stopID: "s3", metadata: m, at: now)?.evidence, .officialEstimates)
    }
    func testOfficialProfileIsNotAppliedToABusWaitingAtItsFirstStop() throws {
        let m = try withOfficialProfile(source().0, seconds: 200)
        let forecast = replay(starts: [0], rates: [0], metadata: m), bus = lastReport(start: 0, rate: 0, metadata: m)
        XCTAssertNil(forecast.prediction(bus, stopID: "s3", metadata: m, at: now))
    }
    func testColdRideKeepsTheBaselineAndIdentifiesItsSource() {
        let (m, ride) = source(); let estimate = VehicleArrivalForecast().ridingEstimate(ride, metadata: m, at: now)
        XCTAssertEqual(estimate.evidence, .typical)
        // The city pace for the hour (TravelTimeModel), with nothing observed.
        let tuning = ForecastTuning.current
        XCTAssertEqual(estimate.seconds, (m.line("observed", direction: "0")!.length / tuning.typicalSpeed + Double(ride.stopCount) * tuning.stopSeconds)
            * tuning.cityPaceFactor(at: now), accuracy: 1)
    }
    func testDistributedObservedTrafficIncludesDwellOnlyOnce() {
        let (m, ride) = source(), f = replay(starts: [250, 1500, 3000], rates: [5, 5, 5], metadata: m)
        let estimate = f.ridingEstimate(ride, metadata: m, at: now)
        XCTAssertEqual(estimate.evidence, .recentTraffic); XCTAssertEqual(estimate.observedVehicles, 3)
        XCTAssertEqual(estimate.seconds, m.line("observed", direction: "0")!.length / 5, accuracy: 1)
        // Not the observed pace plus every stop's allowance again.
        XCTAssertLessThan(estimate.seconds, m.line("observed", direction: "0")!.length / 5 + Double(ride.stopCount) * ForecastTuning.current.stopSeconds - 1)
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
        let ours = TripRanking.assess(riding: [37.0 * 60], walking: [walking / 2, walking / 2], arrivals: [11 * 60], at: now)
        XCTAssertEqual(ours.elapsedSeconds, 53.0 * 60)
        XCTAssertEqual(ours.waitingSeconds, 6.0 * 60)
        XCTAssertEqual(ours.walkingSeconds, walking)
        let appleStyleRide = 29.0 * 60
        XCTAssertEqual(37.0 * 60 - appleStyleRide, 8.0 * 60)
        // Apple route identity, actual source time and walking position are not
        // supplied by the whole-trip ETA response, so it cannot replace this ride.
    }
}
