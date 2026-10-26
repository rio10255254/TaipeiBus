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
    /// Ends listening with Apple's newer recogniser (iOS 26), when that is what listens.
    private var stopAnalyzer: (() -> Void)?
    /// The language of the attempt, for what it says about a problem.
    private var spokenLanguage = AppLanguage.current
    /// The voice conversation: speaking and listening share one audio session from start to end, so no
    /// time goes into switching between turns and the rider can talk over an answer.
    var duplex = false
    /// Listening while an answer is spoken: words are passed to `onWords` but end nothing until
    /// `release(dropping:)` says the rider is talking.
    private(set) var held = false
    private var onWords: ((String) -> Void)?
    /// The assistant's own words heard before the rider cut in, left out of what was said.
    private var echo = ""
    /// When a voice was last heard above the room's own sound, and that sound's level: a pause is timed
    /// from the voice, not from the last new word, since words can arrive later than they are said.
    private var lastVoice = Date.distantPast
    private var noiseFloor = 0.2
    /// When the first words were heard; listening ends after a long monologue all the same.
    private var wordsSince: Date?
    /// The longest a turn listens once words came, even while new words keep arriving (a TV, a
    /// conversation nearby): listening must always end.
    private static let longestTalk = 20.0
    /// Listening has ended and the recogniser is giving its final reading of what it heard.
    private var finishing = false
    private var settle: Task<Void, Never>?
    /// Asks SpeechAnalyzer for its final reading once the audio has ended.
    private var finalize: (() -> Void)?
    /// Bumped by every start and stop, so a late callback from an earlier attempt is ignored.
    private var attempt = 0

    /// `modern` listens with Apple's newer recogniser where the phone has it and its language is
    /// downloaded (iOS 26); otherwise, and if it fails before hearing anything, with the usual one.
    func start(language: AppLanguage = .current, hints: [String] = [], modern: Bool = false, hold: Bool = false,
               onWords: ((String) -> Void)? = nil, unheard: (() -> Void)? = nil, finished: @escaping (String) -> Void) async {
        stop()
        self.hints = Array(hints.prefix(VoiceVocabulary.limit)); self.unheard = unheard; spokenLanguage = language
        held = hold; self.onWords = onWords; echo = ""
        lastVoice = .distantPast; noiseFloor = 0.2; wordsSince = nil
        transcript = ""; problem = nil; blocked = false; failed = false; preparing = true
        let current = attempt
        JourneyDiagnostics.shared.record("speech tap speech=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic=\(AVAudioApplication.shared.recordPermission.rawValue)")
        let allowed = await Self.permissions()
        guard current == attempt else { return }
        guard allowed else {
            preparing = false
            JourneyDiagnostics.shared.record("speech denied")
            blocked = true; failed = true
            problem = AppText.text("需要麥克風與語音辨識權限才能用說的，請到系統設定開啟；也可以直接打字。", language: spokenLanguage)
            takeUnheard()?()
            return
        }
        let locale = language == .english ? Locale(identifier: "en-US") : Locale(identifier: "zh-TW")
        if modern, Self.modernEnabled {
            if #available(iOS 26.0, *), let transcriber = await ModernSpeech.transcriber(for: locale) {
                guard current == attempt else { return }
                self.finished = finished
                if await beginAnalyzer(transcriber, locale: locale, attempt: current) { return }
                guard current == attempt else { return }
            }
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            preparing = false
            JourneyDiagnostics.shared.record("speech unavailable")
            problem = AppText.text("語音辨識目前無法使用，請直接打字。", language: spokenLanguage); failed = true
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
        // 「嗎？」 at the end lets listening stop sooner.
        request.addsPunctuation = true
        do {
            try activateSession()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechFailure.noMicrophone }
            input.removeTap(onBus: 0)
            // The audio thread calls this; it must not belong to the main actor.
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request) { [weak self] value in
                Task { @MainActor in self?.heard(level: value) }
            })
            engine.prepare()
            try engine.start()
        } catch {
            JourneyDiagnostics.shared.record("speech audio-error \((error as NSError).domain) \((error as NSError).code)")
            problem = AppText.text("麥克風目前無法使用，請直接打字。", language: spokenLanguage); failed = true
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
        if !held { waitForSilence(waitForWords) }
    }
    private func receive(text: String?, final: Bool, code: String?, attempt current: Int, recognizer: SFSpeechRecognizer, onDevice: Bool) {
        guard current == attempt, listening else { return }
        if finishing {
            if let text, !text.isEmpty { transcript = text }
            if final || code != nil { deliver() }
            return
        }
        if held {
            // Only the answer's own sound so far: an ended recognition just stops listening quietly.
            if let text, !text.isEmpty { transcript = text; onWords?(text) }
            if final || code != nil { stop() }
            return
        }
        if let text, !text.isEmpty { transcript = text; wordsSince = wordsSince ?? Date(); waitForSilence(pause(after: text), counting: true) }
        if let code, transcript.isEmpty {
            JourneyDiagnostics.shared.record("speech error \(code) on-device=\(onDevice)")
            let finished = self.finished, unheard = self.unheard
            stop()
            if onDevice, let finished {
                self.finished = finished; self.unheard = unheard
                begin(recognizer, onDevice: false)
            } else {
                problem = AppText.text("沒有辨識到內容，請再說一次，或直接打字。", language: spokenLanguage)
                unheard?()
            }
            return
        }
        // The recogniser decided the sentence is over: its reading is final already.
        if final || code != nil { finishing = true; deliver() }
    }
    private enum SpeechFailure: Error { case noMicrophone }

    static let modernKey = "speechModernRecognition.v1"
    /// On unless the rider turned it off in Settings to compare.
    static var modernEnabled: Bool { UserDefaults.standard.object(forKey: modernKey) as? Bool ?? true }

    /// Listens with SpeechAnalyzer. False when it could not start, so the usual recogniser takes over.
    @available(iOS 26.0, *)
    private func beginAnalyzer(_ transcriber: SpeechTranscriber, locale: Locale, attempt current: Int) async -> Bool {
        guard let format = await ModernSpeech.format(for: transcriber, locale: locale) else { return false }
        guard current == attempt else { return true }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (sequence, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        do {
            try activateSession()
            let node = engine.inputNode
            let microphone = node.outputFormat(forBus: 0)
            guard microphone.sampleRate > 0, microphone.channelCount > 0,
                  let converter = AVAudioConverter(from: microphone, to: format) else { throw SpeechFailure.noMicrophone }
            converter.primeMethod = .none
            // The microphone first: what is said while the analyzer starts waits in the stream, so the
            // first word is not lost.
            node.removeTap(onBus: 0)
            node.installTap(onBus: 0, bufferSize: 1024, format: microphone, block: Self.analyzerTap(converter, to: format, into: input) { [weak self] value in
                Task { @MainActor in self?.heard(level: value) }
            })
            engine.prepare()
            try engine.start()
            preparing = false; listening = true
            Haptics.listening()
            try await analyzer.start(inputSequence: sequence)
            guard current == attempt else { input.finish(); await analyzer.cancelAndFinishNow(); return true }
        } catch {
            JourneyDiagnostics.shared.record("speech analyzer-error \((error as NSError).domain) \((error as NSError).code)")
            input.finish()
            Task { await analyzer.cancelAndFinishNow() }
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            listening = false; preparing = true
            return false
        }
        let english = locale.language.languageCode == .english
        let results = Task { [weak self] in
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    var text = String(result.text.characters)
                    if english, !finalized.isEmpty, !finalized.hasSuffix(" "), !text.hasPrefix(" ") { text = " " + text }
                    if result.isFinal { finalized += text }
                    self?.receiveAnalyzed(result.isFinal ? finalized : finalized + text, attempt: current)
                }
                self?.analyzerEnded(attempt: current)
            } catch {
                self?.analyzerFailed(error, locale: locale, attempt: current)
            }
        }
        stopAnalyzer = {
            input.finish(); results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        finalize = {
            input.finish()
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        JourneyDiagnostics.shared.record("speech start analyzer \(locale.identifier)")
        if !held { waitForSilence(waitForWords) }
        return true
    }

    private func receiveAnalyzed(_ text: String, attempt current: Int) {
        guard current == attempt, listening else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        transcript = text
        if finishing { return }
        if held { onWords?(text); return }
        wordsSince = wordsSince ?? Date()
        waitForSilence(pause(after: text), counting: true)
    }

    /// The rider is talking: from now on a pause ends listening as usual. `echo`, the answer's own words
    /// heard so far, is left out of what was said.
    func release(dropping echo: String = "") {
        guard held, listening else { return }
        held = false; self.echo = echo
        if transcript.isEmpty { waitForSilence(waitForWords) } else { wordsSince = Date(); waitForSilence(pause(after: transcript), counting: true) }
    }

    /// Words that lead on (「我想去圓山的…」) wait longer for the rest of the sentence.
    private static let leadOn = ["的", "去", "到", "在", "和", "跟", "從", "往", "要", "想", "有", "還有", "然後", "那個", "就是", "嗯", "呃"]
    private static let englishLeadOn: Set<String> = ["the", "to", "and", "from", "a", "of", "in", "at", "um", "uh"]
    private func pause(after text: String) -> Double {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        let lastWord = words.split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
        let leadsOn = Self.leadOn.contains(where: { words.hasSuffix($0) }) || Self.englishLeadOn.contains(lastWord)
        return leadsOn ? pauseAfterWords + 0.6 : pauseAfterWords
    }

    /// The microphone's level: shown on screen, and above the room's own sound it counts as a voice.
    private func heard(level value: Double) {
        guard listening else { return }
        meter.value = value
        // The room's sound sinks the floor at once and lifts it slowly, so a voice stands out above it.
        noiseFloor = value < noiseFloor ? value : noiseFloor + (value - noiseFloor) * 0.02
        if value > noiseFloor + 0.18 { lastVoice = Date() }
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        if duplex {
            // A headset's own microphone is the one near the mouth: with earbuds in and the phone in a
            // pocket it hears far better, so Bluetooth headsets are allowed in for listening too.
            if session.category != .playAndRecord {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .duckOthers])
            }
        } else {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// The analyzer gave its final reading after the audio ended.
    private func analyzerEnded(attempt current: Int) {
        guard current == attempt, finishing else { return }
        deliver()
    }

    /// Failed before hearing anything: once more with the usual recogniser, as with the phone's own.
    private func analyzerFailed(_ error: Error, locale: Locale, attempt current: Int) {
        if current == attempt, finishing { return deliver() }
        guard current == attempt, listening, transcript.isEmpty else { return }
        JourneyDiagnostics.shared.record("speech analyzer-failed \((error as NSError).domain) \((error as NSError).code)")
        let finished = self.finished, unheard = self.unheard
        stop()
        guard let finished, let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            problem = AppText.text("語音辨識目前無法使用，請直接打字。", language: spokenLanguage); failed = true
            unheard?(); return
        }
        self.finished = finished; self.unheard = unheard
        begin(recognizer, onDevice: recognizer.supportsOnDeviceRecognition)
    }

    /// Listening ends: the microphone stops and the recogniser gets a moment for its final reading of
    /// what it heard, which is better than its last guess while listening; then the words go on.
    func finish() {
        guard listening, !held, !finishing else { return }
        finishing = true
        silence?.cancel(); silence = nil; silenceSince = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        meter.value = 0
        request?.endAudio()
        finalize?(); finalize = nil
        let current = attempt
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, current == self.attempt else { return }
            self.deliver()
        }
    }

    private func deliver() {
        guard listening, finishing else { return }
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !echo.isEmpty, text.hasPrefix(echo) { text = String(text.dropFirst(echo.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        let done = finished, unheard = self.unheard
        stop()
        JourneyDiagnostics.shared.record("speech done heard=\(!text.isEmpty)")
        if text.isEmpty { problem = AppText.text("沒有聽到聲音，請再說一次，或直接打字。", language: spokenLanguage); unheard?() }
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
        stopAnalyzer?(); stopAnalyzer = nil
        request = nil; task = nil; listening = false; preparing = false; finished = nil; unheard = nil; meter.value = 0; silenceSince = nil
        held = false; onWords = nil
        finishing = false; settle?.cancel(); settle = nil; finalize = nil
        // The conversation keeps its session between turns; it lets go when it ends.
        if !duplex { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private func takeUnheard() -> (() -> Void)? {
        defer { unheard = nil }
        return unheard
    }

    /// `counting` shows the countdown: words were heard and the pause is being timed.
    private func waitForSilence(_ seconds: Double, counting: Bool = false) {
        silence?.cancel()
        silenceSince = counting ? Date() : nil; silenceLength = seconds
        // New words restart the pause, but never past the longest talk.
        let talked = wordsSince.map { Date().timeIntervalSince($0) } ?? 0
        silence = Task { @MainActor [weak self] in
            var wait = counting ? max(0, min(seconds, Self.longestTalk - talked)) : seconds
            while true {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                guard let self else { return }
                // Still talking, though no new word came yet: the pause counts from the last sound of a voice,
                // up to the longest talk.
                let quiet = Date().timeIntervalSince(self.lastVoice)
                let left = Self.longestTalk - Date().timeIntervalSince(self.wordsSince ?? .distantPast)
                if counting, quiet < seconds, left > 0 { wait = min(seconds - quiet, left); continue }
                self.finish()
                return
            }
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
            if meter.due(), let value = loudness(buffer) { level(value) }
        }
    }
    /// The same for SpeechAnalyzer, which takes the microphone's audio only in its own format.
    @available(iOS 26.0, *)
    nonisolated private static func analyzerTap(_ converter: AVAudioConverter, to format: AVAudioFormat,
                                                into input: AsyncStream<AnalyzerInput>.Continuation,
                                                level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        let meter = LevelMeter()
        return { buffer, _ in
            let frames = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up))
            if frames > 0, let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData
                    return buffer
                }
                if status != .error, converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
            }
            if meter.due(), let value = loudness(buffer) { level(value) }
        }
    }
    /// 0…1 for how loud a buffer is: speech sits around -50…-10 dB.
    nonisolated private static func loudness(_ buffer: AVAudioPCMBuffer) -> Double? {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return Double(min(1, max(0, (decibels + 50) / 40)))
    }
    nonisolated private static func results(_ deliver: @escaping @Sendable (String?, Bool, String?) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false,
                    (error as NSError?).map { "\($0.domain) \($0.code)" })
        }
    }
}

