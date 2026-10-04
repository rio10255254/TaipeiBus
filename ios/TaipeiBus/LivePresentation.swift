import SwiftUI
import UIKit
import TransitCore

private struct LiveSettingsEnvironmentKey: EnvironmentKey {
    static let defaultValue = LiveSettings.defaults
}
extension EnvironmentValues {
    var liveSettings: LiveSettings {
        get { self[LiveSettingsEnvironmentKey.self] }
        set { self[LiveSettingsEnvironmentKey.self] = newValue }
    }
}
extension UIColor {
    convenience init(liveHex: String) {
        let value = UInt32(liveHex.dropFirst(), radix: 16) ?? 0x007AFF
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
extension Color {
    init(liveHex: String) {
        self.init(uiColor: UIColor { traits in
            let base = UIColor(liveHex: liveHex)
            guard traits.userInterfaceStyle == .dark else { return base }
            if liveHex.uppercased() == "#007AFF" { return UIColor.systemBlue.resolvedColor(with: traits) }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getRed(&r, green: &g, blue: &b, alpha: &a)
            return UIColor(red: r + (1-r)*0.18, green: g + (1-g)*0.18, blue: b + (1-b)*0.18, alpha: a)
        })
    }
}
private struct LiveFontModifier: ViewModifier {
    @Environment(\.liveSettings) private var live
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let style: Font.TextStyle
    let weight: Font.Weight
    let design: Font.Design
    private var uiStyle: UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
    func body(content: Content) -> some View {
        let category = UITraitCollection(preferredContentSizeCategory: .large)
        let base = UIFont.preferredFont(forTextStyle: uiStyle, compatibleWith: category).pointSize
        let size = UIFontMetrics(forTextStyle: uiStyle).scaledValue(for: base * CGFloat(live.appearance.textScale))
        // Read dynamicTypeSize so system accessibility changes invalidate this modifier too.
        let _ = dynamicTypeSize
        return content.font(.system(size: size, weight: weight, design: design))
    }
}
extension View {
    func liveFont(_ style: Font.TextStyle, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(LiveFontModifier(style: style, weight: weight, design: design))
    }
}

/// Animate discrete interface changes without animating every GPS or countdown update.
enum InterfaceMotion {
    static func reduced(_ system: Bool) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-reduce-motion") { return true }
#endif
        return system
    }
}
private struct SmoothChange<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }
    let value: Value
    func body(content: Content) -> some View {
        content.contentTransition(reduceMotion ? .identity : .opacity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: value)
    }
}
extension View {
    func smoothChanges<Value: Equatable>(_ value: Value) -> some View { modifier(SmoothChange(value: value)) }
    func secondaryAction() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
    }
}

/// Published English names keep their Chinese sign text visible as a smaller
/// second line. Route/stop identifiers and search keys never change language.
struct BilingualName: View {
    @Environment(\.liveSettings) private var live
    let chinese: String
    let english: String
    init(_ station: Station) { chinese = station.name; english = station.englishName }
    init(_ stop: BusStop) { chinese = stop.name; english = stop.englishName }
    init(chinese: String, english: String) { self.chinese = chinese; self.english = english }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(live.language == .english && !english.isEmpty ? english : chinese)
            if live.language == .english, !english.isEmpty, english != chinese {
                Text(chinese).liveFont(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine).smoothChanges(live.language)
    }
}
