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
            // The microphone and voice stop when the app leaves the screen; the next tap starts a new
            // conversation. Inactive is not enough: iOS's permission prompts and Control Center pass through it.
            .onChange(of: scenePhase) { _, phase in if phase == .background, chat.active { chat.end() } }
            .alert(AppText.text("開啟語音對話？"), isPresented: Binding(
                get: { chat.askingConsent },
                set: { if !$0, chat.askingConsent { chat.answerConsent(false) } })) {
                Button(AppText.text("開始對話")) { chat.answerConsent(true) }
                Button(AppText.text("不要"), role: .cancel) { chat.answerConsent(false) }
            } message: {
                Text(AppText.text("你說的話、現在畫面上的行程與附近站名（不含位置座標）會經由本 App 的伺服器傳給 Anthropic 的 Claude 理解並回答；需要最新資訊時，Claude 會用網路搜尋（每天最多 3 次）。Claude 暫時無法使用時，改由 Groq 上的開源模型處理。回答由 iPhone 念出，伺服器不保存對話。Pro 每天可以問 40 次，之後可在資訊與設定關閉。"))
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
        hiding?.cancel(); hiding = nil
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
    private var hiding: Task<Void, Never>?
    /// After the panel's own exit animation, unless the conversation came back meanwhile.
    func hide(after delay: Double = 0.28) {
        hiding?.cancel()
        hiding = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.window?.isHidden = true
            self.window = nil
        }
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
            // The rider's voice while listening, the answer's words while speaking.
            EdgeGlow(mood: mood, level: chat.phase == .speaking ? chat.output.level : chat.speech.meter, reduceMotion: reduceMotion)
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
        .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)) { shown = true } }
        // Ending slides the panel away before the window goes.
        .onChange(of: chat.active) { _, active in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { shown = active }
        }
    }
}

/// The glass panel: what was heard, what is said, and the choices or question that wait for an answer.
struct VoiceChatPanel: View {
    @ObservedObject var chat: VoiceConversation
    @ObservedObject var speech: SpeechInput
    @State private var askingReport = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Every change of the panel springs into place, unless motion is reduced.
    private var motion: Animation? { InterfaceMotion.reduced(systemReduceMotion) ? nil : .spring(response: 0.36, dampingFraction: 0.86) }