/// Apple's newer recogniser (iOS 26): used once the phone has it and the language is downloaded. The
/// first time, the language downloads in the background while the usual recogniser listens.
@available(iOS 26.0, *)
@MainActor
enum ModernSpeech {
    private static var downloading: Set<String> = []
    /// Languages found installed, and their analyzer formats: asked once, so listening starts sooner.
    private static var installed: [String: Locale] = [:]
    private static var formats: [String: AVAudioFormat] = [:]

    static func transcriber(for locale: Locale) async -> SpeechTranscriber? {
        if let supported = installed[locale.identifier] { return SpeechTranscriber(locale: supported, preset: .progressiveTranscription) }
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed { installed[locale.identifier] = supported; return transcriber }
        if status == .supported, downloading.insert(supported.identifier).inserted {
            JourneyDiagnostics.shared.record("speech analyzer-download \(supported.identifier)")
            Task.detached(priority: .utility) {
                let module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
                do { try await AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall() } catch {
                    await MainActor.run { _ = ModernSpeech.downloading.remove(supported.identifier) }
                }
            }
        }
        return nil
    }

    static func format(for transcriber: SpeechTranscriber, locale: Locale) async -> AVAudioFormat? {
        if let format = formats[locale.identifier] { return format }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        formats[locale.identifier] = format
        return format
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
    static let description = IntentDescription("說出要去哪裡，「一路」會在手機上理解並開始規劃路線。")
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
        ], shortTitle: "問一路", systemImageName: "waveform")
    }
}
