import Foundation
import AVFoundation
import MapKit
import UIKit
import TransitCore

/// Speaks the assistant's answers with the best Taiwanese Mandarin voice on the phone. The written
/// caption stays as it is; only the voice hears route numbers digit by digit.
@MainActor
final class SpeechOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var speaking = false
    private let synthesizer = AVSpeechSynthesizer()
    /// Sentences handed to the synthesizer and not yet spoken.
    private var queued: [AVSpeechUtterance] = []
    /// Sentences cut off by `stop()`, kept until they report back late so that report cannot end the
    /// next answer early.
    private var stopped: [AVSpeechUtterance] = []
    /// With VoiceOver on, the whole answer is announced at the end in the rider's own voice settings.
    private var announcement = ""
    private var done: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// An enhanced or premium voice when the rider has downloaded one, otherwise the standard one.
    static func voice(language: AppLanguage) -> AVSpeechSynthesisVoice? {
        let code = language == .english ? "en-US" : "zh-TW"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == code }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: code)
    }

    /// Returns when the sentence has been spoken or `stop()` cut it short.
    func speak(_ text: String, routes: [String] = [], language: AppLanguage = .current) async {
        stop()
        enqueue(text, routes: routes, language: language)
        await finishSpeaking()
    }

    /// Speaks a sentence after the ones already queued, without waiting: the first sentence of an
    /// answer starts while the rest is still on its way.
    func enqueue(_ text: String, routes: [String] = [], language: AppLanguage = .current) {
        guard !text.isEmpty else { return }
        // VoiceOver reads it in the rider's own voice settings instead of a second voice over it.
        if UIAccessibility.isVoiceOverRunning { announcement += text; return }
        if queued.isEmpty {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? session.setActive(true)
        }
        let utterance = AVSpeechUtterance(string: SpokenAnswer.speakable(text, routes: routes))
        utterance.voice = Self.voice(language: language)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.06)
        queued.append(utterance)
        speaking = true
        synthesizer.speak(utterance)
    }

    /// Returns once everything queued has been spoken or `stop()` cut it short.
    func finishSpeaking() async {
        if !announcement.isEmpty {
            let text = announcement
            announcement = ""
            // Until VoiceOver says it has finished, so listening does not start over it; a long
            // pause covers an announcement that never reports back.
            let finished = NotificationCenter.default.notifications(named: UIAccessibility.announcementDidFinishNotification)
            UIAccessibility.post(notification: .announcement, argument: text)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in finished { return } }
                group.addTask { try? await Task.sleep(for: .seconds(min(30, 2 + Double(text.count) * 0.35))) }
                await group.next()
                group.cancelAll()
            }
            return
        }
        guard !queued.isEmpty else { return }
        await withCheckedContinuation { continuation in
            // Only one wait at a time: an earlier one is let go rather than left hanging.
            done?.resume()
            done = continuation
        }
    }

    func stop() {
        stopped = Array((stopped + queued).suffix(8))
        queued = []
        announcement = ""
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish()
    }

    private func finish() {
        done?.resume(); done = nil
        speaking = false
    }

    private func spoken(_ utterance: ObjectIdentifier) {
        if let index = stopped.firstIndex(where: { ObjectIdentifier($0) == utterance }) { stopped.remove(at: index); return }
        guard let index = queued.firstIndex(where: { ObjectIdentifier($0) == utterance }) else { return }
        queued.remove(at: index)
        if queued.isEmpty { finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.spoken(id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.spoken(id) }
    }
}

