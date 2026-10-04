import SwiftUI
import MapKit
import TransitCore

struct JourneyPlanningView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    @ObservedObject var location: LocationService
    @Binding var showingItinerary: Bool
    let compact: Bool
    let expand: () -> Void
    let collapse: () -> Void
    @StateObject private var search = PlaceSearch()
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var editingOrigin = false
    @State private var editingDestination = true
    @State private var resolving = false
    @State private var searchError: String?
    @State private var resolveTask: Task<Void, Never>?
    @State private var resolveToken = UUID()
    @State private var resolvingQuery = ""
    @State private var stationResults: [Station] = []
    @State private var stationResultQuery = ""
    @State private var showingRankingInfo = false

    private var searchingPlaces: Bool { editingOrigin || editingDestination }
    private var searchContext: Coordinate? {
        planner.usingLocation ? location.usableCoordinate ?? location.displayCoordinate : planner.origin?.coordinate
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    originButton
                    if searchingPlaces { placeSearch }
                    else {
                        if planner.started || showingItinerary {
                            JourneyItineraryView(model: model, planner: planner)
                        } else {
                            JourneyOptionsView(model: model, planner: planner, collapse: { dismiss() })
                        }
                    }
                }.padding(.horizontal, 20 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 16 * CGFloat(live.appearance.spacingScale))
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(editingOrigin ? "出發地" : searchingPlaces ? "目的地" : planner.started || showingItinerary ? "行程" : planner.destination?.name ?? "路線")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(live.text(searchingPlaces ? "取消" : "返回地圖")) {
                        if searchingPlaces, planner.destination != nil {
                            focused = false; resolveTask?.cancel(); search.cancel()
                            resolving = false; editingOrigin = false; editingDestination = false
                            if !planner.started { collapse() }
                        } else { dismiss() }
                    }
                }
                if !searchingPlaces {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(live.text("更改")) { edit(origin: false) }
                    }
                    if !planner.started, !showingItinerary {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button(live.text("查看行程")) { showingItinerary = true; expand() }
                                Button("重新比較路線") { planner.refreshRecommendations() }
                                Button("推薦順序說明") { showingRankingInfo = true }
                                Button(live.text("其他交通方式")) { planner.openAppleTransit() }
                            } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                                .accessibilityLabel(live.text("更多行程選項"))
                        }
                    }
                }
            }
        }
        .alert("推薦順序", isPresented: $showingRankingInfo) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("先確認實際步行，再比較可趕上的班次、候車與搭車時間。推薦兼顧時間、少走路與少轉乘；較快方案會另外保留。班距推估會標示範圍，班次不足則標示待確認。抵達時間包含走路、候車與搭車。")
        }
        .onAppear {
            search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
            search.setContext(searchContext)
            editingDestination = planner.destination == nil
            if planner.origin == nil && planner.usingLocation {
                planner.useLocation(location.usableCoordinate, metadata: model.metadata)
                if location.usableCoordinate == nil { location.request() }
            }
            focused = editingDestination
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-journey-search") {
                focused = false
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "--preview-search-query"), arguments.indices.contains(index + 1) { query = arguments[index + 1] }
                else { query = "臺北車站" }
            }
