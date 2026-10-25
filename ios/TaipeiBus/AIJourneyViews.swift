import SwiftUI
import TransitCore

/// 用一句話規劃, from sentence to route. It runs where the sentence was given (the search box, the
/// microphone, a recent request, Siri) and only opens a sheet for what it cannot settle by itself:
/// several saved journeys, a place that was not found, no current location, or a failure.
@MainActor
final class JourneyAssistantSession: ObservableObject {
    /// What stopped planning, and what the rider can do about it.
    enum Problem: Equatable {
        case destination(String), origin(String), unsavedDestination(String), unsavedOrigin(String), location
        var keyword: String {
            switch self {
            case .destination(let text), .origin(let text), .unsavedDestination(let text), .unsavedOrigin(let text): text
            case .location: ""
            }
        }
        var isOrigin: Bool {
            switch self { case .origin, .unsavedOrigin, .location: true; default: false }
        }
        var unsaved: Bool {
            switch self { case .unsavedDestination, .unsavedOrigin: true; default: false }
        }
    }

    @Published var input = ""
    /// The sheet: typing from scratch, or something only the rider can answer. It takes over
    /// from the voice screen when a question or problem needs it.
    @Published var presented = false
    /// The voice assistant screen: from the tap until the routes appear.
    @Published private(set) var voiceActive = false
    /// How the voice assistant looks this time, read from Settings when it opens.
    @Published private(set) var voiceStyle = VoiceStyle.current
    /// The voice screen is fading out; it closes a moment later.
    @Published private(set) var voiceClosing = false
    /// The short ✓ moment before the voice screen gives way to the routes.
    @Published private(set) var celebrating = false
    /// Microphone and speech recognition were never asked: the voice screen explains first.
    @Published private(set) var voicePermissionStep = false
    /// The route panel opens the sheet once it has appeared (the voice screen started on the map).
    var reopenSheetInPanel = false
    private var refiningVoice = false
    /// The sentence being understood or planned.
    @Published private(set) var source = ""
    @Published private(set) var clarification: AssistantClarification?
    @Published private(set) var problem: Problem?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var activity = AppText.text("正在理解你的需求…")
    @Published private(set) var startedAt = Date()
    @Published var fixQuery = ""
    @Published private(set) var fixResults: [TravelPlace] = []
    @Published private(set) var fixSearching = false
    @Published var saveFix = true
    /// The one-time question before the first sentence goes online.
    @Published var askingConsent = false
    private var waitingForConsent = ""
    /// Counts requests that reached the route screen, so the panel can step aside.
    @Published private(set) var plannedCount = 0
    let speech = SpeechInput()

    private unowned let model: TransitAppModel
    private let search = PlaceSearch()
    private var turn: AssistantJourneyTurn?
    private var conversation: (any JourneyAssistantConversation)?
    private var prepared: (context: JourneyAssistantContext, conversation: any JourneyAssistantConversation)?
    private var activeContext: JourneyAssistantContext?
    /// Places the rider picked after a problem, kept while another one is fixed.
    private var chosenDestination: TravelPlace?
    private var chosenOrigin: TravelPlace?
    private var operation: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    /// The on-device model can be slow, but the screen must never wait indefinitely.
    private static let timeLimit: Double = 45

    init(model: TransitAppModel) { self.model = model }

    var unavailable: String? { OnDeviceJourneyAssistant.plannerUnavailableReason() }
    var currentPlace: TravelPlace? {
        model.location.usableCoordinate.flatMap { point in
            point.isInServiceArea ? TravelPlace(name: AppText.text("目前位置"), address: "", coordinate: point) : nil
        }
    }
    private var preference: RoutePreference {
        turn.flatMap { RoutePreference(rawValue: $0.request.preference.rawValue) } ?? .balanced
    }

    // MARK: Entry points

    /// Typing from scratch, with examples and recent requests.
    func open() {
        cancel(); input = ""; prepare(); present()
    }
    /// One tap, then speak: understanding starts when the rider stops talking. On the route screen
    /// (`refining`), what is said changes the trip shown instead of starting a new one.
    /// `inline` listens inside the typing sheet without the full voice screen.
    func listen(refining: Bool = false, inline: Bool = false) {
        guard unavailable == nil else { present(); return }
        // The voice screen replaces the keyboard.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        cancel(); speech.reset(); prepare()
        refiningVoice = refining
        guard !inline else { startSpeech(); return }
        voiceRound += 1; voiceClosing = false; celebrating = false
        if !voiceActive { setVoice(true) }
        // Ask in our own words first; the system prompts follow the rider's tap.
        if SpeechInput.permission == .undetermined { voicePermissionStep = true; return }
        voicePermissionStep = false
        startSpeech()
    }
    /// 「允許並開始說話」 on the voice screen.
    func allowVoice() {
        voicePermissionStep = false
        Haptics.stage()
        startSpeech()
    }
    private func startSpeech() {
        let refining = refiningVoice
        Task { await speech.start { [weak self] text in if refining { self?.refine(text) } else { self?.run(text) } } }
    }

    /// 「改騎車」, 「晚一點」, 「不要搭公車」, 「改去101」 for the trip on screen. The online model reads the
    /// change with the trip described in words; the rules fill what it leaves out or read it alone.
    func refine(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 300 else { return }
        guard let trip = model.currentAssistantTrip else { run(value); return }
        if OnlineJourneyReader.needsConsent {
            speech.stop(); waitingForConsent = value; waitingToRefine = true; source = value; askingConsent = true
            return
        }
        speech.stop(); operation?.cancel(); deadlineTask?.cancel()
        busy = true; message = nil; source = value; startedAt = Date(); activity = AppText.text("正在理解你的修改…")
        let pro = model.purchases.hasPro
        let now = Date()
        operation = Task { @MainActor in
            let rules = AssistantChange.read(value, now: now, constraints: trip.constraints, departure: trip.departure)
            var change = rules, reader = "rules"
            if OnlineJourneyReader.enabled,
               let online = try? await OnlineJourneyReader.refine(value, trip: Self.describe(trip), now: now, pro: pro) {
                change = online.filled(from: rules); reader = "online"
            }
            guard !Task.isCancelled else { return }
            busy = false
            JourneyDiagnostics.shared.record("ai-refine reader=\(reader) mode=\(change.mode != nil) time=\(change.time != nil) avoid=\(change.constraints != nil) place=\(!change.destination.isEmpty)")
            if change.isEmpty {
                // Nothing to change: it was a new request after all.
                run(value); return
            }
            if !change.destination.isEmpty || !change.origin.isEmpty {
                await replace(trip, with: change, request: value)
            } else {
                model.applyAssistantChange(change, request: value)
                Haptics.success()
                finishVoice()
            }
        }
    }
    private var waitingToRefine = false

