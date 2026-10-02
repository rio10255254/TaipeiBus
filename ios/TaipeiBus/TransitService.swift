import Foundation
import TransitCore

/// Networking, gzip, parsing and road matching all run outside the UI actor.
actor TransitService {
    private let session: URLSession
    private let cacheDirectory: URL
    private var metadata = TransitMetadata()
    private var snapshot = TransitSnapshot()
    private var refreshTask: Task<TransitSnapshot, Never>?
    private var metadataLoadedAt: Date?
    private(set) var metadataNotice: String?
    private static let metadataNames = ["GetRoute", "GetStop", "GetPathDetail", "GetProvider", "GetBusShape"]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaipeiTransit", isDirectory: true)
    }

    func prepare(force: Bool = false) async throws -> TransitMetadata {
        let refreshInterval: TimeInterval = metadataNotice == nil ? 86_400 : 300
        if !force, let date = metadataLoadedAt, Date().timeIntervalSince(date) < refreshInterval { return metadata }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var feeds: [String: Data] = [:]
        var notices: [String] = []
        // Independent metadata requests; failure of shapes does not disable station arrivals.
        await withTaskGroup(of: (String, Data?, String?).self) { group in
            for name in Self.metadataNames {
                group.addTask { await self.metadataFeed(name, force: force) }
            }
            for await (name, data, notice) in group {
                if let data { feeds[name] = data }
                if let notice { notices.append(notice) }
            }
        }
        try Task.checkCancellation()
        let decoded = try FeedDecoder.metadata(feeds: feeds)
        if decoded.lines.isEmpty || decoded.paths.isEmpty { notices.append("路線軌跡／站序") }
        metadata = decoded
        metadataLoadedAt = Date()
        metadataNotice = notices.isEmpty ? nil : "部分路線資料暫用快取或未取得"
        return decoded
    }

    private func metadataFeed(_ name: String, force: Bool) async -> (String, Data?, String?) {
        let url = cacheDirectory.appendingPathComponent("\(name).json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        if !force, let modified, Date().timeIntervalSince(modified) < 86_400,
           let bytes = try? Data(contentsOf: url) {
            do { try FeedDecoder.validateMetadataFeed(bytes); return (name, bytes, nil) }
            catch { /* Treat an empty or malformed cache as a cache miss. */ }
        }
        do {
            let bytes = try await fetch(name)
            try FeedDecoder.validateMetadataFeed(bytes)
            try bytes.write(to: url, options: .atomic)
            return (name, bytes, nil)
        } catch {
            if let bytes = try? Data(contentsOf: url) {
                do { try FeedDecoder.validateMetadataFeed(bytes); return (name, bytes, name) }
                catch { /* A broken cache cannot become the fallback. */ }
            }
            return (name, nil, name)
        }
    }

    func refresh() async -> TransitSnapshot {
        // A pull-to-refresh joins polling instead of returning an old snapshot while it is busy.
        if let task = refreshTask {
            return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        refreshTask = nil
        return result
    }

    private func performRefresh() async -> TransitSnapshot {
        async let vehicleData = fetch("GetBusData")
        async let estimateData = fetch("GetEstimateTime")
        do {
            let data = try await vehicleData
            try Task.checkCancellation()
            let result = try FeedDecoder.vehicles(data, metadata: metadata, previous: snapshot.vehicles, now: Date())
            if let updatedAt = result.updatedAt,
               snapshot.sourceUpdatedAt.map({ updatedAt >= $0 }) ?? true {
                snapshot.vehicles = result.vehicles
                snapshot.sourceUpdatedAt = updatedAt
                snapshot.receivedAt = Date()
                snapshot.vehicleError = nil
            } else { snapshot.vehicleError = "定位來源回報較舊，保留最後資料" }
        } catch {
            if !Task.isCancelled { snapshot.vehicleError = "定位來源連線中斷，保留最後回報" }
        }
        do {
            let data = try await estimateData
            try Task.checkCancellation()
            let result = try FeedDecoder.estimates(data)
            if let updatedAt = result.updatedAt,
               snapshot.estimates.updatedAt.map({ updatedAt >= $0 }) ?? true {
                snapshot.estimates = result
            } else { snapshot.estimates.error = "到站預估來源回報較舊" }
        } catch {
            if !Task.isCancelled { snapshot.estimates.error = "到站預估來源連線中斷" }
        }
        snapshot.revision += 1
        return snapshot
    }

    private func fetch(_ name: String) async throws -> Data {
        let url = URL(string: "https://tcgbusfs.blob.core.windows.net/blobbus/\(name).gz")!
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty, data.count <= 32 * 1024 * 1024 else { throw FeedError.invalid(name) }
        guard data.starts(with: [0x1f, 0x8b]) else { return data }
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = data.withUnsafeBytes { bytes in
            TaipeiBusInflateGzip(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &output, &length)
        }
        guard status == 0, let output else { throw FeedError.invalid("壓縮來源") }
        defer { TaipeiBusFreeBytes(output) }
        return Data(bytes: output, count: length)
    }
}