#endif
        }
        .onChange(of: query) { _, value in
            if resolving && value != resolvingQuery {
                resolveTask?.cancel(); resolveToken = UUID(); resolving = false; search.cancel()
            }
            searchError = nil; search.update(value)
        }
        .onChange(of: planner.options.count) { _, count in
            if count > 0, !searchingPlaces, !planner.started, !showingItinerary { focused = false }
        }
        .onChange(of: location.revision) { _, _ in search.setContext(searchContext) }
        .onChange(of: model.liveSettings.revision) { _, _ in
            search.setRules(vocabulary: model.vocabulary, settings: model.liveSettings.search, revision: model.liveSettings.revision)
        }
        .onDisappear { resolveTask?.cancel(); search.cancel() }
        .task(id: query + ":" + model.stationSearchContextKey) {
            let text = query
            let matches = await model.findStations(query: text, limit: text.isEmpty ? 3 : model.liveSettings.search.resultLimit)
            guard !Task.isCancelled else { return }
            stationResults = matches; stationResultQuery = text
            search.setStationHints(matches)
        }
    }
    private var originButton: some View {
        HStack(spacing: 10) {
            Image(systemName: planner.usingLocation ? "location.fill" : "circle.fill").foregroundStyle(Color(liveHex: live.appearance.accentColor))
            Button { edit(origin: true) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(planner.origin?.name ?? (location.requesting ? "取得位置中" : "選擇出發地"))
                        .liveFont(.subheadline, weight: .semibold).lineLimit(1)
                    if planner.origin == nil {
                        Text(location.message ?? "可使用定位，或輸入出發地／站名").liveFont(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button {
                planner.useLocation(location.usableCoordinate, metadata: model.metadata); location.request()
                editingOrigin = false; editingDestination = planner.destination == nil; query = ""
            } label: { Image(systemName: "location.circle").liveFont(.title2).frame(width: 44, height: 44) }
                .accessibilityLabel(live.text("使用目前位置出發"))
        }.padding(.vertical, 4)
    }
    private var placeSearch: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(editingOrigin ? "出發地、地址或站名" : "地點、地址或站名", text: $query)
                    .accessibilityIdentifier("journey-search-field")
                    .focused($focused).submitLabel(.search).autocorrectionDisabled()
                    .onSubmit { resolve(text: query) }
                if resolving || search.searching { ProgressView() }
                else if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }.padding(14).frame(minHeight: 52)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 15 * CGFloat(live.appearance.cornerScale)))
            if let error = searchError ?? search.error { Text(error).liveFont(.subheadline).foregroundStyle(.secondary) }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { resolve(text: query) } label: {
                    Label("搜尋「\(query)」", systemImage: "arrow.up.right").liveFont(.subheadline, weight: .semibold).frame(minHeight: 44)
                }.disabled(resolving)
            }
            if query.isEmpty {
                if !editingOrigin && !planner.recentPlaces.isEmpty {
                    Text(live.text("最近目的地")).liveFont(.subheadline, weight: .semibold).padding(.top, 8 * CGFloat(live.appearance.spacingScale))
                    ForEach(planner.recentPlaces) { place in placeButton(place, symbol: "clock") }
                }
                if !editingOrigin && live.display.quickDestinations {
                    HStack(spacing: 8) {
                        ForEach(live.quickDestinations, id: \.self) { name in
                            Button(name) { query = name; resolve(text: name) }.liveFont(.subheadline)
                                .padding(.horizontal, 12 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 44)
                                .background(Color(liveHex: live.appearance.accentColor).opacity(0.08), in: Capsule())
                        }
                    }.padding(.top, 8 * CGFloat(live.appearance.spacingScale))
                }
            }
            if !search.places.isEmpty {
                Text(live.text("地點搜尋結果")).liveFont(.subheadline, weight: .semibold).padding(.top, 8 * CGFloat(live.appearance.spacingScale))
                ForEach(search.places) { place in placeButton(place, symbol: "mappin.circle.fill") }
            }
            if !search.suggestions.isEmpty && search.places.isEmpty { Text(live.text("地點")).liveFont(.subheadline, weight: .semibold).padding(.top, 8 * CGFloat(live.appearance.spacingScale)) }
            ForEach(Array((search.places.isEmpty ? Array(search.suggestions.prefix(6)) : []).enumerated()), id: \.offset) { _, completion in
                Button { resolve(text: completion.title, completion: completion) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle").liveFont(.title2).foregroundStyle(Color(liveHex: live.appearance.accentColor))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(completion.title).liveFont(.body, weight: .medium)
                            Text(completion.subtitle).liveFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0); Image(systemName: "arrow.up.left").liveFont(.caption).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(resolving)
                Divider()
            }
            let stations = stationResultQuery == query ? stationResults : []
            if !stations.isEmpty { Text(live.text("公車站牌")).liveFont(.subheadline, weight: .semibold).padding(.top, 8 * CGFloat(live.appearance.spacingScale)) }
            ForEach(StationSearch.groups(stations)) { group in
                DisclosureGroup {
                ForEach(group.stations) { station in
                    Button {
                        choose(TravelPlace(name: station.name, address: "\(station.bearingLabel) · \(station.address)", coordinate: station.coordinate))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bus.fill").foregroundStyle(Color(liveHex: live.appearance.accentColor)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(station.bearingLabel.isEmpty ? station.name : station.bearingLabel).liveFont(.subheadline, weight: .medium)
                                Text(station.address.isEmpty ? station.name : station.address).liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
                        }.frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(resolving)
                }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bus.fill").foregroundStyle(Color(liveHex: live.appearance.accentColor)).frame(width: 22)
                        Text(group.name).liveFont(.body, weight: .medium)
                        Spacer(minLength: 4)
                        Text("\(group.stations.count) 處").liveFont(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }.accessibilityIdentifier("journey-stations-" + group.name)
            }
        }
    }
    private func placeButton(_ place: TravelPlace, symbol: String) -> some View {
        Button { choose(place) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).liveFont(.title3).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name).liveFont(.body, weight: .medium)
                    if !place.address.isEmpty { Text(place.address).liveFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if !place.coordinate.isInServiceArea { Text(live.text("公車規劃範圍外")).liveFont(.caption).foregroundStyle(.secondary) }
                }
                Spacer(); Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
            }.frame(minHeight: 58).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(resolving)
    }
    private func edit(origin: Bool) {
        expand()
        resolveTask?.cancel(); resolveToken = UUID(); search.cancel(); resolving = false
        editingOrigin = origin; editingDestination = !origin; showingItinerary = false; query = ""; searchError = nil; focused = true
        search.setContext(searchContext)
    }
    private func resolve(text: String, completion: MKLocalSearchCompletion? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        resolveTask?.cancel(); resolveToken = UUID(); let token = resolveToken
        resolving = true; resolvingQuery = query; searchError = nil
        resolveTask = Task {
            do {
                let places = try await search.find(text: text, completion: completion)
                guard !Task.isCancelled, token == resolveToken else { return }
                resolving = false
                if completion != nil, let place = places.first { choose(place) }
                else if places.isEmpty { searchError = "找不到相符地點，試試地址或站牌" }
                else { focused = false }
            } catch {
                guard !Task.isCancelled, token == resolveToken else { return }
                resolving = false; searchError = "搜尋暫時無法連線，可改選站牌，或稍後重試。"
            }
        }
    }
    private func choose(_ place: TravelPlace) {
        focused = false
        if editingOrigin { planner.setOrigin(place, metadata: model.metadata) }
        else { planner.setDestination(place, metadata: model.metadata, currentLocation: location.usableCoordinate) }
        editingOrigin = false; editingDestination = planner.destination == nil; query = ""
        search.cancel()
        if planner.destination != nil, planner.origin == nil { edit(origin: true) }
    }
}

