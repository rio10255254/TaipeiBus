import XCTest
@testable import TransitCore

final class ArrivalIntegrityTests: XCTestCase {
    func testRecordedDahuExcludesPassedBusAndWithholdsUnstableMinuteClaims() throws {
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
                let display = forecast.display(bus, stopID: ride.boarding.id, metadata: metadata, at: date, officialSeconds: guide.estimateSeconds)
                print("Dahu bus \(bus.plate), distance \(String(describing: progress?.distance)), raw prediction \(String(describing: prediction)), visible label \(display.label)")
                if bus.plate == "388-U8" {
                    XCTAssertEqual(display.label, "已過站")
                    XCTAssertNil(display.prediction)
                } else if let shown = display.prediction {
                    // The recorded sparse observations cannot support the App's own minute claim; as the next bus,
                    // the official estimate may stand in, and only as itself.
                    XCTAssertEqual(shown.evidence, .official, "The recorded sparse observations cannot support individual minute claims")
                    XCTAssertEqual(shown.seconds, Double(max(guide.estimateSeconds ?? -1, 15)))
                } else {
                    XCTAssertTrue(display.label.contains("站"))
                    XCTAssertFalse(display.label.contains("分"))
                }
            }
            XCTAssertFalse(guide.approaches.contains { $0.vehicle.plate == "388-U8" }, "Recorded westbound bus is already past Dahu")
            previous = result.vehicles
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func source(count: Int = 8, boarding: Int = 4) -> (TransitMetadata, TransitRide) {
        var metadata = TransitMetadata()
        let route = BusRoute(id: "operator-a", parentID: "family", name: "630", variantName: "630 A",
                             departure: "起点", destination: "终点")
        metadata.routes[route.id] = route
        let line = RouteLine(coordinates: (0..<count).map {
            Coordinate(latitude: 25.08, longitude: 121.59 + Double($0) * 0.002)
        })
        metadata.lines["sub:operator-a"] = line
        for index in 0..<count {
            let stop = BusStop(id: "stop-\(index)", routeID: "family", stationID: "station-\(index)",
                name: "站\(index)", direction: "0", sequence: index, coordinate: line.coordinates[index])
            metadata.stops[stop.id] = stop
            metadata.paths[route.id, default: []].append(StopReference(stopID: stop.id, sequence: index))
        }
        metadata.rebuildJourneys()
        let stops = metadata.orderedStops(routeID: route.id, direction: "0")
        return (metadata, TransitRide(route: route, direction: "0", stops: Array(stops[boarding...]),
                                      coordinates: Array(stops[boarding...]).map(\.coordinate)))
    }

    private func bus(_ id: String = "physical", along: Double, age: Double = 0, speed: Double = 18,
                     heading: Double = 90, route: String = "operator-a", metadata: TransitMetadata) -> BusVehicle {
        let line = metadata.line(route, direction: "0")!
        let coordinate = line.sample(fraction: along / line.length).0
        let date = now.addingTimeInterval(-age)
        let raw = BusVehicle(id: id, plate: id, routeID: route, parentRouteID: "family", routeName: "630",
            direction: "0", destination: "终点", coordinate: coordinate, rawCoordinate: coordinate,
            heading: heading, speed: speed, observedAt: date, status: "0", lowFloor: true, provider: nil)
        return VehicleTracker.accept(raw, previous: nil, metadata: metadata, now: date)
    }

