import SwiftUI
import UIKit
import TransitCore

@main
struct TaipeiBusApp: App {
    @StateObject private var model = TransitAppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var update = AppUpdateRequirement.none
    @State private var updateMessage: String?
    @AppStorage("dismissedRecommendedVersion") private var dismissedRecommendedVersion = ""
    private let updates = AppUpdateService(cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AppUpdate"))
    /// Loads the last calibrated arrival constants from disk at launch, then checks for new ones.
    private let tuning = ForecastTuningService(cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ForecastTuning"))

    init() {
#if DEBUG
        ViewChangeLog.start()
#endif
        AskTaipeiBusIntent.connect()
    }

    var body: some Scene {
        WindowGroup {
            root
                .onOpenURL { model.open($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
#if DEBUG || ISLAND_RENDER_AUDIT
                    // The gallery owns a separate real activity controller.
                    // Do not let an empty home-screen model clean up its session.
                    if ProcessInfo.processInfo.arguments.contains("--preview-island") { return }
                    // The motion lab measures the decoration alone, without feeds polling behind it.
                    if ProcessInfo.processInfo.arguments.contains("--test-motion-lab") { return }
#endif
                    model.setActive(phase == .active)
                    if phase == .active { Task { await checkForUpdate() }; Task { await tuning.refresh() } }
                }
                .overlay { if update == .required { RequiredUpdateView(message: updateMessage) } }
                .alert(AppText.text("有新版本"), isPresented: Binding(
                    get: { if case .recommended(let version) = update { return version != dismissedRecommendedVersion }; return false },
                    set: { shown in if !shown, case .recommended(let version) = update { dismissedRecommendedVersion = version } })) {
                    Button(AppText.text("更新")) { UIApplication.shared.open(AppUpdateService.storeURL) }
                    Button(AppText.text("稍後"), role: .cancel) {}
                } message: {
                    Text(updateMessage ?? AppText.text("新版本包含修正與改進，建議更新。"))
                }
        }
    }

    private func checkForUpdate() async {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let result = await updates.requirement(appVersion: version,
            systemVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
        updateMessage = await updates.message(english: model.language == .english)
        update = result
    }

    @ViewBuilder private var root: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-island") {
            IslandPreviewGallery(language: model.language).environment(\.locale, model.language.locale)
        } else if ProcessInfo.processInfo.arguments.contains("--preview-widgets") {
            WidgetPreviewGallery(language: model.language).environment(\.locale, model.language.locale)
        } else if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--test-motion-lab") {
            let arguments = ProcessInfo.processInfo.arguments
            MotionLabView(component: arguments.indices.contains(index + 1) ? arguments[index + 1] : "idle")
        } else if ProcessInfo.processInfo.arguments.contains("--test-motion-cost") {
            home.overlay(alignment: .topLeading) { MotionCostLabel() }.onAppear { MotionCostProbe.shared.start() }
        } else { home }
#elseif ISLAND_RENDER_AUDIT
        if ProcessInfo.processInfo.arguments.contains("--preview-island") {
            IslandPreviewGallery(language: ProcessInfo.processInfo.arguments.contains("en") ? .english : .traditionalChinese)
        } else { home }
#else
        home
#endif
    }
    private var home: some View {
            TransitHomeView(model: model)
                .environment(\.liveSettings, model.presentationSettings)
                .environment(\.locale, model.language.locale)
                .modifier(AuditTextSize())
                .accentColor(Color(liveHex: model.liveSettings.appearance.accentColor))
                .tint(Color(liveHex: model.liveSettings.appearance.accentColor))
    }
}

private struct AuditTextSize: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-accessibility-text") {
            content.dynamicTypeSize(.accessibility3)
        } else { content }
#else
        content
#endif
    }
}

