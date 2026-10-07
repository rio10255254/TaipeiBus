import Foundation
import TransitCore

/// Networking, gzip, parsing and road matching all run outside the UI actor.
actor TransitService {
    private var metroRealtimeAt = Date.distantPast
    private var metroPacket: MetroRealtime?
    /// The URL belongs to an authorized server relay; credentials stay on that server.
    func metroRealtime(network: MetroNetwork, force: Bool = false) async -> MetroRealtime? {
        if !force, Date().timeIntervalSince(metroRealtimeAt) < 15 { return metroPacket }
        metroRealtimeAt = Date()
        guard let text = Bundle.main.object(forInfoDictionaryKey: "MetroRealtimeURL") as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 8; request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return metroPacket }
            let packet = try MetroRealtime(data: bytes, network: network, at: Date()); metroPacket = packet; return packet
        } catch { return metroPacket }
    }
    private let transport: ConditionalFeedTransport
    private let cacheDirectory: URL
    private var metadata = TransitMetadata()
    private var snapshot = TransitSnapshot()
    private var refreshTask: Task<TransitSnapshot, Never>?
    private var metadataLoadedAt: Date?
    private var bundledOfficial: OfficialTravelTimes?
    private var checkedBundledOfficial = false
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
    func offlineMetroMetadata() -> TransitMetadata? {
        var result = TransitMetadata(); installMetro(in:&result)
        return result.metro.stations.isEmpty ? nil : result
    }
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
        var loaded = value
        let cached = (try? Data(contentsOf: cacheDirectory.appendingPathComponent("OfficialTravelTimes.json")))
            .flatMap { try? OfficialTravelTimes(data: $0) }
        loaded.officialTravelTimes = (preferredOfficial(cached, bundledOfficialTravelTimes()) ?? .init()).matching(loaded)
        installMetro(in: &loaded)
        metadata = loaded
        return loaded
    }

    func prepare(force: Bool = false) async throws -> TransitMetadata {
        let refreshInterval: TimeInterval = metadataNotice == nil ? settings.refresh.metadataHours * 3_600 : 300
        if !force, let date = metadataLoadedAt, Date().timeIntervalSince(date) < refreshInterval { return metadata }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var feeds: [String: Data] = [:]
        var notices: [String] = []
        async let official = officialTravelTimes(force: force)
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
        let decodedBus: TransitMetadata
        do { decodedBus = try FeedDecoder.metadata(feeds: feeds) }
        catch {
            if metadata.routes.isEmpty, let offline = offlineMetroMetadata() { metadata = offline }
            guard !metadata.routes.isEmpty else { throw error }
            metadataLoadedAt = Date()
            metadataNotice = AppText.text("公車資料暫缺，捷運路線仍可使用")
            return metadata
        }
        var decoded = decodedBus
        decoded.officialTravelTimes = await official.matching(decoded)
        installMetro(in: &decoded)
        if decoded.lines.isEmpty || decoded.paths.isEmpty { notices.append(AppText.text("路線軌跡／站序")) }
        metadata = decoded
        metadataLoadedAt = Date()
        metadataNotice = notices.isEmpty ? nil : AppText.text("部分路線資料暫用快取或未取得")
        return metadata
    }

    private func installMetro(in metadata: inout TransitMetadata) {
        guard let url = Bundle.main.url(forResource: "MetroNetwork", withExtension: "json"),
              let data = try? Data(contentsOf: url), let metro = try? MetroNetwork(data: data) else { return }
        metro.attach(to: &metadata)
    }

    private func bundledOfficialTravelTimes() -> OfficialTravelTimes? {
        guard !checkedBundledOfficial else { return bundledOfficial }
        checkedBundledOfficial = true
        if let url = Bundle.main.url(forResource: "OfficialTravelTimes", withExtension: "json"),
           let bytes = try? Data(contentsOf: url), let catalog = try? OfficialTravelTimes(data: bytes), catalog.patternCount > 0 {
            bundledOfficial = catalog
        }
        return bundledOfficial
    }

    private func preferredOfficial(_ cached: OfficialTravelTimes?, _ bundled: OfficialTravelTimes?) -> OfficialTravelTimes? {
        [cached, bundled].compactMap { $0 }.max { ($0.generatedAt ?? .distantPast) < ($1.generatedAt ?? .distantPast) }
    }

    private func officialTravelTimes(force: Bool) async -> OfficialTravelTimes {
        let file = cacheDirectory.appendingPathComponent("OfficialTravelTimes.json")
        let cached = (try? Data(contentsOf: file)).flatMap { try? OfficialTravelTimes(data: $0) }
        let bundled = bundledOfficialTravelTimes()
        let saved = preferredOfficial(cached, bundled)
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        if !force, let modified, Date().timeIntervalSince(modified) < 86400, let saved { return saved }
        if !force, cached == nil, let bundled, let generated = bundled.generatedAt,
           (-300...86400).contains(Date().timeIntervalSince(generated)) { return bundled }
        // A shared, public, bounded dataset is fetched once per device/day. TDX
        // credentials and the owner's account quota are never sent to the phone.
        let url = URL(string: "https://github.com/rio10255254/TaipeiBus/releases/download/travel-time-data/official-times.json")!
        var request = URLRequest(url: url); request.timeoutInterval = 4
        do {
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let catalog = try? OfficialTravelTimes(data: bytes), catalog.patternCount > 0 else { return saved ?? .init() }
            if let saved, (saved.generatedAt ?? .distantPast) > (catalog.generatedAt ?? .distantPast) { return saved }
            try? bytes.write(to: file, options: .atomic)
            return catalog
        } catch { return saved ?? .init() }
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