/// The voice conversation (Pro): listen, think, speak, and listen again, until the rider is done or
/// stays quiet. The server reads what was said; the app supplies every number and runs the actions.
@MainActor
final class VoiceConversation: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking, speaking }
    /// What the home screen should open for the result.
    enum PanelRequest: Equatable { case routes, navigation, place(MKMapItem) }

    @Published private(set) var active = false
    @Published private(set) var phase = Phase.idle
    /// The rider's words as they are heard.
    @Published private(set) var heard = ""
    /// What the assistant said last, as written.
    @Published private(set) var caption = ""
    /// The page an answer from the web came from, shown in small print under it.
    @Published private(set) var source: String?
    @Published private(set) var choices: [String] = []
    /// Something was put on screen for the rider: while listening, the panel keeps to one row so it
    /// covers as little of it as it can.
    @Published private(set) var compact = false
    /// Asked and waiting for a yes: shown as a button as well.
    @Published private(set) var pending: VoiceAction?
    /// Turns left today, once the server has said.
    @Published private(set) var remaining: Int?
    /// Heard and spoken in this language: the app's own until the rider switches it in the panel, so a
    /// visitor can talk English to the Chinese app. Claude answers in the language it hears.
    @Published private(set) var language = VoiceConversation.savedLanguage
    @Published var askingConsent = false
    @Published var panelRequest: PanelRequest?

    let speech = SpeechInput()
    let output = SpeechOutput()
    private unowned let model: TransitAppModel
    private var history = VoiceHistory()
    private var work: Task<Void, Never>?
    /// A trip was handed to the planner this turn: once the answer is spoken, what it found is followed up.
    private var planning = false
    /// The planner's places or options offered as choices, in the order shown.
    private var planPlaces: [TravelPlace] = []
    private var planOptions: [String] = []

    init(model: TransitAppModel) { self.model = model }

    static let consentKey = "voiceConversationConsent.v1"
    /// The voice consent the server's data use matches.
    static let consentVersion = 1
    /// nil until asked; false keeps the microphone on the one-sentence planner.
    static var consent: Bool? { UserDefaults.standard.object(forKey: consentKey) as? Bool }
    static var available: Bool { AssistantServer.configured }
    static let languageKey = "voiceConversationLanguage.v1"
    private static var savedLanguage: AppLanguage {
        UserDefaults.standard.string(forKey: languageKey).flatMap(AppLanguage.init(rawValue:))
            ?? (AppLanguage.current == .english ? .english : .traditionalChinese)
    }
    /// Stop and place names put back into what was heard: 忠孝敦華 becomes 忠孝敦化. Built in the
    /// background when a conversation starts and used once ready; Chinese only.
    private var names: NameCorrection?

    /// The microphone opens the conversation for Pro riders who have not turned it down; everyone else
    /// keeps the one-sentence planner.
    var handlesMicrophone: Bool { Self.available && model.purchases.hasPro && Self.consent != false }

    private static let goodbyes = ["謝謝", "沒事了", "沒有了", "不用了", "掰掰", "再見", "好了"]
    /// 「結束」 alone ends the conversation; 「結束導航」 is a request about the trip.
    private static let endings: Set<String> = ["結束", "結束吧", "結束對話", "結束了"]
    private static let englishGoodbyes = ["thanks", "thank you", "bye", "that's all", "that is all", "never mind", "nothing else"]

    private func isGoodbye(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.count <= 20, Self.englishGoodbyes.contains(where: lowered.contains) { return true }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if Self.endings.contains(plain) { return true }
        return text.count <= 6 && Self.goodbyes.contains(where: text.contains)
    }

    // MARK: Starting and ending

    func start() {
        guard Self.available else { return }
        guard model.purchases.hasPro else { model.showingProPlans = true; return }
        active = true; history = VoiceHistory(); pending = nil; choices = []; caption = ""; heard = ""
        names = nil; language = Self.savedLanguage; compact = false; planning = false; planPlaces = []; planOptions = []
        // Built for Chinese even when listening in English, so switching languages needs no wait.
        let nearby = VoiceStateBuilder(model: model).hints(language: .traditionalChinese)
        let others = model.metadata.stations.values.map(\.name) + VoiceVocabulary.landmarks.map(\.chinese)
        Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { NameCorrection(nearby: nearby, others: others) }.value
            self?.names = built
        }
        if Self.consent == true { listen(firstTurn: true) } else { askingConsent = true }
    }

    func answerConsent(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: Self.consentKey)
        askingConsent = false
        if allowed { listen(firstTurn: true) } else { end() }
    }

    func end() {
        work?.cancel(); work = nil
        speech.stop(); output.stop()
        active = false; phase = .idle; pending = nil; choices = []; askingConsent = false
    }

    /// Tapped while it speaks: stop talking and listen right away.
    func interrupt() {
        guard active else { return }
        work?.cancel(); work = nil
        output.stop()
        listen(firstTurn: false)
    }

    func choose(_ choice: String) {
        guard active else { return }
        speech.stop(); output.stop()
        handle(choice)
    }

    /// The panel's language button: listen in the other language from now on, starting right away.
    func switchLanguage() {
        guard active else { return }
        language = language == .english ? .traditionalChinese : .english
        UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
        JourneyDiagnostics.shared.record("voice language \(language.rawValue)")
        work?.cancel(); work = nil
        speech.stop(); output.stop()
        listen(firstTurn: false)
    }

    /// The confirmation button: the same as saying yes or no.
    func confirm(_ yes: Bool) {
        guard active else { return }
        speech.stop(); output.stop()
        handle(yes ? (language == .english ? "yes" : "好") : (language == .english ? "no" : "不要"))
    }

    // MARK: The loop

    private func listen(firstTurn: Bool) {
        guard active else { return }
        phase = .listening; heard = ""
        Haptics.listening()
        speech.pauseAfterWords = 0.9
        // A follow-up waits a little less than the first question.
        speech.waitForWords = firstTurn ? 7 : 5
        let hints = VoiceStateBuilder(model: model).hints(language: language)
        Task {
            await speech.start(language: language, hints: hints, modern: true, unheard: { [weak self] in
                guard let self else { return }
                // Silence after an answer simply ends the conversation; a microphone or recognition
                // problem is said first, so the panel does not just vanish.
                guard self.speech.failed, let problem = self.speech.problem else { return self.end() }
                self.work = Task { await self.say(problem); self.end() }
            }, finished: { [weak self] text in
                guard let self else { return }
                let corrected = self.language == .traditionalChinese ? self.names?.correct(text) ?? text : text
                if corrected != text { JourneyDiagnostics.shared.record("voice heard \(text) as \(corrected)") }
                self.handle(corrected)
            })
        }
    }

    private func handle(_ text: String) {
        guard active else { return }
        // A tapped choice can arrive while the last answer is still being spoken; that answer's wait
        // must not go on to open the microphone over this one.
        work?.cancel(); work = nil
        heard = text
        if let index = VoiceChoice.pick(text, among: choices), !planPlaces.isEmpty || !planOptions.isEmpty {
            return choosePlan(index)
        }
        planPlaces = []; planOptions = []
        if let pending {
            switch VoiceConfirmation.read(text) {
            case .yes:
                self.pending = nil
                run(pending)
                respond(acknowledgement(pending), followUp: false)
                return
            case .no:
                self.pending = nil
                respond(phrase("好，先不要。"), followUp: true)
                return
            case .unclear: break
            }
        }
        if isGoodbye(text) {
            work = Task { await say(phrase("好，有需要再叫我。")); end() }
            return
        }
        work = Task { await turn(text, lookups: 1) }
    }

    private func turn(_ text: String, lookups: Int) async {
        phase = .thinking; choices = []; source = nil
        // Names and figures in the language the rider speaks, so the voice can say them.
        let context = AppLanguage.$override.withValue(language) { VoiceStateBuilder(model: model).context(pending: pending) }
        let body: [String: Any] = ["utterance": text, "state": context.prompt(), "history": history.json,
                                   "consent": Self.consentVersion, "stream": true]
        var answer = SpokenTurn(context: context, heard: text)
        func speak(_ sentence: String) { speakPart(sentence, routes: context.names) }
        do {
            let (lines, response) = try await AssistantServer.stream("converse", body: body, timeout: 9)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: break
            case 403:
                model.showingProPlans = true
                return respond(phrase("語音對話是 Pro 功能，可以在方案頁開啟。"), followUp: false)
            case 429: return respond(phrase("今天的語音對話次數用完了，明天再聊，或改用打字搜尋。"), followUp: false)
            default: return respond(phrase("我現在連不上，請稍後再試一次。"), followUp: false)
            }
            var final: [String: Any]?
            for try await line in lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:"),
                      let event = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any] else { continue }
                // The first sentence is spoken while the rest of the answer is still being written.
                if let words = event["say"] as? String { answer.receive(words).forEach(speak) }
                if event["said"] as? Bool == true { answer.finishWords().forEach(speak) }
                if event["reply"] != nil || event["error"] != nil { final = event; break }
            }
            try Task.checkCancellation()
            guard let final, let json = final["reply"] as? [String: Any], let reply = VoiceReply(json: json) else {
                // Cut off after some of the answer was spoken: let the rider go on from there.
                if !answer.spoken.isEmpty { return respond(nil, followUp: true) }
                return respond(phrase("我現在連不上，請稍後再試一次。"), followUp: true)
            }
            AssistantServer.answered(by: final["model"] as? String, response: response)
            if let used = final["used"] as? Int, let limit = final["limit"] as? Int { remaining = max(0, limit - used) }
            // The state had no answer: look it up while 「我查一下」 is spoken, then ask once more.
            if lookups > 0, let lookup = reply.actions.first(where: Self.isLookup),
               await self.lookup(lookup) {
                return await turn(text, lookups: lookups - 1)
            }
            compact = reply.actions.contains { !Self.isLookup($0) }
            for action in reply.actions { run(action) }
            pending = reply.confirm
            choices = reply.choices
            // An answer from the web: its times may be checked against what its sources said.
            let quoted = (final["quoted"] as? [String]) ?? []
            source = ((final["sources"] as? [[String: Any]])?.first?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            answer.finish(choices: reply.choices, quoted: quoted).forEach(speak)
            var said = answer.spoken.joined()
            if let failure = answer.refused { JourneyDiagnostics.shared.record("voice left out \(failure)") }
            // A sentence with a live figure the app cannot vouch for was left out; only when nothing at
            // all could be said is the rider told so.
            if let failure = answer.refused, answer.spoken.isEmpty {
                let fallback: String
                if case .unknownSlot = failure { fallback = phrase("這個我現在查不到，可以換個方式問嗎？") }
                else { fallback = phrase("結果在畫面上，請看一下。") }
                speak(fallback)
                said += fallback
            }
            history.append(user: text, said: said)
            respond(nil, followUp: true)
        } catch {
            guard !Task.isCancelled else { return }
            if !answer.spoken.isEmpty { return respond(nil, followUp: true) }
            respond(phrase("連線不穩，請再說一次。"), followUp: true)
        }
    }

    /// One sentence of the answer, after any already queued; the caption grows with it.
    private func speakPart(_ sentence: String, routes: [String]) {
        guard !Task.isCancelled, active else { return }
        caption = phase == .speaking ? caption + sentence : sentence
        phase = .speaking
        output.enqueue(sentence, routes: routes, language: language)
    }

    private static func isLookup(_ action: VoiceAction) -> Bool {
        if case .lookup = action { return true }
        return false
    }

    /// Speak, then keep listening so the rider can simply go on talking. Without a sentence, it waits
    /// for what is already being spoken.
    private func respond(_ sentence: String?, followUp: Bool, routes: [String] = []) {
        work?.cancel()
        work = Task {
            if let sentence { await say(sentence, routes: routes) } else { await output.finishSpeaking() }
            guard !Task.isCancelled, active else { return }
            if planning { planning = false; await followPlan() }
            guard !Task.isCancelled, active else { return }
            if followUp || pending != nil || !choices.isEmpty { listen(firstTurn: false) } else { end() }
        }
    }

    private func say(_ sentence: String, routes: [String] = []) async {
        caption = sentence; phase = .speaking
        await output.speak(sentence, routes: routes, language: language)
    }

    private func acknowledgement(_ action: VoiceAction) -> String {
        switch action {
        case .startNavigation: model.planner.started ? phrase("好，開始導航。") : phrase("目前沒有可以開始的路線。")
        case .boarded: phrase("好，已上車，我會提醒你下車。")
        case .alighted: phrase("好，已下車。")
        case .endTrip: phrase("好，行程結束。")
        default: phrase("好。")
        }
    }

    /// A fixed sentence in the language the conversation is in, which may not be the app's.
    private func phrase(_ key: String, _ values: String...) -> String { AppText.format(key, values: values, language: language) }

    // MARK: Following the planner

    /// The planner finds the places after the answer was spoken. When it could not settle one, say so and
    /// offer what it found, to say or tap, instead of leaving 「我幫你規劃」 standing over 「找不到」.
    private func followPlan() async {
        let assistant = model.assistant
        var waited = 0
        while (assistant.busy || assistant.fixSearching), waited < 48 {
            try? await Task.sleep(for: .milliseconds(250)); waited += 1
        }
        guard !Task.isCancelled, active else { return }
        if let problem = assistant.problem, !problem.keyword.isEmpty {
            planPlaces = Array(assistant.fixResults.prefix(3))
            choices = planPlaces.map(\.localizedName)
            compact = false
            JourneyDiagnostics.shared.record("voice plan unsettled places=\(planPlaces.count)")
            await say(planPlaces.isEmpty ? phrase("找不到「%@」，請換個說法再說一次。", problem.keyword)
                      : phrase("「%@」要去哪一個？可以直接說或點選。", problem.keyword))
        } else if let clarification = assistant.clarification {
            planOptions = clarification.options
            choices = Array(planOptions.prefix(3))
            compact = false
            await say(clarification.question)
        } else if let message = assistant.message {
            compact = false
            await say(message)
        }
    }

    private func choosePlan(_ index: Int) {
        let places = planPlaces, options = planOptions
        planPlaces = []; planOptions = []; choices = []
        if places.indices.contains(index) {
            model.assistant.chooseFix(places[index])
        } else if options.indices.contains(index) {
            model.assistant.answer(index)
        } else { return }
        planning = true; compact = true
        panelRequest = .routes
        respond(phrase("好，改到%@。", places.indices.contains(index) ? places[index].localizedName : options[index]), followUp: true)
    }

    // MARK: Actions

    private func run(_ action: VoiceAction) {
        let planner = model.planner
        switch action {
        case .showStop(let name):
            Task {
                guard let station = await model.findStations(query: name, limit: 5).first else { return }
                model.selectStation(station)
            }
        case .showRoute(let name):
            guard let result = model.routes(query: name).first else { return }
            model.selectRoute(result.route, variantOnly: result.matchedVariant != nil)
        case .followVehicle(let route):
            if let vehicle = VoiceStateBuilder(model: model).approachingVehicle(route: route) {
                model.trackApproachingVehicle(vehicle)
            } else if let result = model.routes(query: route).first {
                model.selectRoute(result.route, variantOnly: result.matchedVariant != nil)
            }
        case .showBike(let near):
            if let station = VoiceStateBuilder(model: model).nearestBikeStation(near: near) { model.selectBikeStation(station.id) }
        case .showPlace(let name):
            Task {
                guard let place = await Self.place(named: name) else { return }
                panelRequest = .place(place)
            }
        case .planTrip(let destination, let origin, let time, let mode, let preference, let then):
            // The ordinary one-sentence planner takes it from here: places, times, later stops and questions.
            var sentence = time
            if !origin.isEmpty { sentence += "從\(origin)" }
            sentence += (mode == "cycling" ? "騎單車" : mode == "walking" ? "走路" : "") + "去\(destination)"
            if !then.isEmpty { sentence += "，再去\(then)" }
            sentence += ["faster": "，快一點", "lessWalking": "，少走路", "fewerTransfers": "，少轉乘"][preference] ?? ""
            model.assistant.run(sentence)
            planning = true
            panelRequest = .routes
        case .chooseOption(let index):
            guard planner.options.indices.contains(index - 1), !planner.started else { return }
            planner.select(planner.options[index - 1])
            panelRequest = .routes
        case .startNavigation:
            guard planner.selected != nil, !planner.started else { return }
            planner.begin()
            guard planner.started else { return }
            if case .walk(let index) = planner.currentStep { model.showWalkOnMap(index) }
            panelRequest = .navigation
        case .boarded:
            guard planner.started, case .ride = planner.currentStep, model.boardedVehicle == nil else { return }
            model.boardCurrentRide()
        case .alighted:
            guard planner.started, case .ride = planner.currentStep else { return }
            model.alight()
        case .endTrip:
            guard planner.started else { return }
            model.finishJourney()
        case .lookup:
            break
        }
    }

    /// The Apple Maps place for a name said in Taipei, for its card.
    private static func place(named name: String) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25.05, longitude: 121.55),
                                            span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6))
        return try? await MKLocalSearch(request: request).start().mapItems.first
    }

    /// Puts what the rider asked about on screen so the next state includes it. False when nothing matched.
    private func lookup(_ action: VoiceAction) async -> Bool {
        guard case .lookup(let stop, let route) = action else { return false }
        if !stop.isEmpty, let station = await model.findStations(query: stop, limit: 5).first {
            model.selectStation(station)
            return true
        }
        if !route.isEmpty, let station = VoiceStateBuilder(model: model).nearestStation(serving: route) {
            model.selectStation(station)
            return true
        }
        return false
    }
}

