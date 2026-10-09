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
    @State private var editingDestination: Bool
    @State private var resolving = false
    @State private var searchError: String?
    @State private var resolveTask: Task<Void, Never>?
    @State private var resolveToken = UUID()
    @State private var resolvingQuery = ""
    @State private var stationResults: [Station] = []
    @State private var stationResultQuery = ""
    @State private var showingRankingInfo = false
    @State private var searchReturnToItinerary = false

    init(model: TransitAppModel, planner: JourneyPlannerModel, location: LocationService, showingItinerary: Binding<Bool>,
         compact: Bool, expand: @escaping () -> Void, collapse: @escaping () -> Void) {
        self.model = model; self.planner = planner; self.location = location
        _showingItinerary = showingItinerary
        self.compact = compact; self.expand = expand; self.collapse = collapse
        // Start on the page the sheet will actually show. Starting on place search and flipping
        // in onAppear animated a squeezed search page into every itinerary opening.
        _editingDestination = State(initialValue: planner.destination == nil)
    }

    private var searchingPlaces: Bool { editingOrigin || editingDestination }
    private var searchContext: Coordinate? {
        planner.usingLocation ? location.usableCoordinate ?? location.displayCoordinate : planner.origin?.coordinate
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: compact && !searchingPlaces ? 12 : 20) {
                    if searchingPlaces { originButton }
                    else if !planner.started && !showingItinerary { routeEndpoints }
                    if searchingPlaces { placeSearch }
                    else {
                        if planner.started || showingItinerary {
                            JourneyItineraryView(model: model, planner: planner, showMap: {
                                if planner.started { dismiss() }
                                else { showingItinerary = false; collapse() }
                            })
                        } else {
                            JourneyOptionsView(model: model, planner: planner, collapse: {
                                showingItinerary = false; collapse()
                            }, compact: compact, expand: expand, showSteps: {
                                showingItinerary = true; expand()
                            }, go: { option in
                                // Apple Maps' Go: start the shown option straight from its card.
                                planner.select(option); planner.begin()
                                guard planner.started else { return }
                                if case .walk(let index) = planner.currentStep { model.showWalkOnMap(index) }
                                dismiss()
                            })
                        }
                    }
                }.padding(.horizontal, 16 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 12 * CGFloat(live.appearance.spacingScale))
                    .smoothChanges(searchingPlaces)
                    .smoothChanges(showingItinerary)
                    .smoothChanges(model.language)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if !searchingPlaces, showingItinerary, !planner.started, planner.selected != nil {
                    Button {
                        planner.begin()
                        guard planner.started else { return }
                        if case .walk(let index) = planner.currentStep { model.showWalkOnMap(index) }
                        dismiss()
                    } label: {
                        Label(AppText.text("開始導航"), systemImage: "location.fill")
                            .liveFont(.body, weight: .bold).frame(maxWidth: .infinity, minHeight: 52)
                    }.buttonStyle(MapActionStyle(prominent: true, tint: MapChrome.go)).accessibilityIdentifier("journey-start-navigation")
                        .disabled(planner.selected.map { !$0.verified || $0.walkIssue != nil || planner.unavailableBoarding($0) != nil } ?? true)
                        .padding(.horizontal, 20).padding(.vertical, 10).background(.regularMaterial)
                }
            }
            .navigationTitle(editingOrigin ? AppText.text("出發地") : searchingPlaces ? AppText.text("目的地") : planner.started || showingItinerary ? AppText.text("行程") : AppText.text("路線"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if searchingPlaces || showingItinerary || planner.started {
                ToolbarItem(placement: .cancellationAction) {
                    Button(live.text(searchingPlaces ? "取消" : showingItinerary && !planner.started ? "返回路線" : "返回地圖")) {
                        if showingItinerary && !planner.started && !searchingPlaces {
                            model.clearWalkingMap(); showingItinerary = false; collapse()
                            model.focusMap(.journey(planner.mapCoordinates))
                        } else if searchingPlaces, planner.destination != nil {
                            focused = false; resolveTask?.cancel(); search.cancel()
                            resolving = false; editingOrigin = false; editingDestination = false
                            showingItinerary = searchReturnToItinerary; searchReturnToItinerary = false
                            if !planner.started { if showingItinerary { expand() } else { collapse() } }
                        } else { dismiss() }
                    }.accessibilityIdentifier("journey-back")
                }
                }
                if !searchingPlaces {
                    ToolbarItem(placement: .confirmationAction) {
                        if planner.started {
                            Button(live.text("更改")) { edit(origin: false) }
                        } else {
                            Button { model.finishJourney(); dismiss() } label: {
                                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.primary).frame(width: 36, height: 36)
                            }.accessibilityLabel(AppText.text("關閉路線"))
                                .accessibilityIdentifier("journey-close")
                        }
                    }
                    if !planner.started, !showingItinerary {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                Button(live.text("查看行程")) { showingItinerary = true; expand() }
                                Button(AppText.text("重新比較路線")) { planner.refreshRecommendations() }
                                Button(AppText.text("推薦順序說明")) { showingRankingInfo = true }
                                Button(live.text("其他交通方式")) { planner.openAppleTransit() }
                            } label: { Image(systemName: "ellipsis").foregroundStyle(.primary).frame(width: 36, height: 36) }
                                .accessibilityLabel(live.text("更多行程選項"))
                        }
                    }
                }
            }
        }
        .alert(AppText.text("推薦順序"), isPresented: $showingRankingInfo) {
            Button(AppText.text("知道了"), role: .cancel) {}
        } message: {
            Text(AppText.text("先確認實際步行，再比較可趕上的班次、候車與搭車時間。推薦兼顧時間、少走路與少轉乘；較快方案會另外保留。班距推估會標示範圍，班次不足則標示待確認。抵達時間包含走路、候車與搭車。"))
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
    private var routeEndpoints: some View {
        VStack(spacing: 0) {
            Button { edit(origin: true) } label: {
                HStack(spacing: 12) {
                    Image(systemName: planner.usingLocation ? "location.circle.fill" : "mappin.circle.fill")
                        .foregroundStyle(.blue).liveFont(.title2).frame(width: 28)
                    Text(planner.origin?.localizedName ?? AppText.text("選擇出發地"))
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Image(systemName: "chevron.down").liveFont(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("journey-edit-origin")
            Divider().padding(.leading, 40)
            Button { edit(origin: false) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(.red).liveFont(.title2).frame(width: 28)
                    Text(planner.destination?.localizedName ?? AppText.text("目的地"))
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                    Image(systemName: "chevron.down").liveFont(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("journey-edit-destination")
        }.liveFont(.subheadline, weight: .medium).foregroundStyle(.primary).buttonStyle(PhonePressStyle())
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18))
    }
    private var originButton: some View {
        HStack(spacing: 10) {
            Image(systemName: planner.usingLocation ? "location.fill" : "circle.fill").foregroundStyle(Color(liveHex: live.appearance.accentColor))
            Button { edit(origin: true) } label: {
                HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(planner.origin?.localizedName ?? (location.requesting ? AppText.text("取得位置中") : AppText.text("選擇出發地")))
                        .liveFont(.subheadline, weight: .semibold).lineLimit(1)
                    if planner.origin == nil {
                        Text(location.message.map(live.text) ?? AppText.text("可使用定位，或輸入出發地／站名")).liveFont(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").liveFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                }.padding(10).frame(minHeight: 44).contentShape(RoundedRectangle(cornerRadius: 12))
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(PhonePressStyle())
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
                TextField(editingOrigin ? AppText.text("出發地、地址或站名") : AppText.text("地點、地址或站名"), text: $query)
                    .accessibilityIdentifier("journey-search-field")
                    .focused($focused).submitLabel(.search).autocorrectionDisabled()
                    .onSubmit { resolve(text: query) }
                if resolving || search.searching { ProgressView() }
                else if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }.padding(14).frame(minHeight: 52)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 15 * CGFloat(live.appearance.cornerScale)))
            if let error = searchError ?? search.error { Text(live.text(error)).liveFont(.subheadline).foregroundStyle(.secondary) }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { resolve(text: query) } label: {
                    Label(AppText.text("搜尋「%@」", query), systemImage: "arrow.up.right").liveFont(.subheadline, weight: .semibold).frame(minHeight: 44)
                }.secondaryAction().disabled(resolving)
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
            if !stations.isEmpty { Text(live.text("車站與站牌")).liveFont(.subheadline, weight: .semibold).padding(.top, 8 * CGFloat(live.appearance.spacingScale)) }
            ForEach(StationSearch.groups(stations)) { group in
                DisclosureGroup {
                ForEach(group.stations) { station in
                    Button {
                        choose(TravelPlace(name: station.name, address: "\(station.localizedBearing) · \(station.address)", coordinate: station.coordinate, englishName: station.englishName))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: station.mode == .bus ? "bus.fill" : "tram.fill").foregroundStyle(Color(liveHex: live.appearance.accentColor)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(station.localizedBearing.isEmpty ? station.localizedName : station.localizedBearing).liveFont(.subheadline, weight: .medium)
                                Text(station.address.isEmpty ? station.localizedName : station.address).liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
                        }.frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(resolving)
                }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: group.stations.contains(where: { $0.mode != .bus }) ? "tram.fill" : "bus.fill").foregroundStyle(Color(liveHex: live.appearance.accentColor)).frame(width: 22)
                        BilingualName(chinese: group.name, english: group.localizedName).liveFont(.body, weight: .medium)
                        Spacer(minLength: 4)
                        Text(AppText.text("%@ 處", group.stations.count)).liveFont(.caption).foregroundStyle(.secondary)
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
                    BilingualName(chinese: place.name, english: place.englishName ?? AppText.text(place.name)).liveFont(.body, weight: .medium)
                    if !place.address.isEmpty { Text(place.address).liveFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if !place.coordinate.isInServiceArea { Text(live.text("公車規劃範圍外")).liveFont(.caption).foregroundStyle(.secondary) }
                }
                Spacer(); Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
            }.frame(minHeight: 58).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(resolving)
    }
    private func edit(origin: Bool) {
        searchReturnToItinerary = showingItinerary || planner.started
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
        searchReturnToItinerary = false
        focused = false
        if editingOrigin { planner.setOrigin(place, metadata: model.metadata) }
        else { planner.setDestination(place, metadata: model.metadata, currentLocation: location.usableCoordinate) }
        editingOrigin = false; editingDestination = planner.destination == nil; query = ""
        search.cancel()
        if planner.destination != nil, planner.origin == nil { edit(origin: true) }
        else if planner.destination != nil { collapse() }
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
        if ride.route.mode != .bus {
            MetroBoardingRows(model: model, ride: ride, date: date)
        } else {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
#if DEBUG
                    model.recordMapTap("show-arrivals")
#endif
                    model.showingArrivingVehicles = true
                } label: {
                    HStack(spacing: 4) {
                        Text(AppText.text("到站車輛"))
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }.liveFont(.subheadline, weight: .semibold).frame(minHeight: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.primary).accessibilityIdentifier("journey-all-vehicles")
                Spacer()
                Button { showTimingInfo = true } label: { Image(systemName: "info.circle").liveFont(.subheadline).frame(width: 32, height: 32) }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(live.text("到站時間說明"))
                    .popover(isPresented: $showTimingInfo) {
                        Text(live.text("候車以官方下一班到站時間為主。官方未指定車牌；各車紀錄足夠才顯示分鐘數，否則先看位置與站數。地圖平順銜接已收到的定位，保留短暫緩衝。點「到站車輛」可查看時間說明。"))
                            .liveFont(.subheadline).padding(20).frame(maxWidth: 300).presentationCompactAdaptation(.popover)
                    }
            }
            if guide.nextBusWithoutPosition {
                NextBusRow(guide: guide)
                    .background(Color(uiColor: .systemBackground).opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if guide.approaches.isEmpty { Text(live.text(guide.emptyPositionLabel)).liveFont(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6 * CGFloat(live.appearance.spacingScale)) }
            else {
                VStack(spacing: 0) {
                    ForEach(Array(guide.approaches.prefix(3))) { approach in
                        BoardingVehicleRow(model: model, ride: ride, approach: approach, date: date)
                        if approach.id != guide.approaches.prefix(3).last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(Color(uiColor: .systemBackground).opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            if let bus = model.selectedVehicle, model.metadata.canServe(ride, vehicle: bus),
               !guide.approaches.contains(where: { $0.id == bus.id }) {
                let passed = model.metadata.journey(routeID: bus.routeID, direction: bus.direction)?
                    .progress(stopID: ride.boarding.id, vehicle: bus, at: date).map { $0.distance < -20 } ?? false
                Text(bus.plate + (passed ? AppText.text(" · 已離開上車站") : AppText.text(" · 位置更新中")))
                    .liveFont(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The officially timed next bus, listed even before its GPS appears on the route.
private struct NextBusRow: View {
    @Environment(\.liveSettings) private var live
    let guide: BoardingGuide
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bus.fill").liveFont(.subheadline, weight: .semibold).foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(live.text("下一班")).liveFont(.body, weight: .semibold)
                Text(live.text(guide.emptyPositionLabel)).liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(guide.arrivalShortLabel).liveFont(.body, weight: .bold).monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine).accessibilityIdentifier("boarding-next-bus-without-position")
    }
}

struct VehicleArrivalsView: View {
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
                        HStack { BilingualName(ride.boarding); Spacer(); Text(guide.arrivalShortLabel).bold().monospacedDigit() }
                        Text(AppText.text("往 ") + ride.route.localizedDestination(direction: ride.direction)).foregroundStyle(.secondary)
                    } header: { Text(AppText.text("官方下一班")) }
                    Section {
                        if guide.nextBusWithoutPosition { NextBusRow(guide: guide) }
                        else if guide.approaches.isEmpty { Text(live.text(guide.emptyPositionLabel)).foregroundStyle(.secondary) }
                        ForEach(guide.approaches) { approach in
                            VStack(alignment: .leading, spacing: 3) {
                                BoardingVehicleRow(model: model, ride: ride, approach: approach, date: timeline.date)
                                let display = model.arrivalDisplay(approach.vehicle, stopID: ride.boarding.id, at: timeline.date)
                                DisclosureGroup("時間說明") {
                                    Text(display.positionLabel)
                                    if let prediction = display.prediction { Text(prediction.rangeLabel) }
                                    Text(display.explanation)
                                    Text(AppText.text("車輛位置更新於 ") + approach.vehicle.observedAt.formatted(date: .omitted, time: .standard))
                                }.liveFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: { Text(AppText.text("%@ · 已發車車輛", ride.route.localizedName)) }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle(AppText.text("到站車輛")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppText.text("完成")) { dismiss() }.accessibilityIdentifier("journey-vehicles-done") } }
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
            .upcoming(vehicle: approach.vehicle, at: date).first?.stop.localizedName
    }
    var body: some View {
        Button {
            if tracking { model.following = false }
            else { model.trackApproachingVehicle(approach.vehicle) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(approach.vehicle.plate).liveFont(.subheadline, weight: .semibold).monospaced()
                    if selected { Text(nextStop.map { AppText.text("前方 · ") + $0 } ?? AppText.text("位置待確認")).liveFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(model.arrivalDisplay(approach.vehicle, stopID: ride.boarding.id, at: date).label)
                    .liveFont(.subheadline, weight: .semibold, design: .rounded).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                Label(tracking ? AppText.text("追蹤中") : AppText.text("追蹤"), systemImage: "scope").liveFont(.caption, weight: .semibold)
                    .foregroundStyle(tracking ? Color.white : Color(liveHex: live.appearance.accentColor))
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .background(Color(liveHex: live.appearance.accentColor).opacity(tracking ? 1 : 0.12), in: Capsule())
                    .animation(.smooth(duration: 0.2), value: tracking)
            }.frame(minHeight: 48).padding(.vertical, 2 * CGFloat(live.appearance.spacingScale)).padding(.horizontal, 14).contentShape(Rectangle())
        }.buttonStyle(PhonePressStyle()).foregroundStyle(.primary).accessibilityHint(tracking ? AppText.text("停止追蹤") : AppText.text("點一下追蹤這輛公車"))
            .accessibilityValue(tracking ? AppText.text("追蹤中") : selected ? AppText.text("已選擇") : "")
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
            if ride.route.mode != .bus {
                MetroOnboardSummary(model: model, ride: ride, date: date)
            } else if let bus = model.onboardVehicle(for: ride) {
                let journey = model.metadata.journey(routeID: bus.routeID, direction: bus.direction)
                let next = journey?.progress(stopID: ride.alighting.id, vehicle: bus, at: date) != nil
                    ? model.onboardStops(for: ride, at: date).first : nil
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.map { AppText.text("下一站 · ") + $0.localizedName } ?? AppText.text("位置更新中")).lineLimit(2)
                        if live.language == .english, let next { Text(next.name).liveFont(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let next {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.onboardEstimateLabel(bus, stopID: next.id, at: date)).lineLimit(2).minimumScaleFactor(0.75)
                            Text(AppText.remainingStops(1)).liveFont(.caption)
                        }.monospacedDigit().frame(width: live.language == .english ? 115 : 110, alignment: .trailing)
                    }
                }.liveFont(.subheadline).foregroundStyle(.secondary).accessibilityElement(children: .combine).accessibilityIdentifier("journey-next-stop")
                let progress = journey?.progress(stopID: ride.alighting.id, vehicle: bus, at: date)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text((progress?.distance ?? 0) < -20 ? AppText.text("已通過「%@」", ride.alighting.localizedName) : AppText.text("在「%@」下車", ride.alighting.localizedName))
                            .liveFont(.title3, weight: .bold).lineLimit(2)
                        if live.language == .english { Text(ride.alighting.name).liveFont(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.onboardEstimateLabel(bus, stopID: ride.alighting.id, at: date))
                            .liveFont(.title3, weight: .bold).monospacedDigit().lineLimit(2).minimumScaleFactor(0.75)
                            .frame(maxWidth: live.language == .english ? 115 : 110, alignment: .trailing)
                        if let count = model.onboardStops(for: ride, at: date).firstIndex(where: { $0.id == ride.alighting.id }) {
                            Text(AppText.remainingStops(count + 1)).liveFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityElement(children: .combine).accessibilityIdentifier("journey-alighting-time")
            } else {
                Text(AppText.text("在「%@」下車", ride.alighting.localizedName)).liveFont(.title3, weight: .bold).lineLimit(2)
                if live.language == .english { Text(ride.alighting.name).liveFont(.caption).foregroundStyle(.secondary) }
                Text(model.onboardPlate(for: ride) == nil ? AppText.text("選擇車牌即可看沿途時間") : AppText.text("車輛位置更新中"))
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
                let stops = ride.route.mode == .bus ? model.onboardStops(for: ride, at: timeline.date) : model.metroRemaining(ride, at: timeline.date).stops
                List {
                    Section {
                        if ride.route.mode != .bus {
                            Text(AppText.text("依站間車程估計 · 到站請確認站名")).foregroundStyle(.secondary)
                        } else if let plate = model.onboardPlate(for: ride) {
                            Text(plate).monospaced().bold().accessibilityIdentifier("onboard-confirmed-plate")
                            if bus?.hasReliablePosition(at: timeline.date) != true { Text(AppText.text("車輛位置更新中")).foregroundStyle(.secondary) }
                        } else { Text(AppText.text("請先在搭車畫面選擇車牌")).foregroundStyle(.secondary) }
                    } header: { Text(ride.route.localizedName + AppText.text(" · 往 ") + ride.route.localizedDestination(direction: ride.direction)) }
                    Section {
                        ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                            HStack(spacing: 12) {
                                Image(systemName: stop.id == ride.alighting.id ? "arrow.down.circle.fill" : "circle.fill")
                                    .font(.system(size: stop.id == ride.alighting.id ? 20 : 8))
                                    .foregroundStyle(stop.id == ride.alighting.id ? Color.orange : Color.secondary).frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    BilingualName(stop).liveFont(.subheadline, weight: stop.id == ride.alighting.id ? .bold : .regular)
                                    if stop.id == ride.alighting.id { Text(AppText.text("在這裡下車")).liveFont(.caption).foregroundStyle(.orange) }
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(ride.route.mode != .bus ? model.metroStopLabel(ride, stop: stop, at: timeline.date) : bus.map { model.onboardEstimateLabel($0, stopID: stop.id, at: timeline.date) } ?? live.text("時間待確認"))
                                        .liveFont(.subheadline, weight: .semibold).monospacedDigit().lineLimit(2)
                                    Text(AppText.remainingStops(index + 1)).liveFont(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: live.language == .english ? 115 : 110, alignment: .trailing)
                            }.frame(minHeight: 40).accessibilityIdentifier("onboard-stop-" + stop.id)
                        }
                    } header: { Text(AppText.text("這輛車的沿途預估")) } footer: {
                        Text(ride.route.mode != .bus ? AppText.text("依官方捷運站間車程") : bus.map { model.arrivalDisplay($0, stopID: ride.alighting.id, at: timeline.date, onboard: true).explanation }
                             ?? AppText.text("時間依行駛情況更新，塞車與停靠可能影響預估。"))
                    }
                }.listStyle(.insetGrouped)
            }
            .navigationTitle(ride.route.mode == .bus ? AppText.text("沿途站牌") : AppText.text("沿線車站")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(AppText.text("完成")) { dismiss() }.accessibilityIdentifier("journey-stops-done") } }
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
                    if vehicles.isEmpty { Text(AppText.text("暫無車輛位置，稍後再選擇")).foregroundStyle(.secondary) }
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
                } header: { Text(ride.route.localizedName + AppText.text(" · 往 ") + ride.route.localizedDestination(direction: ride.direction)) } footer: { Text(AppText.text("依車內或車身顯示的車牌選擇。")) }
            }.navigationTitle(AppText.text("搭乘車牌")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppText.text("取消")) { dismiss() } } }
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(planner.destination?.localizedName ?? AppText.text("目的地")).liveFont(.headline, weight: .bold).lineLimit(1)
                if let option = planner.selected {
                    TimelineView(.periodic(from: .now, by: 15)) { timeline in
                        if let duration = model.journeyDuration(option, at: timeline.date) {
                            Text((planner.started ? duration.summaryLabel(remaining: true) : duration.label) + " · " + duration.arrivalLabel)
                                .liveFont(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
                                .accessibilityIdentifier("journey-total-duration")
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            Button(action: showJourney) {
                Image(systemName: "list.bullet").liveFont(.body, weight: .semibold).frame(width: 40, height: 40)
            }
            .buttonStyle(MapActionStyle(tint: Color.primary))
            .accessibilityLabel(live.text(planner.started ? "行程" : "路線"))
            .accessibilityIdentifier("journey-options")
            Button { model.finishJourney() } label: {
                Text(AppText.text("結束")).liveFont(.subheadline, weight: .bold).padding(.horizontal, 14).frame(minHeight: 40)
            }
            .buttonStyle(MapActionStyle(tint: MapChrome.destructive))
            .accessibilityLabel(live.text("結束行程"))
        }
    }
}

private struct JourneyDockSurface: ViewModifier {
    @Environment(\.liveSettings) private var live
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MapChrome.cardRadius * CGFloat(live.appearance.cornerScale), style: .continuous)
        content.padding(.horizontal, 16 * CGFloat(live.appearance.spacingScale)).padding(.top, 14)
            .padding(.bottom, 16)
            .background {
                if reduceTransparency || live.appearance.solidSurfaces { shape.fill(Color(uiColor: .secondarySystemBackground)) }
                else { shape.fill(.thickMaterial) }
            }
            .overlay { shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.16 : 0.07), lineWidth: 0.6) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.14), radius: 18, y: 6)
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
                if planner.selected?.walks.indices.contains(index) == true, planner.selected?.walks[index].internalTransfer != true {
                Button { model.showWalkOnMap(index) } label: {
                    Label(planner.activeRide?.route.mode == .bus ? live.text("走到站牌") : live.text("走到車站"), systemImage: "figure.walk")
                        .liveFont(.body, weight: .semibold).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 50)
                }.buttonStyle(MapActionStyle())
                    .disabled(planner.selected?.verified != true || planner.selected?.walkIssue != nil)
                    .accessibilityHint(AppText.text("在目前地圖查看步行路線"))
                    .accessibilityIdentifier("journey-walk-to-stop")
                }
                Button(action: board) {
                    Text(live.text("已上車")).liveFont(.body, weight: .bold).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }.buttonStyle(MapActionStyle(prominent: true))
                    .disabled(planner.selected?.verified != true || planner.selected?.walkIssue != nil)
                    .accessibilityIdentifier("journey-board")
            }
            if let option = planner.selected, index == 0 {
                if planner.checkingWalks { ProgressView().controlSize(.small) }
                else if let walk = option.walks.first, let duration = walk.duration, duration >= 30 {
                    Text(planner.walkingStatus(at: index) ?? walk.timeLabel).liveFont(.caption).foregroundStyle(.secondary).accessibilityIdentifier("walking-live-status")
                }
                if let issue = option.walkIssue { Text(issue).liveFont(.caption).foregroundStyle(MapChrome.caution) }
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    if model.journeyDuration(option, at: timeline.date)?.waits.first?.missedNext == true {
                        Label(AppText.text("下一班可能趕不上"), systemImage: "exclamationmark.triangle.fill")
                            .liveFont(.caption, weight: .semibold).foregroundStyle(MapChrome.caution)
                    }
                }
            }
        }
    }
}

