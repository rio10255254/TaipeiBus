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
    /// The shown reference range spans this many uncertainties before and after the estimate.
    /// Buses run late more often than early, so the late side is wider.
    public var rangeEarlyScale = 1.39
    public var rangeLateScale = 1.74
    /// Measured ratio of actual to estimated time, by Taipei hour (index 0 = 00:00–00:59), for
    /// segments timed from the official hour profile or from a bus's own recent pace. Segments
    /// timed from other buses' recent crossings already reflect current traffic and are not scaled.
    /// Weekends and national holidays use the holiday table (tools/arrival-benchmark/fit_corrections.py).
    public var workdayPaceFactors = ForecastTuning.measuredWorkdayFactors
    public var holidayPaceFactors = ForecastTuning.measuredHolidayFactors

    public init() {}

    // MEASURED-FACTORS-BEGIN
    static let measuredWorkdayFactors: [Double] = [0.996, 0.999, 1, 1, 1.002, 1.025, 1.044, 1.089, 1.033, 1.015, 1.022, 1.03, 1.04, 1.029, 1.024, 1.037, 1.052, 1.075, 1.042, 0.997, 1.013, 1.018, 0.99, 0.978]
    static let measuredHolidayFactors: [Double] = [0.998, 1.003, 1.001, 1, 1.002, 1.013, 1.021, 1.028, 1.032, 1.033, 1.029, 1.023, 1.028, 1.026, 1.019, 1.019, 1.027, 1.028, 1.005, 1.018, 1.018, 1.013, 0.991, 0.985]
    // MEASURED-FACTORS-END

    private static let taipei = TimeZone(identifier: "Asia/Taipei")!

    /// The pace factor for travel at this moment.
    public func paceFactor(at date: Date) -> Double {
        // Every segment of every planned ride asks, so the Taipei hour is worked out without a Calendar.
        let local = date.timeIntervalSince1970 + Double(Self.taipei.secondsFromGMT(for: date))
        let hour = Int(local.truncatingRemainder(dividingBy: 86_400).rounded(.down) / 3_600 + 24) % 24
        let table = TransitServiceCalendar.isHoliday(date) ? holidayPaceFactors : workdayPaceFactors
        return table.indices.contains(hour) ? table[hour] : 1
    }

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
        ("limitedUncertainty", 0.05...0.8, \.limitedUncertainty),
        ("rangeEarlyScale", 0.5...3, \.rangeEarlyScale),
        ("rangeLateScale", 0.5...4, \.rangeLateScale)
    ]

    /// Key → (bounds of every entry, path). Each table has exactly 24 entries, one per hour.
    public static let tables: [(key: String, range: ClosedRange<Double>, path: WritableKeyPath<ForecastTuning, [Double]>)] = [
        ("workdayPaceFactors", 0.8...1.4, \.workdayPaceFactors),
        ("holidayPaceFactors", 0.8...1.4, \.holidayPaceFactors)
    ]

    public static func decode(_ data: Data) throws -> ForecastTuning {
        guard data.count <= 8_192, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["schemaVersion"] as? Int == 1 else { throw SettingsError.invalid("tuning") }
        var value = ForecastTuning()
        let known = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0) })
        let knownTables = Dictionary(uniqueKeysWithValues: tables.map { ($0.key, $0) })
        for (key, raw) in root where key != "schemaVersion" && key != "note" {
            if let table = knownTables[key] {
                guard let items = raw as? [Any], items.count == 24 else { throw SettingsError.invalid("tuning.\(key)") }
                value[keyPath: table.path] = try items.map { item in
                    guard let number = item as? NSNumber, !isBoolean(number), table.range.contains(number.doubleValue) else {
                        throw SettingsError.invalid("tuning.\(key)")
                    }
                    return number.doubleValue
                }
                continue
            }
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
