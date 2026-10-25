import Foundation
import AVFoundation
import UIKit
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
    /// Tapped, waiting for permission or the microphone: shown at once so the tap is never silent.
    @Published private(set) var preparing = false
    @Published private(set) var problem: String?
    /// The microphone or recogniser could not be used at all, as opposed to nothing being said.
    private(set) var failed = false
    /// How loud the voice is right now, 0…1, for the listening animation.
    /// Kept in its own object so only the glow and orb redraw at the microphone's pace.
    let meter = VoiceLevel()
    /// Microphone or speech recognition was turned off: only Settings can turn it back on.
    @Published private(set) var blocked = false
    /// After words were heard, listening ends by itself once this much silence has passed.
    @Published private(set) var silenceSince: Date?
    @Published private(set) var silenceLength: Double = 1.3

    enum Permission { case undetermined, granted, denied }
    /// Read without asking, so the app can explain before iOS shows its prompts.
    static var permission: Permission {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let microphone = AVAudioApplication.shared.recordPermission
        if speech == .denied || speech == .restricted || microphone == .denied { return .denied }
        if speech == .authorized && microphone == .granted { return .granted }
        return .undetermined
    }
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var finished: ((String) -> Void)?
    /// Called instead of `finished` when listening ends without words: silence, an error or no permission.
    private var unheard: (() -> Void)?
    /// How long a pause after words ends listening. A conversation answers sooner than a request.
    var pauseAfterWords = 1.3
    /// How long to wait for the first word before giving up.
    var waitForWords = 6.0
    /// Stop, route and place names the recogniser should expect.
    private var hints: [String] = []
    /// Bumped by every start and stop, so a late callback from an earlier attempt is ignored.
    private var attempt = 0

    func start(language: AppLanguage = .current, hints: [String] = [], unheard: (() -> Void)? = nil,
               finished: @escaping (String) -> Void) async {
        stop()
        self.hints = Array(hints.prefix(100)); self.unheard = unheard
        transcript = ""; problem = nil; blocked = false; failed = false; preparing = true
        let current = attempt
        JourneyDiagnostics.shared.record("speech tap speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic=\(AVAudioApplication.shared.recordPermission.rawValue)")
        let allowed = await Self.permissions()
        guard current == attempt else { return }
        guard allowed else {
            preparing = false
            JourneyDiagnostics.shared.record("speech denied")
            blocked = true; failed = true
            problem = AppText.text("需要麥克風與語音辨識權限才能用說的，請到系統設定開啟；也可以直接打字。")
            takeUnheard()?()
            return
        }
        let locale = language == .english ? Locale(identifier: "en-US") : Locale(identifier: "zh-TW")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            preparing = false
            JourneyDiagnostics.shared.record("speech unavailable")
            problem = AppText.text("語音辨識目前無法使用，請直接打字。"); failed = true
            takeUnheard()?()
            return
        }
        self.finished = finished
        begin(recognizer, onDevice: recognizer.supportsOnDeviceRecognition)
    }

    /// On the phone when it can; if the phone's recogniser fails before hearing anything (its
    /// language may not be downloaded), once more with Apple's recognition service.
    private func begin(_ recognizer: SFSpeechRecognizer, onDevice: Bool) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.contextualStrings = hints
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechFailure.noMicrophone }
            input.removeTap(onBus: 0)
            // The audio thread calls this; it must not belong to the main actor.
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request) { [weak self] value in
                Task { @MainActor in if self?.listening == true { self?.meter.value = value } }
            })
            engine.prepare()
            try engine.start()
        } catch {
            JourneyDiagnostics.shared.record("speech audio-error \((error as NSError).domain) \((error as NSError).code)")
            problem = AppText.text("麥克風目前無法使用，請直接打字。"); failed = true
            let unheard = takeUnheard()
            stop(); unheard?(); return
        }
        self.request = request
        preparing = false; listening = true
        Haptics.listening()
        JourneyDiagnostics.shared.record("speech start on-device=\(onDevice)")
        let current = attempt
        // Recognition results arrive on a background queue; they are handed to the main actor here.
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, final, code in
            Task { @MainActor in self?.receive(text: text, final: final, code: code, attempt: current, recognizer: recognizer, onDevice: onDevice) }
        })
        // Nothing said at all: stop instead of listening forever, and say so.
        waitForSilence(waitForWords)
    }
    private func receive(text: String?, final: Bool, code: String?, attempt current: Int, recognizer: SFSpeechRecognizer, onDevice: Bool) {
        guard current == attempt, listening else { return }
        if let text, !text.isEmpty { transcript = text; waitForSilence(pauseAfterWords, counting: true) }
        if let code, transcript.isEmpty {
            JourneyDiagnostics.shared.record("speech error \(code) on-device=\(onDevice)")
            let finished = self.finished, unheard = self.unheard
            stop()
            if onDevice, let finished {
                self.finished = finished; self.unheard = unheard
                begin(recognizer, onDevice: false)
            } else {
                problem = AppText.text("沒有辨識到內容，請再說一次，或直接打字。")
                unheard?()
            }
            return
        }
        if final || code != nil { finish() }
    }
    private enum SpeechFailure: Error { case noMicrophone }

    func finish() {
        guard listening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = finished, unheard = self.unheard
        stop()
        JourneyDiagnostics.shared.record("speech done heard=\(!text.isEmpty)")
        if text.isEmpty { problem = AppText.text("沒有聽到聲音，請再說一次，或直接打字。"); unheard?() }
        else { done?(text) }
    }

    /// A new attempt starts clean, so an old problem never flashes on the voice screen.
    func reset() { stop(); transcript = ""; problem = nil; blocked = false }

    func stop() {
        attempt += 1
        silence?.cancel(); silence = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        request = nil; task = nil; listening = false; preparing = false; finished = nil; unheard = nil; meter.value = 0; silenceSince = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func takeUnheard() -> (() -> Void)? {
        defer { unheard = nil }
        return unheard
    }

    /// `counting` shows the countdown: words were heard and the pause is being timed.
    private func waitForSilence(_ seconds: Double, counting: Bool = false) {
        silence?.cancel()
        silenceSince = counting ? Date() : nil; silenceLength = seconds
        silence = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.finish()
        }
    }

    // These run off the main actor: iOS calls permission, audio and recognition callbacks on its own
    // queues, and a closure that belongs to the main actor stops the app or never returns there.
    nonisolated private static func permissions() async -> Bool {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard speech == .authorized else { return false }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }
    /// Feeds the recogniser and, about fifteen times a second, reports how loud the voice is.
    nonisolated private static func tap(_ request: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        let meter = LevelMeter()
        return { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0, meter.due() else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            // Speech sits around -50…-10 dB; map that to 0…1.
            let decibels = 20 * log10(max(rms, 0.000_01))
            level(Double(min(1, max(0, (decibels + 50) / 40))))
        }
    }
    nonisolated private static func results(_ deliver: @escaping @Sendable (String?, Bool, String?) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false,
                    (error as NSError?).map { "\($0.domain) \($0.code)" })
        }
    }
}

/// How loud the voice is, 0…1, about fifteen times a second while listening.
final class VoiceLevel: ObservableObject {
    @Published var value: Double = 0
    /// For orbs that do not listen, such as the one on the search screen.
    static let silent = VoiceLevel()
}

/// Limits level reports from the audio thread to about fifteen a second.
private final class LevelMeter: @unchecked Sendable {
    private var last: TimeInterval = 0
    private let lock = NSLock()
    func due() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= 0.066 else { return false }
        last = now; return true
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
        AppShortcut(intent: AskTaipeiBusIntent(), phrases: [
            "問\(.applicationName)",
            "用\(.applicationName)問問題",
            "打開\(.applicationName)語音對話",
        ], shortTitle: "問台北公車", systemImageName: "waveform")
    }
}