/// Route signs wrap as complete segments instead of shrinking a mixed trip into tiny text.
private struct JourneyChainLayout: Layout {
    var spacing: CGFloat = 6
    private func arrangement(_ subviews: Subviews, width: CGFloat) -> (sizes: [CGSize], points: [CGPoint], height: CGFloat) {
        var sizes: [CGSize] = [], points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for item in subviews {
            let natural = item.sizeThatFits(.unspecified)
            let size = natural.width > width ? item.sizeThatFits(ProposedViewSize(width:width,height:nil)) : natural
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            sizes.append(size); points.append(CGPoint(x:x,y:y))
            x += size.width + spacing; row = max(row,size.height)
        }
        return (sizes,points,y + row)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width + spacing }.reduce(0,+)
        return CGSize(width:width,height:arrangement(subviews,width:max(1,width)).height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let result = arrangement(subviews,width:max(1,bounds.width))
        for index in subviews.indices {
            subviews[index].place(at:CGPoint(x:bounds.minX + result.points[index].x,y:bounds.minY + result.points[index].y),
                anchor:.topLeading,proposal:ProposedViewSize(width:result.sizes[index].width,height:result.sizes[index].height))
        }
    }
}

private struct JourneyRouteChain: View {
    let option: JourneyOption
    var body: some View {
        JourneyChainLayout {
            ForEach(option.walks.indices, id: \.self) { index in
                if option.rides.indices.contains(index) || (option.walks[index].duration ?? 0) >= 30 {
                HStack(spacing: 5) {
                if let duration = option.walks[index].duration, duration >= 30 {
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    HStack(spacing: 1) {
                        Image(systemName: "figure.walk")
                        Text("\(max(1, Int(ceil(duration / 60))))")
                    }
                    .liveFont(.subheadline, weight: .semibold).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityElement(children: .combine)
                }
                if option.rides.indices.contains(index) {
                    if index > 0 || (option.walks[index].duration ?? 0) >= 30 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    RouteBadge(name: option.rides[index].route.mode == .bus ? option.rides[index].route.localizedName : option.rides[index].route.lineCode, tintName: option.rides[index].route.name, compact: true)
                        .fixedSize(horizontal:true,vertical:false)
                    Image(systemName: option.rides[index].route.mode == .bus ? "bus.fill" : "tram.fill")
                        .liveFont(.subheadline, weight: .semibold).foregroundStyle(.primary).accessibilityHidden(true)
                }
                }.fixedSize(horizontal:true,vertical:false)
                }
            }
        }.lineLimit(1)
    }
}

