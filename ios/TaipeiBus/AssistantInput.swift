import Foundation
import AVFoundation
import Speech
import AppIntents
import TransitCore

/// Whether text typed in the ordinary search box is a trip request rather than a place name.
/// 「台大」 searches as before; 「騎單車去台大」 or 「明天九點前到北車」 is understood and planned.
enum AssistantSentence {
    private static let markers = ["去", "到", "回家", "回公司", "從", "騎", "走路", "步行", "點前", "點以前",
                                  "快一點", "幫我", "帶我", "怎麼", "我要", "想要", "出發"]
    static func looksLikeRequest(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, value.count <= 600 else { return false }
        return markers.contains { value.contains($0) }
    }
}

/// The last sentences that led to a plan, offered as one-tap chips. Kept only on this phone.
@MainActor
final class AssistantRecents: ObservableObject {
    static let shared = AssistantRecents()
    private let key = "assistantRecentRequests.v1"
    private let defaults: UserDefaults
    @Published private(set) var items: [String]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = Array((defaults.stringArray(forKey: "assistantRecentRequests.v1") ?? []).prefix(6))
    }
    func remember(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80 else { return }
        items = Array(([value] + items.filter { $0 != value }).prefix(6))
        defaults.set(items, forKey: key)
    }
    func remove(_ text: String) { items.removeAll { $0 == text }; defaults.set(items, forKey: key) }
    func clear() { items = []; defaults.removeObject(forKey: key) }
}

/// Speech to text for one request, on the phone when the recogniser supports it. Listening stops
/// by itself after a short silence, so the rider only taps once.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var listening = false
    @Published private(set) var problem: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var finished: ((String) -> Void)?

    func start(language: AppLanguage = .current, finished: @escaping (String) -> Void) async {
        stop()
        transcript = ""; problem = nil; self.finished = finished
        guard await Self.authorized() else {
            problem = AppText.text("需要麥克風與語音辨識權限才能用說的，請到系統設定開啟；也可以直接打字。")
            return
        }
        let locale = language == .english ? Locale(identifier: "en-US") : Locale(identifier: "zh-TW")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            problem = AppText.text("語音辨識目前無法使用，請直接打字。")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            problem = AppText.text("語音辨識目前無法使用，請直接打字。")
            stop(); return
        }
        self.request = request
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.listening else { return }
                if let text, !text.isEmpty { self.transcript = text; self.waitForSilence(1.2) }
                if final || error != nil { self.finish() }
            }
        }
        // Nothing said at all: stop instead of listening forever.
        waitForSilence(5)
    }

    func finish() {
        guard listening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = finished
        stop()
        if !text.isEmpty { done?(text) }
    }

    func stop() {
        silence?.cancel(); silence = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        request = nil; task = nil; listening = false; finished = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func waitForSilence(_ seconds: Double) {
        silence?.cancel()
        silence = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.finish()
        }
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// A request handed over by Siri, picked up by the home screen when the app opens.
@MainActor
enum AssistantLaunch {
    static let notification = Notification.Name("TaipeiBusAssistantLaunch")
    private(set) static var pending: String?
    static func request(_ text: String) {
        pending = text
        NotificationCenter.default.post(name: notification, object: nil)
    }
    static func take() -> String? { defer { pending = nil }; return pending }
}

struct PlanTripIntent: AppIntent {
    static let title: LocalizedStringResource = "規劃行程"
    static let description = IntentDescription("說出要去哪裡，台北公車會在手機上理解並開始規劃路線。")
    static let openAppWhenRun = true
    @Parameter(title: "行程", requestValueDialog: IntentDialog("要去哪裡？"))
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AssistantLaunch.request(request)
        return .result()
    }
}

struct TaipeiBusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlanTripIntent(), phrases: [
            "用\(.applicationName)規劃行程",
            "用\(.applicationName)規劃路線",
            "\(.applicationName)帶我去",
        ], shortTitle: "規劃行程", systemImageName: "sparkles")
    }
}