    /// A new destination or start keeps everything else the rider already set.
    private func replace(_ trip: TransitAppModel.AssistantTrip, with change: AssistantChange, request: String) async {
        func place(_ words: String, near: Coordinate?) async -> TravelPlace? {
            search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
            search.setContext(near)
            let found = ((try? await search.find(text: words, queryLimit: 3)) ?? []).filter { $0.coordinate.isInServiceArea }
            return found.first { Self.matches($0, words) }
        }
        busy = true; activity = AppText.text("正在搜尋地點…")
        let destination = change.destination.isEmpty ? trip.destination : await place(change.destination, near: model.location.usableCoordinate)
        let origin = change.origin.isEmpty ? trip.origin : await place(change.origin, near: model.location.usableCoordinate)
        busy = false
        guard let destination, change.origin.isEmpty || origin != nil else {
            // Not sure which place: the rider picks, as for a new request.
            run(request); return
        }
        var departure = trip.departure, arriveBy = trip.arriveBy
        switch change.time {
        case .now?: departure = nil; arriveBy = nil
        case .depart(let date)?: departure = date; arriveBy = nil
        case .arrive(let date)?: departure = nil; arriveBy = date
        case nil: break
        }
        let preference = change.preference.flatMap { RoutePreference(rawValue: $0.rawValue) } ?? trip.preference
        model.previewAssistantJourney(request: request, origin: origin, destination: destination, preference: preference,
                                      mode: change.mode ?? trip.mode, departure: departure, arriveBy: arriveBy,
                                      nextStop: change.next.isEmpty ? trip.nextStop : change.next,
                                      constraints: change.constraints ?? trip.constraints)
        Haptics.success()
        plannedCount += 1; finishVoice()
    }
    /// The trip in words for the online model: places, way of travelling, time and limits, no coordinates.
    private static func describe(_ trip: TransitAppModel.AssistantTrip) -> String {
        let formatter = DateFormatter()
        formatter.calendar = AssistantJourneyRequest.calendar; formatter.timeZone = AssistantJourneyRequest.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let time = trip.arriveBy.map { "\(formatter.string(from: $0)) 前抵達" } ?? trip.departure.map { "\(formatter.string(from: $0)) 出發" } ?? "現在出發"
        let limits = trip.constraints.isEmpty ? "無" : trip.constraints.summary
        return "從\(trip.origin?.name ?? "目前位置")到\(trip.destination.name)；交通方式 \(trip.mode.rawValue)；偏好 \(trip.preference.rawValue)；\(time)；限制 \(limits)"
    }
    /// Understands the sentence and plans it, without opening anything when nothing needs asking.
    func run(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard unavailable == nil else { input = value; present(); return }
        guard !value.isEmpty, value.count <= 600 else { return }
        if OnlineJourneyReader.needsConsent {
            speech.stop(); waitingForConsent = value; input = value; source = value; askingConsent = true
            return
        }
        speech.stop(); operation?.cancel(); deadlineTask?.cancel()
        input = value; source = value
        busy = true; message = nil; clarification = nil; conversation = nil; problem = nil; turn = nil
        chosenDestination = nil; chosenOrigin = nil
        let ready = prepared; prepared = nil
        let context = ready?.context ?? makeContext()
        track(context); activeContext = context
        activity = AppText.text("正在理解你的需求…"); startedAt = Date()
        startDeadline("understand", context: context)
        operation = Task { @MainActor in
            do {
                let session = try ready?.conversation ?? OnDeviceJourneyAssistant.conversation(context: context, pro: model.purchases.hasPro)
                conversation = session
                let result = try await session.begin(value, at: Date())
                try Task.checkCancellation()
                deadlineTask?.cancel()
                record("understand", outcome: "ok", context: context)
                receive(result)
            } catch {
                guard !Task.isCancelled else { return }
                deadlineTask?.cancel()
                record("understand", outcome: "error:" + OnDeviceJourneyAssistant.failureKind(error), context: context)
                busy = false
                fail(AppText.text("這句話暫時無法理解，請換個說法再試，或直接搜尋地點。"))
            }
        }
    }
    func answer(_ index: Int) {
        guard let conversation, !busy else { return }
        operation?.cancel(); busy = true; message = nil
        activity = AppText.text("正在理解你的選擇…"); startedAt = Date()
        let context = activeContext ?? makeContext()
        startDeadline("answer", context: context)
        operation = Task { @MainActor in
            do {
                let result = try await conversation.answer(option: index)
                try Task.checkCancellation()
                deadlineTask?.cancel()
                record("answer", outcome: "ok", context: context)
                receive(result)
            } catch {
                guard !Task.isCancelled else { return }
                deadlineTask?.cancel()
                record("answer", outcome: "error:" + OnDeviceJourneyAssistant.failureKind(error), context: context)
                busy = false; clarification = nil
                fail(AppText.text("這個選擇暫時無法處理，請再試一次。"))
            }
        }
    }
    /// Remembered for good; it can be changed in 資訊與設定. The waiting sentence then goes ahead.
    func answerConsent(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: OnlineJourneyReader.enabledKey)
        askingConsent = false
        let text = waitingForConsent, refining = waitingToRefine; waitingForConsent = ""; waitingToRefine = false
        if !text.isEmpty { if refining { refine(text) } else { run(text) } }
    }
    /// Editing the sentence discards an answer that belonged to the old one.
    func edited() {
        guard !busy, input != source else { return }
        clarification = nil; conversation = nil; problem = nil; message = nil
    }
    /// Closes the voice screen after a brief ✓ when it led to routes.
    private func finishVoice() {
        guard voiceActive else { return }
        celebrating = true
        voiceRound += 1
        let round = voiceRound
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            // Listening again in the meantime keeps its own screen open.
            guard round == voiceRound else { return }
            closeVoice()
        }
    }
    private var voiceRound = 0
    /// The voice screen comes and goes without the sliding sheet animation; it fades itself.
    private func setVoice(_ active: Bool) {
        if active { voiceStyle = VoiceStyle.current }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { voiceActive = active }
        // The edge glow lives in its own window above the app, so the map stays in view and usable.
        if voiceStyle == .glow {
            if active { VoiceGlowOverlay.shared.show(self) } else { VoiceGlowOverlay.shared.hide() }
        }
    }
    /// Fades the voice screen out, closes it, then runs `then` once nothing is being presented.
    private func closeVoice(then action: (() -> Void)? = nil) {
        guard voiceActive else { action?(); return }
        voiceRound += 1
        let round = voiceRound
        voiceClosing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard round == voiceRound else { return }
            setVoice(false); voiceClosing = false; celebrating = false; voicePermissionStep = false
            guard let action else { return }
            try? await Task.sleep(for: .milliseconds(380))
            action()
        }
    }
    /// The rider closed the voice screen.
    func dismissVoice() { cancel(); closeVoice() }
    /// 「改用打字」: the voice screen gives way to the typing sheet.
    func typeInstead() {
        cancel()
        closeVoice { [weak self] in guard let self else { return }; input = ""; prepare(); presented = true }
    }
    /// Questions and problems need the sheet; the voice screen closes first.
    private func present() {
        if voiceActive { closeVoice { [weak self] in self?.presented = true } } else { presented = true }
    }
    func cancel() {
        operation?.cancel(); deadlineTask?.cancel(); search.cancel(); speech.stop()
        busy = false; clarification = nil; problem = nil; message = nil; conversation = nil; turn = nil
        fixResults = []; fixSearching = false; pendingLeg = nil
        askingConsent = false; waitingForConsent = ""; waitingToRefine = false
    }
    /// The sheet was closed: nothing half-asked stays behind.
    func dismissed() {
        if busy || clarification != nil || problem != nil || message != nil { cancel() }
        prepared = nil
    }
    /// Starts loading the model while the rider types or speaks.
    func prepare() {
        guard unavailable == nil, prepared == nil else { return }
        let context = makeContext()
        guard let session = try? OnDeviceJourneyAssistant.conversation(context: context, pro: model.purchases.hasPro) else { return }
        session.prewarm()
        prepared = (context, session)
    }

    // MARK: Fixing what stopped planning

    func findFix() {
        let text = fixQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
        search.setContext(model.location.usableCoordinate)
        fixSearching = true
        Task { @MainActor in
            let found = (try? await search.find(text: text)) ?? []
            fixResults = Array(found.filter { $0.coordinate.isInServiceArea }.prefix(6))
            fixSearching = false
            message = fixResults.isEmpty ? AppText.text("找不到服務範圍內的地點，請換個關鍵字。") : nil
        }
    }
    func chooseFix(_ place: TravelPlace) {
        guard let problem else { return }
        if let leg = pendingLeg {
            pendingLeg = nil
            model.resolveAssistantStop(leg, place: place); model.showAssistantLeg(leg)
            self.problem = nil; message = nil; presented = false; input = ""
            return
        }
        if problem.unsaved, saveFix, model.purchases.hasPro {
            let word = problem.keyword
            let symbol = JourneyAssistantContext.category(of: word) == .work ? "briefcase.fill"
                : JourneyAssistantContext.category(of: word) == .school ? "book.fill" : "house.fill"
            model.commutes.store(title: word, symbol: symbol, origin: nil, destination: place, preference: .balanced)
        }
        self.problem = nil; message = nil
        if problem.isOrigin { chosenOrigin = place } else { chosenDestination = place }
        planRightAway()
    }
    /// Location became available while it was asked for: plan from here without another tap.
    func locationReady() {
        guard problem == .location, currentPlace != nil else { return }
        problem = nil; planRightAway()
    }

    // MARK: Model

    private func makeContext() -> JourneyAssistantContext {
        let vocabulary = model.vocabulary, settings = model.liveSettings.search, revision = model.liveSettings.revision
        let coordinate = model.location.usableCoordinate
        let context = JourneyAssistantContext(journeys: model.commutes.journeys, matches: Self.matches) { query in
            let toolSearch = PlaceSearch()
            toolSearch.setRules(vocabulary: vocabulary, settings: settings, revision: revision)
            toolSearch.setContext(coordinate)
            return try await toolSearch.find(text: query, queryLimit: 3, timeout: 4)
        }
        // Asked at the moment of choosing, so a consent given after this context was made counts.
        if OnlineJourneyReader.configured {
            let pro = model.purchases.hasPro
            context.choose = { words, sentence, places in
                await OnlineJourneyReader.choose(words, sentence: sentence, places: places, pro: pro)
            }
            context.rewrite = { words, sentence in
                await OnlineJourneyReader.rewrite(words, sentence: sentence, pro: pro)
            }
        }
        return context
    }
    private func track(_ context: JourneyAssistantContext) {
        context.onActivity = { [weak self] value in
            switch value {
            case .search: self?.activity = AppText.text("正在搜尋地點…")
            case .saved: self?.activity = AppText.text("正在查看常用行程…")
            }
        }
    }
    private func startDeadline(_ step: String, context: JourneyAssistantContext) {
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(Self.timeLimit)) } catch { return }
            guard let self, self.busy else { return }
            self.operation?.cancel()
            self.record(step, outcome: "timeout", context: context)
            self.busy = false; self.conversation = nil
            self.fail(AppText.text("手機上的模型這次回應太久，請再試一次，或直接搜尋地點。"))
        }
    }
    /// Timing and kinds only: no request text, places or answers enter the troubleshooting history.
    private func record(_ step: String, outcome: String, context: JourneyAssistantContext) {
        let searches = context.toolCalls.filter { $0.hasPrefix("searchPlaces") }.count
        let saved = context.toolCalls.filter { $0.hasPrefix("listSavedJourneys") }.count
        JourneyDiagnostics.shared.record(String(format: "ai-%@ %@ %.1fs searches=%d search=%.1fs saved=%d %@",
            step, outcome, Date().timeIntervalSince(startedAt), searches, context.searchSeconds, saved, context.trace))
    }
    private func fail(_ text: String) {
        message = text; present()
    }
    private func receive(_ result: AssistantJourneyTurn) {
        turn = result; busy = false
        clarification = result.clarification
        if result.clarification != nil { present() } else { planRightAway() }
    }

    // MARK: Planning

    /// After understanding, plan at once: unstated parts mean current location and leaving now, and
    /// the route screen is where the rider adjusts the rest.
    private func planRightAway() {
        guard let turn else { return }
        let request = turn.request
        guard let target = chosenDestination ?? turn.destinationCandidates.first else {
            stop(JourneyAssistantContext.category(of: request.destination) != nil
                 ? .unsavedDestination(request.destination) : .destination(request.destination))
            return
        }
        let statedOrigin = !request.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let from: TravelPlace?
        if let chosenOrigin { from = chosenOrigin }
        else if statedOrigin {
            guard let found = turn.originCandidates.first else {
                stop(JourneyAssistantContext.category(of: request.origin) != nil ? .unsavedOrigin(request.origin) : .origin(request.origin))
                return
            }
            from = found
        } else {
            guard currentPlace != nil else { stop(.location); return }
            from = nil
        }
        AssistantRecents.shared.remember(source)
        // A stated time is planned in the ordinary route view, on that day's timetables and headways:
        // an arrival time works back to when to leave.
        let arriveBy = request.arriveBy.flatMap { AssistantJourneyRequest.canPlan(arriveBy: $0) ? $0 : nil }
        let timing = arriveBy != nil ? " deadline" : turn.departAt != nil ? " departure" : ""
        JourneyDiagnostics.shared.record("ai-plan started mode=\(turn.mode.rawValue)\(timing)")
        let alternatives = chosenDestination == nil ? Array(turn.destinationCandidates.dropFirst()) : []
        model.previewAssistantJourney(request: source, origin: from, destination: target, alternatives: alternatives,
                                      preference: preference, mode: turn.mode, departure: turn.departAt, arriveBy: arriveBy,
                                      nextStop: turn.nextStop, constraints: turn.avoid)
        if !turn.nextStop.isEmpty { findStop(1, words: turn.nextStop, near: target) }
        Haptics.success()
        conversation = nil; clarification = nil; problem = nil; message = nil
        presented = false; input = ""; plannedCount += 1; finishVoice()
    }
    /// Whether a found place is what the words named (台大機械館 matches 機械工程學系館, not 圖書館).
    static func matches(_ place: TravelPlace, _ words: String) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, JourneyAssistantContext.category(of: text) == nil, NearbyQuery(text) == nil else { return true }
        return StationSearch.placeRank(name: place.name, address: place.address, query: text) != nil
    }

    /// A later stop of 「先去 A 再去 B」 is looked up in the background as soon as the first leg is
    /// planned, so its number appears on the map and tapping it only switches legs.
    private func findStop(_ index: Int, words: String, near: TravelPlace) {
        stopSearch?.cancel()
        let finder = PlaceSearch()
        finder.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
        finder.setContext(near.coordinate)
        stopSearch = Task { @MainActor in
            let found = ((try? await finder.find(text: words, queryLimit: 3)) ?? []).filter { $0.coordinate.isInServiceArea }
            guard !Task.isCancelled else { return }
            stopCandidates[index] = found
            if let place = found.first(where: { Self.matches($0, words) }) {
                model.resolveAssistantStop(index, place: place)
                JourneyDiagnostics.shared.record("ai-plan stop=\(index + 1) found")
            }
        }
    }
    private var stopSearch: Task<Void, Never>?
    private var stopCandidates: [Int: [TravelPlace]] = [:]
    private var pendingLeg: Int?
    /// The numbered stops above the routes: show that leg, or ask which place when unsure.
    func showLeg(_ index: Int) {
        guard let trip = model.assistantTrip, trip.stops.indices.contains(index), index != trip.leg, !busy else { return }
        Haptics.selection()
        if trip.stops[index].place != nil {
            JourneyDiagnostics.shared.record("ai-plan leg=\(index + 1)")
            model.showAssistantLeg(index)
            return
        }
        let words = trip.stops[index].name
        pendingLeg = index; turn = nil; input = AppText.text("接著去%@", words); source = input
        problem = .destination(words); fixQuery = words; fixResults = Array((stopCandidates[index] ?? []).prefix(6)); present()
        if fixResults.isEmpty { findFix() }
    }
    private func stop(_ reason: Problem) {
        JourneyDiagnostics.shared.record("ai-plan stopped=\(reason.isOrigin ? "origin" : "destination")\(reason.unsaved ? "-unsaved" : "")")
        problem = reason; fixResults = []; present()
        fixQuery = reason.unsaved || reason == .location ? "" : reason.keyword
        if !fixQuery.isEmpty { findFix() }
    }
}