    func testEveryBusUnderWayGetsATimeAndTheNextOneTheOfficialEstimate() throws {
        // About four kilometres and twenty stops from the boarding stop: too far for this bus's own short pace.
        let (metadata, ride) = source(count: 32, boarding: 20)
        let far = bus(along: 120, metadata: metadata)
        var forecast = VehicleArrivalForecast(); forecast.ingest([far], metadata: metadata, at: now)
        let own = try XCTUnwrap(forecast.prediction(far, stopID: ride.boarding.id, metadata: metadata, at: now))
        XCTAssertEqual(own.evidence, .cityPace)
        XCTAssertTrue(own.isShowable); XCTAssertFalse(own.hasUsableTime, "Not precise enough to plan a transfer with")
        let alone = forecast.display(far, stopID: ride.boarding.id, metadata: metadata, at: now)
        XCTAssertTrue(alone.label.contains("分")); XCTAssertEqual(alone.prediction?.evidence, .cityPace)
        // As the next bus, its official estimate stands in for the city's pace.
        let official = forecast.display(far, stopID: ride.boarding.id, metadata: metadata, at: now, officialSeconds: 900)
        XCTAssertEqual(official.prediction?.evidence, .official); XCTAssertEqual(official.label, "約 15 分")
        // Not when another bus is ahead of it (the estimate is that bus's), nor when it is impossible for this one.
        let ahead = bus("ahead", along: 2_000, metadata: metadata)
        var behind = VehicleArrivalForecast(); behind.ingest([far, ahead], metadata: metadata, at: now)
        XCTAssertEqual(behind.display(far, stopID: ride.boarding.id, metadata: metadata, at: now, officialSeconds: 900).prediction?.evidence, .cityPace)
        XCTAssertEqual(forecast.display(far, stopID: ride.boarding.id, metadata: metadata, at: now, officialSeconds: 60).prediction?.evidence, .cityPace)
        // A bus standing at its terminal gets no invented time, from either source.
        let parked = bus("parked", along: 20, speed: 0, metadata: metadata)
        var terminal = VehicleArrivalForecast(); terminal.ingest([parked], metadata: metadata, at: now)
        XCTAssertNil(terminal.display(parked, stopID: ride.boarding.id, metadata: metadata, at: now, officialSeconds: 900).prediction)
    }

    func testOfficialTwelveMinutesIsNotReassignedToANearbyPlate() throws {
        let (metadata, ride) = source()
        let target = metadata.journey(routeID: ride.route.id, direction: "0")!.anchors[4].match.along
        let vehicle = bus(along: target - 100, metadata: metadata)
        var forecast = VehicleArrivalForecast(); forecast.ingest([vehicle], metadata: metadata, at: now)
        XCTAssertLessThan(try XCTUnwrap(forecast.prediction(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now)).seconds, 60)
        let display = forecast.display(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now, officialSeconds: 720)
        XCTAssertEqual(display.label, display.positionLabel); XCTAssertEqual(display.positionLabel, "還有 1 站")
        XCTAssertNil(display.prediction)
        XCTAssertFalse(display.label.contains("12")); XCTAssertFalse(display.label.contains("1 分"))
    }

    func testStableObservedMovementAllowsIndividualTimeWithoutOfficialFeed() throws {
        let (metadata, ride) = source()
        var forecast = VehicleArrivalForecast()
        var vehicle: BusVehicle!
        for (age, along) in [(60.0, 100.0), (30.0, 250.0), (0.0, 400.0)] {
            vehicle = bus(along: along, age: age, metadata: metadata)
            forecast.ingest([vehicle], metadata: metadata, at: now.addingTimeInterval(-age))
        }
        let prediction = try XCTUnwrap(forecast.prediction(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now))
        XCTAssertEqual(prediction.evidence, .recentMovement); XCTAssertTrue(prediction.hasUsableTime)
        let display = forecast.display(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now)
        XCTAssertTrue(display.label.contains("分")); XCTAssertNotNil(display.prediction)
        let conflict = forecast.display(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now, officialSeconds: 720)
        XCTAssertEqual(conflict.label, conflict.positionLabel); XCTAssertNil(conflict.prediction)
        XCTAssertTrue(conflict.explanation.contains("候車請以官方下一班為準"))
        for status in [-1, -2, -3, -4] {
            let unavailable = forecast.display(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now, officialSeconds: status)
            XCTAssertNil(unavailable.prediction)
            XCTAssertTrue(unavailable.explanation.contains(EstimateFeed.label(status)))
        }
    }