/// A flat boarding display shared by the sheet and the edge of the map.
struct JourneyBoardingView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            JourneyBoardingContent(model: model, ride: ride, date: timeline.date)
        }
    }
}

private struct JourneyBoardingContent: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    @State private var showTimingInfo = false
    @State private var showVehicles = false
    private var guide: BoardingGuide { BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            platform
            headline
            HStack {
                Button { showVehicles = true } label: {
                    HStack(spacing: 4) { Text("到站車輛"); Image(systemName: "chevron.right") }
                        .liveFont(.caption).frame(minHeight: 28)
                }.accessibilityIdentifier("journey-all-vehicles")
                Spacer()
                Button { showTimingInfo = true } label: { Image(systemName: "info.circle").liveFont(.caption).frame(width: 28, height: 28) }
                    .accessibilityLabel(live.text("到站時間說明"))
                    .popover(isPresented: $showTimingInfo) {
                        Text(live.text("候車以官方下一班到站時間為主。官方未指定車牌；各車紀錄足夠才顯示分鐘數，否則先看位置與站數。地圖平順銜接已收到的定位，保留短暫緩衝。點「到站車輛」可查看時間說明。"))
                            .liveFont(.subheadline).padding(20).frame(maxWidth: 300).presentationCompactAdaptation(.popover)
                    }
            }
            .padding(.bottom, -10)
            if guide.approaches.isEmpty { Text(live.text(guide.emptyPositionLabel)).liveFont(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6 * CGFloat(live.appearance.spacingScale)) }
            VStack(spacing: 0) {
                ForEach(Array(guide.approaches.prefix(3))) { approach in
                    BoardingVehicleRow(model: model, ride: ride, approach: approach, date: date)
                    if approach.id != guide.approaches.prefix(3).last?.id { Divider() }
                }
            }
            if let bus = model.selectedVehicle, model.metadata.canServe(ride, vehicle: bus),
               !guide.approaches.contains(where: { $0.id == bus.id }) {
                let passed = model.metadata.journey(routeID: bus.routeID, direction: bus.direction)?
                    .progress(stopID: ride.boarding.id, vehicle: bus, at: date).map { $0.distance < -20 } ?? false
                Text(bus.plate + (passed ? " · 已離開上車站" : " · 位置更新中"))
                    .liveFont(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $showVehicles) { VehicleArrivalsView(model: model, ride: ride) }
    }
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ride.route.name).liveFont(.title, weight: .bold, design: .rounded)
                    .foregroundStyle(Color(liveHex: live.appearance.accentColor)).lineLimit(1).minimumScaleFactor(0.65)
                    .accessibilityIdentifier("boarding-route")
                Text(live.text("往 ") + ride.route.destination(direction: ride.direction)).liveFont(.caption).lineLimit(1)
                if ride.route.displayName != ride.route.name,
                   model.metadata.routeIDs(serving: ride).filter({ model.metadata.routes[$0] != nil }).count <= 1 {
                    Text(ride.route.displayName).liveFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(guide.arrivalShortLabel).liveFont(.largeTitle, weight: .bold, design: .rounded)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityIdentifier("boarding-official-arrival")
                Text(guide.estimateSeconds == nil ? "暫無預估" : "官方下一班").liveFont(.caption).foregroundStyle(.secondary)
            }.layoutPriority(1)
        }
    }
    private var platform: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                if let station = guide.station, !station.address.isEmpty { Text(station.address).liveFont(.subheadline).foregroundStyle(.secondary) }
                Text(live.text("下車 · ") + ride.alighting.name).liveFont(.subheadline).foregroundStyle(.secondary)
            }.padding(.vertical, 4)
        } label: {
            HStack(spacing: 6) {
                Text(live.text("上車 · ") + ride.boarding.name).liveFont(.title3, weight: .bold).lineLimit(2)
                Spacer(minLength: 4)
                if let station = guide.station { Text(station.bearingLabel).liveFont(.caption).foregroundStyle(.secondary) }
            }
        }.accessibilityIdentifier("boarding-stop-details")
    }
}

