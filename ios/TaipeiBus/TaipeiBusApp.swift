import SwiftUI
import TransitCore

@main
struct TaipeiBusApp: App {
    @StateObject private var model = TransitAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TransitHomeView(model: model)
                .environment(\.liveSettings, model.presentationSettings)
                .environment(\.locale, model.language.locale)
#if DEBUG
                .transformEnvironment(\.accessibilityReduceMotion) { value in
                    if ProcessInfo.processInfo.arguments.contains("--test-reduce-motion") { value = true }
                }
#endif
                .accentColor(Color(liveHex: model.liveSettings.appearance.accentColor))
                .tint(Color(liveHex: model.liveSettings.appearance.accentColor))
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setActive(phase == .active)
                }
        }
    }
}
