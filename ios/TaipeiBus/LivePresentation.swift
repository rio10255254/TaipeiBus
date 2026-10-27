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
    /// One colour per hex value: a fresh dynamic UIColor never equals the last one, so tints and
    /// accents made anew on every update read to SwiftUI and UIKit as a change each time.
    private static let liveHexLock = NSLock()
    nonisolated(unsafe) private static var liveHexColors: [String: Color] = [:]
    init(liveHex: String) {
        Color.liveHexLock.lock(); defer { Color.liveHexLock.unlock() }
        if let known = Color.liveHexColors[liveHex] { self = known; return }
        let made = Color.dynamic(liveHex: liveHex)
        Color.liveHexColors[liveHex] = made
        self = made
    }
    private static func dynamic(liveHex: String) -> Color {
        Color(uiColor: UIColor { traits in
            let base = UIColor(liveHex: liveHex)
            guard traits.userInterfaceStyle == .dark else { return base }
            if liveHex.uppercased() == "#007AFF" { return UIColor.systemBlue.resolvedColor(with: traits) }
            if liveHex.uppercased() == "#FF9500" { return UIColor.systemOrange.resolvedColor(with: traits) }
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
        let traits = UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.contentSizeCategory)
        let size = UIFontMetrics(forTextStyle: uiStyle).scaledValue(for: base * CGFloat(live.appearance.textScale), compatibleWith: traits)
        return content.font(.system(size: size, weight: weight, design: design))
    }
}
extension DynamicTypeSize {
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
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
    /// A finger on a control: quick to press in, a touch of give on release.
    static let press = Animation.spring(response: 0.24, dampingFraction: 0.74)
    /// Floating map controls, chips and cards that appear, move or change size.
    static let chrome = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Sheets and panels that change height or page.
    static let panel = Animation.spring(response: 0.42, dampingFraction: 0.9)
    /// Text, symbols and colours that change in place.
    static let content = Animation.smooth(duration: 0.28)
}

/// Whether decorative motion that never stops (a turning orb, a glow, a breathing ring, a loading
/// pulse) may run. In Low Power Mode or once the phone runs hot it holds still, as the map drops to
/// 60 Hz then; Reduce Motion stills it too (`ContinuousMotion` adds that). Motion that answers a
/// touch (a press, a transition, one bounce) is short and always allowed.
@MainActor
final class MotionBudget: ObservableObject {
    static let shared = MotionBudget()
    /// True while the phone asks apps to save energy or cool down, or the map is dropping frames.
    @Published private(set) var conserving = MotionBudget.evaluate()
    private var observers: [NSObjectProtocol] = []
    /// Until when measured frame drops keep the decoration still; it comes back on its own.
    private var stutterUntil = Date.distantPast
    private var resume: Task<Void, Never>?
    /// The map's display pacing over the last minute. Every iPhone keeps the full design; only
    /// when frames are actually being dropped does the never-ending decoration rest for a few
    /// minutes, giving the main thread back to the map and the trip.
    func notePacing(frames: Int, delayed: Int) {
        guard frames > 120, Double(delayed) / Double(frames) > 0.08 else { return }
        stutterUntil = Date().addingTimeInterval(180)
        refresh()
        resume?.cancel()
        resume = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(181))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
    private init() {
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in MotionBudget.shared.refresh() }
            })
        }
    }
    nonisolated private static func evaluate() -> Bool {
#if DEBUG
        // Measurements compare the same screen with its never-ending decoration held still.
        if ProcessInfo.processInfo.arguments.contains("--test-still-decor") { return true }
#endif
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
    func refresh() {
        let value = Self.evaluate() || Date() < stutterUntil
        if value != conserving { conserving = value }
    }
}