/// The app's state in words for the server, the values behind each `{r1}`, and the names the rider can see.
@MainActor
struct VoiceStateBuilder {
    let model: TransitAppModel

    /// Names the recogniser should expect, in the language it listens in: what is on screen and nearby
    /// first, then the rider's own stops and places, then the city's best-known places.
    func hints(language: AppLanguage) -> [String] {
        let english = language == .english
        func name(_ chinese: String, _ englishName: String?) -> String { english ? englishName.flatMap { $0.isEmpty ? nil : $0 } ?? chinese : chinese }
        func place(_ place: TravelPlace) -> String { name(place.name, place.englishName) }
        var screen = nearbyStations.map { name($0.name, $0.englishName) }
        if let shown = model.mapLabelStation { screen.append(name(shown.name, shown.englishName)) }
        if let shown = model.selectedRoute { screen.append(name(shown.name, shown.englishName)) }
        if let ride = model.planner.activeRide {
            screen += [name(ride.route.name, ride.route.englishName), name(ride.boarding.name, ride.boarding.englishName),
                       name(ride.alighting.name, ride.alighting.englishName)]
        }
        if let destination = model.planner.destination { screen.append(place(destination)) }
        var own = model.favorites.compactMap { model.metadata.stations[$0] }.map { name($0.name, $0.englishName) }
        for journey in model.commutes.journeys { own += [journey.title, place(journey.destination)] + (journey.origin.map { [place($0)] } ?? []) }
        own += model.planner.recentPlaces.map(place)
        let city = VoiceVocabulary.landmarks.map { english ? $0.english : $0.chinese }
        return VoiceVocabulary.hints([screen, own, city, VoiceVocabulary.appWords(english: english)])
    }

