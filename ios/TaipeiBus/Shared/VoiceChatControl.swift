import AppIntents
import SwiftUI
import WidgetKit
import TransitCore

/// Opens the voice conversation (Pro): from Siri, a shortcut, the Action button, and on iOS 18 the
/// Control Center and Lock Screen control. Shared with the widget extension so the control can name
/// it; it runs in the app, which connects `handler` at launch.
struct AskTaipeiBusIntent: AppIntent {
    static let title: LocalizedStringResource = "問台北公車"
    static let description = IntentDescription("打開台北公車的語音對話（Pro）：查到站、規劃路線、導航時上下車。")
    static let openAppWhenRun = true
    @MainActor static var handler: (() -> Void)?

    @MainActor
    func perform() async throws -> some IntentResult {
        Self.handler?()
        return .result()
    }
}

/// 問台北公車 in Control Center and on the Lock Screen: one tap opens the conversation.
@available(iOS 18.0, *)
struct VoiceChatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.rio10255254.TaipeiBus.voice-chat") {
            ControlWidgetButton(action: AskTaipeiBusIntent()) {
                Label(AppText.text("問台北公車", language: AppLanguage.deviceDefault(Locale.preferredLanguages)), systemImage: "waveform")
            }
        }
        .displayName("問台北公車")
        .description("打開語音對話，查到站、規劃路線。")
    }
}
