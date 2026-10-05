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
                .accentColor(Color(liveHex: model.liveSettings.appearance.accentColor))
                .tint(Color(liveHex: model.liveSettings.appearance.accentColor))
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setActive(phase == .active)
                }
        }
    }
}
