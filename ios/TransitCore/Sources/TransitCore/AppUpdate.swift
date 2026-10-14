import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A dotted numeric version such as 1.6.1; missing parts compare as zero.
public struct AppVersion: Comparable, Sendable {
    private let parts: [Int]
    public init?(_ text: String) {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        let values = pieces.compactMap { piece -> Int? in
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), piece.allSatisfy(\.isNumber), let value = Int(piece), value <= 9_999 else { return nil }
            return value
        }
        guard values.count == pieces.count else { return nil }
        parts = values + Array(repeating: 0, count: 4 - values.count)
    }
    public static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}

/// The remote update switch, published at runtime/app-update.json on main.
/// Kept apart from LiveSettings: that decoder rejects unknown fields, so a new key there
/// would make every installed version discard its whole settings file.
public struct AppUpdatePolicy: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    /// Versions below this cannot be used until updated.
    public var minimumVersion = "0.0.0"
    /// Versions below this are reminded once per App Store version, and may continue.
    public var recommendedVersion: String?
    public var message: String?
    public var englishMessage: String?
    public init() {}

    public static func decode(_ data: Data) throws -> AppUpdatePolicy {
        guard data.count <= 8_192 else { throw SettingsError.invalid("app-update size") }
        let value = try JSONDecoder().decode(AppUpdatePolicy.self, from: data)
        let texts = [value.message, value.englishMessage].compactMap { $0 }
        guard value.schemaVersion == 1, AppVersion(value.minimumVersion) != nil,
              value.recommendedVersion.map({ AppVersion($0) != nil }) ?? true,
              texts.allSatisfy({ !$0.isEmpty && $0.count <= 300 }) else { throw SettingsError.invalid("app-update") }
        return value
    }

    /// Only asks for an update the phone can install right now: the App Store must already
    /// offer a version that satisfies the policy and that runs on this iOS version. A mistyped
    /// or not-yet-released version therefore never locks anyone out.
    public func requirement(appVersion: String, store: AppStoreRelease?, systemVersion: String) -> AppUpdateRequirement {
        guard let current = AppVersion(appVersion), let store, let available = AppVersion(store.version), current < available else { return .none }
        if let needed = store.minimumOSVersion.flatMap(AppVersion.init), let system = AppVersion(systemVersion), system < needed { return .none }
        if let minimum = AppVersion(minimumVersion), current < minimum, minimum <= available { return .required }
        if let recommended = recommendedVersion.flatMap(AppVersion.init), current < recommended, recommended <= available {
            return .recommended(store.version)
        }
        return .none
    }
}

public enum AppUpdateRequirement: Equatable, Sendable {
    case none
    case recommended(String)
    case required
}

/// The version currently offered in the Taiwan App Store, from Apple's public lookup.
public struct AppStoreRelease: Codable, Equatable, Sendable {
    public var version: String
    public var minimumOSVersion: String?
    public init(version: String, minimumOSVersion: String?) { self.version = version; self.minimumOSVersion = minimumOSVersion }
    public static func lookup(_ data: Data) -> AppStoreRelease? {
        guard data.count <= 262_144,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let version = first["version"] as? String, AppVersion(version) != nil else { return nil }
        return AppStoreRelease(version: version, minimumOSVersion: first["minimumOsVersion"] as? String)
    }
}

/// Fetches the policy and the App Store version; keeps the last good pair so that an
/// offline launch keeps the same answer instead of opening an update gate.
public actor AppUpdateService {
    public static let policyURL = URL(string: "https://raw.githubusercontent.com/rio10255254/TaipeiBus/refs/heads/main/runtime/app-update.json")!
    public static let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=6818475740&country=tw")!
    public static let storeURL = URL(string: "itms-apps://apps.apple.com/app/id6818475740")!
    private struct State: Codable { var policy: AppUpdatePolicy?; var store: AppStoreRelease? }
    private let cacheFile: URL
    private let session: URLSession
    private var state: State
    private var checkedAt = Date.distantPast

    public init(cacheDirectory: URL, session: URLSession? = nil) {
        cacheFile = cacheDirectory.appendingPathComponent("app-update-state.json")
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 6; config.timeoutIntervalForResource = 10
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: config)
        }
        state = (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    public func requirement(appVersion: String, systemVersion: String, now: Date = Date()) async -> AppUpdateRequirement {
        if now.timeIntervalSince(checkedAt) >= 1_800 {
            checkedAt = now
            async let policy = fetch(Self.policyURL)
            async let store = fetch(Self.lookupURL)
            var changed = false
            if let data = await policy {
                if let value = try? AppUpdatePolicy.decode(data) { state.policy = value; changed = true }
            }
            if let data = await store, let value = AppStoreRelease.lookup(data) { state.store = value; changed = true }
            if changed, let data = try? JSONEncoder().encode(state) {
                try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheFile, options: .atomic)
            }
        }
        return (state.policy ?? AppUpdatePolicy()).requirement(appVersion: appVersion, store: state.store, systemVersion: systemVersion)
    }

    public func message(english: Bool) -> String? { english ? state.policy?.englishMessage : state.policy?.message }

    private func fetch(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }
}
