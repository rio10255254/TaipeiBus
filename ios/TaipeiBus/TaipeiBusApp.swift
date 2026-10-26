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

    init() { AskTaipeiBusIntent.connect() }

    var body: some Scene {
        WindowGroup {
            root
                .onOpenURL { model.open($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
#if DEBUG || ISLAND_RENDER_AUDIT
                    // The gallery owns a separate real activity controller.
                    // Do not let an empty home-screen model clean up its session.
                    if ProcessInfo.processInfo.arguments.contains("--preview-island") { return }
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
