import Foundation
import TransitCore

/// Networking, gzip, parsing and road matching all run outside the UI actor.
actor TransitService {
    private let transport: ConditionalFeedTransport
    private let cacheDirectory: URL
    private var metadata = TransitMetadata()
    private var snapshot = TransitSnapshot()
    private var refreshTask: Task<TransitSnapshot, Never>?
    private var metadataLoadedAt: Date?
    private var settings = LiveSettings.defaults
    private(set) var metadataNotice: String?
    private static let metadataNames = ["GetRoute", "GetStop", "GetPathDetail", "GetProvider", "GetBusShape"]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        transport = ConditionalFeedTransport(session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://tcgbusfs.blob.core.windows.net/blobbus/")!)
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaipeiTransit", isDirectory: true)
    }
    func updateSettings(_ settings: LiveSettings) { self.settings = settings }
    func cachedMetadata() -> TransitMetadata? {
        var feeds: [String: Data] = [:]
        let essentials: Set<String> = ["GetRoute", "GetStop", "GetPathDetail"]
        for name in Self.metadataNames {
            let file = cacheDirectory.appendingPathComponent("\(name).json")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) < settings.refresh.metadataHours * 3_600,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32 * 1_024 * 1_024,
                  let bytes = try? Data(contentsOf: file),
                  (try? FeedDecoder.validateMetadataFeed(bytes)) != nil else {
                if essentials.contains(name) { return nil }
                continue
            }
            feeds[name] = bytes
        }
        guard let value = try? FeedDecoder.metadata(feeds: feeds), !value.stations.isEmpty, !value.routes.isEmpty else { return nil }
        metadata = value
        return value
    }

    func prepare(force: Bool = false) async throws -> TransitMetadata {
        let refreshInterval: TimeInterval = metadataNotice == nil ? settings.refresh.metadataHours * 3_600 : 300
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
        if decoded.lines.isEmpty || decoded.paths.isEmpty { notices.append(AppText.text("路線軌跡／站序")) }
        metadata = decoded
        metadataLoadedAt = Date()
        metadataNotice = notices.isEmpty ? nil : AppText.text("部分路線資料暫用快取或未取得")
        return decoded
    }

    private func metadataFeed(_ name: String, force: Bool) async -> (String, Data?, String?) {
        let url = cacheDirectory.appendingPathComponent("\(name).json")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        if !force, let modified, Date().timeIntervalSince(modified) < settings.refresh.metadataHours * 3_600,
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

    func refresh(onPartial: @escaping @Sendable (TransitSnapshot) async -> Void = { _ in }) async -> TransitSnapshot {
        if let task = refreshTask {
            return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        let task = Task { await self.performRefresh(onPartial: onPartial) }
        refreshTask = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        refreshTask = nil
        return result
    }

    private enum LiveResult: Sendable { case vehicles(Data?), estimates(Data?) }

    private func performRefresh(onPartial: @escaping @Sendable (TransitSnapshot) async -> Void) async -> TransitSnapshot {
        // Publish each independent feed immediately; ETA must not wait for GPS and road matching.
        await withTaskGroup(of: LiveResult.self) { group in
            group.addTask { .vehicles(try? await self.fetch("GetBusData")) }
            group.addTask { .estimates(try? await self.fetch("GetEstimateTime")) }
            for await result in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                switch result {
                case .vehicles(let bytes):
                    do {
                        guard let bytes else { throw FeedError.invalid(AppText.text("車輛定位")) }
                        let value = try FeedDecoder.vehicles(bytes, metadata: metadata, previous: snapshot.vehicles, now: Date())
                        if let date = value.updatedAt, snapshot.sourceUpdatedAt.map({ date >= $0 }) ?? true {
                            snapshot.vehicles = value.vehicles; snapshot.sourceUpdatedAt = date
                            snapshot.receivedAt = Date(); snapshot.vehicleError = nil
                        } else { snapshot.vehicleError = AppText.text("定位來源回報較舊，保留最後資料") }
                    } catch { snapshot.vehicleError = AppText.text("定位來源連線中斷，保留最後回報") }
                case .estimates(let bytes):
                    do {
                        guard let bytes else { throw FeedError.invalid(AppText.text("到站預估")) }
                        let value = try FeedDecoder.estimates(bytes)
                        if let date = value.updatedAt, snapshot.estimates.updatedAt.map({ date >= $0 }) ?? true {
                            snapshot.estimates = value
                        } else { snapshot.estimates.error = AppText.text("到站預估來源回報較舊") }
                    } catch { snapshot.estimates.error = AppText.text("到站預估來源連線中斷") }
                }
                snapshot.revision += 1
                await onPartial(snapshot)
            }
        }
        return snapshot
    }

    private func fetch(_ name: String) async throws -> Data {
        let data = try await transport.data(name)
        guard data.starts(with: [0x1f, 0x8b]) else { return data }
        var output: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = data.withUnsafeBytes { bytes in
            TaipeiBusInflateGzip(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &output, &length)
        }
        guard status == 0, let output else { throw FeedError.invalid(AppText.text("壓縮來源")) }
        defer { TaipeiBusFreeBytes(output) }
        return Data(bytes: output, count: length)
    }
}