/// What this iPhone is, for the diagnostics that tell how the app runs on each model. Nothing here
/// lowers the design by model name; the budget above reacts to what is measured on the phone.
enum DeviceProfile {
    /// The hardware identifier, such as iPhone17,3 (the simulator reports the model it stands for).
    static let model: String = {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()
    /// The A-series generation: iPhone11,x is A12 through iPhone18,x for A19.
    static let chip: Int? = {
        guard model.hasPrefix("iPhone"), let major = Int(model.dropFirst(6).prefix(while: \.isNumber)) else { return nil }
        return major + 1
    }()
    static let memoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    /// One line for the shared diagnostics: model, chip, memory, screen rate and system.
    static var summary: String {
        "device=\(model) chip=\(chip.map { "A\($0)" } ?? "?") memory_gb=\(memoryGB) max_hz=\(UIScreen.main.maximumFramesPerSecond) ios=\(UIDevice.current.systemVersion)"
    }
}

/// Hands its content whether never-ending decorative motion may run right now: not with Reduce
/// Motion, in Low Power Mode or on a hot phone. The content holds still and keeps its colours.
struct ContinuousMotion<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject private var budget = MotionBudget.shared
    private let content: (Bool) -> Content
    init(@ViewBuilder content: @escaping (_ running: Bool) -> Content) { self.content = content }
    var body: some View { content(!InterfaceMotion.reduced(systemReduceMotion) && !budget.conserving) }
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
    /// Rolls the digits when `value` changes. A content transition alone does nothing for
    /// data updates that arrive outside an animation, so this supplies the animation too.
    func liveNumericText<Value: Equatable>(_ value: Value, countsDown: Bool = false) -> some View {
        modifier(LiveNumericText(value: value, countsDown: countsDown))
    }
    func secondaryAction() -> some View {
        modifier(NativeActionSurface(prominent: false)).buttonBorderShape(.capsule).controlSize(.small)
    }
    func primaryAction() -> some View { modifier(NativeActionSurface(prominent: true)).buttonBorderShape(.capsule) }
    func readableMapSurface() -> some View { modifier(ReadableMapSurface()) }
}
private struct LiveNumericText<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let value: Value
    let countsDown: Bool
    func body(content: Content) -> some View {
        let reduced = InterfaceMotion.reduced(systemReduceMotion)
        content.contentTransition(reduced ? .identity : .numericText(countsDown: countsDown))
            .animation(reduced ? nil : .smooth(duration: 0.35), value: value)
    }
}

/// The app's haptic vocabulary. Browsing stays a light selection tick so the firmer
/// patterns keep their meaning during a trip.
///
/// Each generator is made on first use, kept, and primed again after it fires, so a run of
/// taps (keys, pages, a trip's stages) lands on a Taptic Engine that is already awake instead
/// of spinning one up every time. Every caller is on the main thread.
enum Haptics {
    nonisolated(unsafe) private static var selector: UISelectionFeedbackGenerator?
    nonisolated(unsafe) private static var notifier: UINotificationFeedbackGenerator?
    nonisolated(unsafe) private static var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat = 1) {
        let generator = impacts[style] ?? UIImpactFeedbackGenerator(style: style)
        impacts[style] = generator
        generator.impactOccurred(intensity: intensity); generator.prepare()
    }
    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = notifier ?? UINotificationFeedbackGenerator()
        notifier = generator
        generator.notificationOccurred(type); generator.prepare()
    }
    /// Picking a stop, route, bus, key, page or map mode.
    static func selection() {
        let generator = selector ?? UISelectionFeedbackGenerator()
        selector = generator
        generator.selectionChanged(); generator.prepare()
    }
    /// A deliberate step: starting a trip, boarding, alighting, a changed station, or starting
    /// and finishing a spoken request.
    static func stage() { impact(.medium) }
    /// Something finished: the destination reached, or a spoken trip planned.
    static func success() { notify(.success) }
    /// Something needs attention: the assistant could not continue, a search found nothing.
    static func warning() { notify(.warning) }
    /// The microphone opened.
    static func listening() { impact(.soft, intensity: 0.9) }
    /// The sentence was heard and is being understood.
    static func heard() { impact(.rigid, intensity: 0.7) }
    /// A question for the rider, such as consent to go online.
    static func prompt() { impact(.light) }
    /// A trip or a walk put away before its end: softer than a stage, so it never reads as arriving.
    static func ended() { impact(.soft, intensity: 0.6) }
    /// Something switched on or off in place: a favourite, the alighting reminder, following a bus.
    static func toggle(_ on: Bool) { if on { impact(.light, intensity: 0.8) } else { selection() } }
}

