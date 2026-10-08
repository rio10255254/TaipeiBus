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
        modifier(NativeActionSurface(prominent: false)).buttonBorderShape(.capsule).controlSize(.small)
    }
    func primaryAction() -> some View { modifier(NativeActionSurface(prominent: true)).buttonBorderShape(.capsule) }
    func readableMapSurface() -> some View { modifier(ReadableMapSurface()) }
}

private struct NativeActionSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let prominent: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

private struct ReadableMapSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.foregroundStyle(.primary)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 19))
            .overlay { RoundedRectangle(cornerRadius: 19).stroke(Color.primary.opacity(scheme == .dark ? 0.18 : 0.09), lineWidth: 0.7) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.12), radius: 9, y: 3)
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
                Text(chinese).liveFont(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
            }
        }.accessibilityElement(children: .combine).smoothChanges(live.language)
    }
}

/// Taipei route families keep their published sign colours so a badge, its map
/// line and the navigation banner read as the same route at a glance. Every
/// tint keeps white text at 4.5:1 or better.
enum RouteTint {
    static let general = "#1F6FD1"
    static func hex(for name: String) -> String {
        let metro = ["文湖線":"#b57a25", "板南線":"#0a59ae", "淡水信義線":"#d90023", "松山新店線":"#107547", "中和新蘆線":"#f5a818", "環狀線":"#fedb00", "三鶯線":"#47C1E1",
            "Wenhu Line":"#b57a25", "Bannan Line":"#0a59ae", "Tamsui-Xinyi Line":"#d90023", "Songshan-Xindian Line":"#107547", "Zhonghe-Xinlu Line":"#f5a818", "Circular Line":"#fedb00", "Sanying Line":"#47C1E1"]
        if let color = metro[name] { return color }
        let value = name.trimmingCharacters(in: .whitespaces)
        let lower = value.lowercased()
        func starts(_ chinese: String, _ english: String) -> Bool { value.hasPrefix(chinese) || lower.hasPrefix(english) }
        if starts("紅", "red") { return "#C62828" }
        if starts("藍", "blue") { return "#1A4E9C" }
        if starts("棕", "brown") { return "#8A5A2B" }
        if starts("綠", "green") { return "#1B7F38" }
        if starts("橘", "orange") { return "#C25E00" }
        if starts("黃", "yellow") { return "#8F6C00" }
        if starts("小", "minibus") || (lower.hasPrefix("s") && value.dropFirst().first?.isNumber == true) { return "#0F7C80" }
        if value.contains("幹線") || lower.contains("metro bus") { return "#6E3FA3" }
        return general
    }
    static func color(for name: String) -> Color { Color(liveHex: hex(for: name)) }
    static func signInk(for name: String) -> Color {
        ["中和新蘆線","環狀線","三鶯線","Zhonghe-Xinlu Line","Circular Line","Sanying Line"].contains(name) ? .black : .white
    }
    /// The route colour for text and lines on a sheet, lifted in dark mode to stay readable.
    static func accent(for name: String) -> Color {
        Color(uiColor: UIColor { UIColor(liveHex: mapHex(for: name, dark: $0.userInterfaceStyle == .dark)) })
    }
    /// Map lines draw on a dark basemap in dark mode, so lift them toward white.
    static func mapHex(for name: String, dark: Bool) -> String {
        guard dark else { return hex(for: name) }
        let base = UIColor(liveHex: hex(for: name))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> Int { Int(((value + (1 - value) * 0.32) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
    }
}

/// Shared measurements for the Apple Maps style cards, banners and controls.
enum MapChrome {
    static let cardRadius: CGFloat = 26
    static let controlSize: CGFloat = 48
    static let walkingLight = "#1F6FD1"
    static let walkingDark = "#5AA2FF"
    static let destructive = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(liveHex: "#FF6961") : UIColor(liveHex: "#C4151C") })
    static let positive = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(liveHex: "#5EDB86") : UIColor(liveHex: "#1A7F37") })
    /// Apple Maps' green Go action, dark enough for white text.
    static let go = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(liveHex: "#30A14E") : UIColor(liveHex: "#1E7F3C") })
    static let caution = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(liveHex: "#FFB340") : UIColor(liveHex: "#B35900") })
}

/// Filled or tinted capsule actions used by the trip cards, matching the
/// large rounded buttons in Apple Maps place cards and navigation.
struct MapActionStyle: ButtonStyle {
    @Environment(\.liveSettings) private var live
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var prominent = false
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        let color = tint ?? Color(liveHex: live.appearance.accentColor)
        let reduced = InterfaceMotion.reduced(systemReduceMotion)
        return configuration.label
            .foregroundStyle(prominent ? Color.white : color)
            .background(prominent ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.13)), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduced ? 0.97 : 1)
            .animation(reduced ? nil : .spring(response: 0.24, dampingFraction: 0.74), value: configuration.isPressed)
    }
}

/// Apple Maps place-card action tiles: icon above a short label.
struct MapTileStyle: ButtonStyle {
    @Environment(\.liveSettings) private var live
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        let accent = Color(liveHex: live.appearance.accentColor)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let reduced = InterfaceMotion.reduced(systemReduceMotion)
        return configuration.label
            .labelStyle(.tile)
            .foregroundStyle(prominent ? Color.white : accent)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(prominent ? AnyShapeStyle(accent) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)), in: shape)
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduced ? 0.97 : 1)
            .animation(reduced ? nil : .spring(response: 0.24, dampingFraction: 0.74), value: configuration.isPressed)
    }
}

struct TileLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.system(size: 19, weight: .semibold))
            configuration.title.liveFont(.caption, weight: .semibold).lineLimit(1).minimumScaleFactor(0.75)
        }.padding(.horizontal, 6)
    }
}
extension LabelStyle where Self == TileLabelStyle {
    static var tile: TileLabelStyle { TileLabelStyle() }
}
