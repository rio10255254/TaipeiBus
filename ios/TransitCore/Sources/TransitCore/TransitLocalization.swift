import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case traditionalChinese = "zh-Hant"
    case english = "en"
    public static let preferenceKey = "appInterfaceLanguage"
    // The app initializes a missing preference from the device. Core consumers
    // without an app preference retain their original deterministic language.
    public static var current: AppLanguage {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .traditionalChinese
    }
    public static func deviceDefault(_ preferences: [String]) -> AppLanguage {
        preferences.first?.lowercased().hasPrefix("zh") == true ? .traditionalChinese : .english
    }
    public var locale: Locale { Locale(identifier: self == .english ? "en_TW" : "zh_Hant_TW") }
}

public enum AppText {
    static let english: [String: String] = {
        guard let url = Bundle.module.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return catalog
    }()
    private static let originals = Dictionary(english.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    public static func canonical(_ text: String) -> String { originals[text] ?? text }
    public static func text(_ key: String, _ values: Any..., language: AppLanguage? = nil) -> String {
        format(key, values: values.map { String(describing: $0) }, language: language ?? .current)
    }
    public static func format(_ key: String, values: [String], language: AppLanguage = .current) -> String {
        let original = canonical(key)
        var template = language == .english ? english[original] ?? key : original
        // Only shipped templates can contain placeholders. Values are never
        // interpreted as format instructions, including user-entered place names.
        guard !values.isEmpty else { return template }
        if language == .english, values.first == "1" {
            for (plural, singular) in [("%@ stops", "%@ stop"), ("%@ buses", "%@ bus"), ("%@ routes", "%@ route")] {
                template = template.replacingOccurrences(of: plural, with: singular)
            }
        }
        return String(format: template, locale: language.locale, arguments: values.map { $0 as CVarArg })
    }
    public static func stops(_ count: Int, language: AppLanguage = .current) -> String {
        language == .english ? "\(count) \(count == 1 ? "stop" : "stops")" : "\(count) 站"
    }
    public static func remainingStops(_ count: Int, language: AppLanguage = .current) -> String {
        language == .english ? "\(stops(count, language: language)) left" : "還有 \(count) 站"
    }
    public static func minutes(_ count: Int, language: AppLanguage = .current) -> String {
        language == .english ? "\(count) min" : "\(count) 分"
    }
}
