import SwiftUI
import AppIntents
import MapKit
import TransitCore

/// The voice conversation over the map: a glow at the screen edge and one glass panel with the
/// words heard, the answer as it is spoken, and any question to answer by tapping instead. Both live
/// in a window above the app, so they stay in view when the route panel or navigation opens under them.
struct VoiceChatHost: ViewModifier {
    @ObservedObject var chat: VoiceConversation
    @Environment(\.scenePhase) private var scenePhase
    /// A place whose Apple Maps card the rider asked for.
    @State private var place: MKMapItem?
    /// The route panel, for planned routes.
    let openRoutes: () -> Void
    /// The navigation screen, once a trip has started.
    let showNavigation: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: chat.active && !chat.askingConsent) { _, visible in
                if visible { VoiceChatOverlay.shared.show(chat) } else { VoiceChatOverlay.shared.hide() }
            }
            // The microphone and voice stop with the app; the next tap starts a new conversation.
            .onChange(of: scenePhase) { _, phase in if phase != .active, chat.active { chat.end() } }
            .alert(AppText.text("開啟語音對話？"), isPresented: Binding(
                get: { chat.askingConsent },
                set: { if !$0, chat.askingConsent { chat.answerConsent(false) } })) {
                Button(AppText.text("開始對話")) { chat.answerConsent(true) }
                Button(AppText.text("不要"), role: .cancel) { chat.answerConsent(false) }
            } message: {
                Text(AppText.text("你說的話、現在畫面上的行程與附近站名（不含位置座標）會經由台北公車的伺服器傳給 Anthropic 的 Claude 理解並回答；需要最新資訊時，Claude 會用網路搜尋（每天最多 3 次）。Claude 暫時無法使用時，改由 Groq 上的開源模型處理。回答由 iPhone 念出，伺服器不保存對話。Pro 每天可以問 40 次，之後可在資訊與設定關閉。"))
            }
            .onChange(of: chat.panelRequest) { _, request in
                guard let request else { return }
                chat.panelRequest = nil
                switch request {
                case .routes: openRoutes()
                case .navigation: showNavigation()
                case .place(let item): place = item
                }
            }
            .modifier(PlaceCard(item: $place))
    }
}

/// Apple Maps' own card for a place: opening hours, phone and website, from Apple. Before iOS 18 the
/// place opens in Apple Maps instead.
private struct PlaceCard: ViewModifier {
    @Binding var item: MKMapItem?
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.mapItemDetailSheet(item: $item)
        } else {
            content.onChange(of: item) { _, place in
                guard let place else { return }
                place.openInMaps()
                item = nil
            }
        }
    }
}

private final class VoiceChatWindow: UIWindow {
    var touchableArea: CGRect = .zero
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { touchableArea.contains(point) }
}

/// The window above the app for the conversation; only the panel takes touches, so the map, sheets
/// and buttons underneath keep working while it talks.
@MainActor
final class VoiceChatOverlay {
    static let shared = VoiceChatOverlay()
    private var window: VoiceChatWindow?
    func show(_ chat: VoiceConversation) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = VoiceChatWindow(windowScene: scene)
        // Above the app and its sheets, below the app's own alerts.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: VoiceChatLayer(chat: chat) { [weak window] area in
            window?.touchableArea = area
        })
        host.view.backgroundColor = .clear
        window.rootViewController = host
        // Shown without becoming the key window, so the app keeps its focus and status bar.
        window.isHidden = false
        self.window = window
    }
    func hide() {
        window?.isHidden = true
        window = nil
    }
}

private struct VoiceChatLayer: View {
    @ObservedObject var chat: VoiceConversation
    let reportPanel: (CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var shown = false

    private var mood: VoiceOrb.Mood {
        switch chat.phase {
        case .listening: .listening
        case .thinking: .thinking
        case .speaking, .idle: .calm
        }
    }

    var body: some View {
        let reduceMotion = InterfaceMotion.reduced(systemReduceMotion)
        ZStack(alignment: .bottom) {
            EdgeGlow(mood: mood, level: chat.speech.meter, reduceMotion: reduceMotion)
                .opacity(shown ? 1 : 0)
            VoiceChatPanel(chat: chat, speech: chat.speech)
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { reportPanel(proxy.frame(in: .global)) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in reportPanel(frame) }
                })
                .padding(.horizontal, 12).padding(.bottom, 6)
                .offset(y: shown || reduceMotion ? 0 : 200)
                .opacity(shown ? 1 : 0)
        }
        .onAppear { withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { shown = true } }
    }
}

