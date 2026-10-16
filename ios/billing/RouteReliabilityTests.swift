import XCTest
import MapKit
@testable import TransitCore
@testable import TaipeiBus

/// The production entry point, full bundled network and real street provider. No
/// preverified options or fabricated pedestrian geometry may make this test pass.
@MainActor final class RouteReliabilityTests: XCTestCase {
    let campus = Coordinate(latitude: 25.01945, longitude: 121.53955)

    func testTemporaryStreetFailureDoesNotEnterUnreachableCache() async throws {
        let p = JourneyPlannerModel(); defer { p.finish() }
        let leg = WalkingLeg(from:campus,to:.init(latitude:25.026154,longitude:121.543636))
        var calls = 0
        p.testStreet = { value,_ in
            calls += 1
            if calls == 1 { throw NSError(domain:MKErrorDomain,code:Int(MKError.Code.serverFailure.rawValue)) }
            var checked = value; checked.distance = 1200; checked.duration = 900
            checked.coordinates = [value.from,value.to]; return checked
        }
        let failed = try await p.auditStreet(leg)
        XCTAssertFalse(failed.verified); XCTAssertTrue(failed.temporaryStreetFailure)
        let recovered = try await p.auditStreet(leg)
        XCTAssertTrue(recovered.verified); XCTAssertEqual(calls,2)
    }

    func testInterruptedBikeAccessDoesNotDownloadTheRideAndEgress() async throws {
        let p = JourneyPlannerModel(); defer { p.finish() }
        let pickup = BikeStation(id:"p",name:"pickup",coordinate:.init(latitude:25.0195,longitude:121.54),capacity:30)
        let dropoff = BikeStation(id:"d",name:"dropoff",coordinate:.init(latitude:25.026,longitude:121.543),capacity:30)
        let end = Coordinate(latitude:25.026154,longitude:121.543636)
        var leg = WalkingLeg(from:campus,to:end)
        leg.bike = BikeLeg(BikeConnection(pickup:pickup,dropoff:dropoff,bikes:8,docks:8,
            accessMeters:100,rideMeters:900,egressMeters:100,accessSeconds:80,
            rideSeconds:300,egressSeconds:80,handlingSeconds:60))
        var calls = 0
        p.testStreet = { _,_ in
            calls += 1
            throw NSError(domain:MKErrorDomain,code:Int(MKError.Code.serverFailure.rawValue))
        }
        let failed = try await p.verifyCyclingLegForTest(leg)
        XCTAssertFalse(failed.verified); XCTAssertTrue(failed.temporaryStreetFailure)
        XCTAssertEqual(calls,1,"No cycling or onward request is useful until the pickup walk is confirmed")
    }