struct JourneyOptionsView: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let collapse: () -> Void
    var compact = false
    var expand: () -> Void = {}
    var showSteps: () -> Void = {}
    var go: (JourneyOption) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if planner.planning || model.loading {
                HStack(spacing: 10) { ProgressView(); Text(live.text("查詢中")).liveFont(.subheadline) }.padding(.vertical, 8)
            }
            if let message = planner.message { Text(live.text(message)).liveFont(.subheadline).foregroundStyle(.secondary) }
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                if compact, !planner.options.isEmpty {
                    TabView(selection: Binding(get: { planner.selectedID ?? planner.options.first?.id ?? "" }, set: { id in
                        if let option = planner.options.first(where: { $0.id == id }) { planner.select(option) }
                    })) {
                        ForEach(planner.options) { option in compactCard(option, at: timeline.date).tag(option.id) }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: (live.language == .english ? 182 : 160) * CGFloat(max(1, live.appearance.textScale)))
                    .animation(InterfaceMotion.reduced(systemReduceMotion) ? nil : .smooth(duration: 0.25), value: planner.selectedID)
                    .accessibilityIdentifier("journey-preview-pages")
                    HStack(spacing: 8) {
                        HStack(spacing: 0) {
                            ForEach(Array(planner.options.enumerated()), id: \.element.id) { index, option in
                                Button { planner.select(option) } label: {
                                    Circle().fill(option.id == planner.selectedID ? Color.primary : Color.secondary.opacity(0.3))
                                        .frame(width: 6, height: 6).frame(width: 20, height: 44)
                                }.accessibilityLabel(AppText.text("路線方案 %@", index + 1))
                                    .accessibilityIdentifier("journey-page-\(index)")
                            }
                        }
                        Button(action: expand) {
                            Text(AppText.text("全部路線")).liveFont(.subheadline).frame(minHeight: 44)
                        }.accessibilityIdentifier("journey-all-options")
                        Spacer(minLength: 4)
                        if let option = planner.selected {
                            Button { go(option) } label: {
                                Text(AppText.text("出發")).liveFont(.subheadline, weight: .bold)
                                    .padding(.horizontal, 18).frame(minHeight: 42)
                            }.buttonStyle(MapActionStyle(prominent: true, tint: MapChrome.go))
                                .disabled(!usable(option))
                                .accessibilityLabel(AppText.text("開始導航")).accessibilityIdentifier("journey-go-" + option.id)
                        }
                    }.padding(.top, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(planner.options) { option in
                            optionRow(option, at: timeline.date)
                            if option.id != planner.options.last?.id { Divider() }
                        }
                    }
                }
            }
            if planner.checkingWalks { ProgressView().padding(.vertical, 8).accessibilityLabel(AppText.text("確認接駁與其他方案")) }
            if planner.comparisonChanged, !planner.checkingWalks, !compact {
                Button { planner.refreshRecommendations() } label: {
                    Label(AppText.text("更新推薦"), systemImage: "arrow.clockwise").liveFont(.subheadline).frame(minHeight: 44)
                }.accessibilityIdentifier("journey-refresh-options")
            }
        }
    }
    private func usable(_ option: JourneyOption) -> Bool {
        option.verified && option.walkIssue == nil && planner.unavailableBoarding(option) == nil
    }
    private func compactCard(_ option: JourneyOption, at date: Date) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button { planner.select(option); collapse() } label: {
                summary(option, at: date, compact: true).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(PhonePressStyle()).foregroundStyle(.primary)
                .accessibilityIdentifier("journey-option-" + option.id)
            Button { planner.select(option); showSteps() } label: {
                VStack(spacing: 4) {
                    Image(systemName: "chevron.right.2").liveFont(.title2, weight: .bold)
                    Text(AppText.text("步驟")).liveFont(.caption, weight: .bold)
                }.frame(width: 58, height: 70)
                    .background(Color(liveHex: live.appearance.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }.buttonStyle(PhonePressStyle()).foregroundStyle(Color(liveHex:live.appearance.accentColor))
                .accessibilityLabel(AppText.text("查看搭乘步驟")).accessibilityIdentifier("journey-steps-" + option.id)
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 1)
    }
    private func optionRow(_ option: JourneyOption, at date: Date) -> some View {
        Button { planner.select(option); collapse() } label: {
            HStack(spacing: 12) {
                summary(option, at: date, compact: false).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: option.id == planner.selectedID ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(option.id == planner.selectedID ? Color(liveHex: live.appearance.accentColor) : Color.secondary)
            }.padding(.vertical, 14).contentShape(Rectangle())
        }.buttonStyle(PhonePressStyle()).foregroundStyle(.primary)
            .accessibilityIdentifier("journey-option-" + option.id)
            .accessibilityHint(AppText.text("預覽此路線"))
    }
    private func summary(_ option: JourneyOption, at date: Date, compact: Bool) -> some View {
        let timing = model.journeyDuration(option, at: date)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(timing?.conciseLabel ?? AppText.text("確認接駁中"))
                    .liveFont(compact ? .title2 : .title3, weight: .bold, design: .rounded)
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                if let label = planner.optionLabels[option.id] {
                    Text(live.text(label)).liveFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
            }
            if let timing {
                if !option.walkingOnly { Text(timing.waitingLabel).liveFont(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1) }
                Text(timing.arrivalLabel).liveFont(.subheadline).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
            JourneyRouteChain(option: option).padding(.top, 5)
            if live.language == .english, let first = option.rides.first, let last = option.rides.last {
                Text(first.boarding.name + " → " + last.alighting.name).liveFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let unavailable = planner.unavailableBoarding(option) {
                Text(unavailable.route + " · " + EstimateFeed.label(unavailable.status)).liveFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct JourneyItineraryView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var showMap: () -> Void = {}
    @State private var showTimingInfo = false
    var body: some View {
        if let option = planner.selected {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(planner.destination?.localizedName ?? AppText.text("目的地"))
                        .liveFont(.title2, weight: .bold).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("journey-destination-title")
                    if live.language == .english, let name = planner.destination?.name { Text(name).liveFont(.subheadline).foregroundStyle(.secondary) }
                    TimelineView(.periodic(from: .now, by: 15)) { timeline in
                        if let duration = model.journeyDuration(option, at: timeline.date) {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(planner.started ? duration.summaryLabel(remaining: true) : duration.conciseLabel)
                                        .liveFont(.headline).monospacedDigit()
                                    Text(duration.arrivalLabel).liveFont(.subheadline).foregroundStyle(.secondary)
                                }.accessibilityElement(children: .combine).accessibilityIdentifier("journey-duration-breakdown")
                                Spacer()
                                Button { showTimingInfo = true } label: { Image(systemName: "info.circle").frame(width: 40, height: 40) }
                                    .accessibilityLabel(AppText.text("行程時間說明")).accessibilityIdentifier("journey-time-info")
                                    .popover(isPresented: $showTimingInfo) {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(duration.breakdownLabel).liveFont(.headline)
                                            Text(duration.waitingLabel)
                                            if duration.ridingSeconds > 0 { Text(duration.ridingSourceLabel) }
                                            Text(AppText.text("總時間已包含步行、候車與搭車。")).fixedSize(horizontal: false, vertical: true)
                                        }.liveFont(.subheadline).padding(20).frame(maxWidth: 320).presentationCompactAdaptation(.popover)
                                    }
                            }
                        }
                    }
                }.padding(.bottom, 18)
                ForEach(option.walks.indices, id: \.self) { index in
                    JourneyWalkingStep(model: model, planner: planner, option: option, index: index, showMap: showMap)
                    Divider().padding(.leading, 48)
                    if option.rides.indices.contains(index) {
                        JourneyRideStep(model: model, planner: planner, option: option, index: index, showMap: showMap)
                        Divider().padding(.leading, 48)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "mappin.circle.fill").liveFont(.title2).foregroundStyle(.red).frame(width: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppText.text("抵達")).liveFont(.headline)
                        Text(planner.destination?.localizedName ?? AppText.text("目的地")).liveFont(.subheadline).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 16)
            }
        }
    }
}

