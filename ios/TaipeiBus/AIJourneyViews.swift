import SwiftUI
import TransitCore

struct AIJourneyAssistantView: View {
    @ObservedObject var model: TransitAppModel
    let planned: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = PlaceSearch()
    @State private var input = ""
    @State private var reviewed = false
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
    @State private var showingArrival = false

    private var unavailable: String? { OnDeviceJourneyAssistant.unavailableReason() }
    private var requiresPro: Bool { preference != .balanced && !model.purchases.hasPro }
    private var start: TravelPlace? {
        origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? model.location.usableCoordinate.flatMap { point in
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
                            .lineLimit(3...6).accessibilityIdentifier("ai-request")
                        Button(AppText.text("理解行程需求")) { extract() }
                            .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || input.count > 600)
                            .accessibilityIdentifier("ai-extract")
                        if input.count > 600 { Text(AppText.text("請將需求縮短至 600 字以內。")) }
                    } footer: {
                        Text(AppText.text("文字只交給手機上的模型理解。請確認下方條件；地點搜尋與步行路線仍由 Apple 地圖處理。"))
                    }
                }
                if reviewed {
                    Section(AppText.text("確認行程條件")) {
                        TextField(AppText.text("目的地"), text: $destination).accessibilityIdentifier("ai-destination")
                        TextField(AppText.text("出發地（留空使用目前位置）"), text: $origin)
                        Picker(AppText.text("個人路線偏好"), selection: $preference) {
                            ForEach(RoutePreference.allCases) { Text($0.title).tag($0) }
                        }
                        if requiresPro { Text(AppText.text("此路線偏好需要 Pro；可改選「推薦」繼續規劃。")) }
                        Toggle(AppText.text("指定抵達期限"), isOn: $hasDeadline).accessibilityIdentifier("ai-deadline-toggle")
                        if hasDeadline {
                            DatePicker(AppText.text("抵達期限（台北時間）"), selection: $deadline,
                                in: Date()...Date().addingTimeInterval(90 * 86_400), displayedComponents: [.date, .hourAndMinute])
                                .environment(\.timeZone, AssistantJourneyRequest.calendar.timeZone)
                        } else { Text(AppText.text("現在出發")) }
                        Button(AppText.text("搜尋並選擇實際地點")) { findPlaces() }.disabled(busy || destination.isEmpty)
                    }
                    if !origin.isEmpty { places(origins, selected: $selectedOrigin, title: AppText.text("出發地")) }
                    places(destinations, selected: $selectedDestination, title: AppText.text("目的地"))
                    if selectedDestination != nil {
                        Section {
                            if start == nil { Text(AppText.text("請選擇出發地，或開啟定位後再規劃。")) }
                            Button(AppText.text("依確認條件規劃")) { apply() }
                                .disabled(busy || requiresPro || start == nil || (hasDeadline && deadline <= Date()))
                                .accessibilityIdentifier("ai-plan")
                        }
                    }
                }
                if busy { ProgressView().accessibilityIdentifier("ai-progress") }
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
        .onChange(of: input) { _, _ in operation?.cancel(); busy = false; reviewed = false; message = nil; resetPlaces() }
        .onChange(of: destination) { _, _ in resetPlaces() }
        .onChange(of: origin) { _, _ in resetPlaces() }
        .onDisappear { operation?.cancel(); search.cancel() }
    }
    private func places(_ values: [TravelPlace], selected: Binding<TravelPlace?>, title: String) -> some View {
        Section(title) {
            ForEach(values) { place in
                Button { selected.wrappedValue = place } label: {
                    HStack {
                        VStack(alignment: .leading) { Text(place.localizedName); Text(place.address).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if selected.wrappedValue?.id == place.id { Image(systemName: "checkmark.circle.fill") }
                    }
                }
            }
        }
    }
    private func resetPlaces() {
        operation?.cancel(); search.cancel(); busy = false
        destinations = []; origins = []; selectedDestination = nil; selectedOrigin = nil
    }
    private func extract() {
        operation?.cancel(); busy = true; message = nil; reviewed = false
        let source = input
        operation = Task { @MainActor in
            do {
                let result = try await OnDeviceJourneyAssistant.parse(source)
                try Task.checkCancellation()
                destination = result.destination; origin = result.origin
                preference = RoutePreference(rawValue: result.preference.rawValue) ?? .balanced
                hasDeadline = result.arriveBy != nil; deadline = result.arriveBy ?? Date().addingTimeInterval(3600)
                reviewed = true; busy = false
            } catch {
                guard !Task.isCancelled else { return }
                busy = false
                message = AppText.text("無法確定完整條件，請改寫目的地與抵達時間，或返回手動搜尋。")
            }
        }
    }
    private func findPlaces() {
        resetPlaces(); busy = true; message = nil
        search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
        operation = Task { @MainActor in
            do {
                let found = try await search.find(text: destination)
                let from = origin.isEmpty ? [] : try await search.find(text: origin)
                try Task.checkCancellation()
                destinations = found.filter { $0.coordinate.isInServiceArea }
                origins = from.filter { $0.coordinate.isInServiceArea }
                if destinations.isEmpty || (!origin.isEmpty && origins.isEmpty) {
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
        guard !requiresPro, let start, let selectedDestination else { return }
        if hasDeadline {
            guard deadline > Date() else { return }
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
