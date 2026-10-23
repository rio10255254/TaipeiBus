import SwiftUI
import TransitCore

/// 用一句話規劃: type or say one sentence and the route search starts. The sheet stays open only
/// for the few cases it cannot settle by itself: several saved journeys, a place that was not found,
/// or no current location.
struct AIJourneyAssistantView: View {
    @ObservedObject var model: TransitAppModel
    /// A sentence already typed in the search box or said to Siri; it is understood at once.
    var seed: String? = nil
    /// Opened from the microphone button: start listening at once.
    var listen = false
    let planned: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearch()
    @StateObject private var speech = SpeechInput()
    @ObservedObject private var recents = AssistantRecents.shared
    @FocusState private var inputFocused: Bool
    @FocusState private var fixFocused: Bool
    @State private var input = ""
    @State private var clarification: AssistantClarification?
    @State private var conversation: (any JourneyAssistantConversation)?
    @State private var turn: AssistantJourneyTurn?
    @State private var problem: Problem?
    @State private var fixQuery = ""
    @State private var fixResults: [TravelPlace] = []
    @State private var fixSearching = false
    @State private var saveFix = true
    /// Places the rider picked after a problem, kept while another one is fixed.
    @State private var chosenDestination: TravelPlace?
    @State private var chosenOrigin: TravelPlace?
    @State private var busy = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var deadlineTask: Task<Void, Never>?
    @State private var prepared: (context: JourneyAssistantContext, conversation: any JourneyAssistantConversation)?
    @State private var activity = AppText.text("正在理解你的需求…")
    @State private var startedAt = Date()
    @State private var activeContext: JourneyAssistantContext?
    @State private var arrival: (origin: TravelPlace, destination: TravelPlace, target: FutureTripTime)?
    @State private var showingArrival = false
    /// The on-device model can be slow, but the screen must never wait indefinitely.
    private static let timeLimit: Double = 45

    /// What stopped planning, and what the rider can do about it.
    private enum Problem: Equatable {
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