private struct JourneyWalkingStep: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let option: JourneyOption
    let index: Int
    let showMap: () -> Void
    private var leg: WalkingLeg { option.walks[index] }
    private var walked: Bool { planner.started && (planner.steps.firstIndex(of: .walk(index)) ?? .max) < planner.stepIndex }
    private var target: String { option.rides.indices.contains(index) ? option.rides[index].boarding.localizedName : planner.destination?.localizedName ?? AppText.text("目的地") }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "figure.walk").liveFont(.title2).foregroundStyle(.primary).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(leg.internalTransfer ? AppText.text("站內轉乘 · %@",target) : (walked ? AppText.text("已走到 ") : AppText.text("步行至 ")) + target)
                    .liveFont(.headline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("journey-walk-status-\(index)")
                if live.language == .english, option.rides.indices.contains(index) {
                    Text(option.rides[index].boarding.name).liveFont(.caption).foregroundStyle(.secondary)
                }
                Text(walked ? AppText.text("已完成") : (leg.distance.map { distanceLabel($0) + " · " } ?? "") + leg.timeLabel)
                    .liveFont(.subheadline).foregroundStyle(.secondary)
                if let instruction = leg.stationInstruction { Text(instruction).liveFont(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if !walked, !leg.internalTransfer, planner.currentStep == .walk(index) {
                Button { model.showWalkOnMap(index); showMap() } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond").liveFont(.title3).frame(width: 40, height: 44)
                }.accessibilityLabel(planner.started ? AppText.text("步行導航到%@", target) : AppText.text("預覽步行至%@", target))
                    .accessibilityIdentifier("journey-in-app-walk-\(index)")
            }
        }.padding(.vertical, 16)
    }
}

