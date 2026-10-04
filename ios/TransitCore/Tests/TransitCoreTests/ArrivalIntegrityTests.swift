import XCTest
@testable import TransitCore

final class ArrivalIntegrityTests: XCTestCase {
    func testRecordedDahuVehicleProgressAndForecastDiagnostics() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "DahuConflict", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rawMetadata = try XCTUnwrap(object["metadata"] as? [String: Any])
        let feeds = try rawMetadata.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        let metadata = try FeedDecoder.metadata(feeds: feeds)
        let route = try XCTUnwrap(metadata.routes["160879"])
        let stops = metadata.orderedStops(routeID: route.id, direction: "1")
        let start = try XCTUnwrap(stops.firstIndex { $0.id == "23639" })
        let ride = TransitRide(route: route, direction: "1", stops: Array(stops[start...]), coordinates: Array(stops[start...]).map(\.coordinate))
        var previous: [BusVehicle] = [], forecast = VehicleArrivalForecast()
        for entry in try XCTUnwrap(object["snapshots"] as? [[String: Any]]) {
            let bytes = try JSONSerialization.data(withJSONObject: entry["vehicles"]!)
            let date = try XCTUnwrap(FeedDecoder.rows(bytes).1)
            let result = try FeedDecoder.vehicles(bytes, metadata: metadata, previous: previous, now: date)
            let estimates = try FeedDecoder.estimates(JSONSerialization.data(withJSONObject: entry["estimates"]!))
            let snapshot = TransitSnapshot(vehicles: result.vehicles, sourceUpdatedAt: date, receivedAt: date,
                                           estimates: estimates, revision: 1)
            forecast.ingest(result.vehicles, metadata: metadata, at: date)
            let guide = BoardingGuide(ride: ride, metadata: metadata, snapshot: snapshot, at: date)
            print("Dahu official \(String(describing: guide.estimateSeconds)) at \(date)")
            for bus in result.vehicles where ["388-U8", "KKA-0363"].contains(bus.plate) {
                let progress = metadata.journey(routeID: bus.routeID, direction: bus.direction)?.progress(stopID: ride.boarding.id, vehicle: bus, at: date)
                let prediction = forecast.prediction(bus, stopID: ride.boarding.id, metadata: metadata, at: date)
                print("Dahu bus \(bus.plate), direction \(bus.direction), aligned \(bus.aligned), distance \(String(describing: progress?.distance)), prediction \(String(describing: prediction))")
            }
            XCTAssertFalse(guide.approaches.contains { $0.vehicle.plate == "388-U8" }, "Recorded westbound bus is already past Dahu")
            previous = result.vehicles
        }
    }
}