/// Covers the whole app until it is updated; shown only when the App Store already offers
/// a version that meets the remote minimum and runs on this phone.
private struct RequiredUpdateView: View {
    let message: String?
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.down.app.fill").font(.system(size: 56)).foregroundStyle(.tint)
            Text(AppText.text("需要更新 App")).font(.title2.weight(.semibold))
            Text(message ?? AppText.text("這個版本已不再提供服務，請更新到最新版本後繼續使用。"))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { UIApplication.shared.open(AppUpdateService.storeURL) } label: {
                Text(AppText.text("前往 App Store")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
    }
}

#if DEBUG
/// For finding a layout that never settles (`--test-view-changes`): what made each trip view
/// evaluate again, in SwiftUI's own words, written to view-changes.log in the app's tmp folder.
enum ViewChangeLog {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--test-view-changes")
    static func start() {
        guard enabled else { return }
        let descriptor = open(NSTemporaryDirectory() + "view-changes.log", O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if descriptor >= 0 { dup2(descriptor, STDOUT_FILENO); close(descriptor) }
    }
    static func note<V: View>(_ view: V.Type) { if enabled { V._printChanges() } }
}

/// For measurements only (`--test-motion-cost`, `--test-motion-lab`): how much of the main thread
/// the interface takes and how evenly frames arrive, in five-second windows. UI tests read the
/// windows from a hidden label once, after they have passed, so reading never lands inside one.
@MainActor
final class MotionCostProbe: NSObject, ObservableObject {
    static let shared = MotionCostProbe()
    @Published private(set) var report = "{}"
    private var link: CADisplayLink?
    private var pacing = FramePacingWindow(interval: 5)
    private var windowStart: (wall: CFTimeInterval, main: Double, process: Double)?
    private var windows: [[String: Any]] = []
    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if windowStart == nil { windowStart = (now, Self.mainThreadSeconds(), Self.processSeconds()) }
        guard let frames = pacing.observe(timestamp: link.timestamp, targetInterval: link.targetTimestamp - link.timestamp),
              let start = windowStart else { return }
        let main = Self.mainThreadSeconds(), process = Self.processSeconds()
        let wall = max(0.001, now - start.wall)
        windowStart = (now, main, process)
        let ended = Date().timeIntervalSince1970
        windows.append(["began": ended - wall, "ended": ended, "seconds": wall, "fps": frames.framesPerSecond, "frames": frames.frames,
                        "delayed": frames.delayedFrames, "longest_ms": frames.longestGapMilliseconds,
                        "main_cpu_pct": (main - start.main) / wall * 100,
                        "process_cpu_pct": (process - start.process) / wall * 100])
        let environment = ProcessInfo.processInfo.environment
        let value: [String: Any] = ["windows": Array(windows.suffix(12)), "count": windows.count,
            "os": UIDevice.current.systemVersion,
            "device": environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.model,
            "model": environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "",
            "screen_hz": UIScreen.main.maximumFramesPerSecond,
            "still": MotionBudget.shared.conserving, "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled]
        if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            report = String(decoding: data, as: UTF8.self)
        }
    }
    /// CPU time the main thread has used, in seconds.
    private static func mainThreadSeconds() -> Double {
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }
    /// CPU time every thread of the app has used, in seconds.
    private static func processSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}

struct MotionCostLabel: View {
    @ObservedObject private var probe = MotionCostProbe.shared
    var body: some View {
        Text(probe.report).font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
            .accessibilityIdentifier("motion-cost-state").allowsHitTesting(false)
    }
}

/// One piece of never-ending decoration at a time, alone on a plain screen, as the app shows it.
/// Launched with `--test-still-decor` the same piece holds still, which is the baseline.
private struct MotionLabView: View {
    let component: String
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            switch component {
            case "orb":
                // As on the home screen, beside the search field.
                VoiceOrb(mood: .calm, compact: true)
                    .frame(width: 72, height: 72).frame(width: 56, height: 56)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: Color(red: 0.5, green: 0.4, blue: 1).opacity(0.35), radius: 8, y: 3)
            case "orb-large":
                VoiceOrb(mood: .listening).frame(width: 250, height: 250)
            case "glow":
                EdgeGlow(mood: .listening)
            case "preview":
                // The voice style card in Settings: glow and orb inside a clipped, composited,
                // faded group, as the unchosen card shows them.
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    EdgeGlow(mood: .listening, corner: 22, scale: 0.28)
                    VoiceOrb(mood: .listening, compact: true).frame(width: 52, height: 52)
                }
                .frame(width: 150, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .compositingGroup()
                .opacity(0.75)
            case "pulse":
                // The waiting banner's route sign with a bus arriving, and the riding banner's next-stop dot.
                VStack(spacing: 28) {
                    RouteBadge(name: "307", tintName: "307").attentionPulse(true, color: Color(liveHex: "#6EE7A0"), cornerRadius: 10)
                    Circle().fill(Color(liveHex: "#FFD60A")).frame(width: 8, height: 8).attentionPulse(true, color: Color(liveHex: "#FFD60A"))
                }
                .padding(28).background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            case "loading":
                LoadingRows(count: 5, label: "loading").padding(.horizontal, 18)
            case "symbols":
                ContinuousMotion { running in
                    Image(systemName: "figure.walk").font(.title).symbolEffect(.pulse, options: .repeating, isActive: running)
                }
            default:
                EmptyView()
            }
            MotionCostLabel().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { MotionCostProbe.shared.start() }
    }
}
#endif