private struct JourneyRideStep: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let option: JourneyOption
    let index: Int
    let showMap: () -> Void
    private var ride: TransitRide { option.rides[index] }
    private var aboard: Bool { planner.started && planner.currentStep == .ride(index) }
    private var ridden: Bool { planner.started && (planner.steps.firstIndex(of: .ride(index)) ?? .max) < planner.stepIndex }
    private var tint: Color { RouteTint.accent(for: ride.route.name) }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // The route's own sign colour, as on its badge and map line.
            Image(systemName: ride.route.mode == .bus ? "bus.fill" : "tram.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RouteTint.color(for: ride.route.name), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ride.route.mode == .bus ? AppText.text("搭乘 %@ 公車", ride.route.localizedName) : AppText.text("搭乘 %@", ride.route.localizedName)).liveFont(.headline)
                        Text(AppText.text("往 %@", ride.route.localizedDestination(direction: ride.direction))).liveFont(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.selectRoute(ride.route, direction: ride.direction, variantOnly: true, boardingStopID: ride.boarding.id); showMap()
                    } label: {
                        Text(ride.route.mode == .bus ? AppText.text("看公車") : AppText.text("看列車")).liveFont(.subheadline, weight: .semibold).foregroundStyle(tint)
                            .padding(.horizontal, 12).frame(minHeight: 34).background(tint.opacity(0.14), in: Capsule())
                            .frame(minHeight: 44)
                    }.buttonStyle(PhonePressStyle())
                }
                if aboard {
                    Text(AppText.text("搭乘中") + (model.onboardPlate(for: ride).map { " · " + $0 } ?? ""))
                        .liveFont(.subheadline).accessibilityIdentifier("journey-ride-status-\(index)")
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in OnboardSummary(model: model, ride: ride, date: timeline.date) }
                } else if ridden {
                    Text(AppText.text("已下車")).liveFont(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("journey-ride-status-\(index)")
                } else {
                    TimelineView(.periodic(from: .now, by: 15)) { timeline in
                        VStack(alignment: .leading, spacing: 5) {
                            JourneyArrivalView(model: model, ride: ride, walk: option.walks[index])
                            if let duration = planner.duration(option, at: timeline.date), duration.waits.indices.contains(index), duration.waits[index].missedNext {
                                Text(AppText.text("可搭後續班次 · ") + duration.waits[index].label).liveFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    // A route-coloured line joins the boarding and alighting stops, as on the map.
                    VStack(spacing: 0) {
                        Circle().strokeBorder(tint, lineWidth: 3).background(Circle().fill(Color(uiColor: .systemBackground)))
                            .frame(width: 14, height: 14)
                        Rectangle().fill(tint).frame(width: 4).frame(maxHeight: .infinity)
                        Circle().fill(tint).frame(width: 14, height: 14)
                    }.frame(width: 16).padding(.vertical, 2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(ride.boarding.localizedName)
                        if live.language == .english { Text(ride.boarding.name).liveFont(.caption).foregroundStyle(.secondary) }
                        TimelineView(.periodic(from: .now, by: 15)) { timeline in
                            let estimate = model.plannedRideTime(ride, at: timeline.date)
                            Text(AppText.text("搭乘 %@ 站 · 約 %@ 分鐘", ride.stopCount, max(1, Int(ceil(estimate.seconds / 60)))))
                                .fontWeight(.semibold).foregroundStyle(tint).accessibilityIdentifier("journey-ride-time-\(index)")
                        }
                        Text(AppText.text("在「%@」下車", ride.alighting.localizedName))
                        if live.language == .english { Text(ride.alighting.name).liveFont(.caption).foregroundStyle(.secondary) }
                    }
                }.liveFont(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 16)
    }
}

struct JourneyArrivalView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var walk: WalkingLeg?
    private var requiresVariantConfirmation: Bool {
        let allowed = model.metadata.routeIDs(serving: ride)
        return model.metadata.variants(routeID: ride.route.id).contains { variant in
            !allowed.contains(variant.id) && model.metadata.orderedStops(routeID: variant.id, direction: ride.direction)
                .contains { $0.id == ride.boarding.id || $0.stationID == ride.boarding.stationID }
        }
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let eta = model.snapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: timeline.date)
            VStack(alignment: .leading, spacing: 4) {
                Text(ride.route.mode == .bus ? AppText.text("路線到站：%@", EstimateFeed.label(eta)) : model.metroWaitLabel(ride, at: timeline.date)).liveFont(.subheadline, weight: .medium).monospacedDigit()
                if ride.route.mode != .bus { Text(model.metroArrival(ride, at: timeline.date) == nil ? AppText.text("依官方班距估計") : AppText.text("官方下一班")).liveFont(.caption).foregroundStyle(.secondary) }
                if requiresVariantConfirmation {
                    Text(AppText.text("上車前請確認「%@」走法。", ride.route.localizedDisplayName)).liveFont(.caption).foregroundStyle(.secondary)
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
                        Button { model.finishJourney() } label: {
                            Text(live.text("完成")).liveFont(.body, weight: .bold).frame(maxWidth: .infinity, minHeight: 50)
                        }.buttonStyle(MapActionStyle(prominent: true))
                    } else if case .ride(let index) = planner.currentStep {
                        let ride = option.rides[index]
                        HStack(spacing: 8) {
                            if ride.route.mode != .bus {
                                TimelineView(.periodic(from:.now,by:1)) { timeline in
                                    MetroOnboardSummary(model:model,ride:ride,date:timeline.date,compact:true)
                                }
                            } else {
                            Button { chooseVehicle = true } label: {
                                Label(model.onboardPlate(for: ride) ?? AppText.text("選擇搭乘車牌"), systemImage: "bus")
                                    .liveFont(.subheadline, weight: .semibold).monospaced().lineLimit(1).minimumScaleFactor(0.8)
                                    .padding(.horizontal, 14).frame(minHeight: 40)
                            }.buttonStyle(MapActionStyle()).accessibilityIdentifier("journey-onboard-vehicle")
                            if let bus = model.onboardVehicle(for: ride) {
                                Button { model.trackApproachingVehicle(bus) } label: {
                                    Image(systemName: "scope").liveFont(.body, weight: .semibold).frame(width: 40, height: 40)
                                }.buttonStyle(MapActionStyle()).accessibilityLabel(AppText.text("追蹤 ") + bus.plate)
                            }
                            }
                            Spacer(minLength: 0)
                            Button { showRideStops = true } label: {
                                Label(ride.route.mode == .bus ? AppText.text("沿途站牌") : AppText.text("沿線車站"), systemImage: "list.bullet").liveFont(.subheadline, weight: .semibold)
                                    .lineLimit(1).padding(.horizontal, 14).frame(minHeight: 40)
                            }
                            .buttonStyle(MapActionStyle(tint: Color.primary))
                            .accessibilityIdentifier("journey-ride-stops")
                        }
                        if option.rides.indices.contains(index + 1) {
                            let next = option.rides[index + 1]
                            Text(AppText.text("接著轉搭 %@ · %@", next.route.localizedName, next.boarding.localizedName)).liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        HStack(spacing: 12) {
                            Button { model.returnToWaiting() } label: {
                                Text(live.text("返回等車")).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(MapActionStyle(tint: Color.primary))
                            Button { model.alight() } label: {
                                Text(live.text("已下車")).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(MapActionStyle(prominent: true))
                                .accessibilityIdentifier("journey-alight")
                        }.liveFont(.body, weight: .semibold)
                    } else {
                        let index: Int = { if case .walk(let value) = planner.currentStep { return value }; return 0 }()
                        if option.walks.indices.contains(index) {
                            Text(planner.walkingStatus(at: index) ?? option.walks[index].timeLabel).liveFont(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("walking-live-status")
                        }
                        HStack(spacing: 12) {
                            Button { if !planner.started { planner.begin() }; model.showWalkOnMap(index) } label: {
                                Label(live.text("看步行路線"), systemImage: "figure.walk")
                                    .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(MapActionStyle()).accessibilityHint(AppText.text("在目前地圖查看步行路線"))
                            Button { if !planner.started { planner.begin() }; planner.advance() } label: {
                                Text(live.text("已抵達")).lineLimit(1).frame(maxWidth: .infinity, minHeight: 50)
                            }.buttonStyle(MapActionStyle(prominent: true))
                                .accessibilityIdentifier("journey-arrive")
                        }.liveFont(.body, weight: .semibold)
                    }
                }.journeyDockSurface()
                    .smoothChanges(planner.currentStep)
                    .smoothChanges(model.language)
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

/// The Apple Maps style instruction at the top of the map: what to do now in
/// large type, with the following step in a slim strip underneath.
struct JourneyInstructionBanner: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var body: some View {
        if let option = planner.selected {
            Group {
                if let index = planner.boardingRideIndex, option.rides.indices.contains(index) {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        WaitingBannerContent(model: model, ride: option.rides[index], date: timeline.date)
                    }
                } else if case .ride(let index) = planner.currentStep, option.rides.indices.contains(index) {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        RidingBannerContent(model: model, ride: option.rides[index], date: timeline.date)
                    }
                } else {
                    WalkingBannerContent(planner: planner)
                }
            }
            .modifier(InstructionBannerSurface())
            .smoothChanges(planner.currentStep)
            .smoothChanges(planner.selectedID)
        }
    }
}

struct InstructionBannerSurface: ViewModifier {
    @Environment(\.liveSettings) private var live
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MapChrome.cardRadius * CGFloat(live.appearance.cornerScale), style: .continuous)
        content.foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 0.97) : UIColor(white: 0.11, alpha: 0.95) })))
            .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6) }
            .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
    }
}

