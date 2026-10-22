import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Arrival and ride-time constants that the owner can recalibrate from runtime/tuning.json
/// without a new App Store version. Every value has fixed bounds; a file with any unknown key
/// or out-of-range value is ignored as a whole and the shipped defaults stay in effect.
public struct ForecastTuning: Equatable, Sendable {
    /// Share of a ride time it may run early or late, by how the time was obtained.
    public var railSpread = 0.05
    public var stationHistorySpread = 0.10
    public var officialProfileSpread = 0.15
    public var recentTrafficSpread = 0.15
    public var typicalSpread = 0.25
    /// Uncertainty of one segment timed from the official hour profile, as a share of it.
    public var officialSegmentMargin = 0.25
    /// How many recent crossings the official profile counts as when blended with them.
    public var officialProfileWeight = 2.0
    /// Driving speed (m/s) and per-stop allowance (s) used when nothing better is known.
    public var typicalSpeed = 4.5
    public var stopSeconds = 20.0
    /// Smallest arrival uncertainty as a share of the remaining time, for normal and limited evidence.
    public var minimumUncertainty = 0.12
    public var limitedUncertainty = 0.3

    public init() {}

    /// Key → (minimum, maximum, path to the value). runtime/tuning.schema.json must list the same bounds.
    public static let fields: [(key: String, range: ClosedRange<Double>, path: WritableKeyPath<ForecastTuning, Double>)] = [
        ("railSpread", 0.01...0.5, \.railSpread),
        ("stationHistorySpread", 0.02...0.6, \.stationHistorySpread),
        ("officialProfileSpread", 0.02...0.6, \.officialProfileSpread),
        ("recentTrafficSpread", 0.02...0.6, \.recentTrafficSpread),
        ("typicalSpread", 0.02...0.8, \.typicalSpread),
        ("officialSegmentMargin", 0.05...0.8, \.officialSegmentMargin),
        ("officialProfileWeight", 0...10, \.officialProfileWeight),
        ("typicalSpeed", 2...10, \.typicalSpeed),
        ("stopSeconds", 0...90, \.stopSeconds),
        ("minimumUncertainty", 0.03...0.5, \.minimumUncertainty),
        ("limitedUncertainty", 0.05...0.8, \.limitedUncertainty)
    ]

    public static func decode(_ data: Data) throws -> ForecastTuning {
        guard data.count <= 8_192, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schemaVersion"] as? Int == 1 else { throw SettingsError.invalid("tuning") }
        var value = ForecastTuning()
        let known = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0) })
        for (key, raw) in root where key != "schemaVersion" && key != "note" {
            guard let field = known[key], let number = raw as? NSNumber, !isBoolean(number),
                  field.range.contains(number.doubleValue) else { throw SettingsError.invalid("tuning.\(key)") }
            value[keyPath: field.path] = number.doubleValue
        }
        if let note = root["note"], !((note as? String).map { $0.count <= 300 } ?? false) { throw SettingsError.invalid("tuning.note") }
        return value
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        // swift-corelibs-foundation decodes JSON true/false as a char-typed NSNumber; JSON numbers never are.
        return String(cString: number.objCType) == "c"
        #endif
    }

    private static let lock = NSLock()
    private static var active = ForecastTuning()
    /// The values every forecast reads; replaced when a validated remote file arrives.
    public static var current: ForecastTuning {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set { lock.lock(); defer { lock.unlock() }; active = newValue }
    }
}

/// Loads runtime/tuning.json (GitHub, then the jsDelivr copy) at most every 30 minutes and
/// keeps the last good file, so the calibrated values also apply offline and right at launch.
public actor ForecastTuningService {
    public static let tuningURL = URL(string: "https://raw.githubusercontent.com/rio10255254/TaipeiBus/refs/heads/main/runtime/tuning.json")!
    public static let tuningMirrorURL = URL(string: "https://cdn.jsdelivr.net/gh/rio10255254/TaipeiBus@main/runtime/tuning.json")!
    private let cacheFile: URL
    private let sources: [URL]
    private let session: URLSession
    private var checkedAt = Date.distantPast

    public init(cacheDirectory: URL, sources: [URL] = [ForecastTuningService.tuningURL, ForecastTuningService.tuningMirrorURL],
                session: URLSession? = nil) {
        cacheFile = cacheDirectory.appendingPathComponent("forecast-tuning.json")
        self.sources = sources
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 10
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: config)
        }
        if let data = try? Data(contentsOf: cacheFile), let value = try? ForecastTuning.decode(data) { ForecastTuning.current = value }
    }

    @discardableResult
    public func refresh(now: Date = Date()) async -> ForecastTuning {
        guard now.timeIntervalSince(checkedAt) >= 1_800 else { return ForecastTuning.current }
        checkedAt = now
        for source in sources {
            guard let (data, response) = try? await session.data(from: source),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
            // A file that answers but is invalid is a mistake in the published file: keep the
            // last good values rather than a possibly older CDN copy.
            guard let value = try? ForecastTuning.decode(data) else { break }
            ForecastTuning.current = value
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            break
        }
        return ForecastTuning.current
    }
}