    private var unavailable: String? { OnDeviceJourneyAssistant.unavailableReason() }
    private var currentPlace: TravelPlace? {
        model.location.usableCoordinate.flatMap { point in
            point.isInServiceArea ? TravelPlace(name: AppText.text("目前位置"), address: "", coordinate: point) : nil
        }
    }
    private var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if let unavailable {
                    Section {
                        Text(unavailable).accessibilityIdentifier("ai-unavailable")
                        Button(AppText.text("返回手動搜尋")) { dismiss() }.accessibilityIdentifier("ai-manual-search")
                    }
                } else {
                    requestSection
                    if trimmed.isEmpty, !busy, !speech.listening, problem == nil { examplesSection }
                    if busy { progressSection }
                    if let clarification { clarificationSection(clarification) }
                    if let problem { problemSection(problem) }
                    if let message { Section { Text(message).accessibilityIdentifier("ai-error") } }
                }
            }
            .navigationTitle(AppText.text("用一句話規劃")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppText.text("關閉")) { dismiss() } } }
            .navigationDestination(isPresented: $showingArrival) {
                if let arrival {
                    ArrivalJourneyView(metadata: model.metadata, origin: arrival.origin, destination: arrival.destination,
                        target: arrival.target, preferences: preference.applying(to: model.liveSettings.planning))
                }
            }
        }
        .onChange(of: input) { _, _ in
            guard !busy else { return }
            clarification = nil; conversation = nil; problem = nil; message = nil
        }
        .onAppear {
            prepare()
            if let seed, !seed.isEmpty { input = seed; extract() }
            else if listen { startListening() }
            else { inputFocused = true }
        }
        .onDisappear { operation?.cancel(); deadlineTask?.cancel(); search.cancel(); speech.stop(); conversation = nil; prepared = nil }
    }

    // MARK: Sections

    private var requestSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField(AppText.text("例如：騎單車去台大、明天 9 點前到公司"), text: $input)
                    .focused($inputFocused).submitLabel(.go).onSubmit { extract() }
                    .disabled(busy || speech.listening)
                    .accessibilityIdentifier("ai-request")
                Button { speech.listening ? speech.finish() : startListening() } label: {
                    Image(systemName: speech.listening ? "stop.circle.fill" : "mic.fill")
                        .font(.title3).frame(width: 44, height: 44)
                }.buttonStyle(.borderless).disabled(busy)
                    .accessibilityLabel(speech.listening ? AppText.text("停止聆聽") : AppText.text("用說的"))
                    .accessibilityIdentifier("ai-voice")
            }
            if speech.listening {
                Label(speech.transcript.isEmpty ? AppText.text("請說出要去哪裡…") : speech.transcript, systemImage: "waveform")
                    .foregroundStyle(.secondary).accessibilityIdentifier("ai-listening")
            }
            if let issue = speech.problem { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            Button(AppText.text("理解並規劃")) { extract() }
                .disabled(busy || trimmed.isEmpty || trimmed.count > 600)
                .accessibilityIdentifier("ai-extract")
        } footer: {
            Text(AppText.text("說或打一句話就會直接規劃；沒說的就從目前位置、現在出發。文字只在手機上理解，地點與路線由 Apple 地圖處理。"))
        }
    }

    private var examplesSection: some View {
        Section(recents.items.isEmpty ? AppText.text("試試看") : AppText.text("最近說過")) {
            let examples = recents.items.isEmpty ? [AppText.text("回家"), AppText.text("騎單車去台大"), AppText.text("明天 9 點前到台北車站")] : recents.items
            ForEach(examples, id: \.self) { text in
                Button { input = text; extract() } label: { Label(text, systemImage: recents.items.isEmpty ? "sparkles" : "clock") }
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
                Text(activity)
                Spacer()
                TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                    Text(AppText.text("%@ 秒", "\(max(0, Int(timeline.date.timeIntervalSince(startedAt))))"))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }.accessibilityIdentifier("ai-progress")
        }
    }

    private func clarificationSection(_ question: AssistantClarification) -> some View {
        Section(AppText.text("確認你的意思")) {
            Text(question.question).font(.headline)
            ForEach(question.options.indices, id: \.self) { index in
                Button(question.options[index]) { answer(index) }
                    .disabled(busy).accessibilityIdentifier("ai-choice-\(index)")
            }
        }
    }

    private func problemSection(_ problem: Problem) -> some View {
        Section {
            switch problem {
            case .location:
                Text(AppText.text("需要目前位置才能從這裡出發。")).font(.headline)
                Button(AppText.text("開啟定位")) { model.location.request() }
                Button(AppText.text("已開啟，繼續規劃")) { self.problem = nil; planRightAway() }
                    .disabled(currentPlace == nil)
                Text(AppText.text("或輸入出發地：")).font(.footnote).foregroundStyle(.secondary)
            case .unsavedDestination(let word), .unsavedOrigin(let word):
                Text(AppText.text("還沒有儲存「%@」，輸入它的地址或附近地點：", word)).font(.headline)
            case .destination(let word), .origin(let word):
                Text(AppText.text("找不到「%@」，換個說法或選一個地點：", word)).font(.headline)
            }
            HStack {
                TextField(problem.isOrigin ? AppText.text("出發地、地址或站名") : AppText.text("地點、地址或站名"), text: $fixQuery)
                    .focused($fixFocused).submitLabel(.search).onSubmit { findFix() }
                    .accessibilityIdentifier("ai-fix-query")
                if fixSearching { ProgressView() }
            }
            ForEach(fixResults) { place in
                Button { chooseFix(place) } label: {
                    VStack(alignment: .leading) {
                        Text(place.localizedName)
                        if !place.address.isEmpty { Text(place.address).font(.caption).foregroundStyle(.secondary) }
                    }
                }.accessibilityIdentifier("ai-fix-\(place.name)")
            }
            if problem.unsaved, model.purchases.hasPro {
                Toggle(AppText.text("同時儲存為「%@」", problem.keyword), isOn: $saveFix)
            }
        }
    }

    // MARK: Model

    private var preference: RoutePreference {
        turn.flatMap { RoutePreference(rawValue: $0.request.preference.rawValue) } ?? .balanced
    }
    private func makeContext() -> JourneyAssistantContext {
        let vocabulary = model.vocabulary, settings = model.liveSettings.search, revision = model.liveSettings.revision
        let coordinate = model.location.usableCoordinate
        return JourneyAssistantContext(journeys: model.commutes.journeys) { query in
            let toolSearch = PlaceSearch()
            toolSearch.setRules(vocabulary: vocabulary, settings: settings, revision: revision)
            toolSearch.setContext(coordinate)
            return try await toolSearch.find(text: query, queryLimit: 2, timeout: 4)
        }
    }
    /// Starts loading the model while the user types or speaks.
    private func prepare() {
        guard unavailable == nil, prepared == nil else { return }
        let context = makeContext()
        guard let session = try? OnDeviceJourneyAssistant.conversation(context: context) else { return }
        session.prewarm()
        prepared = (context, session)
    }
    private func startListening() {
        inputFocused = false
        Task { await speech.start { text in input = text; extract() } }
    }
    private func track(_ context: JourneyAssistantContext) {
        context.onActivity = { value in
            switch value {
            case .search: activity = AppText.text("正在搜尋地點…")
            case .saved: activity = AppText.text("正在查看常用行程…")
            }
        }
    }
    private func startDeadline(_ step: String, context: JourneyAssistantContext) {
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(Self.timeLimit)) } catch { return }
            guard busy else { return }
            operation?.cancel()
            record(step, outcome: "timeout", context: context)
            busy = false; conversation = nil
            message = AppText.text("手機上的模型這次回應太久，請再試一次，或關閉後直接搜尋。")
        }
    }
    /// Timing and kinds only: no request text, places or answers enter the troubleshooting history.
    private func record(_ step: String, outcome: String, context: JourneyAssistantContext) {
        let searches = context.toolCalls.filter { $0.hasPrefix("searchPlaces") }.count
        let saved = context.toolCalls.filter { $0.hasPrefix("listSavedJourneys") }.count
        JourneyDiagnostics.shared.record(String(format: "ai-%@ %@ %.1fs searches=%d search=%.1fs saved=%d %@",
            step, outcome, Date().timeIntervalSince(startedAt), searches, context.searchSeconds, saved, context.trace))
    }
    private func extract() {
        guard !busy, !trimmed.isEmpty, trimmed.count <= 600 else { return }
        inputFocused = false; speech.stop()
        operation?.cancel(); busy = true; message = nil; clarification = nil; conversation = nil; problem = nil; turn = nil
        chosenDestination = nil; chosenOrigin = nil
        let source = trimmed
        let ready = prepared; prepared = nil
        let context = ready?.context ?? makeContext()
        track(context); activeContext = context
        activity = AppText.text("正在理解你的需求…"); startedAt = Date()
        startDeadline("understand", context: context)
        operation = Task { @MainActor in
            do {
                let session = try ready?.conversation ?? OnDeviceJourneyAssistant.conversation(context: context)
                conversation = session
                let result = try await session.begin(source, at: Date())
                try Task.checkCancellation()
                deadlineTask?.cancel()
                record("understand", outcome: "ok", context: context)
                receive(result)
            } catch {
                guard !Task.isCancelled else { return }
                deadlineTask?.cancel()
                let kind = OnDeviceJourneyAssistant.failureKind(error)
                record("understand", outcome: "error:" + kind, context: context)
                busy = false
                message = AppText.text("這句話暫時無法理解，請換個說法再試，或關閉後直接搜尋。") + "\n(" + kind + ")"
            }
        }
    }
    private func answer(_ index: Int) {
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
                message = AppText.text("這個選擇暫時無法處理，請再試一次。")
            }
        }
    }
    private func receive(_ result: AssistantJourneyTurn) {
        turn = result; busy = false
        clarification = result.clarification
        if result.clarification == nil { planRightAway() }
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
        AssistantRecents.shared.remember(trimmed)
        if let arrive = request.arriveBy, AssistantJourneyRequest.canPlan(arriveBy: arrive), let start = from ?? currentPlace {
            JourneyDiagnostics.shared.record("ai-plan started deadline")
            arrival = (start, target, .arriveBy(arrive)); showingArrival = true
            return
        }
        // A later departure is planned in the ordinary route view, on that day's timetables and headways.
        JourneyDiagnostics.shared.record("ai-plan started mode=\(turn.mode.rawValue)\(turn.departAt == nil ? "" : " departure")")
        let alternatives = chosenDestination == nil ? Array(turn.destinationCandidates.dropFirst()) : []
        model.previewAssistantJourney(request: trimmed, origin: from, destination: target, alternatives: alternatives,
                                      preference: preference, mode: turn.mode, departure: turn.departAt)
        planned(); dismiss()
    }
    private func stop(_ reason: Problem) {
        JourneyDiagnostics.shared.record("ai-plan stopped=\(reason.isOrigin ? "origin" : "destination")\(reason.unsaved ? "-unsaved" : "")")
        problem = reason; fixResults = []
        fixQuery = reason.unsaved || reason == .location ? "" : reason.keyword
        if !fixQuery.isEmpty { findFix() } else { fixFocused = true }
    }
    private func findFix() {
        let text = fixQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
        search.setContext(model.location.usableCoordinate)
        fixSearching = true
        Task { @MainActor in
            let found = (try? await search.find(text: text)) ?? []
            fixResults = Array(found.filter { $0.coordinate.isInServiceArea }.prefix(6))
            fixSearching = false
            if fixResults.isEmpty { message = AppText.text("找不到服務範圍內的地點，請換個關鍵字。") } else { message = nil }
        }
    }
    private func chooseFix(_ place: TravelPlace) {
        guard let problem else { return }
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
}