private struct VehicleArrivalsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let guide = BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: timeline.date)
                List {
                    Section {
                        HStack { Text(ride.boarding.name); Spacer(); Text(guide.arrivalShortLabel).bold().monospacedDigit() }
                        Text("往 " + ride.route.destination(direction: ride.direction)).foregroundStyle(.secondary)
                    } header: { Text("官方下一班") }
                    Section {
                        if guide.approaches.isEmpty { Text(guide.emptyPositionLabel).foregroundStyle(.secondary) }
                        ForEach(guide.approaches) { approach in
                            VStack(alignment: .leading, spacing: 3) {
                                BoardingVehicleRow(model: model, ride: ride, approach: approach, date: timeline.date)
                                let display = model.arrivalDisplay(approach.vehicle, stopID: ride.boarding.id, at: timeline.date)
                                DisclosureGroup("時間說明") {
                                    Text(display.positionLabel)
                                    if let prediction = display.prediction { Text(prediction.rangeLabel) }
                                    Text(display.explanation)
                                    Text("車輛位置更新於 " + approach.vehicle.observedAt.formatted(date: .omitted, time: .standard))
                                }.liveFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text("\(ride.route.name) · 已發車車輛") }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle("到站車輛").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("journey-vehicles-done") } }
        }.presentationDetents([.large])
    }
}

private struct BoardingVehicleRow: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let approach: VehicleApproach
    let date: Date
    private var selected: Bool { model.selectedVehicleID == approach.id }
    private var tracking: Bool { selected && model.following }
    private var nextStop: String? {
        model.metadata.journey(routeID: approach.vehicle.routeID, direction: approach.vehicle.direction)?
            .upcoming(vehicle: approach.vehicle, at: date).first?.stop.name
    }
    var body: some View {
        Button {
            if tracking { model.following = false }
            else { model.trackApproachingVehicle(approach.vehicle) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(approach.vehicle.plate).liveFont(.subheadline, weight: .semibold).monospaced()
                    if selected { Text(nextStop.map { "前方 · " + $0 } ?? "位置待確認").liveFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(model.arrivalDisplay(approach.vehicle, stopID: ride.boarding.id, at: date).label)
                    .liveFont(.subheadline, weight: .semibold, design: .rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                Label(tracking ? "追蹤中" : "追蹤", systemImage: "scope").liveFont(.caption)
                    .foregroundStyle(tracking ? Color(liveHex: live.appearance.accentColor) : Color.secondary)
            }.frame(minHeight: 48).padding(.vertical, 4 * CGFloat(live.appearance.spacingScale)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint(tracking ? "停止追蹤" : "點一下追蹤這輛公車")
            .accessibilityValue(tracking ? "追蹤中" : selected ? "已選擇" : "")
            .accessibilityIdentifier("boarding-vehicle-" + approach.vehicle.plate)
    }
}

private struct OnboardSummary: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bus = model.onboardVehicle(for: ride) {
                let journey = model.metadata.journey(routeID: bus.routeID, direction: bus.direction)
                let next = journey?.upcoming(vehicle: bus, at: date).first
                HStack {
                    Text(next.map { "下一站 · " + $0.stop.name } ?? "位置更新中").lineLimit(1)
                    Spacer()
                    if let next {
                        Text(model.arrivalDisplay(bus, stopID: next.stop.id, at: date, onboard: true).label).monospacedDigit()
                    }
                }.liveFont(.subheadline).foregroundStyle(.secondary).accessibilityElement(children: .combine).accessibilityIdentifier("journey-next-stop")
                let progress = journey?.progress(stopID: ride.alighting.id, vehicle: bus, at: date)
                HStack(alignment: .firstTextBaseline) {
                    Text((progress?.distance ?? 0) < -20 ? "已通過「\(ride.alighting.name)」" : "在「\(ride.alighting.name)」下車")
                        .liveFont(.title3, weight: .bold).lineLimit(2)
                    Spacer(minLength: 4)
                    Text(model.arrivalDisplay(bus, stopID: ride.alighting.id, at: date, onboard: true).label)
                        .liveFont(.title3, weight: .bold).monospacedDigit().fixedSize()
                }.accessibilityElement(children: .combine).accessibilityIdentifier("journey-alighting-time")
            } else {
                Text("在「\(ride.alighting.name)」下車").liveFont(.title3, weight: .bold).lineLimit(2)
                Text(model.onboardPlate(for: ride) == nil ? "選擇車牌即可看沿途時間" : "車輛位置更新中")
                    .liveFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardStopsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let bus = model.onboardVehicle(for: ride)
                let upcoming = bus.flatMap { model.metadata.journey(routeID: $0.routeID, direction: $0.direction)?.upcoming(vehicle: $0, at: timeline.date) } ?? []
                let stops = upcoming.isEmpty ? Array(ride.stops.dropFirst()) : upcoming.map(\.stop)
                List {
                    Section {
                        if let plate = model.onboardPlate(for: ride) {
                            Text(plate).monospaced().bold().accessibilityIdentifier("onboard-confirmed-plate")
                            if bus?.hasReliablePosition(at: timeline.date) != true { Text("車輛位置更新中").foregroundStyle(.secondary) }
                        } else { Text("請先在搭車畫面選擇車牌").foregroundStyle(.secondary) }
                    } header: { Text(ride.route.name + " · 往 " + ride.route.destination(direction: ride.direction)) }
                    Section {
                        ForEach(stops) { stop in
                            HStack(spacing: 12) {
                                Image(systemName: stop.id == ride.alighting.id ? "arrow.down.circle.fill" : "circle.fill")
                                    .font(.system(size: stop.id == ride.alighting.id ? 20 : 8))
                                    .foregroundStyle(stop.id == ride.alighting.id ? Color.orange : Color.secondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(stop.name).liveFont(.subheadline, weight: stop.id == ride.alighting.id ? .bold : .regular)
                                    if stop.id == ride.alighting.id { Text("在這裡下車").liveFont(.caption).foregroundStyle(.orange) }
                                }
                                Spacer(minLength: 4)
                                Text(bus.map { model.arrivalDisplay($0, stopID: stop.id, at: timeline.date, onboard: true).label } ?? "—")
                                    .liveFont(.subheadline, weight: .semibold).monospacedDigit().fixedSize()
                            }.frame(minHeight: 40).accessibilityIdentifier("onboard-stop-" + stop.id)
                        }
                    } header: { Text("這輛車的沿途預估") } footer: {
                        Text(bus.map { model.arrivalDisplay($0, stopID: ride.alighting.id, at: timeline.date, onboard: true).explanation }
                             ?? "時間依行駛情況更新，塞車與停靠可能影響預估。")
                    }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle("沿途站牌").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("journey-stops-done") } }
        }.presentationDetents([.large])
    }
}

