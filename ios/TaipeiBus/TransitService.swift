import Foundation
import CryptoKit
import TransitCore

/// Networking, gzip, parsing and road matching all run outside the UI actor.
actor TransitService {
    private var metroRealtimeAt = Date.distantPast
    private var metroPacket: MetroRealtime?
    private var bundledMetadata: TransitMetadata?
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
    private var platformFetchedAt = Date.distantPast
    private var platformTag: String?
    /// Taipei Metro's free open-data "train entering station" feed. The file is rewritten about
    /// every 16 s; a conditional request costs no body when nothing changed. It has no countdown
    /// or train identity, so the app estimates waits and places trains from it.
    func metroPlatformEvents(network: MetroNetwork) async -> [MetroPlatformEvent]? {
        guard Date().timeIntervalSince(platformFetchedAt) >= 14, !network.stations.isEmpty else { return nil }
        platformFetchedAt = Date()
        var request = URLRequest(url: MetroPlatformFeed.url)
        request.timeoutInterval = 8; request.cachePolicy = .reloadIgnoringLocalCacheData
        if let platformTag { request.setValue(platformTag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 304 { return [] }
            guard http.statusCode == 200 else { return nil }
            let tag = http.value(forHTTPHeaderField: "ETag")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let server = (http.value(forHTTPHeaderField: "Date")).flatMap(formatter.date(from:))
            let events = try MetroPlatformFeed.parse(bytes, network: network, serverDate: server, receivedAt: Date())
            platformTag = tag
            return events
        } catch { return nil }
    }
    private var bikeNetworkValue: BikeNetwork?
    private var checkedBundledBikes = false
    /// The bundled station list: names, addresses, coordinates and dock counts, which change
    /// a few times a month. Live counts never ship inside the app.
    func bikeNetwork() -> BikeNetwork {
        if let bikeNetworkValue { return bikeNetworkValue }
        guard !checkedBundledBikes else { return .empty }
        checkedBundledBikes = true
        guard let url = Bundle.main.url(forResource: "BikeNetwork", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), let network = try? BikeNetwork(data: bytes) else { return .empty }
        bikeNetworkValue = network
        return network
    }
    /// Taipei's YouBike and New Taipei's: separate files, each with its own pace and cache.
    private let bikeSources: [TransitSource]
    private struct BikeFeed {
        var fetchedAt = Date.distantPast
        var retryAt = Date.distantPast
        var tag: String?
        var packet: BikeAvailability?
        var request: Task<Void, Never>?
    }
    private var bikeFeeds: [String: BikeFeed] = [:]
    private var checkedBikeCache = false
    private let bikeSession: URLSession
    private let bikeNow: @Sendable () -> Date
    private var bikePacket: BikeAvailability? { BikeAvailability.combining(bikeSources.compactMap { bikeFeeds[$0.id]?.packet }) }
    /// Taipei's file keeps the name it always had.
    private func bikeCacheFile(_ source: TransitSource) -> URL {
        cacheDirectory.appendingPathComponent(source == bikeSources.first ? "YouBikeImmediate.json" : "\(source.id)-YouBikeImmediate.json")
    }
    /// Reuse a recent official report across launches, keeping its original receipt and
    /// station report times. Loading a file never makes old counts current again.
    func cachedBikeAvailability(network: BikeNetwork) -> BikeAvailability? {
        guard !network.stations.isEmpty else { return nil }
        if checkedBikeCache { return bikePacket }
        checkedBikeCache = true
        let now = bikeNow()
        for source in bikeSources {
            let file = bikeCacheFile(source)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let received = attributes[.modificationDate] as? Date,
                  (0..<BikeDock.freshnessSeconds).contains(now.timeIntervalSince(received)),
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8 * 1_024 * 1_024,
                  let bytes = try? Data(contentsOf: file),
                  let packet = try? BikeAvailability(data: bytes, network: network, at: received),
                  packet.docks.values.contains(where: { $0.isFresh(at: now) }) else { continue }
            bikeFeeds[source.id, default: BikeFeed()].packet = packet
            bikeFeeds[source.id, default: BikeFeed()].fetchedAt = received
        }
        return bikePacket
    }
    /// Taipei's public YouBike 2.0 feed is one file for the whole city, rewritten about once a
    /// minute; New Taipei's is rewritten about every five and asked for less often. Load a recent
    /// cache first, share concurrent requests, and retry a failed first download promptly rather
    /// than treating it as a successful cache.
    func bikeAvailability(network: BikeNetwork) async -> BikeAvailability? {
        guard !network.stations.isEmpty else { return nil }
        _ = cachedBikeAvailability(network: network)
        await withTaskGroup(of: Void.self) { group in
            for source in bikeSources { group.addTask { await self.refreshBikes(source, network: network) } }
        }
        return bikePacket
    }
    private func refreshBikes(_ source: TransitSource, network: BikeNetwork) async {
        let interval = source.refreshSeconds > 0 ? source.refreshSeconds : 60
        if bikeNow().timeIntervalSince(bikeFeeds[source.id]?.fetchedAt ?? .distantPast) < interval { return }
        if let request = bikeFeeds[source.id]?.request { await request.value; return }
        guard bikeNow() >= bikeFeeds[source.id]?.retryAt ?? .distantPast else { return }
        let request = Task { await self.fetchBikeAvailability(source, network: network) }
        bikeFeeds[source.id, default: BikeFeed()].request = request
        await request.value
        bikeFeeds[source.id]?.request = nil
    }
    private func fetchBikeAvailability(_ source: TransitSource, network: BikeNetwork) async {
        bikeFeeds[source.id, default: BikeFeed()].retryAt = bikeNow().addingTimeInterval(10)
        var request = URLRequest(url: source.feed)
        request.timeoutInterval = 12; request.cachePolicy = .reloadIgnoringLocalCacheData
        if let tag = bikeFeeds[source.id]?.tag, bikeFeeds[source.id]?.packet != nil { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (bytes, response) = try await bikeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 304 { bikeFeeds[source.id]?.fetchedAt = bikeNow(); return }
            guard http.statusCode == 200 else { return }
            let received = bikeNow()
            let packet = try BikeAvailability(data: bytes, network: network, at: received)
            bikeFeeds[source.id]?.tag = http.value(forHTTPHeaderField: "ETag")
            bikeFeeds[source.id]?.packet = packet; bikeFeeds[source.id]?.fetchedAt = received
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let file = bikeCacheFile(source)
            if (try? bytes.write(to: file, options: .atomic)) != nil {
                try? FileManager.default.setAttributes([.modificationDate: received], ofItemAtPath: file.path)
            }
        } catch { return }
    }
    /// Taipei's and New Taipei's buses: one numbering from one information centre, published as two
    /// sets of files. The first is the one the app cannot work without.
    private let busSources: [TransitSource]
    private let transports: [String: ConditionalFeedTransport]
    private let cacheDirectory: URL
    private var metadata = TransitMetadata()
    private var snapshot = TransitSnapshot()
    private var refreshTask: Task<TransitSnapshot, Never>?
    private var refreshGeneration = UUID()
    private var metadataLoadedAt: Date?
    private var bundledOfficial: [String: OfficialTravelTimes] = [:]
    private var checkedBundledOfficial: Set<String> = []
    private var settings = LiveSettings.defaults
    private(set) var metadataNotice: String?
    private static let metadataNames = ["GetRoute", "GetStop", "GetPathDetail", "GetProvider", "GetBusShape"]

    init(bikeSession: URLSession = .shared, feedSession: URLSession? = nil, cacheDirectory: URL? = nil,
         busSources: [TransitSource] = RegionCatalog.shared.sources(.bus), bikeSources: [TransitSource] = RegionCatalog.shared.sources(.bike),
         bikeNow: @escaping @Sendable () -> Date = { Date() }) {
        self.bikeSession = bikeSession; self.bikeNow = bikeNow; self.busSources = busSources; self.bikeSources = bikeSources
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        let session = feedSession ?? URLSession(configuration: configuration)
        transports = Dictionary(busSources.map {
            ($0.id, ConditionalFeedTransport(session: session, baseURL: $0.feed))
        }, uniquingKeysWith: { first, _ in first })
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaipeiTransit", isDirectory: true)
    }
    func updateSettings(_ settings: LiveSettings) { self.settings = settings }
    /// The primary source's files keep the names they always had; another source's carry its id.
    private func cacheFile(_ name: String, _ source: TransitSource) -> URL {
        cacheDirectory.appendingPathComponent(source == busSources.first ? "\(name).json" : "\(source.id)-\(name).json")
    }
    private func bundledFeeds(_ source: TransitSource) -> [String: Data] {
        var feeds: [String: Data] = [:]
        for name in Self.metadataNames {
            let folder = source == busSources.first ? "BusMetadata" : "BusMetadata/\(source.id)"
            guard let url = Bundle.main.url(forResource: name, withExtension: "gz", subdirectory: folder),
                  let compressed = try? Data(contentsOf: url), let bytes = try? inflate(compressed) else { continue }
            feeds[name] = bytes
        }
        return feeds
    }
    private static let essentialNames: Set<String> = ["GetRoute", "GetStop", "GetPathDetail"]
    func offlineMetroMetadata() -> TransitMetadata? {
        if let bundledMetadata { return bundledMetadata }
        var result = (try? FeedDecoder.metadata(sources: busSources.map { bundledFeeds($0) })) ?? TransitMetadata()
        result.officialTravelTimes = OfficialTravelTimes.combining(busSources.compactMap { bundledOfficialTravelTimes($0) }).matching(result)
        installMetro(in:&result)
        bundledMetadata = result
        metadata = result
        return result.metro.stations.isEmpty ? nil : result
    }
    func cachedMetadata() -> TransitMetadata? {
        func recent(_ source: TransitSource) -> [String: Data]? {
            var feeds: [String: Data] = [:]
            for name in Self.metadataNames {
                let file = cacheFile(name, source)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                      let modified = attributes[.modificationDate] as? Date,
                      Date().timeIntervalSince(modified) < settings.refresh.metadataHours * 3_600,
                      ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 32 * 1_024 * 1_024,
                      let bytes = try? Data(contentsOf: file),
                      (try? FeedDecoder.validateMetadataFeed(bytes)) != nil else {
                    if Self.essentialNames.contains(name) { return nil }
                    continue
                }
                feeds[name] = bytes
            }
            return feeds
        }
        // Without a recent copy of the primary source the app waits for the network as before; another
        // source without one uses the copy inside the app.
        guard let first = busSources.first, let primary = recent(first) else { return nil }
        let sources = [primary] + busSources.dropFirst().map { recent($0) ?? bundledFeeds($0) }
        guard let value = try? FeedDecoder.metadata(sources: sources), !value.stations.isEmpty, !value.routes.isEmpty else { return nil }
        var loaded = value
        loaded.officialTravelTimes = OfficialTravelTimes.combining(busSources.compactMap { source in
            let cached = (try? Data(contentsOf: officialFile(source, "json"))).flatMap { try? OfficialTravelTimes(data: $0) }
            return preferredOfficial(cached, bundledOfficialTravelTimes(source))
        }).matching(loaded)
        installMetro(in: &loaded)
        metadata = loaded
        return loaded
    }

    func prepare(force: Bool = false) async throws -> TransitMetadata {
        let refreshInterval: TimeInterval = metadataNotice == nil ? settings.refresh.metadataHours * 3_600 : 300
        if !force, let date = metadataLoadedAt, Date().timeIntervalSince(date) < refreshInterval { return metadata }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var feeds: [String: [String: Data]] = [:]
        var notices: [String] = []
        async let official = officialTravelTimes(force: force)
        // Independent metadata requests; failure of shapes does not disable station arrivals.
        await withTaskGroup(of: (String, String, Data?, String?).self) { group in
            for source in busSources {
                for name in Self.metadataNames {
                    group.addTask { await self.metadataFeed(name, source: source, force: force) }
                }
            }
            for await (source, name, data, notice) in group {
                if let data { feeds[source, default: [:]][name] = data }
                if let notice { notices.append(notice) }
            }
        }
        try Task.checkCancellation()
        let decodedBus: TransitMetadata
        do {
            // A missing path feed cannot replace a complete catalog with guessed parent stop order.
            let complete = { (source: TransitSource) in Self.essentialNames.allSatisfy { feeds[source.id]?[$0] != nil } }
            guard let first = busSources.first, complete(first) else {
                throw FeedError.invalid("Incomplete bus planning metadata")
            }
            // Another source that cannot be read in full uses the copy inside the app.
            let sources = busSources.map { complete($0) ? feeds[$0.id]! : bundledFeeds($0) }
            let candidate = try FeedDecoder.metadata(sources: sources)
            guard !candidate.paths.isEmpty else { throw FeedError.invalid("Missing bus stop order") }
            decodedBus = candidate
        }
        catch {
            if metadata.routes.isEmpty, let offline = offlineMetroMetadata() { metadata = offline }
            guard !metadata.routes.isEmpty else { throw error }
            metadataLoadedAt = Date()
            metadataNotice = AppText.text("路線與站牌使用內建官方資料，等待更新")
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
              let data = try? Data(contentsOf: url), var metro = try? MetroNetwork(data: data) else { return }
        // Underground / at-grade / viaduct heights; without them trains stay on the street plane.
        if let url = Bundle.main.url(forResource: "MetroLevels", withExtension: "json"),
           let bytes = try? Data(contentsOf: url), let levels = try? MetroLevels(data: bytes) {
            metro = metro.withLevels(levels)
        }
        metro.attach(to: &metadata)
    }

    /// Each city's official station-to-station catalog. Taipei's keeps the names every installed app
    /// uses (official-times* in the release, OfficialTravelTimes.json inside the app and in the cache);
    /// another city's carries its id and ships inside the app compressed, beside its bus files.
    private func officialName(_ source: TransitSource) -> String {
        source == busSources.first ? "official-times" : "official-times-\(source.id)"
    }
    private func officialFile(_ source: TransitSource, _ suffix: String) -> URL {
        cacheDirectory.appendingPathComponent(source == busSources.first ? "OfficialTravelTimes.\(suffix)" : "\(source.id)-OfficialTravelTimes.\(suffix)")
    }
    private func bundledOfficialTravelTimes(_ source: TransitSource) -> OfficialTravelTimes? {
        guard !checkedBundledOfficial.contains(source.id) else { return bundledOfficial[source.id] }
        checkedBundledOfficial.insert(source.id)
        let primary = source == busSources.first
        if let url = primary ? Bundle.main.url(forResource: "OfficialTravelTimes", withExtension: "json")
                             : Bundle.main.url(forResource: "OfficialTravelTimes.json", withExtension: "gz", subdirectory: "BusMetadata/\(source.id)"),
           let stored = try? Data(contentsOf: url), let bytes = primary ? stored : (try? inflate(stored)),
           let catalog = try? OfficialTravelTimes(data: bytes), catalog.patternCount > 0 {
            bundledOfficial[source.id] = catalog
        }
        return bundledOfficial[source.id]
    }

    private func preferredOfficial(_ cached: OfficialTravelTimes?, _ bundled: OfficialTravelTimes?) -> OfficialTravelTimes? {
        [cached, bundled].compactMap { $0 }.max { ($0.generatedAt ?? .distantPast) < ($1.generatedAt ?? .distantPast) }
    }

    private struct OfficialManifest: Decodable { let schema: Int; let generatedAt: String; let sha256: String; let bytes: Int; let gzipBytes: Int }
    private static let officialRelease = "https://github.com/rio10255254/TaipeiBus/releases/download/travel-time-data/"
    /// The same files on jsDelivr's CDN (route-times.yml pushes them to the phone-data branch).
    /// It may lag a few hours behind; every copy is checked against the manifest's SHA-256.
    private static let officialRaw = "https://raw.githubusercontent.com/rio10255254/TaipeiBus/phone-data/"
    private static let officialMirror = "https://cdn.jsdelivr.net/gh/rio10255254/TaipeiBus@phone-data/"

    /// Every city's catalog, each checked and downloaded on its own; a city whose catalog cannot be
    /// had keeps the generic speed estimate without holding back the others.
    private func officialTravelTimes(force: Bool) async -> OfficialTravelTimes {
        var parts: [OfficialTravelTimes] = []
        for source in busSources { parts.append(await officialTravelTimes(source, force: force)) }
        return OfficialTravelTimes.combining(parts.filter { $0.patternCount > 0 })
    }

    private func officialTravelTimes(_ source: TransitSource, force: Bool) async -> OfficialTravelTimes {
        let name = officialName(source)
        let file = officialFile(source, "json")
        let checkFile = officialFile(source, "checked")
        let cached = (try? Data(contentsOf: file)).flatMap { try? OfficialTravelTimes(data: $0) }
        let bundled = bundledOfficialTravelTimes(source)
        let saved = preferredOfficial(cached, bundled)
        func age(_ url: URL) -> TimeInterval? {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) }
        }
        if !force, let saved, let checked = age(checkFile) ?? age(file), checked < 86400 { return saved }
        if !force, cached == nil, let bundled, let generated = bundled.generatedAt,
           (-300...86400).contains(Date().timeIntervalSince(generated)) { return bundled }
        // A shared, public, bounded dataset. TDX credentials and the owner's account quota are
        // never sent to the phone. The catalog changes weekly, so ask its few-hundred-byte
        // manifest first and download the 6 MB gzip copy only when it is newer.
        func markChecked() {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? Data().write(to: checkFile, options: .atomic)
        }
        if let manifest = await officialManifest(name) {
            let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            let published = plain.date(from: manifest.generatedAt) ?? fractional.date(from: manifest.generatedAt)
            if let saved, let published, (saved.generatedAt ?? .distantPast) >= published { markChecked(); return saved }
            // Use the verified release first; a cold or unavailable third-party mirror must not delay it.
            var verified: (Data, OfficialTravelTimes)?
            for base in [Self.officialRelease, Self.officialRaw, Self.officialMirror] where verified == nil {
                guard let packed = await download(base + name + ".json.gz"), packed.count == manifest.gzipBytes,
                      let bytes = try? inflate(packed), bytes.count == manifest.bytes,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == manifest.sha256,
                      let catalog = try? OfficialTravelTimes(data: bytes), catalog.patternCount > 0 else { continue }
                verified = (bytes, catalog)
            }
            guard let found = verified else { return saved ?? .init() }
            let (bytes, catalog) = found
            if let saved, (saved.generatedAt ?? .distantPast) > (catalog.generatedAt ?? .distantPast) { markChecked(); return saved }
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? bytes.write(to: file, options: .atomic); markChecked()
            return catalog
        }
        // Without a manifest (unreachable, or not yet published) fall back to the full file.
        guard let bytes = await download(Self.officialRelease + name + ".json"),
              let catalog = try? OfficialTravelTimes(data: bytes), catalog.patternCount > 0 else { return saved ?? .init() }
        if let saved, (saved.generatedAt ?? .distantPast) > (catalog.generatedAt ?? .distantPast) { return saved }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? bytes.write(to: file, options: .atomic)
        return catalog
    }

    /// GitHub first, since it is always current; the CDN copy answers when GitHub does not.
    private func officialManifest(_ name: String) async -> OfficialManifest? {
        for base in [Self.officialRelease, Self.officialRaw, Self.officialMirror] {
            guard let data = await download(base + name + "-manifest.json"), data.count <= 4_096,
                  let manifest = try? JSONDecoder().decode(OfficialManifest.self, from: data), manifest.schema == 1,
                  manifest.sha256.count == 64, (1...(32 * 1_024 * 1_024)).contains(manifest.bytes),
                  (1...manifest.bytes).contains(manifest.gzipBytes) else { continue }
            return manifest
        }
        return nil
    }

    private func download(_ address: String) async -> Data? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 4
        guard let (bytes, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return bytes
    }

    private func metadataFeed(_ name: String, source: TransitSource, force: Bool) async -> (String, String, Data?, String?) {
        let url = cacheFile(name, source)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        if !force, let modified, Date().timeIntervalSince(modified) < settings.refresh.metadataHours * 3_600,
           let bytes = try? Data(contentsOf: url) {
            do { try FeedDecoder.validateMetadataFeed(bytes); return (source.id, name, bytes, nil) }
            catch { /* Treat an empty or malformed cache as a cache miss. */ }
        }
        do {
            let bytes = try await fetch(name, from: source)
            do { try FeedDecoder.validateMetadataFeed(bytes) }
            catch { await transports[source.id]?.invalidate(name); throw error }
            try bytes.write(to: url, options: .atomic)
            return (source.id, name, bytes, nil)
        } catch {
            if let bytes = try? Data(contentsOf: url) {
                do { try FeedDecoder.validateMetadataFeed(bytes); return (source.id, name, bytes, name) }
                catch { /* A broken cache cannot become the fallback. */ }
            }
            return (source.id, name, nil, name)
        }
    }

    func refresh(onPartial: @escaping @Sendable (TransitSnapshot) async -> Void = { _ in }) async -> TransitSnapshot {
        if let task = refreshTask, !task.isCancelled {
            return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        let token = UUID(); refreshGeneration = token
        let task = Task { await self.performRefresh(onPartial: onPartial) }
        refreshTask = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if refreshGeneration == token { refreshTask = nil }
        return result
    }

    private enum LiveResult: Sendable { case vehicles(String, Data?), estimates(String, Data?) }
    /// All stops' estimates are about 150 KB a city and change every few seconds, while the app shows
    /// whole minutes counted down from the source time. Fetch them at most this often.
    private let estimateInterval: TimeInterval = 20
    private var estimatesRequestedAt: [String: Date] = [:]
    /// Each source's last accepted report. A source's vehicles are tracked against its own previous
    /// report, so a city that is late or offline never makes the other city's buses look missing.
    private var vehicleParts: [String: (vehicles: [BusVehicle], updatedAt: Date)] = [:]
    private var vehicleErrors: [String: String] = [:]
    private var estimateParts: [String: EstimateFeed] = [:]

    private func performRefresh(onPartial: @escaping @Sendable (TransitSnapshot) async -> Void) async -> TransitSnapshot {
        // Publish each independent feed immediately; ETA must not wait for GPS and road matching.
        await withTaskGroup(of: LiveResult.self) { group in
            for source in busSources {
                group.addTask { .vehicles(source.id, try? await self.fetch("GetBusData", from: source)) }
                let estimates = estimateParts[source.id]
                if estimates?.updatedAt == nil || estimates?.error != nil ||
                    Date().timeIntervalSince(estimatesRequestedAt[source.id] ?? .distantPast) >= estimateInterval {
                    estimatesRequestedAt[source.id] = Date()
                    group.addTask { .estimates(source.id, try? await self.fetch("GetEstimateTime", from: source)) }
                }
            }
            for await result in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                switch result {
                case .vehicles(let source, let bytes):
                    do {
                        guard let bytes else { throw FeedError.invalid(AppText.text("車輛定位")) }
                        let value = try FeedDecoder.vehicles(bytes, metadata: metadata, previous: vehicleParts[source]?.vehicles ?? [], now: Date())
                        if let date = value.updatedAt, vehicleParts[source].map({ date >= $0.updatedAt }) ?? true {
                            vehicleParts[source] = (value.vehicles, date)
                            snapshot.vehicles = busSources.flatMap { vehicleParts[$0.id]?.vehicles ?? [] }.sorted { $0.id < $1.id }
                            snapshot.sourceUpdatedAt = vehicleParts.values.map { $0.updatedAt }.max()
                            snapshot.receivedAt = Date(); vehicleErrors[source] = nil
                        } else { vehicleErrors[source] = AppText.text("定位來源回報較舊，保留最後資料") }
                    } catch {
                        if bytes != nil { await transports[source]?.invalidate("GetBusData") }
                        vehicleErrors[source] = AppText.text("定位來源連線中斷，保留最後回報")
                    }
                    snapshot.vehicleError = busSources.lazy.compactMap { self.vehicleErrors[$0.id] }.first
                case .estimates(let source, let bytes):
                    do {
                        guard let bytes else { throw FeedError.invalid(AppText.text("到站預估")) }
                        let value = try FeedDecoder.estimates(bytes)
                        if let date = value.updatedAt, estimateParts[source]?.updatedAt.map({ date >= $0 }) ?? true {
                            estimateParts[source] = value
                        } else { estimateParts[source, default: EstimateFeed()].error = AppText.text("到站預估來源回報較舊") }
                    } catch {
                        if bytes != nil { await transports[source]?.invalidate("GetEstimateTime") }
                        estimateParts[source, default: EstimateFeed()].error = AppText.text("到站預估來源連線中斷")
                    }
                    snapshot.estimates = EstimateFeed.combining(busSources.compactMap { estimateParts[$0.id] })
                }
                snapshot.revision += 1
                await onPartial(snapshot)
            }
        }
        return snapshot
    }

    private func fetch(_ name: String, from source: TransitSource) async throws -> Data {
        guard let transport = transports[source.id] else { throw FeedError.invalid(name) }
        let data = try await transport.data(name)
        do { return try inflate(data) }
        catch { await transport.invalidate(name); throw error }
    }
    private func inflate(_ data: Data) throws -> Data {
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