extension View {
    /// Swaps one SF Symbol for the next with the system Replace effect (Magic Replace from iOS 18,
    /// so a slash or a badge draws onto the same glyph), and animates the colour that comes with
    /// it. Symbol changes from data updates arrive outside an animation, so this supplies one.
    func symbolSwap<Value: Equatable>(_ value: Value) -> some View { modifier(SymbolSwap(value: value)) }
    /// One bounce of the symbols inside when `value` changes: the visible echo of a tap or of a
    /// moment worth noticing, such as arriving.
    func symbolBounce<Value: Equatable>(_ value: Value) -> some View { modifier(SymbolBounce(value: value)) }
    /// A soft ring that keeps breathing out of the view while `active`: a bus about to arrive, the
    /// rider's stop coming next. `cornerRadius` nil follows a circle or capsule. With Reduce Motion,
    /// in Low Power Mode or on a hot phone the ring holds still and the colour alone says it.
    func attentionPulse(_ active: Bool, color: Color, cornerRadius: CGFloat? = nil) -> some View {
        modifier(AttentionPulse(active: active, color: color, cornerRadius: cornerRadius))
    }
}
private struct SymbolSwap<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let value: Value
    @ViewBuilder func body(content: Content) -> some View {
        if InterfaceMotion.reduced(systemReduceMotion) {
            content.contentTransition(.identity)
        } else if #available(iOS 18.0, *) {
            content.contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .animation(InterfaceMotion.content, value: value)
        } else {
            content.contentTransition(.symbolEffect(.replace)).animation(InterfaceMotion.content, value: value)
        }
    }
}
private struct SymbolBounce<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let value: Value
    @ViewBuilder func body(content: Content) -> some View {
        if InterfaceMotion.reduced(systemReduceMotion) { content }
        else { content.symbolEffect(.bounce, value: value) }
    }
}
private struct AttentionPulse: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let active: Bool
    let color: Color
    /// nil: a circle or capsule.
    let cornerRadius: CGFloat?
    func body(content: Content) -> some View {
        ContinuousMotion { running in
            content.background {
                if active {
                    PulseRing(color: UIColor(color), cornerRadius: cornerRadius, running: running, dark: colorScheme == .dark)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// The attention ring, drawn and animated by Core Animation. Once added, the animation runs in
/// the render server: it costs the app no work per frame, keeps its pace while the main thread is
/// busy planning or decoding, and asks for no more than 60 Hz on a 120 Hz screen.
private struct PulseRing: UIViewRepresentable {
    let color: UIColor
    let cornerRadius: CGFloat?
    let running: Bool
    let dark: Bool
    func makeUIView(context: Context) -> PulseRingView { PulseRingView() }
    func updateUIView(_ view: PulseRingView, context: Context) {
        view.configure(color: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)),
                       cornerRadius: cornerRadius, running: running)
    }
}

final class PulseRingView: UIView {
    private let ring = CAShapeLayer()
    private var cornerRadius: CGFloat?
    private var running = false
    private static let key = "attention-pulse"
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        ring.fillColor = nil
        ring.lineWidth = 2
        layer.addSublayer(ring)
        // Returning from the background, Core Animation may have dropped a repeating animation.
        NotificationCenter.default.addObserver(self, selector: #selector(returnedToForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func returnedToForeground() { applyMotion() }
    func configure(color: UIColor, cornerRadius: CGFloat?, running: Bool) {
        ring.strokeColor = color.cgColor
        let reshape = cornerRadius != self.cornerRadius
        self.cornerRadius = cornerRadius
        if running != self.running { self.running = running; applyMotion() }
        if reshape { setNeedsLayout() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        // Still, the ring sits just outside the mark; moving, it starts on its edge.
        let rect = running ? bounds : bounds.insetBy(dx: -3, dy: -3)
        let radius = cornerRadius.map { $0 + (running ? 0 : 3) } ?? min(rect.width, rect.height) / 2
        ring.path = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { applyMotion() }
    }
    private func applyMotion() {
        setNeedsLayout()
        guard running, window != nil else {
            ring.removeAnimation(forKey: Self.key)
            ring.opacity = running ? 0 : 0.8
            return
        }
        ring.opacity = 0
        guard ring.animation(forKey: Self.key) == nil else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1; grow.toValue = 1.32
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.85; fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = 1.3
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        pulse.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        ring.add(pulse, forKey: Self.key)
    }
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
    @Environment(\.liveSettings) private var live
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.foregroundStyle(.primary)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.97), in: live.shape(.label))
            .overlay { live.shape(.label).stroke(Color.primary.opacity(scheme == .dark ? 0.18 : 0.09), lineWidth: 0.7) }
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
    static func darkInk(for name: String) -> Bool {
        ["中和新蘆線","環狀線","三鶯線","Zhonghe-Xinlu Line","Circular Line","Sanying Line"].contains(name)
    }
    static func signInk(for name: String) -> Color { darkInk(for: name) ? .black : .white }
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
    /// Corner radii, largest to smallest. A surface nested in another takes a
    /// smaller step so the two curves stay close to concentric across the padding.
    enum Corner: CGFloat {
        /// Floating trip cards and banners.
        case card = 26
        /// Glass bars, place cards and grouped blocks in a sheet.
        case panel = 22
        /// Callouts and notices that sit on the map itself.
        case label = 18
        /// Search fields, list groups, rows and tiles inside a card or sheet.
        case row = 14
        /// Route badges, keys and icon tiles.
        case badge = 10
        case badgeCompact = 7
    }
    static let controlSize: CGFloat = 48
    static let walkingLight = "#1F6FD1"
    static let walkingDark = "#5AA2FF"
    /// Readable on the light and dark trip surfaces, including small arrival and wait labels.
    static let secondaryText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(liveHex: "#C8CDD6") : UIColor(liveHex: "#535862") })
    static let destructive = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(liveHex: "#FF6961") : UIColor(liveHex: "#C4151C") })
    static let positive = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(liveHex: "#5EDB86") : UIColor(liveHex: "#1A7F37") })
    /// Apple Maps' green Go action, dark enough for white text.
    static let go = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(liveHex: "#23813F") : UIColor(liveHex: "#1E7F3C") })
    static let caution = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(liveHex: "#FFB340") : UIColor(liveHex: "#B35900") })
}