/// Shown where the sentence was given while it is heard or understood, so nothing jumps in front.
struct AssistantInlineStatus: View {
    @ObservedObject var session: JourneyAssistantSession
    @ObservedObject private var speech: SpeechInput
    init(session: JourneyAssistantSession) { self.session = session; speech = session.speech }
    private func seconds(_ date: Date) -> String {
        AppText.text("%@ 秒", "\(max(0, Int(date.timeIntervalSince(session.startedAt))))")
    }
    var body: some View {
        if speech.preparing, !session.presented {
            HStack(spacing: 12) {
                ProgressView()
                Text(AppText.text("正在開啟麥克風…")).font(.subheadline)
                Spacer(minLength: 0)
                Button(AppText.text("取消")) { session.cancel() }.font(.subheadline).frame(minHeight: 44)
            }
            .padding(12).background(Color(uiColor: .tertiarySystemFill), in: MapChrome.shape(.row))
            .accessibilityIdentifier("ai-inline-preparing")
        } else if speech.listening, !session.presented {
            HStack(spacing: 12) {
                Image(systemName: "waveform").foregroundStyle(.tint).symbolEffect(.variableColor.iterative)
                Text(speech.transcript.isEmpty ? AppText.text("請說出要去哪裡…") : speech.transcript)
                    .font(.subheadline).lineLimit(3)
                Spacer(minLength: 0)
                Button(AppText.text("完成")) { speech.finish() }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            .padding(12).background(Color(uiColor: .tertiarySystemFill), in: MapChrome.shape(.row))
            .accessibilityElement(children: .contain).accessibilityIdentifier("ai-inline-listening")
        } else if session.busy, !session.presented {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("「" + session.source + "」").font(.subheadline.weight(.semibold)).lineLimit(2)
                    TimelineView(.periodic(from: session.startedAt, by: 1)) { timeline in
                        Text(session.activity + " " + seconds(timeline.date))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                Button(AppText.text("取消")) { session.cancel() }.font(.subheadline).frame(minHeight: 44)
            }
            .padding(12).background(Color(uiColor: .tertiarySystemFill), in: MapChrome.shape(.row))
            .accessibilityElement(children: .contain).accessibilityIdentifier("ai-inline-progress")
        } else if let issue = speech.problem, !session.presented {
            Text(issue).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The sheet: typing from scratch, or the one thing the rider has to answer.
struct AIJourneyAssistantView: View {
    @ObservedObject var session: JourneyAssistantSession
    @ObservedObject private var speech: SpeechInput
    @ObservedObject private var recents = AssistantRecents.shared
    @ObservedObject private var location: LocationService
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool
    @FocusState private var fixFocused: Bool
    private let hasPro: Bool

    init(session: JourneyAssistantSession, model: TransitAppModel) {
        self.session = session; speech = session.speech; location = model.location; hasPro = model.purchases.hasPro
    }
    private var trimmed: String { session.input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var idle: Bool {
        !session.busy && !speech.listening && session.problem == nil && session.clarification == nil && session.message == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let unavailable = session.unavailable {
                    Section {
                        Text(unavailable).accessibilityIdentifier("ai-unavailable")
                        Button(AppText.text("返回手動搜尋")) { dismiss() }.accessibilityIdentifier("ai-manual-search")
                    }
                } else {
                    requestSection
                    if trimmed.isEmpty, idle { examplesSection }
                    if session.busy { progressSection }
                    if let clarification = session.clarification { clarificationSection(clarification) }
                    if let problem = session.problem { problemSection(problem) }
                    if let message = session.message { Section { Text(message).accessibilityIdentifier("ai-error") } }
                }
            }
            .navigationTitle(AppText.text("用一句話規劃")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppText.text("關閉")) { dismiss() } } }
        }
        .modifier(OnlineConsentAlert(session: session, inSheet: true))
        .onChange(of: session.input) { _, _ in session.edited() }
        .onChange(of: location.usableCoordinate == nil) { _, _ in session.locationReady() }
        .onAppear {
            session.prepare()
            if session.problem != nil { if session.fixQuery.isEmpty { fixFocused = true } }
            else if idle { inputFocused = true }
        }
    }

    // MARK: Sections

    private var requestSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField(AppText.text("例如：騎單車去台大、明天 9 點前到公司"), text: $session.input)
                    .focused($inputFocused).submitLabel(.go).onSubmit { session.run(session.input) }
                    .disabled(session.busy || speech.listening)
                    .accessibilityIdentifier("ai-request")
                Button {
                    if speech.listening { speech.finish() } else { inputFocused = false; session.listen(inline: true) }
                } label: {
                    Image(systemName: speech.listening ? "stop.circle.fill" : "mic.fill")
                        .font(.title3).frame(width: 44, height: 44)
                }.buttonStyle(.borderless).disabled(session.busy)
                    .accessibilityLabel(speech.listening ? AppText.text("停止聆聽") : AppText.text("用說的"))
                    .accessibilityIdentifier("ai-voice")
            }
            if speech.preparing {
                Label(AppText.text("正在開啟麥克風…"), systemImage: "mic").foregroundStyle(.secondary)
            } else if speech.listening {
                Label(speech.transcript.isEmpty ? AppText.text("請說出要去哪裡…") : speech.transcript, systemImage: "waveform")
                    .foregroundStyle(.secondary).accessibilityIdentifier("ai-listening")
            }
            if let issue = speech.problem { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            Button(AppText.text("理解並規劃")) { session.run(session.input) }
                .disabled(session.busy || trimmed.isEmpty || trimmed.count > 600)
                .accessibilityIdentifier("ai-extract")
        } footer: {
            Text(AppText.text("說或打一句話就會直接規劃；沒說的就從目前位置、現在出發。文字只在手機上理解，地點與路線由 Apple 地圖處理。"))
        }
    }

    private var examplesSection: some View {
        Section(recents.items.isEmpty ? AppText.text("試試看") : AppText.text("最近說過")) {
            let examples = recents.items.isEmpty ? [AppText.text("回家"), AppText.text("騎單車去台大"), AppText.text("明天 9 點前到台北車站")] : recents.items
            ForEach(examples, id: \.self) { text in
                Button { session.run(text) } label: { Label(text, systemImage: recents.items.isEmpty ? "sparkles" : "clock") }
                    .accessibilityIdentifier("ai-example-" + text)
                    .contextMenu {
                        if !recents.items.isEmpty { Button(AppText.text("從最近說過移除"), role: .destructive) { recents.remove(text) } }
                    }
            }
        }
    }

    private var progressSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text(session.activity)
                Spacer()
                TimelineView(.periodic(from: session.startedAt, by: 1)) { timeline in
                    Text(AppText.text("%@ 秒", "\(max(0, Int(timeline.date.timeIntervalSince(session.startedAt))))"))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("ai-progress")
        }
    }

    private func clarificationSection(_ question: AssistantClarification) -> some View {
        Section(AppText.text("確認你的意思")) {
            Text(question.question).font(.headline)
            ForEach(question.options.indices, id: \.self) { index in
                Button(question.options[index]) { session.answer(index) }
                    .disabled(session.busy).accessibilityIdentifier("ai-choice-\(index)")
            }
        }
    }

    private func problemSection(_ problem: JourneyAssistantSession.Problem) -> some View {
        Section {
            switch problem {
            case .location:
                Text(AppText.text("需要目前位置才能從這裡出發。")).font(.headline)
                Button(AppText.text("開啟定位")) { location.request() }
                Text(AppText.text("或輸入出發地：")).font(.footnote).foregroundStyle(.secondary)
            case .unsavedDestination(let word), .unsavedOrigin(let word):
                Text(AppText.text("還沒有儲存「%@」，輸入它的地址或附近地點：", word)).font(.headline)
            case .destination(let word), .origin(let word):
                Text(AppText.text("找不到「%@」，換個說法或選一個地點：", word)).font(.headline)
            }
            HStack {
                TextField(problem.isOrigin ? AppText.text("出發地、地址或站名") : AppText.text("地點、地址或站名"), text: $session.fixQuery)
                    .focused($fixFocused).submitLabel(.search).onSubmit { session.findFix() }
                    .accessibilityIdentifier("ai-fix-query")
                if session.fixSearching { ProgressView() }
            }
            ForEach(session.fixResults) { place in
                Button { session.chooseFix(place) } label: {
                    VStack(alignment: .leading) {
                        Text(place.localizedName)
                        if !place.address.isEmpty { Text(place.address).font(.caption).foregroundStyle(.secondary) }
                    }
                }.accessibilityIdentifier("ai-fix-\(place.name)")
            }
            if problem.unsaved, hasPro {
                Toggle(AppText.text("同時儲存為「%@」", problem.keyword), isOn: $session.saveFix)
            }
        }
    }
}

