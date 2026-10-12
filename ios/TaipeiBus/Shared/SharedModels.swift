import Foundation
import Security
import SwiftUI
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
        enum Phase: String, Codable, Hashable, Sendable { case waiting, riding, walking }
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
    }
    var destination: String
    var language: String
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