    private var status: (symbol: String, text: String) {
        switch chat.phase {
        // 「請說」 only once the microphone hears, so the first word is not lost.
        case .listening: speech.listening ? ("waveform", AppText.text("請說")) : ("ellipsis", AppText.text("準備聽…"))
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
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)
                Text(status.text).font(.subheadline.weight(.semibold))
                    .contentTransition(.opacity)
                Spacer(minLength: 4)
                if let remaining = chat.remaining, remaining <= 10 {
                    ModelCredit(text: AppText.text("今天還能問 %@ 次", "\(remaining)"))
                } else if let model = AssistantServer.answeredBy, chat.phase == .speaking {
                    ModelCredit(text: model)
                }
                // A wrong answer can be sent to the developer, once the rider agrees.
                if chat.reportable {
                    Button { if !chat.reported { askingReport = true } } label: {
                        Image(systemName: chat.reported ? "checkmark.bubble" : "exclamationmark.bubble")
                            .font(.footnote.weight(.bold)).frame(width: 32, height: 32)
                            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(chat.reported ? AppText.text("已回報") : AppText.text("回報這次回答"))
                    .accessibilityIdentifier("voice-chat-report")
                }
                // The language it listens in: a visitor can talk English to the Chinese app, and back.
                Button { chat.switchLanguage() } label: {
                    Text(verbatim: chat.language == .english ? "EN" : "中").font(.footnote.weight(.bold))
                        .frame(minWidth: 32, minHeight: 32).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chat.language == .english ? AppText.text("改用中文聽") : AppText.text("改用英文聽"))
                .accessibilityIdentifier("voice-chat-language")
                Button { chat.end() } label: {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).frame(width: 32, height: 32)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(AppText.text("結束對話")).accessibilityIdentifier("voice-chat-close")
            }
            let words = chat.phase == .listening ? speech.transcript : chat.heard
            if !words.isEmpty {
                Text(words).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    .contentTransition(.interpolate)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityLabel(AppText.text("你說的：%@", words))
            }
            // Listening after something was put on screen: one row, so the screen stays readable.
            let folded = chat.compact && chat.phase == .listening
            if !chat.caption.isEmpty, !folded {
                // Sentences arrive one after another; each grows in rather than jumping.
                Text(chat.caption).font(.body).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityIdentifier("voice-chat-caption")
            }
            if let source = chat.source, !folded {
                Label(AppText.text("來源：%@", source), systemImage: "globe").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .transition(.opacity)
            }
            if !chat.choices.isEmpty {
                ChipFlow(spacing: 8) {
                    // One after another, a beat apart.
                    ForEach(Array(chat.choices.enumerated()), id: \.element) { index, choice in
                        ChoiceChip(title: choice, delay: Double(index) * 0.05, motion: motion) { chat.choose(choice) }
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
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
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(motion, value: chat.phase)
        .animation(motion, value: chat.caption)
        .animation(motion, value: chat.choices)
        .animation(motion, value: chat.compact)
        .animation(motion, value: chat.pending != nil)
        .animation(motion, value: chat.reportable)
        .animation(motion, value: speech.transcript.isEmpty)
        // A light tap when the answer starts and when listening starts again.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: chat.phase) { _, new in new == .speaking }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        // While it speaks, a tap stops it and listens: the way to cut in without waiting.
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture { if chat.phase == .speaking { chat.interrupt() } }
        .alert(AppText.text("回報這次回答？"), isPresented: $askingReport) {
            Button(AppText.text("回報")) { chat.reportLastAnswer() }
            Button(AppText.text("取消"), role: .cancel) {}
        } message: {
            Text(AppText.text("你說的話、這次的回答與當時的畫面摘要會傳給開發者，保存 30 天，只用來改進語音對話。"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-chat")
    }
}

/// One choice under an answer: it springs in a beat after the one before it, and presses down when tapped.
private struct ChoiceChip: View {
    let title: String
    let delay: Double
    let motion: Animation?
    let action: () -> Void
    @State private var shown = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
            .scaleEffect(shown ? 1 : 0.85).opacity(shown ? 1 : 0)
            .onAppear { withAnimation(motion?.delay(delay)) { shown = true } }
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
    @AppStorage(SpeechInput.modernKey) private var modern = true
    @AppStorage(NavigationVoice.key) private var prompts = true
    @AppStorage(VoiceConversation.bargeInKey) private var bargeIn = true
    /// Only the compact voice is on the phone: answers and prompts sound flat until a better one is downloaded.
    private var basicVoice: Bool {
        guard let voice = SpeechOutput.voice(language: AppLanguage.current == .english ? .english : .traditionalChinese) else { return true }
        return voice.quality == .default
    }
    var body: some View {
        Section {
            Toggle(AppText.text("語音對話"), isOn: $enabled).accessibilityIdentifier("voice-chat-toggle")
            if enabled {
                Toggle(AppText.text("回答時可以直接插話"), isOn: $bargeIn).accessibilityIdentifier("voice-chat-barge-in")
            }
            // Said on the phone only; nothing leaves it.
            Toggle(AppText.text("導航時語音提示"), isOn: $prompts).accessibilityIdentifier("navigation-voice-toggle")
            // iOS 26's recogniser, on by default; off returns to the usual one, to compare.
            if enabled {
                if #available(iOS 26.0, *) {
                    Toggle(AppText.text("新版語音辨識"), isOn: $modern).accessibilityIdentifier("voice-chat-modern-recognition")
                }
            }
        } header: {
            SectionHeader(title: AppText.text("語音對話（Pro）"), symbol: "bubble.left.and.text.bubble.right.fill", color: Brand.accent)
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if basicVoice {
                    Label(AppText.text("目前只有基本語音，念起來比較生硬。到 iPhone 的「設定 > 輔助使用 > 朗讀內容 > 聲音」，在中文（台灣）下載「高品質」或「進階」語音，回答和導航提示會自然很多。"), systemImage: "waveform.badge.plus")
                }
                Text(AppText.text("開啟後，按麥克風就能和「一路」來回對話：問到站、規劃路線、導航時說「我上車了」，也能問票價、景點等一般問題。你說的話、畫面上的行程與附近站名會經由本 App 的伺服器傳給 Anthropic 的 Claude（備援為 Groq 上的開源模型），需要最新資訊時 Claude 會上網搜尋，每天最多 3 次；伺服器不保存對話。關閉時，麥克風改回用一句話規劃。"))
            }
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

extension AskTaipeiBusIntent {
    /// Runs the intent in the app; the widget extension, which shares the intent, never sets it.
    @MainActor static func connect() { handler = { VoiceChatLaunch.request() } }
}