/// Everything that shapes the routes below in one place: when, how, what to avoid, the next stop,
/// and for a trip planned from a sentence, what was said and how to change it. One row of chips
/// instead of stacked panels; notes collapse into one footnote.
struct TripConditionsBar: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    @ObservedObject var session: JourneyAssistantSession
    @State private var choosingTime = false
    @State private var arriving = false
    @State private var chosen = Date()
    @State private var editing = false
    @State private var change = ""
    @FocusState private var changeFocused: Bool
    @State private var comparison: String?
    @State private var comparing = false

    static func label(_ date: Date, now: Date = Date()) -> String {
        let calendar = AssistantJourneyRequest.calendar
        let locale = AppLanguage.current.locale
        let clock = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
            calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return AppText.text("今天 %@", clock) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return AppText.text("明天 %@", clock)
        }
        let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.defaultDigits).day().weekday(.abbreviated))
        return day + " " + clock
    }
    private static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: AppLanguage.current.locale,
            calendar: AssistantJourneyRequest.calendar, timeZone: AssistantJourneyRequest.calendar.timeZone))
    }
    private func title(_ mode: AssistantTravelMode) -> String {
        switch mode {
        case .any: AppText.text("推薦路線")
        case .cycling: AppText.text("騎 YouBike 優先")
        case .walking: AppText.text("步行優先")
        }
    }
    private func symbol(_ mode: AssistantTravelMode) -> String {
        switch mode { case .any: "tram.fill"; case .cycling: "bicycle"; case .walking: "figure.walk" }
    }
    private var timeTitle: String {
        if let deadline = planner.arrivalDeadline {
            let leave = planner.scheduledDeparture.map { " · " + AppText.text("%@ 出發", Self.clock($0)) } ?? ""
            return AppText.text("%@ 前抵達", Self.label(deadline)) + leave
        }
        return planner.scheduledDeparture.map { AppText.text("%@ 出發", Self.label($0)) } ?? AppText.text("現在出發")
    }
    private func chip(_ text: String, _ image: String, menu: Bool = true, tint: Bool = false, removable: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: image).font(.caption)
            Text(text).font(.subheadline.weight(tint ? .semibold : .regular)).lineLimit(1)
            if menu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
            if removable { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).frame(minHeight: Metrics.chip)
        .foregroundStyle(tint ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .background(tint ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)), in: Capsule())
        .contentShape(Capsule())
    }

    var body: some View {
        let trip = model.currentAssistantTrip
        VStack(alignment: .leading, spacing: 10) {
            if let trip { requestRow(trip) }
            // Chips wrap onto a second line rather than hiding off the edge.
            ChipFlow(spacing: Metrics.tight) {
                timeMenu
                modeMenu(trip?.mode ?? planner.preferredMode)
                if let trip, !trip.alternatives.isEmpty { placeMenu(trip) }
                if let trip { constraintChips(trip) }
                if OnlineJourneyReader.enabled, planner.options.count >= 2, !planner.planning { compareChip(trip) }
            }
            if trip != nil, editing { changeField }
            if let comparison {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").font(.caption).foregroundStyle(.tint)
                    Text(comparison).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { self.comparison = nil } label: { Image(systemName: "xmark").font(.caption) }
                        .foregroundStyle(.secondary).accessibilityLabel(AppText.text("關閉"))
                }
                .padding(Metrics.gap).background(Color.accentColor.opacity(0.08), in: MapChrome.shape(.row))
                .accessibilityIdentifier("journey-comparison")
            }
            if let trip, trip.stops.count > 1 { stopStrip(trip) }
            footnotes(trip)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(trip == nil ? "journey-conditions" : "assistant-trip")
        .sheet(isPresented: $choosingTime) { timeSheet }
        // A comparison belongs to the routes it compared.
        .onChange(of: planner.options.map(\.id)) { _, _ in comparison = nil }
    }

    // MARK: Parts

    /// 「先去 A 再去 B」: every stop numbered like the pins on the map; tap one to see that leg.
    /// A later leg leaves when the one before it arrives.
    private func stopStrip(_ trip: TransitAppModel.AssistantTrip) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(trip.stops.enumerated()), id: \.offset) { index, stop in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    }
                    let current = index == trip.leg
                    Button { session.showLeg(index) } label: {
                        HStack(spacing: 6) {
                            Text("\(index + 1)").font(.caption.weight(.bold)).monospacedDigit()
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(current ? Color.white : Color.accentColor))
                                .foregroundStyle(current ? Color.accentColor : Color.white)
                            Text(stop.place?.localizedName ?? stop.name).font(.subheadline.weight(current ? .semibold : .regular)).lineLimit(1)
                            if stop.place == nil { Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.leading, 6).padding(.trailing, 12).frame(minHeight: Metrics.chip)
                        .foregroundStyle(current ? Color.white : Color.primary)
                        .background(current ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppText.text("第 %@ 站：%@", "\(index + 1)", stop.place?.localizedName ?? stop.name))
                    .accessibilityAddTraits(current ? .isSelected : [])
                    .accessibilityIdentifier("assistant-trip-stop-\(index + 1)")
                }
            }
        }
        .accessibilityIdentifier("assistant-trip-next")
    }
    private func requestRow(_ trip: TransitAppModel.AssistantTrip) -> some View {
        // Icon and text sit in the same columns as the start and destination rows above.
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.caption).foregroundStyle(.tint).frame(width: Metrics.icon).accessibilityHidden(true)
            Text(trip.request).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityLabel(AppText.text("你說的：%@", trip.request))
            Spacer(minLength: 4)
            Button(editing ? AppText.text("完成") : AppText.text("修改")) {
                editing.toggle(); changeFocused = editing
            }.font(.subheadline.weight(.semibold)).frame(minHeight: 36).accessibilityIdentifier("assistant-trip-edit")
            Menu {
                Button(AppText.text("用說的修改"), systemImage: "mic") { session.listen(refining: true) }
                    .accessibilityIdentifier("assistant-trip-respeak")
                Button(AppText.text("重新說一次"), systemImage: "arrow.counterclockwise") { session.listen() }
                Button(AppText.text("改回一般路線"), systemImage: "xmark") { model.forgetAssistantTrip() }
                    .accessibilityIdentifier("assistant-trip-dismiss")
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 36, height: 36)
            }.accessibilityLabel(AppText.text("更多"))
        }
        .padding(.leading, Metrics.inset)
    }

    private var timeMenu: some View {
        Menu {
            Button(AppText.text("現在出發")) { model.setJourneyDeparture(nil) }
            Button(AppText.text("30 分鐘後")) { model.setJourneyDeparture(Date().addingTimeInterval(30 * 60)) }
            Button(AppText.text("1 小時後")) { model.setJourneyDeparture(Date().addingTimeInterval(3600)) }
            Button(AppText.text("指定出發時間…"), systemImage: "calendar") { chooseTime(arriving: false) }
            Button(AppText.text("指定抵達時間…"), systemImage: "flag.checkered") { chooseTime(arriving: true) }
        } label: {
            chip(timeTitle, planner.scheduledDeparture == nil ? "clock" : "calendar.badge.clock")
        }.tint(.primary).accessibilityIdentifier("journey-departure-time")
    }

    private func modeMenu(_ current: AssistantTravelMode) -> some View {
        Menu {
            ForEach([AssistantTravelMode.any, .cycling, .walking], id: \.self) { mode in
                Button { model.setTravelMode(mode) } label: {
                    if current == mode { Label(title(mode), systemImage: "checkmark") } else { Text(title(mode)) }
                }
            }
        } label: { chip(title(current), symbol(current)) }
            .tint(.primary)
            .accessibilityLabel(AppText.text("交通方式：%@", title(current)))
            .accessibilityIdentifier("assistant-trip-adjust")
    }

    private func placeMenu(_ trip: TransitAppModel.AssistantTrip) -> some View {
        Menu {
            Section(AppText.text("不是這裡？")) {
                ForEach(trip.alternatives) { place in
                    Button(place.localizedName) { model.switchAssistantDestination(place) }
                }
            }
        } label: { chip(AppText.text("不是這裡？"), "mappin") }
            .tint(.primary).accessibilityIdentifier("assistant-trip-place")
    }

    /// Each limit is its own chip; tapping it lifts that limit.
    @ViewBuilder private func constraintChips(_ trip: TransitAppModel.AssistantTrip) -> some View {
        let limits = trip.constraints
        let items: [(String, TripConstraints)] = {
            var list: [(String, TripConstraints)] = []
            if limits.avoidBus { var c = limits; c.avoidBus = false; list.append((AppText.text("不搭公車"), c)) }
            if limits.avoidMetro { var c = limits; c.avoidMetro = false; list.append((AppText.text("不搭捷運"), c)) }
            if limits.avoidBike { var c = limits; c.avoidBike = false; list.append((AppText.text("不騎 YouBike"), c)) }
            for route in limits.avoidRoutes {
                var c = limits; c.avoidRoutes.removeAll { $0 == route }; list.append((AppText.text("避開%@", route), c))
            }
            return list
        }()
        ForEach(items, id: \.0) { item in
            Button {
                var lifted = AssistantChange(); lifted.constraints = item.1
                model.applyAssistantChange(lifted, request: trip.request)
            } label: { chip(item.0, "nosign", menu: false, removable: true) }
            .buttonStyle(.plain)
                .accessibilityLabel(AppText.text("取消限制：%@", item.0))
                .accessibilityIdentifier("assistant-trip-constraints")
        }
    }

    /// 幫我比較: the online model explains the routes on screen in a sentence or two.
    private func compareChip(_ trip: TransitAppModel.AssistantTrip?) -> some View {
        Button {
            comparing = true
            let summaries = routeSummaries(), request = trip?.request ?? "", pro = model.purchases.hasPro
            Task { @MainActor in
                comparison = await OnlineJourneyReader.compare(summaries, request: request, pro: pro)
                    ?? AppText.text("暫時無法比較，請直接看下方路線。")
                comparing = false
            }
        } label: {
            if comparing { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(AppText.text("比較中")).font(.subheadline) }
                .padding(.horizontal, 12).frame(minHeight: 34).background(Color(uiColor: .tertiarySystemFill), in: Capsule()) }
            else { chip(AppText.text("幫我比較"), "sparkles", menu: false, tint: true) }
        }.buttonStyle(.plain).disabled(comparing).accessibilityIdentifier("journey-compare")
    }
    /// What the comparison is given: each route's name, minutes, walking, waiting, transfers and arrival.
    private func routeSummaries() -> [String] {
        planner.options.prefix(4).enumerated().compactMap { index, option in
            guard let timing = model.journeyDuration(option, at: Date()) else { return nil }
            let name = option.walkingOnly ? AppText.text("全程步行") : option.bikeOnly ? AppText.text("全程 YouBike")
                : option.rides.map(\.route.localizedName).joined(separator: "→")
            let label = planner.optionLabels[option.id].map { "（\($0)）" } ?? ""
            let walk = Int(max(0, timing.walkingSeconds - timing.cyclingSeconds) / 60)
            // Unknown waits (no timetable at that hour) are said as unknown, never as minutes.
            let total = timing.unknownWaits > 0 ? "總時間不明（候車時間無法確認，可能沒有班次）" : "共 \(Int(timing.totalSeconds / 60)) 分，候車 \(Int(timing.waitingSeconds / 60)) 分，\(timing.expectedArrivalLabel)"
            return "\(name)\(label)：\(total)，走路 \(walk) 分，轉乘 \(max(0, option.rides.count - 1)) 次"
        }
    }

    private var changeField: some View {
        HStack(spacing: 8) {
            TextField(AppText.text("還要怎麼改？例如：改騎車、晚一點、不要搭公車"), text: $change)
                .font(.subheadline).submitLabel(.done).focused($changeFocused)
                .onSubmit { submitChange() }
                .accessibilityIdentifier("assistant-trip-change")
            Button { session.listen(refining: true) } label: { Image(systemName: "mic").frame(width: 32, height: 36) }
                .accessibilityLabel(AppText.text("用說的修改"))
            if !change.isEmpty {
                Button(AppText.text("修改")) { submitChange() }.font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, 10).frame(minHeight: 40)
        .background(Color(uiColor: .secondarySystemFill), in: MapChrome.shape(.row))
    }
    private func submitChange() {
        let text = change; change = ""; editing = false; changeFocused = false
        session.refine(text)
    }

    /// Warnings first (orange), then what the times are based on, in at most a few short lines.
    @ViewBuilder private func footnotes(_ trip: TransitAppModel.AssistantTrip?) -> some View {
        let warnings: [String] = [
            planner.arrivalDeadline.flatMap { deadline in
                planner.expectedArrival.flatMap { $0 > deadline ? AppText.text("最快約 %@ 抵達，會晚於指定時間。", Self.label($0)) : nil }
            },
            trip != nil && !(trip!.constraints.isEmpty) && planner.constraintsUnmet ? AppText.text("沒有完全符合的路線，先顯示一般推薦。") : nil,
            trip?.note,
            trip != nil ? planner.wholeTripBikeIssue().map { AppText.text("沒有全程 YouBike 路線：%@", $0) } : nil,
        ].compactMap { $0 }
        if !warnings.isEmpty {
            Text(warnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("assistant-trip-bike-issue")
        }
        if let departure = planner.scheduledDeparture {
            // Between about 1:00 and 5:00 almost nothing runs; say so instead of leaving 待確認 unexplained.
            if (1..<5).contains(AssistantJourneyRequest.calendar.component(.hour, from: departure)) {
                Text(AppText.text("這個時段公車與捷運大多已停駛，時間無法確認；可以改晚一點出發。"))
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("journey-night-note")
            }
            Text(AppText.text("依當天班表與班距估算，不含即時車況；時間到了再開始導航。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("journey-departure-note")
        }
    }

    private func chooseTime(arriving: Bool) {
        self.arriving = arriving
        chosen = (arriving ? planner.arrivalDeadline : planner.scheduledDeparture) ?? Date().addingTimeInterval(3600)
        choosingTime = true
    }
    private var timeSheet: some View {
        NavigationStack {
            DatePicker(arriving ? AppText.text("抵達時間") : AppText.text("出發時間"), selection: $chosen,
                       in: Date()...Date().addingTimeInterval(30 * 86_400))
                .datePickerStyle(.graphical).padding()
                .navigationTitle(arriving ? AppText.text("抵達時間") : AppText.text("出發時間")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(AppText.text("取消")) { choosingTime = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppText.text("規劃")) {
                            choosingTime = false
                            if arriving { model.setJourneyDeparture(nil, arriveBy: chosen) } else { model.setJourneyDeparture(chosen) }
                        }.accessibilityIdentifier("journey-departure-confirm")
                    }
                }
        }.presentationDetents([.large])
    }
}

/// The one-time question before a sentence is first sent to the online model.
struct OnlineConsentAlert: ViewModifier {
    @ObservedObject var session: JourneyAssistantSession
    /// The route panel asks unless the sheet is open; the sheet asks while it is.
    let inSheet: Bool
    func body(content: Content) -> some View {
        content.alert(AppText.text("使用線上 AI 理解？"), isPresented: Binding(
            // The voice screen asks on its own page.
            get: { session.askingConsent && session.presented == inSheet && !session.voiceActive },
            set: { if !$0, session.askingConsent { session.answerConsent(false) } })) {
            Button(AppText.text("使用線上理解")) { session.answerConsent(true) }
            Button(AppText.text("只在手機上理解"), role: .cancel) { session.answerConsent(false) }
        } message: {
            Text(AppText.text("為了更準確，你說或打的那一句話、今天日期，以及需要時搜尋到的地點名稱與地址，會經由台北公車的伺服器傳給 Groq 上的開源模型（OpenAI gpt-oss）讀懂。不包含位置、常用行程或帳號，句子不保存；伺服器只用匿名代號記錄每天用了幾次。沒有網路時改用手機上的理解。之後可在資訊與設定更改。"))
        }
    }
}

/// Lays chips out left to right and wraps them onto further lines.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    /// Measuring and placing share one line-breaking pass, so they can never disagree. They did:
    /// the measured width came back as the placing width and a rounding difference wrapped the
    /// last chip onto a line nobody had made room for, over the route card.
    private func rows(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width + 0.5 { x = 0; y += line + spacing; line = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + line))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let laid = rows(subviews, width: width)
        return CGSize(width: proposal.width ?? laid.size.width, height: laid.size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = rows(subviews, width: proposal.width ?? bounds.width)
        for (view, origin) in zip(subviews, laid.origins) {
            let size = view.sizeThatFits(.unspecified)
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                       proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
        }
    }
}

// MARK: - Voice assistant

enum VoicePhase: Equatable { case permission, blocked, preparing, listening, understanding, consent, done, problem }

/// Settings › 語音助理樣式: a glow around the screen edge over the app, or a full screen of its own.
enum VoiceStyle: String, CaseIterable, Identifiable {
    case glow, fullScreen
    static let key = "voiceStyle.v1"
    static var current: VoiceStyle { VoiceStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .glow }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glow: AppText.text("邊框光暈")
        case .fullScreen: AppText.text("全螢幕")
        }
    }
    var detail: String {
        switch self {
        case .glow: AppText.text("螢幕邊緣發光，可以一邊看地圖一邊說")
        case .fullScreen: AppText.text("專心說話的獨立畫面")
        }
    }
}

