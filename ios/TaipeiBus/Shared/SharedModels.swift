import Foundation
import Security
import SwiftUI
import TransitCore
#if canImport(ActivityKit)
import ActivityKit
#endif

/// A route sign as the app draws it, carried to the widget and Live Activity, which cannot
/// look up route colours themselves.
struct RouteSign: Codable, Hashable, Sendable {
    var text: String
    var color: String
    var darkInk: Bool
}

#if canImport(ActivityKit)
/// The trip on the Lock Screen and in the Dynamic Island. The app updates it while it runs;
/// between updates the system keeps counting down to `target` on its own.
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable { case waiting, riding, walking, cycling, transferring }
        var phase: Phase
        var sign: RouteSign
        /// Waiting: "往 板橋"; riding: the alighting stop; walking: the destination.
        var headline: String
        /// Waiting: the boarding stop; riding: "還有 5 站".
        var detail: String
        /// When the bus or train reaches the boarding stop, or the rider reaches the alighting stop.
        var target: Date?
        /// Shown instead of a countdown when there is no time (e.g. "暫無預估", "末班已過").
        var status: String?
        var stopsLeft: Int?
        var totalStops: Int?
        var updatedAt: Date
        /// Optional additions keep already-running activities decodable after an app update.
        var symbol: String? = nil
        var freshUntil: Date? = nil
        var stepIdentifier: String? = nil
        var rideIdentifier: String? = nil
        var nextInstruction: String? = nil
        var remainingMeters: Double? = nil
        var stepKey: String { stepIdentifier ?? [phase.rawValue, sign.text, headline].joined(separator: ":") }
        /// ActivityKit asks the extension to redraw at this deadline. No view-local
        /// periodic schedule is needed to stop an expired countdown.
        var updateDeadline: Date {
            let expiry = freshUntil ?? updatedAt.addingTimeInterval(120)
            return target.map { min(expiry, max(updatedAt, $0)) } ?? expiry
        }
    }
    var destination: String
    var language: String
}

/// One meaning across the small island, expanded island and Lock Screen.
/// Expiry is checked before stops or urgency, so a lost feed cannot leave a false alight cue.
struct RideActivityPresentation {
    let state: RideActivityAttributes.ContentState
    let language: AppLanguage
    var systemStale = false
    var now = Date()