struct BannerStrip<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.6)
            HStack(spacing: 8) { content }
                .liveFont(.subheadline).foregroundStyle(Color.white.opacity(0.8))
                .padding(.horizontal, 16).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WaitingBannerContent: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    var body: some View {
        let guide = BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: date)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                RouteBadge(name: ride.route.mode == .bus ? ride.route.localizedName : ride.route.lineCode, tintName: ride.route.name)
                    .accessibilityIdentifier("boarding-route")
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.text("往 ") + ride.route.localizedDestination(direction: ride.direction))
                        .liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                    BannerTitle(text: live.text("上車 · ") + ride.boarding.localizedName)
                    if live.language == .english { Text(ride.boarding.name).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)) }
                    if ride.route.displayName != ride.route.name,
                       model.metadata.routeIDs(serving: ride).filter({ model.metadata.routes[$0] != nil }).count <= 1 {
                        Text(ride.route.localizedDisplayName).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ride.route.mode == .bus ? guide.arrivalShortLabel : model.metroWaitLabel(ride, at: date)).liveFont(.title, weight: .bold, design: .rounded)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("boarding-official-arrival")
                    Text(ride.route.mode != .bus ? model.metroWaitSource(ride, at: date) : guide.estimateSeconds == nil ? AppText.text("暫無預估") : AppText.text("官方下一班"))
                        .liveFont(.caption, weight: .semibold).lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle((guide.estimateSeconds ?? -1) >= 0 ? Color(liveHex: "#6EE7A0") : Color.white.opacity(0.72))
                }.layoutPriority(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            BannerStrip {
                Image(systemName: "arrow.down").font(.caption.weight(.bold))
                Text(AppText.text("在「%@」下車", ride.alighting.localizedName)).lineLimit(1)
                Spacer(minLength: 4)
                Text(AppText.text("搭乘 %@ 站 · 約 %@ 分鐘", ride.stopCount, max(1, Int(ceil(model.plannedRideTime(ride, at: date).seconds / 60)))))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            }
        }
    }
}