    func context(pending: VoiceAction?) -> VoiceContext {
        let now = Date(), planner = model.planner
        var facts: [String] = [], items: [(meaning: String, value: String)] = [], names: [String] = []
        let screen: String

        if planner.started, let step = planner.currentStep {
            if let destination = planner.destination { facts.append("目的地：\(destination.localizedName)"); names.append(destination.localizedName) }
            facts += tripFacts(now: now).filter { !$0.hasPrefix("出發") }
            switch step {
            case .walk(let index):
                let next = planner.activeRide.map { "，走到 \($0.boarding.localizedName) 上車" } ?? "，走到目的地"
                screen = "導航中：步行\(next)"
                if let status = planner.walkingStatus(at: index) { items.append(("步行進度", status)) }
                if let ride = planner.activeRide { names += [ride.route.localizedName, ride.boarding.localizedName] }
            case .ride:
                guard let ride = planner.activeRide else { screen = "導航中"; break }
                let route = ride.route.localizedName, destination = ride.route.localizedDestination(direction: ride.direction)
                names += [route, ride.boarding.localizedName, ride.alighting.localizedName]
                facts += ["上車站：\(ride.boarding.localizedName)", "下車站：\(ride.alighting.localizedName)"]
                if model.boardedVehicle != nil {
                    screen = "導航中：在 \(route) 往 \(destination) 的車上"
                    items.append(("預計抵達下車站 \(ride.alighting.localizedName)", model.onboardStopTimeLabel(ride, stopID: ride.alighting.id, at: now)))
                } else {
                    screen = "導航中：在 \(ride.boarding.localizedName) 等 \(route) 往 \(destination)"
                    items.append(("\(route) 到 \(ride.boarding.localizedName) 的下一班", model.boardingInformation(ride, at: now).label))
                }
            }
        } else if let destination = planner.destination {
            screen = "路線方案：到 \(destination.localizedName)"
            names.append(destination.localizedName)
            facts += tripFacts(now: now)
            for (index, option) in planner.options.prefix(3).enumerated() {
                let label = option.walkingOnly ? "全程步行" : option.bikeOnly ? "全程 YouBike" : option.rides.map(\.route.localizedName).joined(separator: "→")
                names += option.rides.map(\.route.localizedName)
                facts.append("第 \(index + 1) 個方案：\(label)")
                if let timing = model.journeyDuration(option, at: now) {
                    items.append(("第 \(index + 1) 個方案的全程時間", timing.comparisonLabel))
                    // One time with its day, as it is said, rather than the screen's range.
                    let arrival = timing.unknownWaits > 0 ? timing.arrivalClockLabel
                        : VoiceClock.label(timing.referenceDate.addingTimeInterval(timing.totalSeconds), now: now)
                    items.append(("第 \(index + 1) 個方案的抵達時間", arrival))
                }
            }
        } else if let station = model.mapLabelStation {
            screen = "站牌：\(station.localizedName)"
        } else if let route = model.selectedRoute {
            screen = "路線：\(route.localizedName)"
            names.append(route.localizedName)
        } else if let bike = model.selectedBikeStation {
            screen = "YouBike 站：\(bike.localizedName)"
        } else {
            screen = "地圖"
        }

        // Arrivals at the station on screen: the same times its card shows, during a trip too, for a
        // station the rider looked up.
        if let station = model.mapLabelStation {
            names.append(station.localizedName)
            for row in StationArrival.rows(station: station, metadata: model.metadata, snapshot: model.snapshot, now: now).prefix(6) {
                guard let route = row.route else { continue }
                let label = route.mode == .bus ? EstimateFeed.label(row.estimateSeconds)
                    : model.metroStationWaitLabel(serviceID: row.stop.serviceID, direction: row.stop.direction, stationID: row.stop.stationID, at: now)
                names.append(route.localizedName)
                items.append(("\(route.localizedName) 往 \(route.localizedDestination(direction: row.stop.direction)) 在 \(station.localizedName) 的到站", label))
            }
        }
        if let bike = model.selectedBikeStation, let dock = model.bikeDock(bike.id) {
            names.append(bike.localizedName)
            items.append(("\(bike.localizedName) 可借車輛", "\(dock.rentable) 輛"))
            items.append(("\(bike.localizedName) 可還空位", "\(dock.returnable) 格"))
        }
        let nearby = nearbyStations.map(\.localizedName)
        if !nearby.isEmpty { facts.append("附近站牌：" + nearby.joined(separator: "、")); names += nearby }
        return VoiceContext(now: now, screen: screen, facts: facts, references: VoiceContext.numbered(items),
                            pending: pending, names: Array(Set(names)))
    }

