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
    /// The same file through jsDelivr's CDN, asked only when GitHub does not answer. It can lag
    /// up to 12 hours; the revision check below never lets an older copy replace a newer one.
    public static let productionMirrorURL = URL(string: "https://cdn.jsdelivr.net/gh/rio10255254/TaipeiBus@main/runtime/settings.json")!
    private let url: URL
    private let mirror: URL?
    private let appVersion: String
    private let cacheFile: URL
    private let session: URLSession
    private var etag: String?
    private var highestRevision = 0
    public init(url: URL = productionURL, mirror: URL? = nil, appVersion: String, cacheDirectory: URL, session: URLSession? = nil) {
        self.url = url; self.mirror = mirror; self.appVersion = appVersion
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
        for source in [url] + [mirror].compactMap({ $0 }) where !Task.isCancelled {
            switch await load(source, current: current, conditional: source == url) {
            case .updated(let packet): return packet
            case .unchanged: return nil
            case .unreachable: continue
            }
        }
        return nil // Keep the shipped defaults or the last validated settings.
    }

    private enum Outcome { case updated(LiveSettingsPacket), unchanged, unreachable }
    private func load(_ source: URL, current: LiveSettings, conditional: Bool) async -> Outcome {
        guard source.scheme == "https" else { return .unreachable }
        var request = URLRequest(url: source)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if conditional, let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, response.url?.host == source.host else { return .unreachable }
            if http.statusCode == 304 { return .unchanged }
            guard http.statusCode == 200 else { return .unreachable }
            let value = try LiveSettings.decode(data, appVersion: appVersion)
            guard value.revision >= max(current.revision, highestRevision) else { return .unchanged }
            guard value.revision > current.revision || value == current else { return .unchanged }
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheFile, options: .atomic)
            highestRevision = value.revision
            if conditional { etag = http.value(forHTTPHeaderField: "ETag") }
            return value == current ? .unchanged : .updated(LiveSettingsPacket(settings: value))
        } catch is CancellationError { return .unchanged }
        catch { return .unreachable }
    }
}