/// A trip planned for later: by an arrival deadline, or for leaving at a chosen time.
enum FutureTripTime {
    case arriveBy(Date), departAt(Date)
}

private actor ArrivalCandidateSearch {
    func options(metadata: TransitMetadata, origin: Coordinate, destination: Coordinate, at date: Date,
                 preferences: LiveSettings.Planning) -> [TransitTrip] {
        guard !Task.isCancelled else { return [] }
        return MultimodalPlanner(metadata: metadata).plan(from: origin, to: destination,
            maximumWalk: preferences.expandedWalkMeters, limit: 12, preferences: preferences, at: date)
    }
}

private struct ArrivalJourneyView: View {
    let metadata: TransitMetadata
    let origin: TravelPlace
    let destination: TravelPlace
    let target: FutureTripTime
    let preferences: LiveSettings.Planning
    @State private var results: [Result] = []
    @State private var busy = true
    private struct Result: Identifiable { let option: JourneyOption; let timing: ArrivalPlan; var id: String { option.id } }
    private func clock(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = AppLanguage.current.locale
        formatter.timeZone = AssistantJourneyRequest.calendar.timeZone; formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    var body: some View {
        List {
            Section {
                Text(destination.localizedName).font(.headline)
                switch target {
                case .arriveBy(let deadline): Text(AppText.text("抵達期限：%@", clock(deadline)))
                case .departAt(let leave): Text(AppText.text("出發時間：%@", clock(leave)))
                }
                Text(AppText.text("依官方班表、班距與車程資料推估，含 10 分鐘預留；不是保證抵達時間。未使用目前車輛位置或未來車位數量。出發當天請重新搜尋並確認公告。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView(AppText.text("確認步行與班距資料")) }
            ForEach(results) { result in
                Section {
                    if case .arriveBy = target {
                        Text(AppText.text("建議預留出發時間：%@", clock(result.timing.departure))).font(.headline)
                    } else {
                        Text(AppText.text("預計抵達：%@", clock(result.timing.latestArrival))).font(.headline)
                    }
                    Text(AppText.text("推估抵達：%@ 至 %@", clock(result.timing.earliestArrival), clock(result.timing.latestArrival)))
                    Text(result.option.walkingTimeLabel)
                    ForEach(result.option.rides) { ride in
                        VStack(alignment: .leading) {
                            Text(ride.route.localizedName).bold()
                            Text(ride.boarding.localizedName + " → " + ride.alighting.localizedName)
                        }
                    }
                }
            }
            if !busy, results.isEmpty {
                Text(AppText.text("目前資料不足以確認這個時間的行程。請改選時間、查看官方班表，並於出發當天重新規劃。"))
                    .accessibilityIdentifier("ai-arrival-unavailable")
            }
        }.navigationTitle(AppText.text("預排行程參考"))
            .task {
                let planner = JourneyPlannerModel()
                let searchTime: Date
                switch target {
                case .arriveBy(let deadline): searchTime = deadline.addingTimeInterval(-3600)
                case .departAt(let leave): searchTime = leave
                }
                let candidates = await ArrivalCandidateSearch().options(metadata: metadata, origin: origin.coordinate,
                    destination: destination.coordinate, at: searchTime, preferences: preferences)
                var checked: [Result] = []
                for trip in candidates.prefix(6) {
                    guard !Task.isCancelled else { return }
                    var option = planner.option(trip, metadata: metadata, origin: origin, destination: destination)
                    do {
                        for index in option.walks.indices where !option.walks[index].internalTransfer {
                            option.walks[index] = try await planner.checkedWalk(option.walks[index])
                        }
                        try Task.checkCancellation()
                        let walking = option.walks.compactMap(\.duration)
                        let timing: ArrivalPlan?
                        switch target {
                        case .arriveBy(let deadline):
                            timing = ArrivalPlanning.assess(trip, metadata: metadata, arriveBy: deadline, walking: walking, preferences: preferences)
                        case .departAt(let leave):
                            timing = ArrivalPlanning.depart(trip, metadata: metadata, at: leave, walking: walking, preferences: preferences)
                        }
                        if option.verified, let timing { checked.append(Result(option: option, timing: timing)) }
                    } catch { if Task.isCancelled { return } }
                }
                if case .departAt = target {
                    results = Array(checked.sorted { $0.timing.latestArrival < $1.timing.latestArrival }.prefix(3))
                } else {
                    results = Array(checked.sorted { $0.timing.assessment.score < $1.timing.assessment.score }.prefix(3))
                }
                busy = false
            }
    }
}

/// What 用一句話規劃 understood, above the routes it started, with the quick changes a rider may want.
struct AssistantTripBanner: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let reopen: () -> Void
    private func title(_ mode: AssistantTravelMode) -> String {
        switch mode {
        case .any: AppText.text("推薦路線")
        case .cycling: AppText.text("騎 YouBike 優先")
        case .walking: AppText.text("步行優先")
        }
    }
    var body: some View {
        if let trip = model.currentAssistantTrip {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("「" + trip.request + "」").font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text([trip.destination.localizedName, title(trip.mode),
                             trip.departure.map { AppText.text("%@ 出發", JourneyDepartureControl.label($0)) } ?? AppText.text("現在出發")].joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        if !trip.alternatives.isEmpty {
                            Section(AppText.text("不是這裡？")) {
                                ForEach(trip.alternatives) { place in
                                    Button(place.localizedName) { model.switchAssistantDestination(place) }
                                }
                            }
                        }
                        Section(AppText.text("交通方式")) {
                            ForEach([AssistantTravelMode.any, .cycling, .walking], id: \.self) { mode in
                                Button { model.setAssistantMode(mode) } label: {
                                    if trip.mode == mode { Label(title(mode), systemImage: "checkmark") } else { Text(title(mode)) }
                                }
                            }
                        }
                        Button(AppText.text("重新說一次"), systemImage: "mic") { reopen() }
                    } label: {
                        Text(AppText.text("調整")).font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                    }.accessibilityIdentifier("assistant-trip-adjust")
                }
                if let note = trip.note { Text(note).font(.caption).foregroundStyle(.orange) }
                if let issue = planner.wholeTripBikeIssue() {
                    Text(AppText.text("沒有全程 YouBike 路線：%@", issue)).font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("assistant-trip-bike-issue")
                }
            }
            .padding(12)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("assistant-trip")
        }
    }
}
