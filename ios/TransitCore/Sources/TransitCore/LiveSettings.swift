import Foundation

/// Downloaded content and bounded settings for features already included in the app.
/// No scripts, executable code, arbitrary URLs, GPS upload or new permissions.
public struct LiveSettings: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var revision = 0
    public var minimumAppVersion = "0.4.2"
    public var copy: [String: String] = [:]
    public var search = Search()
    public var appearance = Appearance()
    public var planning = Planning()
    public var refresh = Refresh()
    public var display = Display()
    public var quickDestinations = ["臺北車站", "臺北101", "西門町"]
    public var language = AppLanguage.current
    // Presentation language belongs to this phone, not the shared download.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, minimumAppVersion, copy, search, appearance, planning, refresh, display, quickDestinations
    }
    public init() {}
    public static let defaults = LiveSettings()

    public struct Alias: Codable, Equatable, Sendable {
        public var names: [String]
        public var queries: [String]
        public init(names: [String], queries: [String]) { self.names = names; self.queries = queries }
    }
    public struct Search: Codable, Equatable, Sendable {
        public var aliases: [Alias] = []
        public var debounceMilliseconds = 180
        public var resultLimit = 12
        public init() {}
    }
    public struct Appearance: Codable, Equatable, Sendable {
        public var accentColor = "#007AFF"
        public var walkingColor = "#FF9500"
        public var waterColor = "#BADCE5"
        public var parkColor = "#D6E6C5"
        public var buildingColor = "#DCE2DB"
        public var textScale = 1.0
        public var spacingScale = 1.0
        public var cornerScale = 1.0
        public var solidSurfaces = false
        public init() {}
    }
    public struct Planning: Codable, Equatable, Sendable {
        public var firstWalkMeters = 800.0
        public var expandedWalkMeters = 1_200.0
        public var walkingOnlyMeters = 900.0
        public var walkingWeight = 1.0
        public var waitingWeight = 1.0
        public var transferPenaltySeconds = 420.0
        public init() {}
    }
    public struct Refresh: Codable, Equatable, Sendable {
        public var vehicleSeconds = 15.0
        public var trackingSeconds = 5.0
        public var metadataHours = 24.0
        public var settingsSeconds = 300.0
        public init() {}
    }
    public struct Display: Codable, Equatable, Sendable {
        public var nearbyStops = true
        public var quickDestinations = true
        public var stationShortcut = true
        public var routeShortcut = true
        public init() {}
    }

    public func text(_ original: String) -> String {
        let key = AppText.canonical(original)
        if language == .english { return copy["en:" + key] ?? AppText.text(key, language: .english) }
        return copy[key] ?? key
    }
    public func supports(appVersion: String) -> Bool {
        guard let minimum = Self.version(minimumAppVersion), let current = Self.version(appVersion) else { return false }
        return !current.lexicographicallyPrecedes(minimum)
    }
    private static func version(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let values = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), (0...999).contains(value) else { return nil }
            return value
        }
        return values.count == 3 ? values : nil
    }
    public static func decode(_ data: Data, appVersion: String) throws -> LiveSettings {
        guard data.count <= 131_072 else { throw SettingsError.invalid("檔案過大") }
        let document = try JSONSerialization.jsonObject(with: data)
        guard let root = document as? [String: Any] else { throw SettingsError.invalid("格式錯誤") }
        // Merge missing optional values with shipped defaults, while rejecting unknown fields.
        let encodedDefaults = try JSONEncoder().encode(Self.defaults)
        let fallback = try JSONSerialization.jsonObject(with: encodedDefaults) as! [String: Any]
        func merge(_ incoming: [String: Any], _ defaults: [String: Any], path: String = "") throws -> [String: Any] {
            var output = defaults
            for (key, value) in incoming {
                guard let base = defaults[key] else { throw SettingsError.invalid(path + key) }
                if key == "copy", path.isEmpty {
                    guard let dictionary = value as? [String: String] else { throw SettingsError.invalid("copy") }
                    output[key] = dictionary
                } else if let object = base as? [String: Any] {
                    guard let objectValue = value as? [String: Any] else { throw SettingsError.invalid(path + key) }
                    output[key] = try merge(objectValue, object, path: path + key + ".")
                } else { output[key] = value }
            }
            return output
        }
        guard root["schemaVersion"] != nil, root["revision"] != nil, root["minimumAppVersion"] != nil else {
            throw SettingsError.invalid("版本資訊缺少")
        }
        let complete = try JSONSerialization.data(withJSONObject: merge(root, fallback))
        let result = try JSONDecoder().decode(LiveSettings.self, from: complete)
        try result.validate(appVersion: appVersion)
        return result
    }
    public func validate(appVersion: String) throws {
        func require(_ valid: Bool, _ field: String) throws { if !valid { throw SettingsError.invalid(field) } }
        func bounded(_ number: Double, _ limits: ClosedRange<Double>, _ field: String) throws {
            try require(number.isFinite && limits.contains(number), field)
        }
        func shortText(_ text: String, maximum: Int) -> Bool {
            !text.isEmpty && text.count <= maximum && !text.unicodeScalars.contains { $0.value < 32 && $0 != "\n" }
        }
        func color(_ value: String) -> Bool {
            value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
        }
        try require(schemaVersion == 1 && (0...1_000_000_000).contains(revision), "schemaVersion/revision")
        try require(supports(appVersion: appVersion), "minimumAppVersion")
        try require(copy.count <= 150 && copy.allSatisfy { shortText($0.key, maximum: 120) && shortText($0.value, maximum: 180) }, "copy")
        try require(search.aliases.count <= 200, "search.aliases")
        for alias in search.aliases {
            try require((2...10).contains(alias.names.count) && (1...3).contains(alias.queries.count), "search.aliases")
            try require((alias.names + alias.queries).allSatisfy { shortText($0, maximum: 80) }, "search.aliases")
        }
        try require((80...500).contains(search.debounceMilliseconds) && (6...20).contains(search.resultLimit), "search")
        try require([appearance.accentColor, appearance.walkingColor, appearance.waterColor, appearance.parkColor, appearance.buildingColor].allSatisfy(color), "appearance.colors")
        try bounded(appearance.textScale, 0.9...1.2, "appearance.textScale")
        try bounded(appearance.spacingScale, 0.8...1.3, "appearance.spacingScale")
        try bounded(appearance.cornerScale, 0.8...1.3, "appearance.cornerScale")
        try bounded(planning.firstWalkMeters, 300...1_000, "planning.firstWalkMeters")
        try bounded(planning.expandedWalkMeters, planning.firstWalkMeters...1_200, "planning.expandedWalkMeters")
        try bounded(planning.walkingOnlyMeters, 300...1_000, "planning.walkingOnlyMeters")
        try bounded(planning.walkingWeight, 0.5...2, "planning.walkingWeight")
        try bounded(planning.waitingWeight, 0.5...2, "planning.waitingWeight")
        try bounded(planning.transferPenaltySeconds, 180...900, "planning.transferPenaltySeconds")
        try bounded(refresh.vehicleSeconds, 10...30, "refresh.vehicleSeconds")
        try bounded(refresh.trackingSeconds, 5...10, "refresh.trackingSeconds")
        try bounded(refresh.metadataHours, 6...24, "refresh.metadataHours")
        try bounded(refresh.settingsSeconds, 60...900, "refresh.settingsSeconds")
        try require((1...6).contains(quickDestinations.count) && quickDestinations.allSatisfy { shortText($0, maximum: 40) }, "quickDestinations")
    }
}

public enum SettingsError: Error, Equatable { case invalid(String) }

/// Compile downloaded aliases once rather than normalizing every alias on every keystroke.
public struct SearchVocabulary: Sendable {
    private var related: [String: Set<String>] = [:]
    private var queries: [String: [String]] = [:]
    public init(aliases: [LiveSettings.Alias] = []) {
        for alias in aliases {
            let names = Set((alias.names + alias.queries).map(StationSearch.normalize))
            for name in names {
                related[name, default: []].formUnion(names)
                queries[name] = alias.queries
            }
        }
    }
    public func expand(_ names: Set<String>) -> Set<String> {
        var result = names
        for name in names { result.formUnion(related[name] ?? []) }
        return result
    }
    public func placeQueries(_ text: String) -> [String]? { queries[StationSearch.normalize(text)] }
}
