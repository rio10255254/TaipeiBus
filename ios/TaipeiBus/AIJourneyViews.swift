import SwiftUI
import TransitCore

struct AIJourneyAssistantView: View {
    @ObservedObject var model: TransitAppModel
    let planned: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearch()
    @FocusState private var inputFocused: Bool
    @State private var input = ""
    @State private var reviewed = false
    @State private var review = AssistantFieldReview()
    @State private var timeDescription = ""
    @State private var clarification: AssistantClarification?
    @State private var conversation: (any JourneyAssistantConversation)?
    @State private var confirmed = false
    @State private var destination = ""
    @State private var origin = ""
    @State private var preference = RoutePreference.balanced
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(3600)
    @State private var destinations: [TravelPlace] = []
    @State private var origins: [TravelPlace] = []
    @State private var selectedDestination: TravelPlace?
    @State private var selectedOrigin: TravelPlace?
    @State private var busy = false
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var deadlineTask: Task<Void, Never>?
    @State private var prepared: (context: JourneyAssistantContext, conversation: any JourneyAssistantConversation)?
    @State private var activity = AppText.text("正在理解你的需求…")
    @State private var startedAt = Date()
    @State private var activeContext: JourneyAssistantContext?
    /// The on-device model can be slow, but the screen must never wait indefinitely.
    private static let timeLimit: Double = 45
    @State private var showingArrival = false