private struct BoardedVehiclePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var body: some View {
        NavigationStack {
            List {
                Section {
                    let vehicles = BoardingGuide.vehicles(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: Date(), approachingOnly: false)
                    if vehicles.isEmpty { Text("暫無車輛位置，稍後再選擇").foregroundStyle(.secondary) }
                    ForEach(vehicles) { approach in
                        Button {
                            model.confirmBoardedVehicle(approach.vehicle, ride: ride); dismiss()
                        } label: {
                            HStack {
                                Text(approach.vehicle.plate).monospaced()
                                Spacer()
                                if model.onboardPlate(for: ride) == approach.vehicle.plate { Image(systemName: "checkmark") }
                            }.frame(minHeight: 40)
                        }.accessibilityIdentifier("onboard-choose-" + approach.vehicle.plate)
                    }
                } header: { Text(ride.route.name + " · 往 " + ride.route.destination(direction: ride.direction)) } footer: { Text("依車內或車身顯示的車牌選擇。") }
            }.navigationTitle("搭乘車牌").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

struct JourneyArrivalDock: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let showJourney: () -> Void
    var body: some View {
        if let option = planner.selected, let index = planner.boardingRideIndex {
            let ride = option.rides[index]
            VStack(alignment: .leading, spacing: 10) {
                JourneyDockHeader(model: model, planner: planner, showJourney: showJourney)
                JourneyBoardingView(model: model, ride: ride)
                if index > 0 {
                    Text(option.walks[index].timeLabel).liveFont(.caption).foregroundStyle(.secondary)
                }
                JourneyWaitingActions(model: model, planner: planner, index: index) { model.boardCurrentRide() }
            }
            .journeyDockSurface()
        }
    }
}

private struct JourneyDockHeader: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let showJourney: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(planner.destination?.name ?? "目的地").liveFont(.subheadline, weight: .medium).foregroundStyle(.secondary).lineLimit(1)
                if let option = planner.selected {
                    TimelineView(.periodic(from: .now, by: 15)) { timeline in
                        if let duration = model.journeyDuration(option, at: timeline.date) {
                            Text((planner.started ? duration.label.replacingOccurrences(of: "全程", with: "剩餘").replacingOccurrences(of: "行程", with: "剩餘行程") : duration.label) + " · " + duration.arrivalLabel)
                                .liveFont(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
                                .accessibilityIdentifier("journey-total-duration")
                        }
                    }
                }
            }
            Spacer()
            Button(live.text(planner.started ? "行程" : "路線"), action: showJourney)
                .liveFont(.subheadline).frame(minHeight: 36).accessibilityIdentifier("journey-options")
            Button { model.finishJourney() } label: {
                Image(systemName: "xmark").liveFont(.caption, weight: .semibold).frame(width: 36, height: 36)
            }.accessibilityLabel(live.text("結束行程"))
        }
    }
}

