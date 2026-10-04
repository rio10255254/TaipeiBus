import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Revalidates public feed bytes without making a repeated HTTP response a new GPS observation.
public actor ConditionalFeedTransport {
    private struct Entry {
        let data: Data
        let etag: String?
        let modified: String?
    }
    private let session: URLSession
    private let baseURL: URL
    private var cache: [String: Entry] = [:]

    public init(session: URLSession, baseURL: URL) {
        self.session = session; self.baseURL = baseURL
    }

    public func data(_ name: String) async throws -> Data {
        let previous = cache[name]
        var request = URLRequest(url: baseURL.appendingPathComponent(name + ".gz"), cachePolicy: .reloadIgnoringLocalCacheData)
        if let etag = previous?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        else if let modified = previous?.modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw FeedError.invalid(name) }
        if http.statusCode == 304 {
            guard let previous else { throw FeedError.invalid(name) }
            return previous.data
        }
        guard (200..<300).contains(http.statusCode), !data.isEmpty, data.count <= 32 * 1_024 * 1_024 else {
            throw FeedError.invalid(name)
        }
        cache[name] = Entry(data: data, etag: http.value(forHTTPHeaderField: "ETag"),
                            modified: http.value(forHTTPHeaderField: "Last-Modified"))
        return data
    }
}