/// A stop name in the navigation banner stays on one line, stepping down in size as needed,
/// so a name is never broken in the middle across two lines.
private struct BannerTitle: View {
    let text: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(text).liveFont(.title3, weight: .bold).lineLimit(1)
            Text(text).liveFont(.headline, weight: .bold).lineLimit(1)
            Text(text).liveFont(.subheadline, weight: .bold).lineLimit(1)
            // Beside the badge and the stop count there is only ~155 pt; shrink rather than wrap.
            Text(text).liveFont(.subheadline, weight: .bold).lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

private struct RidingBannerContent: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    var body: some View {
        if ride.route.mode != .bus {
            let remaining = model.metroRemaining(ride, at: date)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    RouteBadge(name: ride.route.lineCode, tintName: ride.route.name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppText.text("往 %@", ride.route.localizedDestination(direction: ride.direction))).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72))
                        BannerTitle(text: AppText.text("下車 · ") + ride.alighting.localizedName)
                        if live.language == .english { Text(ride.alighting.name).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)) }
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(AppText.minutes(max(0,Int(ceil(remaining.seconds / 60))))).liveFont(.title, weight: .bold).monospacedDigit()
                        Text(AppText.remainingStops(remaining.stops.count)).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72))
                    }
                }.padding(.horizontal, 16).padding(.vertical, 13)
                BannerStrip {
                    Image(systemName: "tram.fill")
                    Text(remaining.stops.first.map { AppText.text("下一站 · ") + $0.localizedName } ?? AppText.text("準備下車"))
                    Spacer()
                    Text(model.metroPositionLabel(remaining.source, detailed: false)).liveFont(.caption)
                }
            }
        } else {
        let bus = model.onboardVehicle(for: ride)
        let journey = bus.flatMap { model.metadata.journey(routeID: $0.routeID, direction: $0.direction) }
        let progress = bus.flatMap { vehicle in journey?.progress(stopID: ride.alighting.id, vehicle: vehicle, at: date) }
        let stops = bus == nil ? [] : model.onboardStops(for: ride, at: date)
        let next = progress != nil ? stops.first : nil
        let alightNext = next?.id == ride.alighting.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                RouteBadge(name: ride.route.mode == .bus ? ride.route.localizedName : ride.route.lineCode, tintName: ride.route.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.text("往 ") + ride.route.localizedDestination(direction: ride.direction))
                        .liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)).lineLimit(1)
                    // Same "action · stop" form as the boarding banner.
                    BannerTitle(text: (progress?.distance ?? 0) < -20 ? AppText.text("已通過「%@」", ride.alighting.localizedName) : live.text("下車 · ") + ride.alighting.localizedName)
                    if live.language == .english { Text(ride.alighting.name).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72)) }
                }
                Spacer(minLength: 4)
                if let bus {
                    let timed = model.arrivalDisplay(bus, stopID: ride.alighting.id, at: date, onboard: true).prediction?.hasUsableTime == true
                    let remaining = stops.firstIndex(where: { $0.id == ride.alighting.id }).map { AppText.remainingStops($0 + 1) }
                    VStack(alignment: .trailing, spacing: 2) {
                        // A far stop has no dependable time yet; lead with the stop count rather than a large "pending".
                        Text(timed ? model.onboardEstimateLabel(bus, stopID: ride.alighting.id, at: date) : remaining ?? model.onboardEstimateLabel(bus, stopID: ride.alighting.id, at: date))
                            .liveFont(.title3, weight: .bold).monospacedDigit().lineLimit(2).minimumScaleFactor(0.7)
                            .multilineTextAlignment(.trailing)
                            .contentTransition(.numericText())
                        if let remaining {
                            Text(timed ? remaining : AppText.text("時間待確認")).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72))
                                .contentTransition(.numericText())
                        }
                    }.frame(maxWidth: live.language == .english ? 120 : 112, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .accessibilityElement(children: .combine).accessibilityIdentifier("journey-alighting-time")
            BannerStrip {
                if let bus {
                    if model.isRiderAnchored(bus) {
                        // The bus follows the rider's own fix, so its position is live rather than delayed.
                        Image(systemName: "location.fill").font(.caption2.weight(.bold)).foregroundStyle(Color(liveHex: "#6EA8FF"))
                            .frame(width: 12).accessibilityLabel(AppText.text("依你的定位即時更新"))
                    } else {
                        Circle().fill(Color(liveHex: "#6EA8FF")).frame(width: 8, height: 8).frame(width: 12)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.map { ($0.id == ride.alighting.id ? AppText.text("下一站下車 · ") : AppText.text("下一站 · ")) + $0.localizedName } ?? AppText.text("位置更新中")).lineLimit(1)
                            .fontWeight(alightNext ? .semibold : nil)
                            .foregroundStyle(alightNext ? Color(liveHex: "#FFD60A") : Color.white.opacity(0.8))
                        if live.language == .english, let next { Text(next.name).liveFont(.caption) }
                    }
                    Spacer(minLength: 4)
                    if let next {
                        Text(model.onboardEstimateLabel(bus, stopID: next.id, at: date) + " · " + AppText.remainingStops(1))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                    }
                } else {
                    Image(systemName: "bus").font(.caption.weight(.semibold))
                    Text(model.onboardPlate(for: ride) == nil ? AppText.text("選擇車牌即可看沿途時間") : AppText.text("車輛位置更新中")).lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine).accessibilityIdentifier("journey-next-stop")
        }
        .sensoryFeedback(.warning, trigger: alightNext) { _, new in new }
        }
    }
}