/// What the voice screens show, shared by the full screen and the edge glow.
extension JourneyAssistantSession {
    var voicePhase: VoicePhase {
        if celebrating { return .done }
        if askingConsent { return .consent }
        if busy { return .understanding }
        if voicePermissionStep { return .permission }
        if speech.listening { return .listening }
        if speech.preparing { return .preparing }
        if speech.blocked { return .blocked }
        if speech.problem != nil || message != nil { return .problem }
        return .preparing
    }
    var voiceMood: VoiceOrb.Mood {
        switch voicePhase {
        case .permission, .preparing, .consent: .calm
        case .listening: .listening
        case .understanding: .thinking
        case .done: .done
        case .blocked, .problem: .warning
        }
    }

    var voiceStatus: String {
        switch voicePhase {
        case .permission: AppText.text("需要你的允許")
        case .blocked: AppText.text("麥克風沒有開啟")
        case .preparing: AppText.text("正在開啟麥克風…")
        case .listening: AppText.text("正在聆聽")
        case .understanding: AppText.text("正在理解")
        case .consent: AppText.text("線上理解")
        case .done: AppText.text("完成")
        case .problem: AppText.text("沒有聽清楚")
        }
    }

    var voiceTitle: String {
        switch voicePhase {
        case .permission: AppText.text("用說的，比打字更快")
        case .blocked: AppText.text("麥克風或語音辨識沒有開啟")
        case .preparing: AppText.text("請說出要去哪裡")
        case .listening: speech.transcript.isEmpty ? AppText.text("請說出要去哪裡") : speech.transcript
        case .understanding, .consent: "「" + source + "」"
        case .done: AppText.text("好了，路線來了")
        case .problem: speech.problem ?? message ?? AppText.text("沒有聽到聲音，請再說一次，或直接打字。")
        }
    }
    var voiceDetail: String {
        switch voicePhase {
        case .permission: AppText.text("按下「允許並開始說話」後，iPhone 會詢問麥克風與語音辨識權限。聲音只用來把這一句話轉成文字。")
        case .blocked: AppText.text("到「設定」開啟麥克風與語音辨識後回到 App，就會直接開始聆聽。")
        case .preparing: AppText.text("例如：明天九點前到台大、騎單車去101")
        case .listening: speech.transcript.isEmpty ? AppText.text("例如：明天九點前到台大、騎單車去101") : AppText.text("說完停一下，就會開始規劃")
        case .understanding: activity
        case .consent: AppText.text("為了更準確，你說或打的那一句話、今天日期，以及需要時搜尋到的地點名稱與地址，會經由台北公車的伺服器傳給 Groq 上的開源模型（OpenAI gpt-oss）讀懂。不包含位置、常用行程或帳號，句子不保存；伺服器只用匿名代號記錄每天用了幾次。沒有網路時改用手機上的理解。之後可在資訊與設定更改。")
        case .done, .problem: ""
        }
    }
}

