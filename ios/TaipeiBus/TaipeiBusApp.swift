import SwiftUI
import TransitCore

@main
struct TaipeiBusApp: App {
    @StateObject private var model = TransitAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            root
                .onOpenURL { model.open($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setActive(phase == .active)
                }
        }
    }

    @ViewBuilder private var root: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-widgets") {
            WidgetPreviewGallery(language: model.language).environment(\.locale, model.language.locale)
        } else { home }
#else
        home
#endif
    }
    private var home: some View {
            TransitHomeView(model: model)
                .environment(\.liveSettings, model.presentationSettings)
                .environment(\.locale, model.language.locale)
                .accentColor(Color(liveHex: model.liveSettings.appearance.accentColor))
                .tint(Color(liveHex: model.liveSettings.appearance.accentColor))
    }
}
