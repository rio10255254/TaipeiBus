import Foundation
import XCTest
@testable import TransitCore

final class ConditionalFeedTransportTests: XCTestCase {
    private func client() -> ConditionalFeedTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedProtocol.self]
        return ConditionalFeedTransport(session: URLSession(configuration: configuration), baseURL: URL(string: "https://feeds.test/blob/")!)
    }

    func testNotModifiedReusesExactBytesAndNeverRefreshesTheirGPSTimestamp() async throws {
        let payload = Data("{\"EssentialInfo\":{\"UpdateTime\":\"2026/10/04 13:17:30\"},\"BusInfo\":[{\"DataTime\":\"2026-10-04 13:17:20\"}]}".utf8)
        FeedProtocol.set([.init(status: 200, data: payload, headers: ["ETag": "\"gps-one\""]), .init(status: 304)])
        let transport = client()
        let first = try await transport.data("GetBusData")
        let unchanged = try await transport.data("GetBusData")
        XCTAssertEqual(first, unchanged)
        XCTAssertEqual(try FeedDecoder.rows(first).1, try FeedDecoder.rows(unchanged).1)
        XCTAssertNil(FeedProtocol.requests[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(FeedProtocol.requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"gps-one\"")
    }

    func testChangedFeedsAndFailuresKeepIndependentValidators() async throws {
        FeedProtocol.set([.init(status: 200, data: Data("GPS A".utf8), headers: ["ETag": "a"]),
            .init(status: 200, data: Data("ETA".utf8), headers: ["Last-Modified": "Sun, 04 Oct 2026 05:00:00 GMT"]),
            .init(status: 503), .init(status: 200, data: Data("GPS B".utf8), headers: ["ETag": "b"]),
            .init(status: 304), .init(status: 304)])
        let transport = client()
        _ = try await transport.data("GetBusData"); _ = try await transport.data("GetEstimateTime")
        do { _ = try await transport.data("GetBusData"); XCTFail("503 must not become an empty successful GPS feed") } catch {}
        let newer = try await transport.data("GetBusData")
        XCTAssertEqual(newer, Data("GPS B".utf8))
        let repeated = try await transport.data("GetBusData")
        let eta = try await transport.data("GetEstimateTime")
        XCTAssertEqual(repeated, newer); XCTAssertEqual(eta, Data("ETA".utf8))
        XCTAssertEqual(FeedProtocol.requests[3].value(forHTTPHeaderField: "If-None-Match"), "a")
        XCTAssertEqual(FeedProtocol.requests[4].value(forHTTPHeaderField: "If-None-Match"), "b")
        XCTAssertEqual(FeedProtocol.requests[5].value(forHTTPHeaderField: "If-Modified-Since"), "Sun, 04 Oct 2026 05:00:00 GMT")
    }

    func testUncachedNotModifiedAndEmptySuccessDoNotInventData() async {
        FeedProtocol.set([.init(status: 304), .init(status: 200)])
        let transport = client()
        for _ in 0..<2 {
            do { _ = try await transport.data("GetBusData"); XCTFail("An empty response is not a new GPS fix") } catch {}
        }
    }
    func testRejectedProviderErrorPageCannotPoisonTheConditionalCache() async throws {
        let invalid = Data("<!doctype html><title>HTTP Status 500</title>".utf8)
        let valid = Data("{\"EssentialInfo\":{\"UpdateTime\":\"2026/10/08 13:00:00\"},\"BusInfo\":[{\"id\":\"one\"}]}".utf8)
        FeedProtocol.set([.init(status:200,data:invalid,headers:["ETag":"bad"]),
            .init(status:200,data:valid,headers:["ETag":"good"]),.init(status:304)])
        let transport = client(), rejected = try await transport.data("GetStop")
        XCTAssertThrowsError(try FeedDecoder.validateMetadataFeed(rejected))
        await transport.invalidate("GetStop")
        let recovered = try await transport.data("GetStop")
        XCTAssertEqual(recovered,valid)
        XCTAssertNil(FeedProtocol.requests[1].value(forHTTPHeaderField:"If-None-Match"))
        let repeated = try await transport.data("GetStop")
        XCTAssertEqual(repeated,valid)
        XCTAssertEqual(FeedProtocol.requests[2].value(forHTTPHeaderField:"If-None-Match"),"good")
    }
}

private final class FeedProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var data = Data()
        var headers: [String: String] = [:]
    }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func set(_ replies: [Reply]) { lock.lock(); defer { lock.unlock() }; Self.replies = replies; captured = [] }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "feeds.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let reply = Self.replies.removeFirst(); Self.captured.append(request)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
