import XCTest
import MapKit
@testable import TransitCore
@testable import TaipeiBus

private final class BikeTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_792_108_800)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private final class BikeFeedProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var status = 200
    private static var requests: [URLRequest] = []
    static func configure(_ data: Data, status: Int = 200, reset: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        payload = data; self.status = status
        if reset { requests = [] }
    }
    static var recorded: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let bytes = Self.payload, status = Self.status
        Self.lock.unlock()
        Thread.sleep(forTimeInterval: 0.08)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["ETag":"bike-report"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class BikeResponseTests: XCTestCase {
    func packet(at date: Date) throws -> Data {
        try JSONSerialization.data(withJSONObject: [["sno":"test", "available_rent_bikes":8,
            "available_return_bikes":12, "Quantity":30, "act":"1",
            "infoTime":ISO8601DateFormatter().string(from: date)]])
    }
    func network() -> BikeNetwork {
        BikeNetwork(stations:[BikeStation(id:"test",name:"測試站",coordinate:Coordinate(latitude:25.04,longitude:121.54),capacity:30)])
    }
    func folder() throws -> URL {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("bike-response-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return directory
    }
    func service(_ directory: URL, clock: BikeTestClock) -> TransitService {
        let config=URLSessionConfiguration.ephemeral
        config.protocolClasses=[BikeFeedProtocol.self]
        let session=URLSession(configuration:config)
        addTeardownBlock { session.invalidateAndCancel() }
        return TransitService(bikeSession:session,cacheDirectory:directory,bikeNow:{ clock.now })
    }
    func testConcurrentFirstLoadsShareTheSameSuccessfulDownload() async throws {
        let clock=BikeTestClock(), s=service(try folder(),clock:clock), bikes=network()
        BikeFeedProtocol.configure(try packet(at:clock.now))
        async let first=s.bikeAvailability(network:bikes)
        async let second=s.bikeAvailability(network:bikes)
        let (one,two)=await(first,second)
        XCTAssertEqual(one?.dock("test")?.rentable,8)
        XCTAssertEqual(two,one,"The second caller must await the report instead of seeing an empty cache")
        XCTAssertEqual(BikeFeedProtocol.recorded.count,1)
        let again=await s.bikeAvailability(network:bikes)
        XCTAssertEqual(again,one);XCTAssertEqual(BikeFeedProtocol.recorded.count,1)
    }
    func testRecentCountsAreReadyAtRelaunchWithoutResettingTheirAge() async throws {
        let clock=BikeTestClock(), directory=try folder(), bikes=network(), original=clock.now
        BikeFeedProtocol.configure(try packet(at:original))
        let first=service(directory,clock:clock)
        _=await first.bikeAvailability(network:bikes)
        clock.advance(120)
        let relaunched=service(directory,clock:clock)
        let cache=await relaunched.cachedBikeAvailability(network:bikes)
        XCTAssertEqual(try XCTUnwrap(cache).receivedAt.timeIntervalSince(original),0,accuracy:1)
        XCTAssertEqual(cache?.dock("test")?.observedAt,original)
        XCTAssertEqual(cache?.dock("test",at:clock.now)?.rentable,8)
        XCTAssertEqual(BikeFeedProtocol.recorded.count,1,"Reading the recent file does not wait for a network request")
        clock.advance(900)
        let stale=service(directory,clock:clock)
        let expired=await stale.cachedBikeAvailability(network:bikes)
        XCTAssertNil(expired,"Old reports must never become current by reopening the app")
    }
    func testFailedFirstDownloadCanRetryAfterTenSecondsInsteadOfWaitingAMinute() async throws {
        let clock=BikeTestClock(), s=service(try folder(),clock:clock), bikes=network()
        BikeFeedProtocol.configure(Data(),status:500)
        let missing=await s.bikeAvailability(network:bikes);XCTAssertNil(missing)
        clock.advance(9)
        _=await s.bikeAvailability(network:bikes)
        XCTAssertEqual(BikeFeedProtocol.recorded.count,1)
        clock.advance(2)
        BikeFeedProtocol.configure(try packet(at:clock.now),reset:false)
        let recovered=await s.bikeAvailability(network:bikes)
        XCTAssertEqual(recovered?.dock("test")?.rentable,8)
        XCTAssertEqual(BikeFeedProtocol.recorded.count,2)
    }
    func testUnchangedOrFailedRefreshPreservesTheStationsOriginalReportTime() async throws {
        let clock=BikeTestClock(), s=service(try folder(),clock:clock), bikes=network(), original=clock.now
        BikeFeedProtocol.configure(try packet(at:original))
        _=await s.bikeAvailability(network:bikes)
        clock.advance(61)
        BikeFeedProtocol.configure(Data(),status:304,reset:false)
        let unchanged=await s.bikeAvailability(network:bikes)
        XCTAssertEqual(unchanged?.dock("test")?.observedAt,original)
        XCTAssertEqual(BikeFeedProtocol.recorded.last?.value(forHTTPHeaderField:"If-None-Match"),"bike-report")
        clock.advance(61)
        BikeFeedProtocol.configure(Data(),status:503,reset:false)
        let failed=await s.bikeAvailability(network:bikes)
        XCTAssertEqual(failed,unchanged)
        XCTAssertEqual(failed?.receivedAt,original)
    }
    func testFreshlySavedFileCannotReviveOldStationCounts() async throws {
        let clock=BikeTestClock(), directory=try folder()
        let file=directory.appendingPathComponent("YouBikeImmediate.json")
        try packet(at:clock.now.addingTimeInterval(-1800)).write(to:file)
        try FileManager.default.setAttributes([.modificationDate:clock.now],ofItemAtPath:file.path)
        let s=service(directory,clock:clock)
        let cached=await s.cachedBikeAvailability(network:network())
        XCTAssertNil(cached)
    }
    func testStreetRequestsShareEndpointsButNeverMixWalkingAndCycling() async throws {
        let p=JourneyPlannerModel(), leg=WalkingLeg(from:Coordinate(latitude:25.04,longitude:121.54),to:Coordinate(latitude:25.04,longitude:121.55))
        var calls: [UInt] = []
        p.testStreet = { input, mode in
            calls.append(mode.rawValue)
            try await Task.sleep(for:.milliseconds(80))
            var result=input;result.duration=mode == .cycling ? 200 : 700
            return result
        }
        async let first=p.auditStreet(leg)
        async let second=p.auditStreet(leg)
        let (one,two)=try await(first,second)
        XCTAssertEqual(one.duration,two.duration);XCTAssertEqual(calls.count,1)
        let bicycle=try await p.auditStreet(leg,cycling:true)
        XCTAssertEqual(bicycle.duration,200);XCTAssertEqual(calls.count,2)
    }
    func testBikeMinutesExcludeWalkingHandlingAndStationTimeButTheTotalIncludesAllOfThem() throws {
        let p=JourneyPlannerModel(), point=Coordinate(latitude:25.04,longitude:121.54)
        let station=BikeStation(id:"s",name:"借車站",coordinate:point,capacity:30)
        var bike=BikeLeg(pickup:station,dropoff:station,bikes:8,docks:8,handlingSeconds:150)
        bike.rideSeconds=300;bike.toPickupSeconds=180;bike.fromDropoffSeconds=120
        var leg=WalkingLeg(from:point,to:point,duration:bike.totalSeconds+90)
        leg.bike=bike;leg.stationSeconds=90
        let option=JourneyOption(id:"test",trip:nil,walks:[leg])
        XCTAssertEqual(bike.ridingMinutes,5)
        XCTAssertEqual(leg.timeLabel,AppText.text("騎車 %@ 分",5))
        let total=try XCTUnwrap(p.duration(option,at:Date()))
        XCTAssertEqual(total.totalSeconds,840,accuracy:0.001)
        XCTAssertEqual(total.cyclingSeconds-total.cyclingHandlingSeconds,300,accuracy:0.001)
        XCTAssertEqual(total.walkingSeconds-total.cyclingSeconds,390,accuracy:0.001)
        XCTAssertEqual(total.breakdownLabel,AppText.text("步行 %@ 分 · 騎車 %@ 分",7,5)+AppText.text(" · 取還車 %@ 分",3))
    }
    func testFreshOrLateBikeCountsAreComparedBeforeTheWalkingQueueFinishes() async throws {
        for late in [false,true] {
            let base=transit("base"), p=JourneyPlannerModel(), now=Date()
            let stations=base.walks.enumerated().flatMap { index,leg in
                [BikeStation(id:"\(index)a",name:"借車",coordinate:leg.from,capacity:30),
                 BikeStation(id:"\(index)b",name:"還車",coordinate:leg.to,capacity:30)]
            }
            let bikes=BikeNetwork(stations:stations)
            let counts=BikeAvailability(docks:Dictionary(uniqueKeysWithValues:stations.map {
                ($0.id,BikeDock(stationID:$0.id,rentable:8,returnable:8,capacity:30,active:true,observedAt:now))
            }),receivedAt:now)
            p.updateBikes(network:bikes,availability:late ? nil : counts)
            p.auditLoadChoices([base],from:TravelPlace(name:"出發",address:"",coordinate:base.walks[0].from),
                to:TravelPlace(name:"目的地",address:"",coordinate:base.walks.last!.to))
            var streetCalls=0, callsAtFirstBike: Int?
            p.testStreet = { input,_ in
                streetCalls += 1
                if late,streetCalls == 1 { p.updateBikes(network:bikes,availability:counts) }
                try await Task.sleep(for:.milliseconds(20))
                var result=input;result.duration=1000;return result
            }
            p.testCycle = { input in
                if callsAtFirstBike == nil { callsAtFirstBike=streetCalls }
                var result=input
                result.duration=try XCTUnwrap(input.bike).totalSeconds
                return result
            }
            var choices: [JourneyOption]=[]
            for index in 0..<12 {
                var option=transit("route-\(index)")
                for slot in option.walks.indices {
                    option.walks[slot].duration=nil
                    // Distinct pedestrian endpoints keep this a real queue instead of cache hits.
                    let source=option.walks[slot].from
                    let to=option.walks[slot].to
                    option.walks[slot]=WalkingLeg(from:Coordinate(latitude:source.latitude+Double(index)*0.000001,longitude:source.longitude),to:to)
                }
                choices.append(option)
            }
            await p.auditVerifyConnections(choices)
            XCTAssertLessThan(try XCTUnwrap(callsAtFirstBike),8,"late=\(late): cycling cannot wait behind all 12 ordinary routes")
            XCTAssertTrue(p.options.contains(where:\.cycles))
            XCTAssertFalse(p.started)
        }
    }
    private func transit(_ id: String) -> JourneyOption {
        let a=Coordinate(latitude:25.04,longitude:121.54), b=Coordinate(latitude:25.04,longitude:121.555)
        let c=Coordinate(latitude:25.06,longitude:121.57), d=Coordinate(latitude:25.06,longitude:121.585)
        var route=BusRoute(id:id,parentID:id,name:id,variantName:"",departure:"上車",destination:"下車")
        route.mode = .metro;route.lineCode="G"
        let stops=[BusStop(id:id+"a",routeID:id,stationID:id+"a",name:"上車",direction:"0",sequence:1,coordinate:b),
                   BusStop(id:id+"b",routeID:id,stationID:id+"b",name:"下車",direction:"0",sequence:2,coordinate:c)]
        let ride=TransitRide(route:route,direction:"0",stops:stops,coordinates:[b,c])
        let trip=TransitTrip(rides:[ride],accessDistance:a.distance(to:b),egressDistance:c.distance(to:d),transferDistance:0,score:0,rideSeconds:[600])
        return JourneyOption(id:trip.id,trip:trip,walks:[WalkingLeg(from:a,to:b,duration:1500),WalkingLeg(from:c,to:d,duration:1500)])
    }
}
