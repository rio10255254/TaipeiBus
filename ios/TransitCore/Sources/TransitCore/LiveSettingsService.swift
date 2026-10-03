import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LiveSettingsPacket: Sendable {
    public let settings: LiveSettings
    public let vocabulary: SearchVocabulary
    public init(settings: LiveSettings) { self.settings = settings; vocabulary = SearchVocabulary(aliases: settings.search.aliases) }
}

/// A fixed HTTPS content endpoint; location and search queries are never attached to this request.
public actor LiveSettingsService {
    public static let productionURL = URL(string: "https://raw.githubusercontent.com/rio10255254/TaipeiBus/refs/heads/main/runtime/settings.json")!
    private let url: URL
    private let appVersion: String
    private let cacheFile: URL
    private let session: URLSession
    private var etag: String?
    private var highestRevision = 0
    public init(url: URL = productionURL, appVersion: String, cacheDirectory: URL, session: URLSession? = nil) {
        self.url = url; self.appVersion = appVersion
        cacheFile = cacheDirectory.appendingPathComponent("last-good-settings.json")
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 10
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: config)
        }
    }
    public func cached() -> LiveSettingsPacket? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 131_072,
              let data = try? Data(contentsOf: cacheFile),
              let value = try? LiveSettings.decode(data, appVersion: appVersion) else { return nil }
        highestRevision = value.revision
        return LiveSettingsPacket(settings: value)
    }
    public func refresh(current: LiveSettings) async -> LiveSettingsPacket? {
        guard url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.host == url.host else { return nil }
            let value = try LiveSettings.decode(data, appVersion: appVersion)
            guard value.revision >= max(current.revision, highestRevision) else { return nil }
            guard value.revision > current.revision || value == current else { return nil }
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheFile, options: .atomic)
            highestRevision = value.revision
            etag = http.value(forHTTPHeaderField: "ETag")
            return value == current ? nil : LiveSettingsPacket(settings: value)
        } catch { return nil } // Keep the shipped defaults or the last validated settings.
    }
}