    func testProductionSearchRetriesAfterAnInitialProviderInterruption() async throws {
        let service = TransitService(), p = JourneyPlannerModel(); defer { p.finish() }
        let loaded = await service.offlineMetroMetadata(), metadata = try XCTUnwrap(loaded)
        var failedAt: Date?, failures = 0
        p.testStreet = { value,_ in
            let now = Date(); if failedAt == nil { failedAt = now }
            if now.timeIntervalSince(failedAt!) < 1.5 {
                failures += 1
                throw NSError(domain:MKErrorDomain,code:Int(MKError.Code.unknown.rawValue))
            }
            var checked = value
            checked.distance = value.from.distance(to:value.to)*1.2
            checked.duration = (checked.distance ?? 0)/1.25
            checked.coordinates = [value.from,value.to]; return checked
        }
        p.setDestination(TravelPlace(name:"內湖站",address:"",coordinate:.init(latitude:25.083675,longitude:121.594363)),
            metadata:metadata,currentLocation:campus)
        for _ in 0..<1200 {
            if !p.planning && !p.checkingWalks { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertGreaterThan(failures,0)
        XCTAssertLessThanOrEqual(failures,2,"A shared provider interruption must stop the batch instead of querying every platform")
        XCTAssertTrue(p.options.contains { $0.verified && $0.walkIssue == nil })
        XCTAssertNil(p.message,"A temporary first pass must recover within the same search")
    }

    func testZhihongIndoorFixRetainsTheProviderWalkingRoute() async throws {
        let p = JourneyPlannerModel(); p.auditStreetDiagnostics = true
        defer { p.finish() }
        let from = Coordinate(latitude:25.0189833,longitude:121.5396361)
        let entrance = Coordinate(latitude:25.026154,longitude:121.543636)
        let leg = try await p.auditStreet(WalkingLeg(from:from,to:entrance))
        XCTAssertTrue(leg.verified,"The provider has a real walking route; an ordinary building-access offset must not delete it")
    }

    func testZhihongToBothReportedDestinationsThroughProductionPlanner() async throws {
        let from = Coordinate(latitude:25.0189833,longitude:121.5396361)
        try await verifyOtherJourney(from:from,to:.init(latitude:25.083675,longitude:121.594363),name:"Zhihong_Neihu")
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "牛肆 吉林路"
        request.region = PlaceSearch.region
        let search = try await MKLocalSearch(request:request).start()
        let shop = try XCTUnwrap(search.mapItems.first { $0.name?.contains("牛肆") == true })
        let point = shop.placemark.coordinate
        print("REPORTED_SHOP name=\(shop.name ?? "") latitude=\(point.latitude) longitude=\(point.longitude)")
        try await verifyOtherJourney(from:from,to:.init(latitude:point.latitude,longitude:point.longitude),name:"Zhihong_NiuSi")
    }

    func testRepeatedProductionSearchWithMovingOriginAndCancelledComparisons() async throws {
        let service = TransitService(), p = JourneyPlannerModel()
        defer { p.finish() }
        let loaded = await service.offlineMetroMetadata(), metadata = try XCTUnwrap(loaded)
        let bikes = await service.bikeNetwork(), counts = await service.bikeAvailability(network:bikes)
        p.updateBikes(network:bikes,availability:counts)
        p.updateSnapshot(await service.refresh()); p.auditStreetDiagnostics = true
        let neihu = try XCTUnwrap(metadata.metro.stations.first { $0.code == "BR19" })
        let targets = [neihu.coordinate, Coordinate(latitude:25.0678,longitude:121.5303)]
        let origins = [campus, Coordinate(latitude:25.01967,longitude:121.53943),
            Coordinate(latitude:25.0202,longitude:121.5397), Coordinate(latitude:25.0185,longitude:121.5385),
            Coordinate(latitude:25.0189833,longitude:121.5396361), Coordinate(latitude:25.0189833,longitude:121.5394361)]
        for index in 0..<12 {
            let start = Date(), from = origins[index % origins.count], to = targets[index % targets.count]
            // Changing origin starts work for the old target; selecting the next
            // target immediately cancels it, just as two consecutive user edits do.
            p.useLocation(from,metadata:metadata)
            p.setDestination(TravelPlace(name:"Repeat-\(index)",address:"",coordinate:to),metadata:metadata,currentLocation:from)
            for _ in 0..<1200 {
                if p.options.contains(where: { $0.verified && $0.walkIssue == nil }) { break }
                if !p.planning && !p.checkingWalks { break }
                try await Task.sleep(for:.milliseconds(100))
            }
            let checked = p.options.filter { $0.verified && $0.walkIssue == nil }
            print("REPEATED_PLAN index=\(index) from=\(from) to=\(to) seconds=\(Date().timeIntervalSince(start)) checked=\(checked.count) planning=\(p.planning) checking=\(p.checkingWalks) message=\(p.message ?? "nil")")
            XCTAssertFalse(checked.isEmpty,"Repeated search \(index) must retain an actual verified street connection")
            if checked.isEmpty { break }
        }
    }

    private func verifyOtherJourney(from: Coordinate, to: Coordinate, name: String) async throws {
        let service = TransitService(), p = JourneyPlannerModel()
        defer { p.finish() }
        let loaded = await service.offlineMetroMetadata(), metadata = try XCTUnwrap(loaded)
        let bikes = await service.bikeNetwork(), counts = await service.bikeAvailability(network:bikes)
        let snapshot = await service.refresh()
        p.auditStreetDiagnostics = true
        p.updateBikes(network:bikes,availability:counts); p.updateSnapshot(snapshot)
        p.setDestination(TravelPlace(name:name,address:"",coordinate:to),metadata:metadata,currentLocation:from)
        for _ in 0..<1500 {
            if !p.planning, !p.checkingWalks { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        let checked = p.options.filter { $0.verified && $0.walkIssue == nil }
        print("GENERAL_JOURNEY name=\(name) checked=\(checked.count) message=\(p.message ?? "nil")")
        for option in checked {
            print("GENERAL_OPTION name=\(name) modes=\(option.rides.map { $0.route.mode.rawValue }) routes=\(option.rides.map { $0.route.name }) bikes=\(option.walks.filter { $0.bike != nil }.count) total=\(p.duration(option,at:Date())?.totalSeconds ?? -1)")
        }
        XCTAssertFalse(checked.isEmpty,"\(name) must work through the same production planner")
        XCTAssertTrue(checked.contains { !$0.rides.isEmpty },"These cross-city journeys must retain a checked transit option")
        XCTAssertNil(p.message)
    }
    func testNeihuToNTUUsesTheSameProductionFlowInReverse() async throws {
        try await verifyOtherJourney(from:.init(latitude:25.083675,longitude:121.594363),to:campus,name:"Neihu_NTU")
    }
    func testNTUToXimenUsesTheSameProductionFlowAcrossDifferentLines() async throws {
        try await verifyOtherJourney(from:campus,to:.init(latitude:25.0434,longitude:121.5062),name:"NTU_Ximen")
    }
    func testCityHallToMiramarUsesTheSameProductionFlowForALandmark() async throws {
        try await verifyOtherJourney(from:.init(latitude:25.041171,longitude:121.565227),
            to:.init(latitude:25.0835,longitude:121.5584),name:"CityHall_Miramar")
    }

    func testCampusToNeihuProductionPlanningWithCurrentSupply() async throws {
        let service = TransitService()
        let loaded = await service.offlineMetroMetadata()
        let metadata = try XCTUnwrap(loaded)
        let station = try XCTUnwrap(metadata.metro.stations.first { $0.code == "BR19" })
        let bikes = await service.bikeNetwork()
        let counts = await service.bikeAvailability(network: bikes)
        let snapshot = await service.refresh()
        print("LIVE_FEEDS gps_age=\(snapshot.sourceUpdatedAt.map { Date().timeIntervalSince($0) } ?? -1) eta_age=\(snapshot.estimates.updatedAt.map { Date().timeIntervalSince($0) } ?? -1) vehicles=\(snapshot.vehicles.count) gps_error=\(snapshot.vehicleError ?? "nil") eta_error=\(snapshot.estimates.error ?? "nil") bikes=\(counts?.docks.count ?? 0)")
        let p = JourneyPlannerModel()
        p.auditStreetDiagnostics = true
        p.updateBikes(network: bikes, availability: counts)
        p.updateSnapshot(snapshot)
        let started = Date()
        p.setDestination(TravelPlace(name: "內湖站", address: "", coordinate: station.coordinate),
                         metadata: metadata, currentLocation: campus)
        var first: Double?
        for _ in 0..<1200 {
            if first == nil, p.options.contains(where: { $0.verified && $0.walkIssue == nil }) {
                first = Date().timeIntervalSince(started)
                print("FIRST_CHECKED seconds=\(first!) options=\(p.options.count)")
            }
            if !p.planning, !p.checkingWalks { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("CAMPUS_NEIHU elapsed=\(Date().timeIntervalSince(started)) planning=\(p.planning) checking=\(p.checkingWalks) message=\(p.message ?? "nil") options=\(p.options.count)")
        for option in p.options {
            print("CHECKED_OPTION id=\(option.id) verified=\(option.verified) issue=\(option.walkIssue ?? "nil") walks=\(option.walks.map { $0.distance ?? -1 }) total=\(p.duration(option, at: Date())?.totalSeconds ?? -1)")
        }
        XCTAssertNotNil(first, "An ordinary campus-to-station journey must not end with every choice removed")
        XCTAssertFalse(p.options.isEmpty)
        XCTAssertTrue(p.options.contains { $0.verified && $0.walkIssue == nil })
        p.finish()
    }

    func testCampusStreetAnchorsAndNeihuStationCentre() async throws {
        let service = TransitService(), p = JourneyPlannerModel()
        let loaded = await service.offlineMetroMetadata(), metadata = try XCTUnwrap(loaded)
        let neihu = try XCTUnwrap(metadata.metro.stations.first { $0.code == "BR19" })
        let technology = try XCTUnwrap(metadata.metro.stations.first { $0.code == "BR08" })
        let entrance = try XCTUnwrap(metadata.metro.nearestExit(stationID: technology.id, to: campus))
        let neihuExit = try XCTUnwrap(metadata.metro.nearestExit(stationID: neihu.id, to: neihu.coordinate))
        p.auditStreetDiagnostics = true
        for (from, to) in [(campus, entrance.coordinate),
                            (Coordinate(latitude:25.01965, longitude:121.53965), entrance.coordinate),
                            (neihuExit.coordinate, neihu.coordinate)] {
            let leg = try await p.auditStreet(WalkingLeg(from: from, to: to))
            print("ANCHOR_CHECK from=\(from) to=\(to) verified=\(leg.verified) meters=\(leg.distance ?? -1)")
        }
        p.finish()
    }
}