    func testParkingAndALongUnobservedGapDoNotBecomeFiftyFourMinuteClaims() throws {
        let (metadata, ride) = source(count: 32, boarding: 20)
        var forecast = VehicleArrivalForecast()
        for (age, along) in [(180.0, 100.0), (90.0, 135.0), (0.0, 135.0)] {
            forecast.ingest([bus(along: along, age: age, speed: 0, metadata: metadata)], metadata: metadata, at: now.addingTimeInterval(-age))
        }
        let vehicle = bus(along: 135, speed: 0, metadata: metadata)
        let raw = try XCTUnwrap(forecast.prediction(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now))
        XCTAssertGreaterThan(raw.seconds, 3_000); XCTAssertFalse(raw.hasUsableTime)
        let display = forecast.display(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now, officialSeconds: 720)
        XCTAssertTrue(display.label.contains("站")); XCTAssertNil(display.prediction)
        XCTAssertEqual(try XCTUnwrap(forecast.prediction(vehicle, stopID: ride.boarding.id, metadata: metadata,
            at: now.addingTimeInterval(30))).seconds, raw.seconds, accuracy: 0.01, "Stopped vehicles do not count down")
        forecast.ingest([bus(along: 300, age: -100, speed: 0, metadata: metadata)], metadata: metadata, at: now.addingTimeInterval(100))
        XCTAssertNil(forecast.prediction(bus(along: 300, age: -100, speed: 0, metadata: metadata), stopID: ride.boarding.id,
            metadata: metadata, at: now.addingTimeInterval(100)), "Reset travel history after a long reporting gap")
    }

    func testFreshMovingGPSOffersUsefulShortEstimateImmediately() throws {
        let (metadata, ride) = source()
        let vehicle = bus(along: 250, metadata: metadata)
        let forecast = VehicleArrivalForecast()
        let prediction = try XCTUnwrap(forecast.prediction(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now))
        XCTAssertEqual(prediction.evidence, .routeProgress)
        XCTAssertTrue(prediction.hasUsableTime)
        let display = forecast.display(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now)
        XCTAssertNotNil(display.prediction); XCTAssertTrue(display.label.contains("約")); XCTAssertTrue(display.label.contains("分"))
        XCTAssertFalse(display.label.contains("–"))
        var snapshot = TransitSnapshot(); snapshot.vehicles = [vehicle]
        XCTAssertEqual(forecast.departures(for: ride, metadata: metadata, snapshot: snapshot, at: now).count, 1)
        XCTAssertNil(forecast.prediction(bus(along: 10, speed: 0, metadata: metadata), stopID: ride.boarding.id, metadata: metadata, at: now))
    }

    func testOneMissingPacketAndUnchangedMetadataRefreshPreserveLearning() throws {
        var (metadata, ride) = source()
        var forecast = VehicleArrivalForecast()
        for (age, along) in [(60.0,100.0),(30.0,250.0)] {
            forecast.ingest([bus(along: along, age: age, metadata: metadata)], metadata: metadata, at: now.addingTimeInterval(-age))
        }
        forecast.ingest([], metadata: metadata, at: now.addingTimeInterval(-15))
        metadata.rebuildJourneys()
        let vehicle = bus(along: 400, metadata: metadata)
        forecast.ingest([vehicle], metadata: metadata, at: now)
        let result = try XCTUnwrap(forecast.prediction(vehicle, stopID: ride.boarding.id, metadata: metadata, at: now))
        XCTAssertEqual(result.evidence,.recentMovement)
        XCTAssertTrue(result.hasUsableTime)
    }

    func testHourOfGPSIncludesStopsMissingPacketsTurnaroundsAndMetadataRefresh() throws {
        var (metadata, ride) = source(count: 80, boarding: 40)
        var forecast = VehicleArrivalForecast()
        var usable = 0
        for second in stride(from: 0, through: 3_600, by: 15) {
            let date = now.addingTimeInterval(Double(second))
            if second > 0, second % 300 == 0 { metadata.rebuildJourneys() }
            let length = metadata.line(ride.route.id, direction: ride.direction)!.length
            let vehicles = (0..<24).compactMap { id -> BusVehicle? in
                if second % 105 == 0, id % 5 == 0 { return nil }
                let travelled = Double(second-(second/120)*20-min(second%120,20)) * 5 + Double(id)*400
                let along = travelled.truncatingRemainder(dividingBy:length)
                return bus("long-\(id)", along: along, age: -Double(second), speed: second % 120 < 20 ? 0 : 18, metadata: metadata)
            }
            forecast.ingest(vehicles,metadata:metadata,at:date)
            var snapshot = TransitSnapshot(); snapshot.vehicles = vehicles
            let departures = forecast.departures(for:ride,metadata:metadata,snapshot:snapshot,at:date)
            XCTAssertEqual(departures.map(\.seconds),departures.map(\.seconds).sorted())
            for departure in departures { XCTAssertTrue(departure.seconds.isFinite); XCTAssertGreaterThanOrEqual(departure.seconds,0) }
            usable += departures.count
            let wait = BoardingTime.wait(official:nil,readyAt:300,buffer:60,departures:departures)
            if wait.evidence == .gps { XCTAssertGreaterThanOrEqual(try XCTUnwrap(wait.departureSeconds),360) }
        }
        XCTAssertGreaterThan(usable,200)
    }