private struct JourneyDockSurface: ViewModifier {
    @Environment(\.liveSettings) private var live
    func body(content: Content) -> some View {
        content.padding(.horizontal, 24 * CGFloat(live.appearance.spacingScale)).padding(.top, 10)
            .padding(.bottom, 16)
            .phoneGlass(in: UnevenRoundedRectangle(topLeadingRadius: 28 * CGFloat(live.appearance.cornerScale),
                topTrailingRadius: 28 * CGFloat(live.appearance.cornerScale)))
            .padding(.horizontal, -24 * CGFloat(live.appearance.spacingScale)).padding(.bottom, -12 * CGFloat(live.appearance.spacingScale))
    }
}
private extension View {
    func journeyDockSurface() -> some View { modifier(JourneyDockSurface()) }
}

private struct JourneyWaitingActions: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let index: Int
    let board: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Button { model.showWalkOnMap(index) } label: {
                    Label(live.text("走到站牌"), systemImage: "figure.walk")
                        .liveFont(.subheadline, weight: .semibold).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(planner.selected?.verified != true || planner.selected?.walkIssue != nil)
                    .accessibilityHint("在目前地圖查看步行路線")
                    .accessibilityIdentifier("journey-walk-to-stop")
                Button(action: board) {
                    Text(live.text("已上車")).liveFont(.subheadline, weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(planner.selected?.verified != true || planner.selected?.walkIssue != nil)
                    .accessibilityIdentifier("journey-board")
            }
            if let option = planner.selected, index == 0 {
                if planner.checkingWalks { ProgressView().controlSize(.small) }
                else if let walk = option.walks.first, let duration = walk.duration, duration >= 30 {
                    Text(walk.timeLabel).liveFont(.caption).foregroundStyle(.secondary)
                }
                if let issue = option.walkIssue { Text(issue).liveFont(.caption).foregroundStyle(.orange) }
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    if model.journeyDuration(option, at: timeline.date)?.waits.first?.missedNext == true {
                        Text("下一班可能趕不上").liveFont(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

struct JourneyOptionsView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let collapse: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if planner.planning || model.loading {
                HStack(spacing: 10) { ProgressView(); Text(live.text("查詢中")).liveFont(.subheadline) }.padding(.vertical, 8)
            }
            if let message = planner.message { Text(message).liveFont(.subheadline).foregroundStyle(.secondary) }
            ForEach(planner.options) { option in
                Button { planner.select(option); collapse() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if let label = planner.optionLabels[option.id], !option.walkingOnly {
                                Text(label).liveFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                            }
                            if option.walkingOnly { Label(live.text("步行即可"), systemImage: "figure.walk").liveFont(.headline) }
                            else {
                                ForEach(Array(option.rides.enumerated()), id: \.element.id) { index, ride in
                                    if index > 0 { Image(systemName: "arrow.right").liveFont(.caption).foregroundStyle(.secondary) }
                                    RouteBadge(name: ride.route.name)
                                }
                            }
                            Spacer(minLength: 4)
                            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                                Text(model.journeyDuration(option, at: timeline.date)?.comparisonLabel ?? "確認接駁中")
                                    .liveFont(.subheadline, weight: .semibold).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                            }
                            Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
                        }
                        if let first = option.rides.first, let last = option.rides.last {
                            Text(first.boarding.name + " → " + last.alighting.name)
                                .liveFont(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        HStack(spacing: 4) {
                            Text((option.walkingOnly ? "" : option.rides.count > 1 ? "轉乘 1 次 · " : "直達 · ") + option.walkingTimeLabel)
                        }.liveFont(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        TimelineView(.periodic(from: .now, by: 15)) { timeline in
                            if let timing = model.journeyDuration(option, at: timeline.date) {
                                HStack(spacing: 6) {
                                    Text(option.walkingOnly ? "" : "行程 \(max(1, Int(ceil(timing.travelSeconds / 60)))) 分 · " + timing.waitingLabel)
                                    Spacer(minLength: 2)
                                    Text(timing.arrivalLabel).monospacedDigit()
                                }.liveFont(.caption).foregroundStyle(timing.unknownWaits > 0 ? Color.orange : Color.secondary)
                            }
                        }
                        if let issue = option.walkIssue { Text(issue).liveFont(.caption).foregroundStyle(.orange).lineLimit(2) }
                        if let unavailable = planner.unavailableBoarding(option) {
                            Text(unavailable.route + " · " + EstimateFeed.label(unavailable.status))
                                .liveFont(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!option.verified || option.walkIssue != nil || planner.unavailableBoarding(option) != nil)
                    .accessibilityIdentifier("journey-option-" + option.id)
                Divider()
            }
            if planner.checkingWalks { HStack(spacing: 8) { ProgressView(); Text("確認接駁與其他方案").liveFont(.caption).foregroundStyle(.secondary) }.padding(.vertical, 8) }
            if planner.comparisonChanged, !planner.checkingWalks {
                Button { planner.refreshRecommendations() } label: {
                    Label("更新推薦", systemImage: "arrow.clockwise").liveFont(.subheadline).frame(minHeight: 44)
                }.accessibilityIdentifier("journey-refresh-options")
            }
            if planner.destination != nil, !planner.planning {
                Button { planner.openAppleTransit() } label: {
                    HStack {
                        Label(live.text("其他交通方式"), systemImage: "map")
                        Spacer()
                        if let seconds = planner.freshAlternativeTransitSeconds,
                           planner.options.first.flatMap({ model.journeyDuration($0, at: Date())?.totalSeconds }).map({ seconds < $0 - 300 }) ?? true {
                            Text("Apple 公運約 \(max(1, Int(ceil(seconds / 60)))) 分").monospacedDigit()
                        }
                        Image(systemName: "arrow.up.right")
                    }.liveFont(.subheadline).frame(minHeight: 44)
                }
                .accessibilityIdentifier("journey-other-transit")
            }
        }
    }
}

struct JourneyItineraryView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var body: some View {
        if let option = planner.selected {
            VStack(alignment: .leading, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    if let duration = model.journeyDuration(option, at: timeline.date) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(planner.started ? duration.label.replacingOccurrences(of: "全程", with: "剩餘").replacingOccurrences(of: "行程", with: "剩餘行程") : duration.label)
                                .liveFont(.title2, weight: .bold).monospacedDigit()
                            Text(duration.arrivalLabel).liveFont(.subheadline, weight: .semibold).monospacedDigit()
                            HStack(spacing: 14) {
                                Label("\(Int(ceil(duration.walkingSeconds / 60))) 分", systemImage: "figure.walk")
                                Label(planner.started && duration.waitingSeconds < 30 && duration.unknownWaits == 0 ? "無需再候車" : duration.waitingLabel, systemImage: "clock")
                                Label("\(Int(ceil(duration.ridingSeconds / 60))) 分", systemImage: "bus.fill")
                            }.liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                            if duration.uncertainWaits > 0 {
                                Text("含估計候車時間，班次更新後會調整").liveFont(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityElement(children: .combine).accessibilityIdentifier("journey-duration-breakdown")
                    }
                }
                ForEach(option.walks.indices, id: \.self) { index in
                    let walk = option.walks[index]
                    let walked = planner.started && (planner.steps.firstIndex(of: .walk(index)) ?? Int.max) < planner.stepIndex
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "figure.walk").liveFont(.title3).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text((walked ? "已走到 " : "走到 ") + (index < option.rides.count ? option.rides[index].boarding.name : planner.destination?.name ?? "目的地"))
                                .liveFont(.subheadline, weight: .semibold).lineLimit(2)
                                .accessibilityIdentifier("journey-walk-status-\(index)")
                            Text(walked ? "已完成" : walk.timeLabel + (walk.distance.map { " · \(distanceLabel($0))" } ?? ""))
                                .liveFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if !walked {
                        Button { planner.navigateWalk(index) } label: { Image(systemName: "arrow.triangle.turn.up.right.diamond").liveFont(.title3).frame(width: 44, height: 44) }
                            .accessibilityLabel("步行導航到\(index < option.rides.count ? option.rides[index].boarding.name : planner.destination?.name ?? "目的地")")
                            .accessibilityIdentifier("journey-external-walk-\(index)")
                        }
                    }
                    if index < option.rides.count {
                        let ride = option.rides[index]
                        let aboard = planner.started && planner.currentStep == .ride(index)
                        let ridden = planner.started && (planner.steps.firstIndex(of: .ride(index)) ?? Int.max) < planner.stepIndex
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 12) {
                                RouteBadge(name: ride.route.name)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("往 \(ride.route.destination(direction: ride.direction))").liveFont(.subheadline, weight: .semibold)
                                    Text("搭 \(ride.stopCount) 站，在「\(ride.alighting.name)」下車").liveFont(.subheadline).lineLimit(2)
                                }
                            }
                            if ride.route.displayName != ride.route.name { Text(ride.route.displayName).liveFont(.caption).foregroundStyle(.secondary) }
                            if aboard {
                                Text("搭乘中" + (model.onboardPlate(for: ride).map { " · " + $0 } ?? ""))
                                    .liveFont(.subheadline, weight: .semibold).accessibilityIdentifier("journey-ride-status-\(index)")
                                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                    OnboardSummary(model: model, ride: ride, date: timeline.date)
                                }
                            } else if ridden {
                                Text("已下車").liveFont(.caption).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("journey-ride-status-\(index)")
                            } else { JourneyArrivalView(model: model, ride: ride, walk: walk) }
                            HStack {
                                if !aboard, !ridden {
                                Button {
                                    if let station = model.metadata.stations[ride.boarding.stationID] { model.selectStation(station) }
                                } label: { Text(live.text("看上車站預估")).frame(minHeight: 44) }
                                }
                                Spacer()
                                Button { model.selectRoute(ride.route, direction: ride.direction, variantOnly: true) } label: {
                                    Label(live.text("看公車"), systemImage: "bus.fill").frame(minHeight: 44)
                                }
                            }.liveFont(.subheadline)
                        }.padding(14).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18 * CGFloat(live.appearance.cornerScale)))
                    }
                }
            }.padding(.top, 6 * CGFloat(live.appearance.spacingScale))
        }
    }
}

