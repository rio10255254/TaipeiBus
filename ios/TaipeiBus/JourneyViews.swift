import SwiftUI
import MapKit
import TransitCore

struct JourneyPlanningView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    @ObservedObject var location: LocationService
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

    private var searchingPlaces: Bool { editingOrigin || editingDestination }
    private var showingPreview: Bool { compact && !searchingPlaces && !planner.started && planner.selected != nil }
    private var searchContext: Coordinate? {
        planner.usingLocation ? location.usableCoordinate ?? location.displayCoordinate : planner.origin?.coordinate
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if showingPreview { JourneyMapPreviewView(model: model, planner: planner) }
                    else {
                    originButton
                    if searchingPlaces { placeSearch }
                    else {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(planner.destination?.name ?? "目的地").liveFont(.title, weight: .bold).lineLimit(2)
                                Text(planner.destination?.address ?? "").liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button(live.text("更改")) { edit(origin: false) }.frame(minHeight: 44)
                        }
                        if planner.started {
                            JourneyItineraryView(model: model, planner: planner)
                        } else {
                            JourneyOptionsView(model: model, planner: planner, collapse: { dismiss() })
                        }
                    }
                    }
                }.padding(.horizontal, 20 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 16 * CGFloat(live.appearance.spacingScale))
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if showingPreview {
                    JourneyStartButton(model: model, planner: planner) {
                        if planner.selected?.walkingOnly == true { planner.begin(); dismiss() }
                        else { planner.boardCurrentRide(); dismiss() }
                    }
                    .padding(.horizontal, 20 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 12 * CGFloat(live.appearance.spacingScale)).background(.regularMaterial)
                }
            }
            .navigationTitle(showingPreview ? planner.destination?.name ?? "目的地" : editingOrigin ? "出發地" : searchingPlaces ? "目的地" : planner.started ? "行程" : "搭車方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(live.text(searchingPlaces ? "取消" : "返回地圖")) {
                        if searchingPlaces, planner.destination != nil {
                            focused = false; resolveTask?.cancel(); search.cancel()
                            resolving = false; editingOrigin = false; editingDestination = false
                        } else { dismiss() }
                    }
                }
                if showingPreview {
                ToolbarItem(placement: .confirmationAction) {
                    Button(live.text("換路線")) { expand() }
                }
                }
            }
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
        editingOrigin = origin; editingDestination = !origin; query = ""; searchError = nil; focused = true
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