/// Shows the voice screen over whatever presents it. It appears without the sliding sheet
/// animation and fades and scales in by itself, so the tap is answered at once.
struct VoiceAssistantPresenter: ViewModifier {
    @ObservedObject var session: JourneyAssistantSession
    var enabled = true
    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(
            get: { enabled && session.voiceActive && session.voiceStyle == .fullScreen },
            set: { if !$0, session.voiceActive { session.dismissVoice() } })) {
            VoiceAssistantView(session: session).presentationBackground(.clear)
        }
    }
}

/// The home mic: the voice screen opens over the map, and the route panel follows once there is
/// something to show there — routes, a question, or the typing sheet.
struct HomeVoiceHost: ViewModifier {
    @ObservedObject var session: JourneyAssistantSession
    let enabled: Bool
    let openPanel: (_ forSheet: Bool) -> Void
    @State private var plannedAtStart = 0
    func body(content: Content) -> some View {
        content
            .modifier(VoiceAssistantPresenter(session: session, enabled: enabled))
            .onChange(of: session.voiceActive) { _, active in
                if active { plannedAtStart = session.plannedCount; return }
                guard enabled, session.plannedCount != plannedAtStart else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { openPanel(false) }
            }
            .onChange(of: session.presented) { _, presented in
                guard presented, enabled else { return }
                session.presented = false
                session.reopenSheetInPanel = true
                openPanel(true)
            }
    }
}

/// One full screen for speaking a trip: it asks for the microphone in its own words, moves with
/// the voice, shows the words as they are heard and a countdown before it stops by itself,
/// shimmers while the sentence is understood, asks about online understanding in place, and
/// ends with a check mark as the routes appear.
struct VoiceAssistantView: View {
    @ObservedObject var session: JourneyAssistantSession
    @ObservedObject private var speech: SpeechInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var shown = false
    init(session: JourneyAssistantSession) { self.session = session; speech = session.speech }
    private var phase: VoicePhase { session.voicePhase }
    private var mood: VoiceOrb.Mood { session.voiceMood }
    private var statusText: String { session.voiceStatus }
    private var title: String { session.voiceTitle }
    private var detail: String { session.voiceDetail }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 8)
                VoiceOrb(mood: mood, level: speech.meter, reduceMotion: reduceMotion)
                    .frame(width: 250, height: 250)
                    .scaleEffect(shown ? 1 : 0.55)
                    .contentShape(Circle())
                    .onTapGesture(perform: orbTapped)
                    .accessibilityHidden(true)
                message
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .top)
                Spacer(minLength: 8)
                controls.padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 24)
        }
        .onAppear { reveal(true) }
        .onChange(of: session.voiceClosing) { _, closing in reveal(!closing) }
        .onChange(of: phase) { old, new in feedback(from: old, to: new) }
        .onChange(of: speech.transcript.isEmpty) { _, empty in
            if !empty { Haptics.selection() }   // the first words were heard
        }
        .onChange(of: scenePhase) { _, value in
            // Back from Settings with both permissions on: start listening right away.
            if value == .active, phase == .blocked, SpeechInput.permission == .granted { session.listen() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-assistant")
    }

    private func reveal(_ visible: Bool) {
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.2)
            : visible ? .spring(response: 0.5, dampingFraction: 0.82) : .easeIn(duration: 0.24)
        withAnimation(animation) { shown = visible }
    }

    // MARK: Pieces

    private var tint: Color {
        switch mood {
        case .calm, .listening: Color(red: 0.36, green: 0.42, blue: 1)
        case .thinking: Color(red: 0.55, green: 0.36, blue: 1)
        case .done: Color(red: 0.2, green: 0.78, blue: 0.5)
        case .warning: Color(red: 1, green: 0.55, blue: 0.2)
        }
    }
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(uiColor: .systemBackground).opacity(0.45)
            RadialGradient(colors: [tint.opacity(0.32), tint.opacity(0)], center: UnitPoint(x: 0.5, y: 0.36),
                           startRadius: 10, endRadius: 420)
                .animation(.easeInOut(duration: 0.6), value: mood)
        }
        .ignoresSafeArea()
        .opacity(shown ? 1 : 0)
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 8) {
                statusIcon
                Text(statusText).font(.footnote.weight(.semibold)).contentTransition(.opacity)
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(.thinMaterial, in: Capsule())
            .animation(.snappy, value: phase)
            .accessibilityIdentifier("voice-status")
            HStack {
                Spacer()
                Button { session.dismissVoice() } label: {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                        .frame(width: 40, height: 40).background(.thinMaterial, in: Circle())
                }
                .buttonStyle(VoicePressStyle()).foregroundStyle(.primary)
                .accessibilityLabel(AppText.text("關閉")).accessibilityIdentifier("voice-close")
            }
        }
        .padding(.top, 8)
    }
    @ViewBuilder private var statusIcon: some View {
        switch phase {
        case .listening: LiveDot(reduceMotion: reduceMotion)
        case .preparing, .understanding: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .blocked, .problem: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .permission: Image(systemName: "mic.fill").foregroundStyle(.tint)
        case .consent: Image(systemName: "sparkles").foregroundStyle(.tint)
        }
    }

    private var message: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(phase == .listening && !speech.transcript.isEmpty ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(phase == .preparing || (phase == .listening && speech.transcript.isEmpty) ? .secondary : .primary)
                .multilineTextAlignment(.center).lineLimit(5).minimumScaleFactor(0.75)
                .modifier(Shimmer(active: phase == .understanding && !reduceMotion))
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.18), value: title)
                .accessibilityIdentifier("voice-headline")
            if !detail.isEmpty {
                Text(detail)
                    .font(phase == .consent ? .footnote : .subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.18), value: detail)
            }
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        switch phase {
        case .permission:
            choices(AppText.text("允許並開始說話"), "voice-allow", primary: { session.allowVoice() })
        case .blocked:
            choices(AppText.text("打開設定"), "voice-settings", primary: {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            })
        case .consent:
            choices(AppText.text("使用線上理解"), "voice-consent-yes", primary: { session.answerConsent(true) },
                    secondary: AppText.text("只在手機上理解"), secondaryID: "voice-consent-no", other: { session.answerConsent(false) })
        case .problem:
            choices(AppText.text("再說一次"), "voice-retry", primary: { session.listen() })
        case .preparing, .listening, .understanding, .done:
            HStack(alignment: .top) {
                side("keyboard", AppText.text("打字"), "voice-type") { session.typeInstead() }
                Spacer(minLength: 0)
                mainButton
                Spacer(minLength: 0)
                side("arrow.counterclockwise", AppText.text("重說"), "voice-restart") { session.listen() }
                    .disabled(phase != .listening)
            }
            .padding(.horizontal, 8)
            .opacity(phase == .done ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: phase)
        }
    }
    /// Full-width answer for a question; 「改用打字」 is always the other way out.
    private func choices(_ title: String, _ id: String, primary: @escaping () -> Void,
                         secondary: String? = nil, secondaryID: String = "voice-type", other: (() -> Void)? = nil) -> some View {
        VStack(spacing: 6) {
            Button(action: primary) {
                Text(title).font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 54)
                    .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
            }
            .buttonStyle(VoicePressStyle()).accessibilityIdentifier(id)
            Button { if let other { other() } else { session.typeInstead() } } label: {
                Text(secondary ?? AppText.text("改用打字")).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(VoicePressStyle()).foregroundStyle(.secondary).accessibilityIdentifier(secondaryID)
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    private func side(_ symbol: String, _ label: String, _ id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
                    .frame(width: 56, height: 56).background(.thinMaterial, in: Circle())
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(VoicePressStyle()).foregroundStyle(.primary)
        .accessibilityLabel(label).accessibilityIdentifier(id)
    }
    /// 說完了: a ring fills while a pause is timed, so stopping by itself is never a surprise.
    private var mainButton: some View {
        Button {
            Haptics.stage()
            speech.finish()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.accentColor).frame(width: 76, height: 76)
                        .shadow(color: Color.accentColor.opacity(0.45), radius: 14, y: 4)
                    if phase == .listening {
                        Image(systemName: "checkmark").font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        ProgressView().tint(.white).transition(.opacity)
                    }
                    SilenceRing(since: speech.silenceSince, length: speech.silenceLength)
                        .frame(width: 90, height: 90)
                }
                .frame(width: 92, height: 92)
                Text(AppText.text("說完了")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(VoicePressStyle())
        .disabled(phase != .listening)
        .accessibilityLabel(AppText.text("說完了")).accessibilityIdentifier("voice-done")
    }

    private func orbTapped() {
        switch phase {
        case .listening: Haptics.stage(); speech.finish()
        case .permission: session.allowVoice()
        case .problem: session.listen()
        default: break
        }
    }
    private func feedback(from old: VoicePhase, to new: VoicePhase) {
        switch new {
        case .understanding where old == .listening: Haptics.heard()
        case .problem, .blocked: Haptics.warning()
        case .consent: Haptics.prompt()
        default: break
        }
    }
}

/// Fills while silence is timed after the words; empties when the voice starts again. One linear
/// animation per pause, run by the render server, instead of redrawing every frame.
private struct SilenceRing: View {
    let since: Date?
    let length: Double
    @State private var progress: Double = 0
    var body: some View {
        Circle().trim(from: 0, to: progress)
            .stroke(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .opacity(since == nil ? 0 : 1)
            .allowsHitTesting(false)
            .onChange(of: since, initial: true) { _, start in
                var reset = Transaction(); reset.disablesAnimations = true
                withTransaction(reset) { progress = 0 }
                guard start != nil else { return }
                withAnimation(.linear(duration: max(length, 0.1))) { progress = 1 }
            }
    }
}

/// A red dot that breathes while the microphone is on.
private struct LiveDot: View {
    let reduceMotion: Bool
    @State private var on = false
    var body: some View {
        Circle().fill(Color.red).frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.red.opacity(0.5), lineWidth: 2).scaleEffect(on ? 2.2 : 1).opacity(on ? 0 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true }
            }
    }
}