struct JourneyArrivalView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var walk: WalkingLeg?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let eta = model.snapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: timeline.date)
            VStack(alignment: .leading, spacing: 4) {
                Text("路線到站：\(EstimateFeed.label(eta))").liveFont(.subheadline, weight: .medium).monospacedDigit()
                if model.metadata.variants(routeID: ride.route.id).count > 1 {
                    Text("上車前請確認「\(ride.route.displayName)」走法。").liveFont(.caption).foregroundStyle(.secondary)
                }
                if let eta, eta >= 0, let duration = walk?.duration, duration > Double(eta) + 45 {
                    Text(live.text("步行時間較長，這班可能趕不上。")).liveFont(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct JourneyGuideCard: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let showJourney: () -> Void
    @State private var showRideStops = false
    @State private var chooseVehicle = false
    var body: some View {
        if let option = planner.selected {
            if planner.boardingRideIndex != nil {
                JourneyArrivalDock(model: model, planner: planner, showJourney: showJourney)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    JourneyDockHeader(model: model, planner: planner, showJourney: showJourney)
                    if planner.arrived {
                        Label(live.text("已抵達"), systemImage: "checkmark.circle.fill").liveFont(.title2, weight: .bold)
                        Button(live.text("完成")) { model.finishJourney() }
                            .frame(maxWidth: .infinity, minHeight: 46).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    } else if case .ride(let index) = planner.currentStep {
                        let ride = option.rides[index]
                        HStack(spacing: 8) {
                            RouteBadge(name: ride.route.name)
                            Text("往 " + ride.route.destination(direction: ride.direction)).liveFont(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let bus = model.onboardVehicle(for: ride) {
                                Button { model.trackApproachingVehicle(bus) } label: {
                                    Image(systemName: "scope").frame(width: 44, height: 44)
                                }.accessibilityLabel("追蹤 " + bus.plate)
                            }
                        }
                        HStack {
                            Button { chooseVehicle = true } label: {
                                Label(model.onboardPlate(for: ride) ?? "選擇搭乘車牌", systemImage: "bus")
                                    .liveFont(.caption).monospaced().frame(minHeight: 44)
                            }.accessibilityIdentifier("journey-onboard-vehicle")
                            Spacer()
                            Button { showRideStops = true } label: { Text("沿途站牌").liveFont(.subheadline).frame(minHeight: 44) }
                                .accessibilityIdentifier("journey-ride-stops")
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            OnboardSummary(model: model, ride: ride, date: timeline.date)
                        }
                        if option.rides.indices.contains(index + 1) {
                            let next = option.rides[index + 1]
                            Text("接著轉搭 \(next.route.name) · \(next.boarding.name)").liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        HStack(spacing: 12) {
                            Button(live.text("返回等車")) { model.returnToWaiting() }
                                .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.bordered).buttonBorderShape(.capsule)
                            Button(live.text("已下車")) { model.alight() }
                                .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                .accessibilityIdentifier("journey-alight")
                        }.liveFont(.subheadline, weight: .semibold)
                    } else {
                        let index: Int = { if case .walk(let value) = planner.currentStep { return value }; return 0 }()
                        Text("走到「\(planner.destination?.name ?? "目的地")」").liveFont(.title2, weight: .bold).lineLimit(2)
                        if option.walks.indices.contains(index) {
                            Text(option.walks[index].timeLabel).liveFont(.subheadline).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button { if !planner.started { planner.begin() }; model.showWalkOnMap(index) } label: {
                                Label(live.text("看步行路線"), systemImage: "figure.walk")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityHint("在目前地圖查看步行路線")
                            Button(live.text("已抵達")) { if !planner.started { planner.begin() }; planner.advance() }
                                .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                .accessibilityIdentifier("journey-arrive")
                        }.liveFont(.subheadline, weight: .semibold)
                    }
                }.journeyDockSurface()
                    .sheet(isPresented: $showRideStops) {
                        if let ride = planner.activeRide { OnboardStopsView(model: model, ride: ride) }
                    }
                    .sheet(isPresented: $chooseVehicle) {
                        if let ride = planner.activeRide { BoardedVehiclePicker(model: model, ride: ride) }
                    }
            }
        }
    }
}
