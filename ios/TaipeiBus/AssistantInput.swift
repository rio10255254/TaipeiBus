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
    /// How loud the voice is right now, 0…1, for the listening animation.
    @Published private(set) var level: Double = 0
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var finished: ((String) -> Void)?
    /// Bumped by every start and stop, so a late callback from an earlier attempt is ignored.
    private var attempt = 0

    func start(language: AppLanguage = .current, finished: @escaping (String) -> Void) async {
        stop()
        transcript = ""; problem = nil; preparing = true
        let current = attempt
        JourneyDiagnostics.shared.record("speech tap speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic=\(AVAudioApplication.shared.recordPermission.rawValue)")
        let allowed = await Self.permissions()
        guard current == attempt else { return }
        guard allowed else {
            preparing = false
            JourneyDiagnostics.shared.record("speech denied")
            problem = AppText.text("需要麥克風與語音辨識權限才能用說的，請到系統設定開啟；也可以直接打字。")
            return
        }
        let locale = language == .english ? Locale(identifier: "en-US") : Locale(identifier: "zh-TW")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            preparing = false
            JourneyDiagnostics.shared.record("speech unavailable")
            problem = AppText.text("語音辨識目前無法使用，請直接打字。")
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
                Task { @MainActor in if self?.listening == true { self?.level = value } }
            })
            engine.prepare()
            try engine.start()
        } catch {
            JourneyDiagnostics.shared.record("speech audio-error \((error as NSError).domain) \((error as NSError).code)")
            problem = AppText.text("麥克風目前無法使用，請直接打字。")
            stop(); return
        }
        self.request = request
        preparing = false; listening = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        JourneyDiagnostics.shared.record("speech start on-device=\(onDevice)")
        let current = attempt
        // Recognition results arrive on a background queue; they are handed to the main actor here.
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, final, code in
            Task { @MainActor in self?.receive(text: text, final: final, code: code, attempt: current, recognizer: recognizer, onDevice: onDevice) }
        })
        // Nothing said at all: stop instead of listening forever, and say so.
        waitForSilence(6)
    }
    private func receive(text: String?, final: Bool, code: String?, attempt current: Int, recognizer: SFSpeechRecognizer, onDevice: Bool) {
        guard current == attempt, listening else { return }
        if let text, !text.isEmpty { transcript = text; waitForSilence(1.2) }
        if let code, transcript.isEmpty {
            JourneyDiagnostics.shared.record("speech error \(code) on-device=\(onDevice)")
            let finished = self.finished
            stop()
            if onDevice, let finished {
                self.finished = finished
                begin(recognizer, onDevice: false)
            } else {
                problem = AppText.text("沒有辨識到內容，請再說一次，或直接打字。")
            }
            return
        }
        if final || code != nil { finish() }
    }
    private enum SpeechFailure: Error { case noMicrophone }

    func finish() {
        guard listening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = finished
        stop()
        JourneyDiagnostics.shared.record("speech done heard=\(!text.isEmpty)")
        if text.isEmpty { problem = AppText.text("沒有聽到聲音，請再說一次，或直接打字。") }
        else { done?(text) }
    }

    func stop() {
        attempt += 1
        silence?.cancel(); silence = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel()
        request = nil; task = nil; listening = false; preparing = false; finished = nil; level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func waitForSilence(_ seconds: Double) {
        silence?.cancel()
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
    }
}