/// A light that sweeps across text while it is being understood.
private struct Shimmer: ViewModifier {
    let active: Bool
    @State private var sweep = false
    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content.overlay {
                GeometryReader { box in
                    LinearGradient(colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: box.size.width * 0.45)
                        .offset(x: sweep ? box.size.width : -box.size.width * 0.45)
                }
                .mask { content }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
            .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { sweep = true } }
        } else {
            content
        }
    }
}

struct VoicePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Soft colour that turns calmly, swells with the voice, spins faster while thinking and turns
/// green when done; a glass core carries the symbol. Built like Siri's orb: the blurred colour is
/// drawn once and only rotated and scaled after that, so the render server animates it and the
/// app never redraws it frame by frame.
struct VoiceOrb: View {
    enum Mood: Equatable { case calm, listening, thinking, done, warning }
    let mood: Mood
    var level: VoiceLevel = .silent
    var reduceMotion = false
    /// The small orb in cards and on the search screen.
    var compact = false
    @State private var spin = false
    @State private var breathe = false

    static func colors(_ mood: Mood) -> [Color] {
        switch mood {
        case .calm, .listening:
            [Color(red: 0.28, green: 0.48, blue: 1), Color(red: 0.66, green: 0.36, blue: 1),
             Color(red: 0.18, green: 0.82, blue: 0.96), Color(red: 1, green: 0.42, blue: 0.74)]
        case .thinking:
            [Color(red: 0.42, green: 0.3, blue: 1), Color(red: 0.78, green: 0.36, blue: 0.98),
             Color(red: 0.2, green: 0.7, blue: 1), Color(red: 0.5, green: 0.9, blue: 0.95)]
        case .done:
            [Color(red: 0.16, green: 0.78, blue: 0.46), Color(red: 0.3, green: 0.9, blue: 0.75),
             Color(red: 0.1, green: 0.66, blue: 0.6), Color(red: 0.55, green: 0.92, blue: 0.5)]
        case .warning:
            [Color(red: 1, green: 0.58, blue: 0.2), Color(red: 1, green: 0.74, blue: 0.28),
             Color(red: 0.96, green: 0.4, blue: 0.3), Color(red: 1, green: 0.66, blue: 0.4)]
        }
    }
    private var symbol: String {
        switch mood {
        case .calm: "mic.fill"
        case .listening: "waveform"
        case .thinking: "sparkles"
        case .done: "checkmark"
        case .warning: "exclamationmark"
        }
    }

    var body: some View {
        GeometryReader { box in
            let side = min(box.size.width, box.size.height)
            let colors = Self.colors(mood)
            ZStack {
                // Two layers of blurred colour turning opposite ways read as moving liquid.
                Circle().fill(AngularGradient(colors: colors + [colors[0]], center: .center))
                    .frame(width: side * 0.78, height: side * 0.78)
                    // Room for the blur inside the flattened layer, or its edges show as a square.
                    .padding(side * 0.25)
                    .blur(radius: side * (compact ? 0.08 : 0.12))
                    .drawingGroup()
                    .rotationEffect(.degrees(spin ? 360 : 0))
                Circle().fill(AngularGradient(colors: Array(colors.reversed()) + [colors[colors.count - 1]], center: .center))
                    .frame(width: side * 0.6, height: side * 0.6)
                    .padding(side * 0.2)
                    .blur(radius: side * (compact ? 0.06 : 0.1))
                    .drawingGroup()
                    .rotationEffect(.degrees(spin ? -540 : 0))
                    .opacity(0.75)
                Circle().fill(RadialGradient(colors: [.white.opacity(0.85), .white.opacity(0)], center: .center,
                                             startRadius: 0, endRadius: side * 0.3))
                    .frame(width: side * 0.6, height: side * 0.6)
                    .blendMode(.plusLighter)
                Circle().fill(.white.opacity(0.16))
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: compact ? 0.5 : 1))
                    .frame(width: side * (compact ? 0.5 : 0.34), height: side * (compact ? 0.5 : 0.34))
                Image(systemName: symbol)
                    .font(.system(size: side * (compact ? 0.24 : 0.13), weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: mood == .listening && !reduceMotion)
                    .symbolEffect(.pulse, options: .repeating, isActive: mood == .thinking && !reduceMotion)
                    .symbolEffect(.bounce, value: mood == .done)
                    .contentTransition(.symbolEffect(.replace))
            }
            .modifier(VoiceSwell(level: level, amount: mood == .listening ? 0.22 : 0))
            .scaleEffect(breathe ? 1.03 : 0.97)
            .frame(width: box.size.width, height: box.size.height)
        }
        .animation(.easeInOut(duration: 0.45), value: mood)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: compact ? 9 : 6).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Scales with the voice; only this small view follows the microphone level.
private struct VoiceSwell: ViewModifier {
    @ObservedObject var level: VoiceLevel
    let amount: Double
    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + amount * level.value)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: level.value)
    }
}