    var stale: Bool {
        systemStale || state.updatedAt.timeIntervalSince(now) > 60
            || now >= (state.freshUntil ?? state.updatedAt.addingTimeInterval(120))
    }
    var target: Date? {
        guard !stale, let target = state.target, target > now, target > state.updatedAt else { return nil }
        return target
    }
    var due: Bool { !stale && state.target.map { $0 <= now } == true }
    var alightingSoon: Bool {
        !stale && state.phase == .riding && state.stopsLeft.map { $0 <= 1 } == true
    }
    var symbol: String {
        if stale { return "arrow.clockwise" }
        if alightingSoon { return "arrow.down" }
        if let symbol = state.symbol { return symbol }
        switch state.phase {
        case .walking, .transferring: return "figure.walk"
        case .cycling: return "bicycle"
        default: return "bus.fill"
        }
    }
    var phaseTitle: String {
        switch state.phase {
        case .waiting: return AppText.text("等車", language: language)
        case .riding: return AppText.text("下車站", language: language)
        case .walking: return AppText.text("步行前往", language: language)
        case .cycling: return AppText.text("騎車前往", language: language)
        case .transferring: return AppText.text("轉乘", language: language)
        }
    }
    var metricCaption: String {
        switch state.phase {
        case .waiting: return AppText.text("距離到站", language: language)
        case .riding: return AppText.text("距離下車", language: language)
        case .cycling: return AppText.text("距離還車", language: language)
        case .walking, .transferring: return AppText.text("預估抵達", language: language)
        }
    }
    var secondaryMetric: String? {
        guard !stale else { return nil }
        if let left = state.stopsLeft { return AppText.stops(max(0, left), language: language) }
        if let meters = state.remainingMeters, meters.isFinite {
            return meters < 1000 ? "\(Int(max(0, meters).rounded())) m" : String(format: "%.1f km", meters / 1000)
        }
        return nil
    }
    var relevance: Double { stale ? 0 : alightingSoon ? 100 : state.phase == .riding ? 80 : 60 }
    var status: String {
        if stale {
            if state.phase == .waiting, state.target.map({ $0 <= now }) == true {
                return AppText.text("留意來車，點一下更新", language: language)
            }
            return AppText.text("點一下更新", language: language)
        }
        if alightingSoon { return AppText.text("準備下車", language: language) }
        if due {
            switch state.phase {
            case .waiting: return AppText.text("留意來車", language: language)
            case .riding: return AppText.text("留意下車站", language: language)
            default: return AppText.text("確認目前進度", language: language)
            }
        }
        return state.status ?? AppText.text("查看行程", language: language)
    }
    var minutes: Int? { target.map { max(1, Int(ceil($0.timeIntervalSince(now) / 60))) } }
    var compactText: String? {
        guard !stale else { return nil }
        if alightingSoon { return AppText.text("下車", language: language) }
        if state.phase == .riding, let stops = state.stopsLeft {
            return AppText.stops(max(0, stops), language: language)
        }
        return minutes.map { AppText.text("%@ 分", $0, language: language) }
    }
    var progress: Double? {
        guard !stale, let left = state.stopsLeft, let total = state.totalStops, total > 0 else { return nil }
        return min(1, max(0, Double(total - left) / Double(total)))
    }
    var accessibilityLabel: String {
        [phaseTitle, state.sign.text, state.headline, stale || due || alightingSoon ? status : compactText ?? status]
            .joined(separator: " · ")
    }
}
#endif

/// Saved trips for the Home Screen widget. The app records the first ride it planned for each
/// trip; the widget asks the official feed for the next arrival at that stop itself.
struct CommuteWidgetPayload: Codable, Sendable {
    struct Ride: Codable, Hashable, Sendable {
        var metro: Bool
        var sign: RouteSign
        /// Official estimate key (parent route and stop IDs). Empty for metro.
        var routeKey: String
        var stopID: String
        var stopName: String
        var toward: String
        var walkSeconds: Double
        /// Typical interval for metro rides, in seconds.
        var headwaySeconds: Double?
    }
    struct Commute: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var title: String
        var symbol: String
        var destination: String
        var ride: Ride?
        /// Planned, and walking is the whole trip: there is no bus to wait for.
        var walkOnly: Bool?
    }
    var language: String
    var proUntil: Date?
    var updatedAt: Date
    var commutes: [Commute]
    static let maximumCommutes = 4
}

/// The app and its widget share one keychain access group, which every App Store profile
/// already allows; no App Group has to be created for this.
enum SharedStore {
    private static let service = "TaipeiBus.shared"
    static let commutesAccount = "commutes.v1"

    static var accessGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BusSharedKeychainGroup") as? String,
              !value.isEmpty, !value.hasPrefix("."), !value.contains("$(") else { return nil }
        return value
    }
    private static func query(_ account: String) -> [String: Any]? {
        guard let accessGroup else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: accessGroup,
                kSecUseDataProtectionKeychain as String: true]
    }
    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        guard var item = query(account) else { return false }
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        if SecItemUpdate(item as CFDictionary, attributes as CFDictionary) == errSecSuccess { return true }
        item.merge(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
    static func read(account: String) -> Data? {
        guard var item = query(account) else { return nil }
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func commutes() -> CommuteWidgetPayload? {
        guard let data = read(account: commutesAccount), data.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(CommuteWidgetPayload.self, from: data)
    }
}

extension Color {
    init(signHex hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x1F6FD1
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255, opacity: 1)
    }
}
