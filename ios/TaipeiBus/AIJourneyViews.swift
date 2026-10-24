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
    /// The sheet: typing from scratch, or something only the rider can answer.
    @Published var presented = false
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
        cancel(); input = ""; prepare(); presented = true
    }
    /// One tap, then speak: understanding starts when the rider stops talking. On the route screen
    /// (`refining`), what is said changes the trip shown instead of starting a new one.
    func listen(refining: Bool = false) {
        guard unavailable == nil else { presented = true; return }
        cancel(); prepare()
        Task { await speech.start { [weak self] text in if refining { self?.refine(text) } else { self?.run(text) } } }
    }

    /// 「改騎車」, 「晚一點」, 「不要搭公車」, 「改去101」 for the trip on screen. The online model reads the
    /// change with the trip described in words; the rules fill what it leaves out or read it alone.
    func refine(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 300 else { return }
        guard let trip = model.currentAssistantTrip else { run(value); return }
        if OnlineJourneyReader.needsConsent {
            speech.stop(); waitingForConsent = value; waitingToRefine = true; askingConsent = true
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        plannedCount += 1
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
        guard unavailable == nil else { input = value; presented = true; return }
        guard !value.isEmpty, value.count <= 600 else { return }
        if OnlineJourneyReader.needsConsent {
            speech.stop(); waitingForConsent = value; input = value; askingConsent = true
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
    func cancel() {
        operation?.cancel(); deadlineTask?.cancel(); search.cancel(); speech.stop()
        busy = false; clarification = nil; problem = nil; message = nil; conversation = nil; turn = nil
        fixResults = []; fixSearching = false; pendingNext = nil
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
        if let trip = pendingNext { pendingNext = nil; planNext(trip, to: place); return }
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
        message = text; presented = true
    }
    private func receive(_ result: AssistantJourneyTurn) {
        turn = result; busy = false
        clarification = result.clarification
        if result.clarification != nil { presented = true } else { planRightAway() }
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        conversation = nil; clarification = nil; problem = nil; message = nil
        presented = false; input = ""; plannedCount += 1
    }
    /// Whether a found place is what the words named (台大機械館 matches 機械工程學系館, not 圖書館).
    static func matches(_ place: TravelPlace, _ words: String) -> Bool {
        let text = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, JourneyAssistantContext.category(of: text) == nil else { return true }
        return StationSearch.placeRank(name: place.name, address: place.address, query: text) != nil
    }

    /// 接著去: plans the second stop from where the first leg ends.
    func continueTrip() {
        guard let trip = model.assistantTrip, let next = trip.nextStop, !busy else { return }
        busy = true; source = AppText.text("接著去%@", next); startedAt = Date(); activity = AppText.text("正在搜尋地點…")
        search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
        search.setContext(trip.destination.coordinate)
        operation = Task { @MainActor in
            let found = ((try? await search.find(text: next, queryLimit: 3)) ?? []).filter { $0.coordinate.isInServiceArea }
            guard !Task.isCancelled else { return }
            busy = false
            if let place = found.first(where: { Self.matches($0, next) }) {
                planNext(trip, to: place, alternatives: found)
            } else {
                // Not sure which place: the rider picks, then the leg is planned from the first stop.
                pendingNext = trip; turn = nil; input = source
                problem = .destination(next); fixQuery = next; fixResults = Array(found.prefix(6)); presented = true
            }
        }
    }
    private var pendingNext: TransitAppModel.AssistantTrip?
    private func planNext(_ trip: TransitAppModel.AssistantTrip, to place: TravelPlace, alternatives: [TravelPlace] = []) {
        JourneyDiagnostics.shared.record("ai-plan next")
        model.previewAssistantJourney(request: AppText.text("接著去%@", trip.nextStop ?? place.localizedName), origin: trip.destination,
                                      destination: place, alternatives: Array(alternatives.filter { $0.id != place.id }.prefix(3)),
                                      preference: trip.preference, mode: trip.mode)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        problem = nil; message = nil; presented = false; input = ""; plannedCount += 1
    }
    private func stop(_ reason: Problem) {
        JourneyDiagnostics.shared.record("ai-plan stopped=\(reason.isOrigin ? "origin" : "destination")\(reason.unsaved ? "-unsaved" : "")")
        problem = reason; fixResults = []; presented = true
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
        if speech.listening, !session.presented {
            HStack(spacing: 12) {
                Image(systemName: "waveform").foregroundStyle(.tint).symbolEffect(.variableColor.iterative)
                Text(speech.transcript.isEmpty ? AppText.text("請說出要去哪裡…") : speech.transcript)
                    .font(.subheadline).lineLimit(3)
                Spacer(minLength: 0)
                Button(AppText.text("完成")) { speech.finish() }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            .padding(12).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
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
            .padding(12).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
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
                    if speech.listening { speech.finish() } else { inputFocused = false; session.listen() }
                } label: {
                    Image(systemName: speech.listening ? "stop.circle.fill" : "mic.fill")
                        .font(.title3).frame(width: 44, height: 44)
                }.buttonStyle(.borderless).disabled(session.busy)
                    .accessibilityLabel(speech.listening ? AppText.text("停止聆聽") : AppText.text("用說的"))
                    .accessibilityIdentifier("ai-voice")
            }
            if speech.listening {
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
        .padding(.horizontal, 12).frame(minHeight: 34)
        .foregroundStyle(tint ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .background(tint ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)), in: Capsule())
        .contentShape(Capsule())
    }

    var body: some View {
        let trip = model.currentAssistantTrip
        VStack(alignment: .leading, spacing: 8) {
            if let trip { requestRow(trip) }
            // Chips wrap onto a second line rather than hiding off the edge.
            ChipFlow(spacing: 8) {
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
                .padding(10).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("journey-comparison")
            }
            if let trip, let next = trip.nextStop {
                // The second stop is the next step of this trip: its own clear button, not one more chip.
                Button { session.continueTrip() } label: {
                    Label(AppText.text("接著去%@", next), systemImage: "arrow.turn.down.right")
                        .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).foregroundStyle(.tint).accessibilityIdentifier("assistant-trip-next")
            }
            footnotes(trip)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(trip == nil ? "journey-conditions" : "assistant-trip")
        .sheet(isPresented: $choosingTime) { timeSheet }
        // A comparison belongs to the routes it compared.
        .onChange(of: planner.options.map(\.id)) { _, _ in comparison = nil }
    }

    // MARK: Parts

    private func requestRow(_ trip: TransitAppModel.AssistantTrip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.caption).foregroundStyle(.tint).accessibilityHidden(true)
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
            return "\(index + 1). \(name)\(label)：共 \(Int(timing.totalSeconds / 60)) 分，走路 \(walk) 分，候車 \(Int(timing.waitingSeconds / 60)) 分，轉乘 \(max(0, option.rides.count - 1)) 次，\(timing.expectedArrivalLabel)"
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
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
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
        if planner.scheduledDeparture != nil {
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
            get: { session.askingConsent && session.presented == inSheet },
            set: { if !$0, session.askingConsent { session.answerConsent(false) } })) {
            Button(AppText.text("使用線上理解")) { session.answerConsent(true) }
            Button(AppText.text("只在手機上理解"), role: .cancel) { session.answerConsent(false) }
        } message: {
            Text(AppText.text("為了更準確，你說或打的那一句話、今天日期，以及需要時搜尋到的地點名稱與地址，會傳給 Groq 上的開源模型（OpenAI gpt-oss）讀懂，不包含位置、常用行程或帳號，App 不保存。沒有網路時改用手機上的理解。之後可在資訊與設定更改。"))
        }
    }
}

/// Lays chips out left to right and wraps them onto further lines.
struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
