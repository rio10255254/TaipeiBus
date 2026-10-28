import XCTest
@testable import TransitCore
@testable import TaipeiBus

private final class RecoveryFeedProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var statuses: [String: Int] = [:]
    private static var delays: [String: Double] = [:]
    private static var captured: [String] = []
    private var delivery: DispatchWorkItem?
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return captured }
    static func configure(statuses: [String: Int] = [:], delays: [String: Double] = [:]) {
        lock.lock(); defer { lock.unlock() }
        Self.statuses = statuses; Self.delays = delays; captured = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tcgbusfs.blob.core.windows.net" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let name = request.url!.deletingPathExtension().lastPathComponent
        Self.lock.lock(); Self.captured.append(name)
        let status = Self.statuses[name] ?? 200, delay = Self.delays[name] ?? 0.02
        Self.lock.unlock()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 28800); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let row: [String: Any] = name == "GetBusData"
            ? ["BusID":"TEST-1", "CarID":"test", "RouteID":"r", "GoBack":"0", "Latitude":"25.04", "Longitude":"121.54", "DataTime":timestamp]
            : ["RouteID":"r", "StopID":"s", "EstimateTime":"300"]
        let bytes = try! JSONSerialization.data(withJSONObject: ["EssentialInfo":["UpdateTime":timestamp], "BusInfo":[row]])
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status == 200 { self.client?.urlProtocol(self, didLoad: bytes) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        delivery = work; DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
    override func stopLoading() { delivery?.cancel() }
}

private actor PartialFeedRecorder {
    var values: [TransitSnapshot] = []
    func append(_ value: TransitSnapshot) { values.append(value) }
}

@MainActor final class FeedRecoveryTests: XCTestCase {
    private func service() -> TransitService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryFeedProtocol.self]
        return TransitService(feedSession: URLSession(configuration: configuration), busSources: Self.taipei)
    }
    /// One city's files: these tests count requests and follow a single feed's recovery.
    private static let taipei = Array(RegionCatalog.shared.sources(.bus).prefix(1))
    func testArrivalFeedPublishesBeforeSlowerGPSFinishes() async throws {
        RecoveryFeedProtocol.configure(delays: ["GetBusData":0.35])
        let service = service(), recorder = PartialFeedRecorder()
        let value = await service.refresh { await recorder.append($0) }
        let partials = await recorder.values
        XCTAssertNotNil(partials.first?.estimates.updatedAt)
        XCTAssertNil(partials.first?.sourceUpdatedAt)
        XCTAssertNotNil(value.sourceUpdatedAt); XCTAssertNil(value.vehicleError)
        XCTAssertTrue((298...300).contains(try XCTUnwrap(value.estimates.value(routeID:"r", stopID:"s", at:Date()))))
    }
    func testFailedGPSKeepsFreshArrivalsAndRecoversOnNextPoll() async {
        RecoveryFeedProtocol.configure(statuses: ["GetBusData":503])
        let service = service(), interrupted = await service.refresh()
        XCTAssertNotNil(interrupted.vehicleError); XCTAssertNil(interrupted.estimates.error)
        XCTAssertNotNil(interrupted.estimates.updatedAt)
        RecoveryFeedProtocol.configure()
        let recovered = await service.refresh()
        XCTAssertNil(recovered.vehicleError); XCTAssertNotNil(recovered.sourceUpdatedAt)
        XCTAssertEqual(recovered.estimates.updatedAt,interrupted.estimates.updatedAt)
        XCTAssertGreaterThan(recovered.revision,interrupted.revision)
    }
    func testCancelledRefreshCannotCaptureTheNewForegroundRequest() async throws {
        RecoveryFeedProtocol.configure(delays: ["GetBusData":0.3,"GetEstimateTime":0.3])
        let service = service(), old = Task { await service.refresh() }
        for _ in 0..<100 {
            if RecoveryFeedProtocol.requests.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(RecoveryFeedProtocol.requests.count,2)
        old.cancel()
        let resumed = await service.refresh()
        _ = await old.value
        XCTAssertNotNil(resumed.sourceUpdatedAt,"The foreground refresh must not join a cancelled background request")
        XCTAssertNotNil(resumed.estimates.updatedAt,"A cancelled ETA attempt must not suppress the first foreground ETA download")
        XCTAssertNil(resumed.vehicleError); XCTAssertNil(resumed.estimates.error)
        XCTAssertGreaterThanOrEqual(RecoveryFeedProtocol.requests.count,4)
        let next = await service.refresh()
        XCTAssertGreaterThan(next.revision,resumed.revision)
    }
    func testSlowCatalogDownloadsCannotHoldTheAppsLiveArrivalLoop() async throws {
        RecoveryFeedProtocol.configure(delays: ["GetRoute":3,"GetStop":3,"GetPathDetail":3,"GetProvider":3,"GetBusShape":3])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryFeedProtocol.self]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = TransitService(feedSession: URLSession(configuration:configuration),cacheDirectory:folder,busSources:Self.taipei)
        _ = await service.offlineMetroMetadata()
        let model = TransitAppModel(service:service)
        model.setActive(true)
        defer { model.setActive(false) }
        let started = Date()
        for _ in 0..<100 {
            if model.snapshot.sourceUpdatedAt != nil, model.snapshot.estimates.updatedAt != nil { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertNotNil(model.snapshot.sourceUpdatedAt)
        XCTAssertNotNil(model.snapshot.estimates.updatedAt)
        XCTAssertLessThan(Date().timeIntervalSince(started),2.5,"Live polling must start before the slow metadata downloads finish")
        XCTAssertFalse(model.loading)
        let requests = RecoveryFeedProtocol.requests
        print("FIRST_LIVE_FEEDS seconds=\(Date().timeIntervalSince(started)) requests=\(requests)")
        let gps = try XCTUnwrap(requests.firstIndex(of:"GetBusData"))
        let eta = try XCTUnwrap(requests.firstIndex(of:"GetEstimateTime"))
        if let catalog = requests.firstIndex(where: { ["GetRoute","GetStop","GetPathDetail","GetProvider","GetBusShape"].contains($0) }) {
            XCTAssertLessThan(gps,catalog,"Live GPS starts before optional catalog downloads")
            XCTAssertLessThan(eta,catalog,"Live arrivals start before optional catalog downloads")
        }
    }
}