extension MapChrome {
    /// The continuous rounded shape for `corner` at its design size, for views that do not
    /// follow the remote appearance settings (the assistant screens, sheets of system text).
    static func shape(_ corner: Corner) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: corner.rawValue, style: .continuous)
    }
}
extension LiveSettings {
    /// The continuous rounded shape for `corner`, scaled by the remote corner setting.
    func shape(_ corner: MapChrome.Corner) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius(corner), style: .continuous)
    }
    /// The radius of `corner`, scaled by the remote corner setting.
    func radius(_ corner: MapChrome.Corner) -> CGFloat { corner.rawValue * CGFloat(appearance.cornerScale) }
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
            .animation(reduced ? nil : InterfaceMotion.press, value: configuration.isPressed)
            .animation(reduced ? nil : InterfaceMotion.content, value: isEnabled)
    }
}

/// Apple Maps place-card action tiles: icon above a short label.
struct MapTileStyle: ButtonStyle {
    @Environment(\.liveSettings) private var live
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var prominent = false
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        let accent = tint ?? Color(liveHex: live.appearance.accentColor)
        let shape = live.shape(.row)
        let reduced = InterfaceMotion.reduced(systemReduceMotion)
        return configuration.label
            .labelStyle(.tile)
            .foregroundStyle(prominent ? Color.white : accent)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(prominent ? AnyShapeStyle(accent) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)), in: shape)
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.42)
            .scaleEffect(configuration.isPressed && !reduced ? 0.97 : 1)
            .animation(reduced ? nil : InterfaceMotion.press, value: configuration.isPressed)
            .animation(reduced ? nil : InterfaceMotion.content, value: isEnabled)
    }
}