/// The glass panel: what was heard, what is said, and the choices or question that wait for an answer.
struct VoiceChatPanel: View {
    @ObservedObject var chat: VoiceConversation
    @ObservedObject var speech: SpeechInput

    private var status: (symbol: String, text: String) {
        switch chat.phase {
        case .listening: ("waveform", AppText.text("請說"))
        case .thinking: ("ellipsis", AppText.text("想一下…"))
        case .speaking: ("speaker.wave.2.fill", AppText.text("回答中"))
        case .idle: ("mic", "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: status.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: chat.phase == .listening || chat.phase == .thinking)
                    .frame(width: 22)
                Text(status.text).font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if let remaining = chat.remaining, remaining <= 10 {
                    ModelCredit(text: AppText.text("今天還能問 %@ 次", "\(remaining)"))
                } else if let model = AssistantServer.answeredBy, chat.phase == .speaking {
                    ModelCredit(text: model)
                }
                Button { chat.end() } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 32, height: 32)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(AppText.text("結束對話")).accessibilityIdentifier("voice-chat-close")
            }
            let words = chat.phase == .listening ? speech.transcript : chat.heard
            if !words.isEmpty {
                Text(words).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityLabel(AppText.text("你說的：%@", words))
            }
            if !chat.caption.isEmpty {
                Text(chat.caption).font(.body).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("voice-chat-caption")
            }
            if let source = chat.source {
                Label(AppText.text("來源：%@", source), systemImage: "globe").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if !chat.choices.isEmpty {
                ChipFlow(spacing: 8) {
                    ForEach(chat.choices, id: \.self) { choice in
                        Button(choice) { chat.choose(choice) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    }
                }
            }
            if let pending = chat.pending {
                HStack(spacing: 8) {
                    Button { chat.confirm(true) } label: {
                        Text(pending.question).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 36)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).accessibilityIdentifier("voice-chat-confirm")
                    Button { chat.confirm(false) } label: {
                        Text(AppText.text("先不要")).font(.subheadline).frame(minHeight: 36).padding(.horizontal, 6)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        // While it speaks, a tap stops it and listens: the way to cut in without waiting.
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture { if chat.phase == .speaking { chat.interrupt() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-chat")
    }
}

/// 問一下 while navigating, where the home microphone is hidden.
struct VoiceChatButton: View {
    @ObservedObject var chat: VoiceConversation
    var body: some View {
        if chat.handlesMicrophone, !chat.active {
            HStack {
                Spacer()
                Button { Haptics.stage(); chat.start() } label: {
                    Label(AppText.text("問一下"), systemImage: "mic.fill").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).frame(minHeight: 40)
                }
                .buttonStyle(PhonePressStyle()).phoneGlass(in: Capsule())
                .accessibilityIdentifier("voice-chat-navigation")
            }
        }
    }
}

/// 語音對話 (Pro) in Settings: on means the rider agreed to the conversation's use of data.
struct VoiceChatSettings: View {
    @AppStorage(VoiceConversation.consentKey) private var enabled = false
    var body: some View {
        Section {
            Toggle(AppText.text("語音對話"), isOn: $enabled).accessibilityIdentifier("voice-chat-toggle")
        } header: {
            Text(AppText.text("語音對話（Pro）"))
        } footer: {
            Text(AppText.text("開啟後，按麥克風就能和台北公車來回對話：問到站、規劃路線、導航時說「我上車了」，也能問票價、景點等一般問題。你說的話、畫面上的行程與附近站名會經由台北公車的伺服器傳給 Anthropic 的 Claude（備援為 Groq 上的開源模型），需要最新資訊時 Claude 會上網搜尋，每天最多 3 次；伺服器不保存對話。關閉時，麥克風改回用一句話規劃。"))
        }
    }
}

/// A conversation started from Siri, picked up by the home screen when the app opens.
@MainActor
enum VoiceChatLaunch {
    static let notification = Notification.Name("TaipeiBusVoiceChatLaunch")
    private(set) static var pending = false
    static func request() {
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }
    static func take() -> Bool { defer { pending = false }; return pending }
}

struct AskTaipeiBusIntent: AppIntent {
    static let title: LocalizedStringResource = "問台北公車"
    static let description = IntentDescription("打開台北公車的語音對話（Pro）：查到站、規劃路線、導航時上下車。")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceChatLaunch.request()
        return .result()
    }
}