/// The way in on the search screen: tap once and say where to go.
struct VoiceStartCard: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            Haptics.stage()
            action()
        } label: {
            HStack(spacing: 14) {
                VoiceOrb(mood: .calm, reduceMotion: reduceMotion, compact: true).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppText.text("按一下，說出要去哪裡")).font(.headline).foregroundStyle(.primary)
                    Text(AppText.text("例如：明天九點前到台大、騎單車去101")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, Metrics.gap).padding(.leading, Metrics.inset - 4).padding(.trailing, Metrics.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemFill).opacity(0.6), in: MapChrome.shape(.panel))
            .overlay(
                MapChrome.shape(.panel)
                    .strokeBorder(LinearGradient(colors: [Color(red: 0.28, green: 0.48, blue: 1).opacity(0.6),
                                                          Color(red: 0.66, green: 0.36, blue: 1).opacity(0.5),
                                                          Color(red: 0.18, green: 0.82, blue: 0.96).opacity(0.5)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            .contentShape(MapChrome.shape(.panel))
        }
        .buttonStyle(VoicePressStyle())
        .accessibilityLabel(AppText.text("用說的規劃"))
        .accessibilityIdentifier("journey-voice")
    }
}

// MARK: - Edge glow

/// A window above the app for the edge glow. Only the card takes touches; everything else falls
/// through to the map and panels underneath.
private final class VoicePassthroughWindow: UIWindow {
    var touchableArea: CGRect = .zero
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { touchableArea.contains(point) }
}

@MainActor
final class VoiceGlowOverlay {
    static let shared = VoiceGlowOverlay()
    private var window: VoicePassthroughWindow?
    func show(_ session: JourneyAssistantSession) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = VoicePassthroughWindow(windowScene: scene)
        // Above the app and its sheets, below the app's own alerts.
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: VoiceGlowView(session: session) { [weak window] area in
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

/// The glow around the screen edge, Apple Intelligence style: colours circle the edge, brighten
/// with the voice and turn green when done. The blurred edge masks are drawn once; the colour
/// under them only rotates, and the voice only changes opacity, so the render server animates
/// everything and the main thread stays free.
struct EdgeGlow: View {
    let mood: VoiceOrb.Mood
    var level: VoiceLevel = .silent
    var reduceMotion = false
    /// For the small preview in Settings: its own corner and thinner, tighter glow.
    var corner: CGFloat?
    var scale: CGFloat = 1
    @State private var spin = false
    @State private var pulse = false
    var body: some View {
        GeometryReader { box in
            // Rounded like the display on Face ID iPhones; the blur hides small differences.
            let corner: CGFloat = self.corner ?? (box.safeAreaInsets.bottom > 0 ? 54 : 0)
            let width = box.size.width + box.safeAreaInsets.leading + box.safeAreaInsets.trailing
            let height = box.size.height + box.safeAreaInsets.top + box.safeAreaInsets.bottom
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            let colors = VoiceOrb.colors(mood)
            let wheel = Rectangle()
                .fill(AngularGradient(colors: colors + [colors[0]], center: .center))
                .frame(width: hypot(width, height), height: hypot(width, height))
                .rotationEffect(.degrees(spin ? 360 : 0))
                .frame(width: width, height: height)
            ZStack {
                // Wide soft glow: follows the voice.
                wheel.mask { shape.strokeBorder(lineWidth: 56 * scale).blur(radius: 34 * scale).drawingGroup() }
                    .modifier(GlowLevel(level: level, mood: mood))
                // Middle glow: breathes while thinking.
                wheel.mask { shape.strokeBorder(lineWidth: 18 * scale).blur(radius: 10 * scale).drawingGroup() }
                    .opacity(mood == .thinking ? (pulse ? 1 : 0.55) : 0.9)
                // Crisp edge.
                wheel.mask { shape.strokeBorder(lineWidth: max(1.5, 3 * scale)) }
            }
            .compositingGroup()
            .frame(width: width, height: height)
            .offset(x: -box.safeAreaInsets.leading, y: -box.safeAreaInsets.top)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.5), value: mood)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// The wide glow's brightness: the voice while listening, steady otherwise.
private struct GlowLevel: ViewModifier {
    @ObservedObject var level: VoiceLevel
    let mood: VoiceOrb.Mood
    func body(content: Content) -> some View {
        let value: Double = switch mood {
        case .listening: 0.25 + 0.75 * level.value
        case .thinking: 0.7
        case .done: 0.85
        case .warning, .calm: 0.4
        }
        content
            .opacity(value)
            .animation(.easeOut(duration: 0.15), value: level.value)
    }
}

/// The edge-glow assistant: the glow, and one floating card with what was heard and the buttons.
/// The map stays visible and can still be moved while speaking.
struct VoiceGlowView: View {
    @ObservedObject var session: JourneyAssistantSession
    @ObservedObject private var speech: SpeechInput
    let reportCard: (CGRect) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var shown = false
    init(session: JourneyAssistantSession, reportCard: @escaping (CGRect) -> Void) {
        self.session = session; speech = session.speech; self.reportCard = reportCard
    }
    private var phase: VoicePhase { session.voicePhase }

    var body: some View {
        ZStack(alignment: .bottom) {
            EdgeGlow(mood: session.voiceMood, level: speech.meter, reduceMotion: reduceMotion)
                .opacity(shown ? 1 : 0)
                .scaleEffect(shown || reduceMotion ? 1 : 1.04)
            card
                .background(GeometryReader { proxy in
                    Color.clear
                        .onAppear { reportCard(proxy.frame(in: .global)) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in reportCard(frame) }
                })
                .padding(.horizontal, 12).padding(.bottom, 6)
                .offset(y: shown ? 0 : 220)
                .opacity(shown ? 1 : 0)
        }
        .onAppear { reveal(true) }
        .onChange(of: session.voiceClosing) { _, closing in reveal(!closing) }
        .onChange(of: phase) { old, new in
            switch new {
            case .understanding where old == .listening: Haptics.heard()
            case .problem, .blocked: Haptics.warning()
            case .consent: Haptics.prompt()
            default: break
            }
        }
        .onChange(of: speech.transcript.isEmpty) { _, empty in if !empty { Haptics.selection() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Back from Settings with both permissions on: start listening right away.
            if phase == .blocked, SpeechInput.permission == .granted { session.listen() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-assistant")
    }

    private func reveal(_ visible: Bool) {
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.2)
            : visible ? .spring(response: 0.45, dampingFraction: 0.8) : .easeIn(duration: 0.24)
        withAnimation(animation) { shown = visible }
    }

    private struct Choice {
        let primary: String, id: String, action: () -> Void
        var secondary: String? = nil
        var secondaryID = "voice-type"
        let other: () -> Void
    }
    private var choices: Choice? {
        let session = session
        let typing: () -> Void = { session.typeInstead() }
        switch phase {
        case .permission:
            return Choice(primary: AppText.text("允許並開始說話"), id: "voice-allow", action: { session.allowVoice() }, other: typing)
        case .blocked:
            let openURL = openURL
            return Choice(primary: AppText.text("打開設定"), id: "voice-settings", action: {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }, other: typing)
        case .consent:
            return Choice(primary: AppText.text("使用線上理解"), id: "voice-consent-yes", action: { session.answerConsent(true) },
                          secondary: AppText.text("只在手機上理解"), secondaryID: "voice-consent-no", other: { session.answerConsent(false) })
        case .problem:
            return Choice(primary: AppText.text("再說一次"), id: "voice-retry", action: { session.listen() }, other: typing)
        default:
            return nil
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VoiceOrb(mood: session.voiceMood, level: speech.meter, reduceMotion: reduceMotion, compact: true)
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.voiceStatus).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .contentTransition(.opacity).accessibilityIdentifier("voice-status")
                    Text(session.voiceTitle)
                        .font(.body.weight(phase == .listening && !speech.transcript.isEmpty ? .semibold : .regular))
                        .foregroundStyle(phase == .preparing || (phase == .listening && speech.transcript.isEmpty) ? .secondary : .primary)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                        .modifier(Shimmer(active: phase == .understanding && !reduceMotion))
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.18), value: session.voiceTitle)
                        .accessibilityIdentifier("voice-headline")
                }
                Spacer(minLength: 0)
                trailing
            }
            if choices != nil || [.understanding, .consent].contains(phase), !session.voiceDetail.isEmpty {
                Text(session.voiceDetail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            if let choices {
                HStack(spacing: 10) {
                    Button(action: choices.other) {
                        Text(choices.secondary ?? AppText.text("改用打字")).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(VoicePressStyle()).foregroundStyle(.primary).accessibilityIdentifier(choices.secondaryID)
                    Button(action: choices.action) {
                        Text(choices.primary).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                    }
                    .buttonStyle(VoicePressStyle()).accessibilityIdentifier(choices.id)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: MapChrome.shape(.card))
        .overlay(MapChrome.shape(.card).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: phase)
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 8) {
            if phase == .listening || phase == .preparing {
                Button { session.typeInstead() } label: {
                    Image(systemName: "keyboard").font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 38).background(.thinMaterial, in: Circle())
                }
                .buttonStyle(VoicePressStyle()).foregroundStyle(.primary)
                .accessibilityLabel(AppText.text("改用打字")).accessibilityIdentifier("voice-type")
                Button {
                    Haptics.stage()
                    speech.finish()
                } label: {
                    ZStack {
                        Circle().fill(Color.accentColor).frame(width: 42, height: 42)
                        Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        SilenceRing(since: speech.silenceSince, length: speech.silenceLength).frame(width: 50, height: 50)
                    }
                    .frame(width: 50, height: 50)
                }
                .buttonStyle(VoicePressStyle())
                .disabled(phase != .listening)
                .accessibilityLabel(AppText.text("說完了")).accessibilityIdentifier("voice-done")
            }
            if phase != .done {
                Button { session.dismissVoice() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30).background(.thinMaterial, in: Circle())
                }
                .buttonStyle(VoicePressStyle()).foregroundStyle(.secondary)
                .accessibilityLabel(AppText.text("關閉")).accessibilityIdentifier("voice-close")
            }
        }
    }
}

/// Settings › 語音與 AI: the two styles as live miniature phones, side by side. Tap one to use it.
struct VoiceStylePicker: View {
    @Binding var selection: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(VoiceStyle.allCases) { style in
                option(style)
            }
        }
        .padding(.vertical, Metrics.tight)
    }
    private func option(_ style: VoiceStyle) -> some View {
        let chosen = selection == style.rawValue
        return Button {
            guard !chosen else { return }
            Haptics.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = style.rawValue }
        } label: {
            VStack(spacing: 10) {
                preview(style)
                    .frame(height: 190)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(chosen ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: chosen ? 2.5 : 1)
                    )
                    .scaleEffect(chosen ? 1 : 0.96)
                    .opacity(chosen ? 1 : 0.75)
                HStack(spacing: 6) {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(style.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                }
                Text(style.detail).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("voice-style-" + style.rawValue)
    }

    /// A small phone: a calm map, then the style drawn on top of it.
    @ViewBuilder private func preview(_ style: VoiceStyle) -> some View {
        let phone = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack {
            MiniMap()
            switch style {
            case .glow:
                EdgeGlow(mood: .listening, reduceMotion: reduceMotion, corner: 22, scale: 0.28)
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        VoiceOrb(mood: .listening, reduceMotion: reduceMotion, compact: true).frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Capsule().fill(Color.primary.opacity(0.35)).frame(width: 34, height: 4)
                            Capsule().fill(Color.primary.opacity(0.6)).frame(width: 52, height: 5)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(7)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(8)
                }
            case .fullScreen:
                Rectangle().fill(.ultraThinMaterial)
                Color(uiColor: .systemBackground).opacity(0.45)
                VStack(spacing: 10) {
                    Spacer()
                    VoiceOrb(mood: .listening, reduceMotion: reduceMotion, compact: true).frame(width: 52, height: 52)
                    Capsule().fill(Color.primary.opacity(0.6)).frame(width: 58, height: 5)
                    Capsule().fill(Color.primary.opacity(0.3)).frame(width: 40, height: 4)
                    Spacer()
                    Capsule().fill(Color.accentColor).frame(width: 64, height: 12)
                        .padding(.bottom, 14)
                }
            }
        }
        .clipShape(phone)
        .compositingGroup()
    }
}

/// A few quiet streets and a park, so the previews look like the map screen.
private struct MiniMap: View {
    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.18))
                .frame(width: 46, height: 38).offset(x: -18, y: -30)
            Path { path in
                path.move(to: CGPoint(x: -10, y: 40)); path.addLine(to: CGPoint(x: 200, y: 110))
                path.move(to: CGPoint(x: 60, y: -10)); path.addLine(to: CGPoint(x: 30, y: 220))
                path.move(to: CGPoint(x: -10, y: 150)); path.addLine(to: CGPoint(x: 200, y: 130))
            }
            .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Circle().fill(Color.blue).frame(width: 7, height: 7)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .offset(x: 6, y: 4)
        }
    }
}