/// A row in a list or search results: a soft rounded highlight under the finger, as iOS
/// lists do, instead of shrinking the whole row. The highlight shows at once on touch and
/// fades out on release; a disabled row (a search still resolving) dims.
struct RowPressStyle: ButtonStyle {
    @Environment(\.liveSettings) private var live
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// How far the highlight reaches past the row's own edges, for rows without inner padding.
    var bleed: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        let reduced = InterfaceMotion.reduced(systemReduceMotion)
        return configuration.label
            .contentShape(Rectangle())
            // Only a pressed row carries a highlight layer; long lists stay as light as before.
            .background {
                if configuration.isPressed {
                    live.shape(.row).fill(Color.primary.opacity(0.08)).padding(.horizontal, -bleed)
                        .transition(.opacity)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(configuration.isPressed || reduced ? nil : .easeOut(duration: 0.3), value: configuration.isPressed)
            .animation(reduced ? nil : InterfaceMotion.content, value: isEnabled)
    }
}

extension View {
    /// The control a sheet opens from, so the sheet can grow out of it (the iOS 18 zoom; on iOS 26
    /// the sheet morphs out of the control's glass). Earlier systems keep the standard slide up.
    @ViewBuilder func sheetSource(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
    /// Presents this sheet out of the control marked with the same `sheetSource` id.
    @ViewBuilder func opensFromSource(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: id, in: namespace)) } else { self }
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

/// A list or search with nothing to show: a symbol, what happened and what to try next,
/// in the manner of ContentUnavailableView but following the app's text scale. Callers
/// pass text that is already localized.
struct EmptyStateView<Actions: View>: View {
    @Environment(\.liveSettings) private var live
    private let symbol: String
    private let title: String?
    private let message: String
    private let actions: Actions
    init(symbol: String, title: String? = nil, message: String, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol; self.title = title; self.message = message; self.actions = actions()
    }
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).liveFont(.title, weight: .medium).foregroundStyle(MapChrome.secondaryText)
                .padding(.bottom, 4).accessibilityHidden(true)
            if let title {
                Text(title).liveFont(.headline).multilineTextAlignment(.center).lineLimit(2)
            }
            Text(message).liveFont(.subheadline).foregroundStyle(MapChrome.secondaryText)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            actions.padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12).padding(.vertical, 24 * CGFloat(live.appearance.spacingScale))
    }
}
extension EmptyStateView where Actions == EmptyView {
    init(symbol: String, title: String? = nil, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// Grey rows in the shape of the list that is loading, so the layout is already in place
/// and nothing jumps when the content arrives. They pulse gently unless Reduce Motion is on.
struct LoadingRows: View {
    @Environment(\.liveSettings) private var live
    var count = 3
    /// Spoken in place of the placeholder rows, already localized.
    let label: String
    @State private var dimmed = false
    var body: some View {
        ContinuousMotion { running in rows(running) }
    }
    private func rows(_ running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(spacing: 12) {
                    live.shape(.badge).frame(width: 46, height: 28)
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().frame(width: index.isMultiple(of: 2) ? 148 : 116, height: 11)
                        Capsule().frame(width: index.isMultiple(of: 2) ? 92 : 128, height: 9)
                    }
                    Spacer(minLength: 0)
                    Capsule().frame(width: 38, height: 11)
                }
                .padding(.vertical, 12 * CGFloat(live.appearance.spacingScale))
                if index < count - 1 { Divider() }
            }
        }
        .foregroundStyle(Color(uiColor: .systemFill))
        .opacity(dimmed ? 0.5 : 1)
        .animation(running ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: dimmed)
        .onChange(of: running, initial: true) { _, run in dimmed = run }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A row icon as in iOS Settings: a white symbol on a rounded colour tile, so rows read at a glance.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 29
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A Settings row label: the coloured tile and the title in the primary colour, also inside links and buttons.
struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color
    var body: some View {
        Label { Text(title).foregroundStyle(.primary) } icon: { SettingsIcon(symbol: symbol, color: color) }
    }
}

/// A section header that carries a small coloured symbol, so long explanation pages scan by topic.
struct SectionHeader: View {
    let title: String
    let symbol: String
    var color: Color = .secondary
    var body: some View {
        Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(color) }
    }
}