    /// The trip the rider asked for, so a later turn keeps its time and stops: where from, when, and
    /// which stops come after this leg of 「先去 A 再去 B」.
    private func tripFacts(now: Date) -> [String] {
        let planner = model.planner
        var facts = ["出發地：\(planner.origin?.localizedName ?? "目前位置")"]
        if let deadline = planner.arrivalDeadline {
            facts.append("時間：\(VoiceClock.label(deadline, now: now)) 前抵達")
        } else if let departure = planner.scheduledDeparture {
            facts.append("時間：\(VoiceClock.label(departure, now: now)) 出發")
        } else {
            facts.append("時間：現在出發")
        }
        if let trip = model.assistantTrip, trip.stops.count > 1 {
            facts.append("行程：\(trip.stops.map(\.name).joined(separator: " → "))，現在是第 \(trip.leg + 1) 段")
            let later = trip.stops.dropFirst(trip.leg + 1).map(\.name)
            if !later.isEmpty { facts.append("之後要去：" + later.joined(separator: "、")) }
        }
        return facts
    }

    private var nearbyStations: [Station] {
        guard let position = model.location.usableCoordinate, position.isInServiceArea else { return [] }
        return model.metadata.stations.values.filter { $0.coordinate.distance(to: position) <= 600 }
            .sorted { $0.coordinate.distance(to: position) < $1.coordinate.distance(to: position) }.prefix(3).map { $0 }
    }