    private var unavailable: String? { OnDeviceJourneyAssistant.unavailableReason() }
    private var requiresPro: Bool { preference != .balanced && !model.purchases.hasPro }
    private var usesCurrentOrigin: Bool { origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var start: TravelPlace? {
        usesCurrentOrigin ? model.location.usableCoordinate.flatMap { point in
            guard point.isInServiceArea else { return nil }
            return TravelPlace(name: AppText.text("目前位置"), address: "", coordinate: point)
        } : selectedOrigin
    }
    var body: some View {
        NavigationStack {
            Form {
                if let unavailable {
                    Section {
                        Text(unavailable).accessibilityIdentifier("ai-unavailable")
                        Button(AppText.text("返回手動搜尋")) { dismiss() }.accessibilityIdentifier("ai-manual-search")
                    }
                } else {
                    Section {
                        TextField(AppText.text("例如：明天 9 點前到台大醫院，不想走太多路"), text: $input, axis: .vertical)
                            .lineLimit(3...6).focused($inputFocused).accessibilityIdentifier("ai-request")
                        Button(AppText.text("理解行程需求")) { extract() }
                            .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.count > 600)
                            .accessibilityIdentifier("ai-extract")
                        if input.count > 600 { Text(AppText.text("請將需求縮短至 600 字以內。")) }
                    } footer: {
                        Text(AppText.text("文字只交給手機上的模型理解。請確認下方條件；地點搜尋與步行路線仍由 Apple 地圖處理。"))
                    }
                }
                if let clarification {
                    Section(AppText.text("確認你的意思")) {
                        Text(clarification.question).font(.headline)
                        ForEach(clarification.options.indices, id: \.self) { index in
                            Button(clarification.options[index]) { answer(index) }
                                .disabled(busy).accessibilityIdentifier("ai-choice-\(index)")
                        }
                        Button(AppText.text("直接修改行程條件")) { abandonClarification() }
                            .disabled(busy).accessibilityIdentifier("ai-edit-conditions")
                    }
                }
                if reviewed {
                    Section {
                        fieldStatus(AppText.text("目的地"), review.destination)
                        TextField(AppText.text("目的地"), text: Binding(get: { destination }, set: {
                            destination = $0; review.destination = .needsConfirmation; editPlace(isOrigin: false)
                        })).accessibilityIdentifier("ai-destination")
                        fieldStatus(AppText.text("出發地"), review.origin)
                        TextField(AppText.text("出發地（留空使用目前位置）"), text: Binding(get: { origin }, set: {
                            origin = $0; review.origin = .needsConfirmation; editPlace(isOrigin: true)
                        })).accessibilityIdentifier("ai-origin")
                        fieldStatus(AppText.text("個人路線偏好"), review.preference)
                        Picker(AppText.text("個人路線偏好"), selection: Binding(get: { preference }, set: {
                            preference = $0; review.preference = .certain; abandonClarification()
                        })) {
                            ForEach(RoutePreference.allCases) { Text($0.title).tag($0) }
                        }
                        if requiresPro { Text(AppText.text("此路線偏好需要 Pro；可改選「推薦」繼續規劃。")) }
                        fieldStatus(AppText.text("抵達期限（台北時間）"), review.time)
                        if !timeDescription.isEmpty { Text(timeDescription).font(.callout) }
                        Toggle(AppText.text("指定抵達期限"), isOn: Binding(get: { hasDeadline }, set: {
                            hasDeadline = $0; review.time = .certain; timeDescription = ""; abandonClarification()
                        })).accessibilityIdentifier("ai-deadline-toggle")
                        if hasDeadline {
                            DatePicker(AppText.text("抵達期限（台北時間）"), selection: Binding(get: { deadline }, set: {
                                deadline = $0; review.time = .certain; timeDescription = ""; abandonClarification()
                            }),
                                in: Date()...Date().addingTimeInterval(90 * 86_400), displayedComponents: [.date, .hourAndMinute])
                                .environment(\.timeZone, AssistantJourneyRequest.calendar.timeZone)
                        } else { Text(AppText.text("現在出發")) }
                        Button(AppText.text("搜尋並選擇實際地點")) { findPlaces() }
                            .disabled(busy || destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text(AppText.text("確認行程條件"))
                    } footer: {
                        Text(AppText.text("需確認的欄位可直接修改；請核對每個條件與實際地點後再規劃。"))
                    }.disabled(busy)
                    if !usesCurrentOrigin { places(origins, selected: $selectedOrigin, status: $review.origin, title: AppText.text("出發地")) }
                    places(destinations, selected: $selectedDestination, status: $review.destination, title: AppText.text("目的地"))
                    if selectedDestination != nil {
                        Section {
                            if start == nil { Text(AppText.text("請選擇出發地，或開啟定位後再規劃。")) }
                            if let start, let selectedDestination {
                                Text(start.localizedName + " → " + selectedDestination.localizedName)
                                Toggle(AppText.text("我已確認所有行程條件與實際地點"), isOn: $confirmed)
                                    .accessibilityIdentifier("ai-confirm-places")
                            }
                            Button(AppText.text("依確認條件規劃")) { apply() }
                                .disabled(busy || !confirmed || clarification != nil || requiresPro || start == nil ||
                                    (hasDeadline && !AssistantJourneyRequest.canPlan(arriveBy: deadline)))
                                .accessibilityIdentifier("ai-plan")
                        }
                    }
                }
                if busy {
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
                if let message { Section { Text(message).accessibilityIdentifier("ai-error") } }
            }
            .navigationTitle(AppText.text("用一句話規劃"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppText.text("關閉")) { dismiss() } } }
            .navigationDestination(isPresented: $showingArrival) {
                if let start, let selectedDestination {
                    ArrivalJourneyView(metadata: model.metadata, origin: start, destination: selectedDestination,
                        deadline: deadline, preferences: preference.applying(to: model.liveSettings.planning))
                }
            }
        }
        .onChange(of: input) { _, _ in
            resetPlaces(); reviewed = false; message = nil; clarification = nil; conversation = nil
        }
        .onChange(of: preference) { _, _ in confirmed = false }
        .onChange(of: hasDeadline) { _, _ in confirmed = false }
        .onChange(of: deadline) { _, _ in confirmed = false }
        .onAppear { prepare() }
        .onDisappear { operation?.cancel(); deadlineTask?.cancel(); search.cancel(); conversation = nil; prepared = nil }
    }
    private func fieldStatus(_ title: String, _ status: AssistantFieldStatus) -> some View {
        Label(title + " · " + (status == .certain ? AppText.text("確定") : AppText.text("需確認")),
              systemImage: status == .certain ? "checkmark.circle" : "exclamationmark.triangle.fill")
            .font(.subheadline.bold())
            .foregroundStyle(status == .certain ? Color.secondary : Color.orange)
            .padding(.vertical, 4)
            .accessibilityIdentifier("ai-status-\(title)")
    }
    private func places(_ values: [TravelPlace], selected: Binding<TravelPlace?>, status: Binding<AssistantFieldStatus>, title: String) -> some View {
        Section(title) {
            ForEach(values) { place in
                Button { selected.wrappedValue = place; status.wrappedValue = .certain; confirmed = false } label: {
                    HStack {
                        VStack(alignment: .leading) { Text(place.localizedName); Text(place.address).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if selected.wrappedValue?.id == place.id { Image(systemName: "checkmark.circle.fill") }
                    }
                }.disabled(busy).accessibilityIdentifier("ai-place-\(place.name)")
            }
        }
    }
    private func abandonClarification() {
        clarification = nil; conversation = nil; confirmed = false
    }
    private func editPlace(isOrigin: Bool) {
        operation?.cancel(); search.cancel(); busy = false; confirmed = false
        clarification = nil; conversation = nil
        if isOrigin { origins = []; selectedOrigin = nil }
        else { destinations = []; selectedDestination = nil }
    }
    private func resetPlaces() {
        operation?.cancel(); search.cancel(); busy = false
        destinations = []; origins = []; selectedDestination = nil; selectedOrigin = nil; confirmed = false
    }
    private func receive(_ turn: AssistantJourneyTurn) {
        let result = turn.request
        destination = result.destination; origin = result.origin
        preference = RoutePreference(rawValue: result.preference.rawValue) ?? .balanced
        hasDeadline = result.arriveBy != nil; deadline = result.arriveBy ?? Date().addingTimeInterval(3600)
        review = result.review; timeDescription = result.timeDescription
        destinations = turn.destinationCandidates; origins = turn.originCandidates
        selectedDestination = nil; selectedOrigin = nil; confirmed = false
        clarification = turn.clarification; reviewed = true; busy = false
    }
    private func makeContext() -> JourneyAssistantContext {
        let vocabulary = model.vocabulary, settings = model.liveSettings.search, revision = model.liveSettings.revision
        let coordinate = model.location.usableCoordinate
        return JourneyAssistantContext(journeys: model.commutes.journeys) { query in
            // A separate search per call avoids cancellation when the model calls tools concurrently.
            let toolSearch = PlaceSearch()
            toolSearch.setRules(vocabulary: vocabulary, settings: settings, revision: revision)
            toolSearch.setContext(coordinate)
            return try await toolSearch.find(text: query, queryLimit: 2, timeout: 4)
        }
    }
    /// Starts loading the model while the user types.
    private func prepare() {
        guard unavailable == nil, prepared == nil else { return }
        let context = makeContext()
        guard let session = try? OnDeviceJourneyAssistant.conversation(context: context) else { return }
        session.prewarm()
        prepared = (context, session)
    }
    private func track(_ context: JourneyAssistantContext) {
        context.onActivity = { value in
            switch value {
            case .search: activity = AppText.text("正在搜尋地點…")
            case .saved: activity = AppText.text("正在查看常用行程…")
            }
        }
    }
    /// Starts the limit for one model step; when it passes, the review stays editable by hand.
    private func startDeadline(_ step: String, context: JourneyAssistantContext, onTimeout: @escaping @MainActor () -> Void) {
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(Self.timeLimit)) } catch { return }
            guard busy else { return }
            operation?.cancel()
            record(step, outcome: "timeout", context: context)
            onTimeout()
        }
    }
    /// Timing only: no request text, places or answers enter the troubleshooting history.
    private func record(_ step: String, outcome: String, context: JourneyAssistantContext) {
        let searches = context.toolCalls.filter { $0.hasPrefix("searchPlaces") }.count
        let saved = context.toolCalls.filter { $0.hasPrefix("listSavedJourneys") }.count
        JourneyDiagnostics.shared.record(String(format: "ai-%@ %@ %.1fs searches=%d search=%.1fs saved=%d",
            step, outcome, Date().timeIntervalSince(startedAt), searches, context.searchSeconds, saved))
    }
    private func manualReview(_ text: String) {
        busy = false
        // Model failures still allow the user to fill in the same review screen.
        reviewed = true; review = .init(); destination = ""; origin = ""
        preference = .balanced; hasDeadline = false; timeDescription = ""
        message = text
    }
    private func extract() {
        inputFocused = false
        resetPlaces(); busy = true; message = nil; reviewed = false; clarification = nil; conversation = nil
        let source = input
        let ready = prepared; prepared = nil
        let context = ready?.context ?? makeContext()
        track(context); activeContext = context
        activity = AppText.text("正在理解你的需求…"); startedAt = Date()
        startDeadline("understand", context: context) {
            conversation = nil
            manualReview(AppText.text("手機上的模型這次回應太久，請直接填寫下方行程條件，或再試一次。"))
        }
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
                manualReview(AppText.text("暫時無法理解，請直接填寫下方行程條件，或再試一次。") + "\n(" + kind + ")")
            }
        }
    }
    private func answer(_ index: Int) {
        guard let conversation, !busy else { return }
        operation?.cancel(); busy = true; confirmed = false; message = nil
        activity = AppText.text("正在理解你的選擇…"); startedAt = Date()
        let context = activeContext ?? makeContext()
        startDeadline("answer", context: context) {
            busy = false; clarification = nil
            message = AppText.text("手機上的模型這次回應太久，已保留條件，請直接修改確認。")
        }
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
                message = AppText.text("暫時無法繼續理解，已保留條件，請直接修改確認。")
            }
        }
    }
    private func findPlaces() {
        operation?.cancel(); search.cancel(); busy = true; message = nil; confirmed = false
        selectedDestination = nil; selectedOrigin = nil
        search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
        search.setContext(model.location.usableCoordinate)
        operation = Task { @MainActor in
            do {
                // Keep tool/library evidence when editing or resolving the other endpoint.
                if destinations.isEmpty {
                    let found = try await search.find(text: destination)
                    try Task.checkCancellation()
                    destinations = found.filter { $0.coordinate.isInServiceArea }
                }
                if !usesCurrentOrigin, origins.isEmpty {
                    let from = try await search.find(text: origin)
                    try Task.checkCancellation()
                    origins = from.filter { $0.coordinate.isInServiceArea }
                }
                if destinations.isEmpty || (!usesCurrentOrigin && origins.isEmpty) {
                    message = AppText.text("找不到服務範圍內的地點，請修改關鍵字。")
                }
            } catch {
                guard !Task.isCancelled else { return }
                message = AppText.text("地點搜尋暫時無法連線，請稍後再試。")
            }
            busy = false
        }
    }
    private func apply() {
        guard !busy, confirmed, clarification == nil, !requiresPro, let start, let selectedDestination,
              start.coordinate.isInServiceArea, selectedDestination.coordinate.isInServiceArea else { return }
        if hasDeadline {
            guard AssistantJourneyRequest.canPlan(arriveBy: deadline) else { return }
            showingArrival = true
        } else {
            model.previewAssistantJourney(origin: start, destination: selectedDestination, preference: preference)
            planned(); dismiss()
        }
    }
}

