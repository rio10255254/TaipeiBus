import XCTest
#if canImport(MapKit)
import MapKit
#endif
@testable import TransitCore

/// Diagnostic evidence for the recommendation audit; does not change shipped routing behavior.
final class RouteRecommendationAuditTests: XCTestCase {
    private func source() -> TransitMetadata {
        var value = TransitMetadata()
        let route = BusRoute(id: "audit", parentID: "family", name: "測試路線", variantName: "",
                             departure: "起點", destination: "終點")
        value.routes[route.id] = route
        let points = [50.0, 250, 1600].map { Coordinate(latitude: 25.04, longitude: 121.55 + $0 / 100_750) }
        value.lines["sub:audit"] = RouteLine(coordinates: points)
        for (index, point) in points.enumerated() {
            let stop = BusStop(id: "stop-\(index)", routeID: "family", stationID: "station-\(index)",
                name: "站\(index)", direction: "0", sequence: index, coordinate: point)
            value.stops[stop.id] = stop
            value.paths[route.id, default: []].append(StopReference(stopID: stop.id, sequence: index))
            value.stations[stop.stationID] = Station(id: stop.stationID, name: stop.name, coordinate: point,
                address: "", bearing: "E", stopIDs: [stop.id])
        }
        value.rebuildJourneys()
        return value
    }

    func testDocumentPreWalkingFamilyPruningCounterexample() throws {
        let metadata = source(), date = Date(), origin = Coordinate(latitude: 25.04, longitude: 121.55)
        let destination = metadata.stops["stop-2"]!.coordinate
        let choices = TripPlanner(metadata: metadata).plan(from: origin, to: destination, maximumWalk: 300, limit: 18)
        let kept = try XCTUnwrap(choices.first)
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(kept.rides[0].boarding.id, "stop-0")
        let stops = Array(metadata.orderedStops(routeID: "audit", direction: "0").dropFirst())
        let ride = TransitRide(route: metadata.routes["audit"]!, direction: "0", stops: stops, coordinates: stops.map(\.coordinate))
        let alternative = TransitTrip(rides: [ride], accessDistance: origin.distance(to: stops[0].coordinate),
            egressDistance: 0, transferDistance: 0, score: 0,
            rideSeconds: [stops[0].coordinate.distance(to: stops[1].coordinate) / 4.5 + 20])
        let keptRealWalk = TripRanking.assessment(kept, estimates: EstimateFeed(), at: date, walkingDurations: [600, 0])
        let alternativeRealWalk = TripRanking.assessment(alternative, estimates: EstimateFeed(), at: date, walkingDurations: [180, 0])
        XCTAssertLessThan(alternativeRealWalk.elapsedSeconds, keptRealWalk.elapsedSeconds - 300)
        print("Recommendation audit counterexample: same-family boarding option discarded before real walking verification; retained \(keptRealWalk.elapsedSeconds / 60) min vs feasible alternative \(alternativeRealWalk.elapsedSeconds / 60) min.")
    }

    func testDocumentBoardingGraceAndUnknownConnectionCosts() {
        let grace = TripRanking.assess(riding: [600], walking: [140, 0], arrivals: [120])
        XCTAssertFalse(grace.missedFirstArrival)
        XCTAssertEqual(grace.waitingSeconds, 0)
        let unknown = TripRanking.assess(riding: [600], walking: [90, 90], arrivals: [nil])
        let pending = TripRanking.assess(riding: [600], walking: [90, 90], arrivals: [-1])
        XCTAssertEqual(unknown.waitingSeconds, 480)
        XCTAssertEqual(pending.waitingSeconds, 900)
        print("Recommendation audit: first bus ETA 120 sec and walk 140 sec still treated as catchable; unknown next service uses 8 min, not-departed uses 15 min without route headway.")
    }