    /// The closest station with a stop of this route: the one on screen first, then near the rider.
    func nearestStation(serving route: String) -> Station? {
        guard let match = model.routes(query: route).first else { return nil }
        let serves: (Station) -> Bool = { station in
            station.stopIDs.contains { model.metadata.stops[$0]?.routeID == match.route.parentID || model.metadata.stops[$0]?.routeID == match.route.id }
        }
        if let station = model.mapLabelStation, serves(station) { return station }
        guard let position = model.location.usableCoordinate else { return nil }
        return model.metadata.stations.values.filter { $0.coordinate.distance(to: position) <= 1_200 && serves($0) }
            .min { $0.coordinate.distance(to: position) < $1.coordinate.distance(to: position) }
    }

    /// The first bus of this route coming to the station on screen.
    func approachingVehicle(route: String) -> BusVehicle? {
        guard let station = model.mapLabelStation else { return nil }
        return StationArrival.rows(station: station, metadata: model.metadata, snapshot: model.snapshot, now: Date())
            .first { $0.route?.localizedName == route || $0.route?.name == route }?.approaches.first?.vehicle
    }

    /// A YouBike station with bikes near the station on screen, or near the rider.
    func nearestBikeStation(near: String) -> BikeStation? {
        let center = model.mapLabelStation?.coordinate ?? model.location.usableCoordinate
        guard let center else { return nil }
        return model.bikeNetwork.stations.filter { $0.coordinate.distance(to: center) <= 800 && (model.bikeDock($0.id)?.rentable ?? 1) > 0 }
            .min { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) }
    }
}