private actor ArrivalCandidateSearch {
    func options(metadata: TransitMetadata, origin: Coordinate, destination: Coordinate, deadline: Date,
                 preferences: LiveSettings.Planning) -> [TransitTrip] {
        guard !Task.isCancelled else { return [] }
        return MultimodalPlanner(metadata: metadata).plan(from: origin, to: destination,
            maximumWalk: preferences.expandedWalkMeters, limit: 12, preferences: preferences,
            at: deadline.addingTimeInterval(-3600))
    }
}

private struct ArrivalJourneyView: View {
    let metadata: TransitMetadata
    let origin: TravelPlace
    let destination: TravelPlace
    let deadline: Date
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
                Text(AppText.text("抵達期限：%@", clock(deadline)))
                Text(AppText.text("依官方班表、班距與車程資料推估，含 10 分鐘預留；不是保證抵達時間。未使用目前車輛位置或未來車位數量。出發當天請重新搜尋並確認公告。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if busy { ProgressView(AppText.text("確認步行與班距資料")) }
            ForEach(results) { result in
                Section {
                    Text(AppText.text("建議預留出發時間：%@", clock(result.timing.departure))).font(.headline)
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
                Text(AppText.text("目前資料不足以確認這個抵達期限的行程。請改選時間、查看官方班表，並於出發當天重新規劃。"))
                    .accessibilityIdentifier("ai-arrival-unavailable")
            }
        }.navigationTitle(AppText.text("預排行程參考"))
            .task {
                let planner = JourneyPlannerModel()
                let candidates = await ArrivalCandidateSearch().options(metadata: metadata, origin: origin.coordinate,
                    destination: destination.coordinate, deadline: deadline, preferences: preferences)
                var checked: [Result] = []
                for trip in candidates.prefix(6) {
                    guard !Task.isCancelled else { return }
                    var option = planner.option(trip, metadata: metadata, origin: origin, destination: destination)
                    do {
                        for index in option.walks.indices where !option.walks[index].internalTransfer {
                            option.walks[index] = try await planner.checkedWalk(option.walks[index])
                        }
                        try Task.checkCancellation()
                        if option.verified, let timing = ArrivalPlanning.assess(trip, metadata: metadata, arriveBy: deadline,
                            walking: option.walks.compactMap(\.duration), preferences: preferences) {
                            checked.append(Result(option: option, timing: timing))
                        }
                    } catch { if Task.isCancelled { return } }
                }
                results = Array(checked.sorted { $0.timing.assessment.score < $1.timing.assessment.score }.prefix(3))
                busy = false
            }
    }
}