private struct JourneyMapPreviewView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var body: some View {
        if let option = planner.selected {
            if let ride = option.rides.first { JourneyBoardingView(model: model, ride: ride) }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(live.text("步行即可抵達"), systemImage: "figure.walk").liveFont(.title3, weight: .semibold)
                    Text(option.walkingTimeLabel).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
    private var guide: BoardingGuide { BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            platform
            headline
            HStack {
                Text(live.text("到站車輛")).liveFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showTimingInfo = true } label: { Image(systemName: "info.circle").liveFont(.caption).frame(width: 28, height: 28) }
                    .accessibilityLabel(live.text("到站時間說明"))
                    .popover(isPresented: $showTimingInfo) {
                        Text(live.text("官方時間是這條路線的到站預估，沒有指定車牌。各車時間依位置、近期移動和中途停靠估算。定位不足時不顯示時間。"))
                            .liveFont(.subheadline).padding(20).frame(maxWidth: 300).presentationCompactAdaptation(.popover)
                    }
            }
            .padding(.bottom, -10)
            if guide.approaches.isEmpty { Text(live.text("暫無車輛位置")).liveFont(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6 * CGFloat(live.appearance.spacingScale)) }
            VStack(spacing: 0) {
                ForEach(Array(guide.approaches.prefix(3))) { approach in
                    BoardingVehicleRow(model: model, ride: ride, approach: approach, date: date)
                    if approach.id != guide.approaches.prefix(3).last?.id { Divider() }
                }
            }
            if let bus = model.selectedVehicle, bus.routeID == ride.route.id, bus.direction == ride.direction,
               !guide.approaches.contains(where: { $0.id == bus.id }) {
                let passed = model.metadata.journey(routeID: bus.routeID, direction: bus.direction)?
                    .progress(stopID: ride.boarding.id, vehicle: bus, at: date).map { $0.distance < -20 } ?? false
                Text(bus.plate + (passed ? " · 已離開上車站" : " · 位置更新中"))
                    .liveFont(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ride.route.name).liveFont(.title, weight: .bold, design: .rounded)
                    .foregroundStyle(Color(liveHex: live.appearance.accentColor)).lineLimit(1).minimumScaleFactor(0.65)
                    .accessibilityIdentifier("boarding-route")
                Text(live.text("往 ") + ride.route.destination(direction: ride.direction)).liveFont(.caption).lineLimit(1)
                if ride.route.displayName != ride.route.name { Text(ride.route.displayName).liveFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(guide.arrivalShortLabel).liveFont(.largeTitle, weight: .bold, design: .rounded)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(guide.estimateSeconds == nil ? "暫無預估" : "官方到站").liveFont(.caption).foregroundStyle(.secondary)
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
                Text(model.arrivalEstimate(approach, ride: ride, at: date).label)
                    .liveFont(.subheadline, weight: .semibold, design: .rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                Label(tracking ? "追蹤中" : "追蹤", systemImage: "scope").liveFont(.caption)
                    .foregroundStyle(tracking ? Color(liveHex: live.appearance.accentColor) : Color.secondary)
            }.frame(minHeight: 48).padding(.vertical, 4 * CGFloat(live.appearance.spacingScale)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("點一下追蹤這輛公車")
            .accessibilityValue(tracking ? "追蹤中" : selected ? "已選擇" : "")
            .accessibilityIdentifier("boarding-vehicle-" + approach.vehicle.plate)
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
                JourneyWaitingActions(model: model, planner: planner, index: index) { planner.boardCurrentRide() }
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
            Text(planner.destination?.name ?? "目的地").liveFont(.subheadline, weight: .medium).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button(live.text(planner.started ? "行程" : "路線"), action: showJourney)
                .liveFont(.subheadline).frame(minHeight: 36).accessibilityIdentifier("journey-options")
            Button { planner.finish(); model.clearSelection() } label: {
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
                Button { planner.navigateWalk(index) } label: {
                    Label(live.text("走到站牌"), systemImage: "figure.walk")
                        .liveFont(.subheadline, weight: .semibold).frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(planner.selected?.walkIssue != nil)
                    .accessibilityHint("開啟 Apple 地圖步行導航")
                    .accessibilityIdentifier("journey-walk-to-stop")
                Button(action: board) {
                    Text(live.text("已上車")).liveFont(.subheadline, weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .accessibilityIdentifier("journey-board")
            }
            if let option = planner.selected, index == 0 {
                if planner.checkingWalks { ProgressView().controlSize(.small) }
                else if let walk = option.walks.first, let duration = walk.duration, duration >= 30 {
                    Text(walk.timeLabel).liveFont(.caption).foregroundStyle(.secondary)
                }
                if let issue = option.walkIssue { Text(issue).liveFont(.caption).foregroundStyle(.orange) }
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    if let ride = planner.activeRide, let walk = option.walks.first,
                       let eta = model.snapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: timeline.date),
                       eta >= 0, let duration = walk.duration, duration > Double(eta) + 45 {
                        Text(live.text("這班可能趕不上")).liveFont(.caption).foregroundStyle(.orange)
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
        VStack(alignment: .leading, spacing: 16) {
            if planner.planning || model.loading {
                HStack(spacing: 12) { ProgressView(); Text(live.text("查詢中")).liveFont(.subheadline) }.padding(.vertical, 16 * CGFloat(live.appearance.spacingScale))
            }
            if let message = planner.message { Text(message).liveFont(.subheadline).foregroundStyle(.secondary) }
            ForEach(planner.options) { option in
                Button { planner.select(option); collapse() } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            if option.walkingOnly { Label(live.text("步行即可"), systemImage: "figure.walk").liveFont(.headline) }
                            else {
                                ForEach(option.rides) { ride in RouteBadge(name: ride.route.name) }
                                Text(option.rides.count == 1 ? "直達" : "轉乘 1 次").liveFont(.subheadline, weight: .medium)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        if let first = option.rides.first, let last = option.rides.last {
                            HStack(alignment: .firstTextBaseline) {
                                Text("上車 · \(first.boarding.name)").liveFont(.subheadline, weight: .semibold).lineLimit(2)
                                Spacer()
                                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                    Text(BoardingGuide(ride: first, metadata: model.metadata, snapshot: model.snapshot, at: timeline.date).arrivalShortLabel)
                                        .liveFont(.subheadline, weight: .semibold).monospacedDigit()
                                }
                            }
                            Text("下車 · \(last.alighting.name)").liveFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack {
                            Text(option.walkingTimeLabel).liveFont(.caption).foregroundStyle(.secondary)
                            if option.id == planner.selectedID && planner.checkingWalks { ProgressView().controlSize(.small) }
                        }
                        if let issue = option.walkIssue { Text(issue).liveFont(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 16 * CGFloat(live.appearance.spacingScale)).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("journey-option-" + option.id)
                Divider()
            }
            if planner.selected != nil {
                DisclosureGroup("查看步行與乘車詳情") {
                    JourneyItineraryView(model: model, planner: planner)
                }.liveFont(.subheadline)
            }
            if planner.destination != nil {
                Button { planner.openAppleTransit() } label: {
                                    Label(live.text("其他交通方式"), systemImage: "map").liveFont(.subheadline).frame(minHeight: 44)
                }
            }
        }
    }
}

private struct JourneyStartButton: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let begin: () -> Void
    var body: some View {
        if let option = planner.selected {
            if option.walkingOnly {
                Button(action: begin) {
                    Label(live.text("開始步行"), systemImage: "figure.walk")
                        .liveFont(.body, weight: .semibold).frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(planner.planning || planner.checkingWalks || option.walkIssue != nil)
            } else {
                JourneyWaitingActions(model: model, planner: planner, index: 0, board: begin)
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
                ForEach(option.walks.indices, id: \.self) { index in
                    let walk = option.walks[index]
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "figure.walk").liveFont(.title3).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(index < option.rides.count ? "走到 \(option.rides[index].boarding.name)" : "走到 \(planner.destination?.name ?? "目的地")")
                                .liveFont(.subheadline, weight: .semibold).lineLimit(2)
                            Text(walk.timeLabel + (walk.distance.map { " · \(distanceLabel($0))" } ?? ""))
                                .liveFont(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { planner.navigateWalk(index) } label: { Image(systemName: "arrow.triangle.turn.up.right.diamond").liveFont(.title3).frame(width: 44, height: 44) }
                            .accessibilityLabel("步行導航到\(index < option.rides.count ? option.rides[index].boarding.name : planner.destination?.name ?? "目的地")")
                    }
                    if index < option.rides.count {
                        let ride = option.rides[index]
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 12) {
                                RouteBadge(name: ride.route.name)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("往 \(ride.route.destination(direction: ride.direction))").liveFont(.subheadline, weight: .semibold)
                                    Text("搭 \(ride.stopCount) 站，在「\(ride.alighting.name)」下車").liveFont(.subheadline).lineLimit(2)
                                }
                            }
                            if ride.route.displayName != ride.route.name { Text(ride.route.displayName).liveFont(.caption).foregroundStyle(.secondary) }
                            JourneyArrivalView(model: model, ride: ride, walk: walk)
                            HStack {
                                Button {
                                    if let station = model.metadata.stations[ride.boarding.stationID] { model.selectStation(station) }
                                } label: { Text(live.text("看上車站預估")).frame(minHeight: 44) }
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
    var body: some View {
        if let option = planner.selected {
            if planner.boardingRideIndex != nil {
                JourneyArrivalDock(model: model, planner: planner, showJourney: showJourney)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    JourneyDockHeader(model: model, planner: planner, showJourney: showJourney)
                    if planner.arrived {
                        Label(live.text("已抵達"), systemImage: "checkmark.circle.fill").liveFont(.title2, weight: .bold)
                        Button(live.text("完成")) { planner.finish(); model.clearSelection() }
                            .frame(maxWidth: .infinity, minHeight: 46).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    } else if case .ride(let index) = planner.currentStep {
                        let ride = option.rides[index]
                        HStack(spacing: 8) {
                            RouteBadge(name: ride.route.name)
                            Text("往 " + ride.route.destination(direction: ride.direction)).liveFont(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let bus = model.selectedVehicle {
                                Button { model.following = true; model.focusMap(.vehicle(bus.id)) } label: {
                                    Image(systemName: "scope").frame(width: 44, height: 44)
                                }.accessibilityLabel("追蹤 " + bus.plate)
                            }
                        }
                        Text("在「\(ride.alighting.name)」下車").liveFont(.title2, weight: .bold).lineLimit(2)
                        Text("搭 \(ride.stopCount) 站").liveFont(.subheadline).foregroundStyle(.secondary)
                        if option.rides.indices.contains(index + 1) {
                            let next = option.rides[index + 1]
                            Text("接著轉搭 \(next.route.name) · \(next.boarding.name)").liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        HStack(spacing: 12) {
                            Button(live.text("返回等車")) { planner.returnToWaiting() }
                                .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.bordered).buttonBorderShape(.capsule)
                            Button(live.text("已下車")) { planner.advance() }
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
                            Button { if !planner.started { planner.begin() }; planner.navigateWalk(index) } label: {
                                Label(live.text("步行導航"), systemImage: "figure.walk")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.bordered).buttonBorderShape(.capsule).accessibilityHint("開啟 Apple 地圖步行導航")
                            Button(live.text("已抵達")) { if !planner.started { planner.begin() }; planner.advance() }
                                .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                                .accessibilityIdentifier("journey-arrive")
                        }.liveFont(.subheadline, weight: .semibold)
                    }
                }.journeyDockSurface()
            }
        }
    }
}