    func testDelayedOrOppositeHeadingGPSNeverPromisesArrival() throws {
        let (metadata, ride) = source()
        var forecast = VehicleArrivalForecast()
        for (age, along) in [(60.0, 100.0), (30.0, 250.0), (0.0, 400.0)] {
            forecast.ingest([bus(along: along, age: age, metadata: metadata)], metadata: metadata, at: now.addingTimeInterval(-age))
        }
        let moving = bus(along: 400, metadata: metadata)
        let delayed = forecast.display(moving, stopID: ride.boarding.id, metadata: metadata, at: now.addingTimeInterval(31))
        XCTAssertNil(delayed.prediction); XCTAssertEqual(delayed.label, "位置更新中")
        XCTAssertTrue(delayed.positionLabel.hasPrefix("上次位置"))
        let near = bus(along: metadata.journey(routeID: ride.route.id, direction: "0")!.anchors[4].match.along - 10, metadata: metadata)
        XCTAssertNil(forecast.prediction(near, stopID: ride.boarding.id, metadata: metadata, at: now.addingTimeInterval(31)))
        let wrongHeading = bus(along: 400, heading: 270, metadata: metadata)
        XCTAssertNil(forecast.prediction(wrongHeading, stopID: ride.boarding.id, metadata: metadata, at: now))
    }

    func testMeasuredSegmentsShareBetweenEquivalentOperatorsButNotDifferentDetours() throws {
        var (metadata, ride) = source()
        metadata.routes["operator-b"] = BusRoute(id: "operator-b", parentID: "family", name: "630", variantName: "630 B",
            departure: "起点", destination: "终点")
        metadata.paths["operator-b"] = metadata.paths["operator-a"]
        metadata.lines["sub:operator-b"] = metadata.lines["sub:operator-a"]
        metadata.rebuildJourneys()
        var forecast = VehicleArrivalForecast()
        let line = metadata.line("operator-a")!
        for index in 0...5 {
            let age = Double(5 - index) * 60
            let vehicles = (1...3).map { bus("learn-\($0)", along: line.cumulative[index] + 10,
                age: age, route: $0 == 3 ? "operator-b" : "operator-a", metadata: metadata) }
            forecast.ingest(vehicles, metadata: metadata, at: now.addingTimeInterval(-age))
        }
        let stopped = bus("stopped", along: line.cumulative[2] + 50, speed: 0, route: "operator-b", metadata: metadata)
        let measured = try XCTUnwrap(forecast.prediction(stopped, stopID: ride.boarding.id, metadata: metadata, at: now))
        XCTAssertEqual(measured.evidence, .roadHistory); XCTAssertTrue(measured.hasUsableTime)
        // Same stop order with a different road in between must not borrow the other operator's traffic.
        var coordinates = line.coordinates
        coordinates.insert(Coordinate(latitude: 25.0815, longitude: 121.596), at: 4)
        metadata.lines["sub:operator-b"] = RouteLine(coordinates: coordinates); metadata.rebuildJourneys()
        let detour = bus("detour", along: line.cumulative[2] + 50, speed: 0, route: "operator-b", metadata: metadata)
        XCTAssertNil(forecast.prediction(detour, stopID: ride.boarding.id, metadata: metadata, at: now))
    }
}
