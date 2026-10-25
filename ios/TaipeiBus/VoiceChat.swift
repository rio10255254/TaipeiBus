import Foundation
import AVFoundation
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
            UIAccessibility.post(notification: .announcement, argument: text)
            try? await Task.sleep(for: .seconds(min(8, 0.6 + Double(text.count) * 0.2)))
            return
        }
        guard !queued.isEmpty else { return }
        await withCheckedContinuation { continuation in done = continuation }
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
    enum PanelRequest: Equatable { case routes, navigation }

    @Published private(set) var active = false
    @Published private(set) var phase = Phase.idle
    /// The rider's words as they are heard.
    @Published private(set) var heard = ""
    /// What the assistant said last, as written.
    @Published private(set) var caption = ""
    @Published private(set) var choices: [String] = []
    /// Asked and waiting for a yes: shown as a button as well.
    @Published private(set) var pending: VoiceAction?
    /// Turns left today, once the server has said.
    @Published private(set) var remaining: Int?
    @Published var askingConsent = false
    @Published var panelRequest: PanelRequest?

    let speech = SpeechInput()
    let output = SpeechOutput()
    private unowned let model: TransitAppModel
    private var history = VoiceHistory()
    private var work: Task<Void, Never>?

    init(model: TransitAppModel) { self.model = model }

    static let consentKey = "voiceConversationConsent.v1"
    /// The voice consent the server's data use matches.
    static let consentVersion = 1
    /// nil until asked; false keeps the microphone on the one-sentence planner.
    static var consent: Bool? { UserDefaults.standard.object(forKey: consentKey) as? Bool }
    /// The server reads Taiwanese Mandarin; the conversation is offered in Chinese only for now.
    static var available: Bool { AssistantServer.configured && AppLanguage.current != .english }

    /// The microphone opens the conversation for Pro riders who have not turned it down; everyone else
    /// keeps the one-sentence planner.
    var handlesMicrophone: Bool { Self.available && model.purchases.hasPro && Self.consent != false }

    private static let goodbyes = ["謝謝", "沒事了", "沒有了", "不用了", "結束", "掰掰", "再見", "好了"]

    // MARK: Starting and ending

    func start() {
        guard Self.available else { return }
        guard model.purchases.hasPro else { model.showingProPlans = true; return }
        active = true; history = VoiceHistory(); pending = nil; choices = []; caption = ""; heard = ""
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

    /// The confirmation button: the same as saying yes or no.
    func confirm(_ yes: Bool) {
        guard active else { return }
        speech.stop(); output.stop()
        handle(yes ? "好" : "不要")
    }

    // MARK: The loop

    private func listen(firstTurn: Bool) {
        guard active else { return }
        phase = .listening; heard = ""
        Haptics.listening()
        speech.pauseAfterWords = 0.9
        // A follow-up waits a little less than the first question.
        speech.waitForWords = firstTurn ? 7 : 5
        let hints = VoiceStateBuilder(model: model).hints
        Task {
            await speech.start(language: .traditionalChinese, hints: hints, unheard: { [weak self] in
                // Silence after an answer simply ends the conversation.
                self?.end()
            }, finished: { [weak self] text in
                self?.handle(text)
            })
        }
    }

    private func handle(_ text: String) {
        guard active else { return }
        heard = text
        if let pending {
            switch VoiceConfirmation.read(text) {
            case .yes:
                self.pending = nil
                run(pending)
                respond(acknowledgement(pending), followUp: false)
                return
            case .no:
                self.pending = nil
                respond("好，先不要。", followUp: true)
                return
            case .unclear: break
            }
        }
        if text.count <= 6, Self.goodbyes.contains(where: text.contains) {
            work = Task { await say("好，有需要再叫我。"); end() }
            return
        }
        work = Task { await turn(text, lookups: 1) }
    }

    private func turn(_ text: String, lookups: Int) async {
        phase = .thinking; choices = []
        let context = VoiceStateBuilder(model: model).context(pending: pending)
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
                return respond("語音對話是 Pro 功能，可以在方案頁開啟。", followUp: false)
            case 429: return respond("今天的語音對話次數用完了，明天再聊，或改用打字搜尋。", followUp: false)
            default: return respond("我現在連不上，請稍後再試一次。", followUp: false)
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
                return respond("我現在連不上，請稍後再試一次。", followUp: true)
            }
            AssistantServer.answered(by: final["model"] as? String, response: response)
            if let used = final["used"] as? Int, let limit = final["limit"] as? Int { remaining = max(0, limit - used) }
            // The state had no answer: look it up while 「我查一下」 is spoken, then ask once more.
            if lookups > 0, let lookup = reply.actions.first(where: Self.isLookup),
               await self.lookup(lookup) {
                return await turn(text, lookups: lookups - 1)
            }
            for action in reply.actions { run(action) }
            pending = reply.confirm
            choices = reply.choices
            answer.finish(choices: reply.choices).forEach(speak)
            var said = answer.spoken.joined()
            if let failure = answer.refused {
                JourneyDiagnostics.shared.record("voice refused \(failure)")
                // A number the app cannot vouch for is never read out; a slot it never offered means
                // the model had nothing to go on.
                let fallback: String
                if case .unknownSlot = failure { fallback = "這個我現在查不到，可以換個方式問嗎？" }
                else { fallback = "結果在畫面上，請看一下。" }
                speak(fallback)
                said += fallback
            }
            history.append(user: text, said: said)
            respond(nil, followUp: true)
        } catch {
            guard !Task.isCancelled else { return }
            if !answer.spoken.isEmpty { return respond(nil, followUp: true) }
            respond("連線不穩，請再說一次。", followUp: true)
        }
    }

    /// One sentence of the answer, after any already queued; the caption grows with it.
    private func speakPart(_ sentence: String, routes: [String]) {
        guard !Task.isCancelled, active else { return }
        caption = phase == .speaking ? caption + sentence : sentence
        phase = .speaking
        output.enqueue(sentence, routes: routes, language: .traditionalChinese)
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
            if followUp || pending != nil || !choices.isEmpty { listen(firstTurn: false) } else { end() }
        }
    }

    private func say(_ sentence: String, routes: [String] = []) async {
        caption = sentence; phase = .speaking
        await output.speak(sentence, routes: routes, language: .traditionalChinese)
    }

    private func acknowledgement(_ action: VoiceAction) -> String {
        switch action {
        case .startNavigation: model.planner.started ? "好，開始導航。" : "目前沒有可以開始的路線。"
        case .boarded: "好，已上車，我會提醒你下車。"
        case .alighted: "好，已下車。"
        case .endTrip: "好，行程結束。"
        default: "好。"
        }
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
        case .planTrip(let destination, let origin, let time, let mode, let preference, let then):
            // The ordinary one-sentence planner takes it from here: places, times, later stops and questions.
            var sentence = time
            if !origin.isEmpty { sentence += "從\(origin)" }
            sentence += (mode == "cycling" ? "騎單車" : mode == "walking" ? "走路" : "") + "去\(destination)"
            if !then.isEmpty { sentence += "，再去\(then)" }
            sentence += ["faster": "，快一點", "lessWalking": "，少走路", "fewerTransfers": "，少轉乘"][preference] ?? ""
            model.assistant.run(sentence)
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

    /// Names the recogniser should expect: what is on screen and nearby.
    var hints: [String] {
        var names = nearbyStations.map(\.name)
        if let station = model.mapLabelStation { names.append(station.name) }
        if let route = model.selectedRoute { names.append(route.name) }
        if let ride = model.planner.activeRide { names += [ride.route.name, ride.boarding.name, ride.alighting.name] }
        return Array(Set(names))
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

        // Arrivals at the station on screen: the same times its card shows.
        if !planner.started, let station = model.mapLabelStation {
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