    #if canImport(MapKit)
    @MainActor
    func testLiveNeihuToZhongxiaoFuxingRecommendations() async throws {
        guard let directory = ProcessInfo.processInfo.environment["BUS_LIVE_FEEDS_DIRECTORY"] else {
            throw XCTSkip("Explicit live recommendation audit only")
        }
        let root = URL(fileURLWithPath: directory)
        var feeds: [String: Data] = [:]
        for name in ["GetRoute", "GetStop", "GetPathDetail", "GetBusShape", "GetEstimateTime"] {
            feeds[name] = try Data(contentsOf: root.appendingPathComponent(name + ".json"))
        }
        let metadata = try FeedDecoder.metadata(feeds: feeds)
        let estimates = try FeedDecoder.estimates(feeds["GetEstimateTime"]!)
        let date = try XCTUnwrap(estimates.updatedAt)
        let destination = Coordinate(latitude: 25.0416, longitude: 121.5438)
        let neihuStations = metadata.stationSearch.search("捷運內湖站", near: Coordinate(latitude: 25.0837, longitude: 121.5947), limit: 6)
            .filter { $0.name.hasPrefix("捷運內湖站") }
        let neihu = try XCTUnwrap(neihuStations.min { $0.coordinate.distance(to: Coordinate(latitude: 25.0837, longitude: 121.5947)) < $1.coordinate.distance(to: Coordinate(latitude: 25.0837, longitude: 121.5947)) })
        let planner = TripPlanner(metadata: metadata)
        var walkingCache: [String: Double] = [:], records: [[String: Any]] = []
        func walking(_ from: Coordinate, _ to: Coordinate) async -> Double? {
            if from.distance(to: to) < 1 { return 0 }
            let key = "\(from.latitude):\(from.longitude):\(to.latitude):\(to.longitude)"
            if let cached = walkingCache[key] { return cached }
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)))
            request.transportType = .walking
            do {
                let response = try await MKDirections(request: request).calculate()
                if let route = response.routes.first { walkingCache[key] = route.expectedTravelTime; return route.expectedTravelTime }
            } catch { print("Recommendation audit walking verification unavailable: \(error)") }
            return nil
        }
        for (name, origin) in [("捷運內湖站附近", neihu.coordinate), ("大湖站牌附近", Coordinate(latitude: 25.08478664, longitude: 121.6000154))] {
            let narrow = planner.plan(from: origin, to: destination, maximumWalk: 800, limit: 18, estimates: estimates, at: date)
            let wider = planner.plan(from: origin, to: destination, maximumWalk: 1200, limit: 18, estimates: estimates, at: date)
            let existing = Set(narrow.map(\.id))
            let actualPool = narrow.contains { $0.transfers == 0 } ? narrow :
                narrow.isEmpty ? wider : narrow + wider.filter { $0.transfers == 0 && !existing.contains($0.id) }
            let displayed = TripRanking.recommended(actualPool, estimates: estimates, at: date, limit: 3)
            for trip in displayed {
                let pairs = [(origin, trip.rides[0].boarding.coordinate)] +
                    (trip.transfers > 0 ? [(trip.rides[0].alighting.coordinate, trip.rides[1].boarding.coordinate)] : []) +
                    [(trip.rides.last!.alighting.coordinate, destination)]
                var actualWalks: [Double?] = []
                for (from, to) in pairs {
                    actualWalks.append(await walking(from, to))
                    try await Task.sleep(for: .seconds(1))
                }
                let result = TripRanking.assessment(trip, estimates: estimates, at: date, walkingDurations: actualWalks)
                let row: [String: Any] = ["origin": name, "destination": "忠孝復興站附近", "origin_latitude": origin.latitude,
                    "origin_longitude": origin.longitude, "routes": trip.rides.map(\.route.name), "transfers": trip.transfers,
                    "boarding": trip.rides[0].boarding.name, "alighting": trip.rides.last!.alighting.name,
                    "total_minutes": result.elapsedSeconds / 60, "walking_minutes": result.walkingSeconds / 60,
                    "waiting_minutes": result.waitingSeconds / 60, "riding_minutes": trip.rideSeconds.reduce(0,+) / 60,
                    "walking_verified": actualWalks.allSatisfy { $0 != nil }, "uncertain_waits": result.uncertainWaits,
                    "missed_first_arrival": result.missedFirstArrival,
                    "candidate_count_800": narrow.count, "candidate_count_1200": wider.count,
                    "wider_best_minutes": wider.first.map { TripRanking.assessment($0, estimates: estimates, at: date).elapsedSeconds / 60 } ?? -1]
                records.append(row)
                print("RECOMMENDATION_AUDIT " + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            }
        }
        XCTAssertFalse(records.isEmpty)
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("recommendation-audit.json"))
    }
    #endif
}