struct MetroBoardingRows: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    private var arrivals: [MetroArrival] {
        (model.metroRealtime?.arrivals ?? []).filter { $0.stationID == ride.boarding.stationID && $0.remaining(at: date) != nil && model.metadata.metro.canServe(ride, patternID: $0.patternID, direction: $0.direction, destinationStationID: $0.destinationStationID) }
            .sorted { ($0.remaining(at: date) ?? .max) < ($1.remaining(at: date) ?? .max) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if arrivals.isEmpty {
                HStack {
                    Image(systemName: "tram.fill").foregroundStyle(.secondary)
                    Text(AppText.text("下班列車")).liveFont(.subheadline, weight: .semibold)
                    Spacer()
                    Text(model.metroWaitLabel(ride, at: date)).liveFont(.subheadline, weight: .bold).monospacedDigit()
                    if let tracked = model.nextTrackedTrain(routeID: ride.route.id, direction: ride.direction, boardingStationID: ride.boarding.stationID,
                                                            alightingStationID: ride.alighting.stationID, at: date) {
                        Button { model.selectedTrainID = tracked.train.id; model.metroRevisionForSelection() } label: {
                            Label(model.selectedTrainID == tracked.train.id ? AppText.text("追蹤中") : AppText.text("追蹤"), systemImage: "scope")
                                .liveFont(.caption, weight: .semibold).padding(8)
                        }.buttonStyle(MapActionStyle()).accessibilityIdentifier("metro-track-estimated")
                    }
                }
                Text(model.metroWaitSource(ride, at: date)).liveFont(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(arrivals.prefix(3).enumerated()), id: \.offset) { index, arrival in
                    HStack {
                        Text(index == 0 ? AppText.text("下班列車") : AppText.text("後續班次")).liveFont(.subheadline)
                        Spacer()
                        Text(MetroCountdown.label(arrival.remaining(at: date))).liveFont(.subheadline, weight: .semibold).monospacedDigit()
                        if let id = arrival.trainID, model.metroTrain(id) != nil {
                            Button { model.selectedTrainID = id; model.metroRevisionForSelection(); } label: {
                                Label(AppText.text("追蹤"), systemImage: "scope").liveFont(.caption, weight: .semibold).padding(8)
                            }.buttonStyle(MapActionStyle()).accessibilityIdentifier("metro-track-arrival-" + id)
                        }
                    }
                }
                Text(AppText.text("官方到站時間")).liveFont(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6).accessibilityElement(children: .contain).accessibilityIdentifier("metro-boarding-arrivals")
    }
}

private struct MetroOnboardSummary: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    var compact = false
    var body: some View {
        let remaining = model.metroRemaining(ride, at: date)
        VStack(alignment: .leading, spacing: 6) {
            if !compact { HStack {
                Text(AppText.text("在「%@」下車", ride.alighting.localizedName)).liveFont(.title3, weight: .bold)
                Spacer()
                Text(AppText.minutes(max(0,Int(ceil(remaining.seconds / 60))))).liveFont(.title3, weight: .bold).monospacedDigit()
            } }
            HStack {
                Text(remaining.stops.first.map { AppText.text("下一站 · ") + $0.localizedName } ?? AppText.text("準備下車"))
                Spacer()
                if !compact { Text(AppText.remainingStops(remaining.stops.count)) }
            }.liveFont(.subheadline).foregroundStyle(.secondary)
            Text(model.metroPositionLabel(remaining.source, detailed: !compact))
                .liveFont(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("metro-onboard-summary")
    }
}

private struct WalkingBannerContent: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var planner: JourneyPlannerModel
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: planner.arrived ? "checkmark.circle.fill" : "figure.walk")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(planner.arrived ? Color(liveHex: "#6EE7A0") : Color.white)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(planner.arrived ? live.text("已抵達") : AppText.text("走到「%@」", planner.destination?.localizedName ?? AppText.text("目的地")))
                    .liveFont(.title3, weight: .bold).lineLimit(2).minimumScaleFactor(0.8)
                if live.language == .english, let name = planner.destination?.name {
                    Text(name).liveFont(.caption).foregroundStyle(Color.white.opacity(0.72))
                }
                // Leaving a metro station: name the exit that faces the destination.
                if !planner.arrived, let exit = planner.selected?.walks.last?.stationInstruction,
                   planner.selected?.rides.last.map({ $0.alighting.mode != .bus }) == true {
                    Label(exit, systemImage: "door.left.hand.open")
                        .liveFont(.subheadline, weight: .semibold).foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .accessibilityIdentifier("walking-metro-exit")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
    }
}
