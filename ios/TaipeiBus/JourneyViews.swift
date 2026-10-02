import SwiftUI
import MapKit
import TransitCore

struct JourneyPlanningView: View {
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

    private var searchingPlaces: Bool { editingOrigin || editingDestination }
    private var showingPreview: Bool { compact && !searchingPlaces && !planner.started && planner.selected != nil }
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
                                Text(planner.destination?.name ?? "目的地").font(.title.bold()).lineLimit(2)
                                Text(planner.destination?.address ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button("更改") { edit(origin: false) }.frame(minHeight: 44)
                        }
                        if planner.started {
                            JourneyItineraryView(model: model, planner: planner)
                            Button("結束行程") { planner.finish(); dismiss() }.frame(minHeight: 44)
                        } else {
                            JourneyOptionsView(model: model, planner: planner, collapse: collapse)
                        }
                    }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if !searchingPlaces, !planner.started, planner.selected != nil {
                    JourneyStartButton(model: model, planner: planner) {
                        planner.navigateWalk(0)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12).background(.regularMaterial)
                }
            }
            .navigationTitle(showingPreview ? planner.destination?.name ?? "目的地" : editingOrigin ? "出發地" : searchingPlaces ? "目的地" : "搭車方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showingPreview { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(showingPreview ? "方案" : "完成") { if showingPreview { expand() } else { dismiss() } }
                }
            }
        }
        .onAppear {
            search.setContext(planner.origin?.coordinate ?? location.usableCoordinate)
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
        .onChange(of: location.coordinate) { _, coordinate in search.setContext(planner.origin?.coordinate ?? coordinate) }
        .onChange(of: planner.selectedID) { _, id in
            if id != nil, !searchingPlaces, !planner.started { focused = false; collapse() }
        }
        .onDisappear { resolveTask?.cancel(); search.cancel() }
    }
    private var originButton: some View {
        HStack(spacing: 10) {
            Image(systemName: planner.usingLocation ? "location.fill" : "circle.fill").foregroundStyle(Color.accentColor)
            Button { edit(origin: true) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(planner.origin?.name ?? (location.requesting ? "取得位置中" : "選擇出發地"))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if planner.origin == nil {
                        Text(location.message ?? "可使用定位，或輸入出發地／站名").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button {
                planner.useLocation(location.usableCoordinate, metadata: model.metadata); location.request()
                editingOrigin = false; editingDestination = planner.destination == nil; query = ""
            } label: { Image(systemName: "location.circle").font(.title2).frame(width: 44, height: 44) }
                .accessibilityLabel("使用目前位置出發")
        }.padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
    private var placeSearch: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(editingOrigin ? "出發地、地址或站名" : "地點、地址或站名", text: $query)
                    .focused($focused).submitLabel(.search).autocorrectionDisabled()
                    .onSubmit { resolve(text: query) }
                if resolving || search.searching { ProgressView() }
                else if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
            }.padding(14).frame(minHeight: 52)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 15))
            if let error = searchError ?? search.error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { resolve(text: query) } label: {
                    Label("搜尋「\(query)」", systemImage: "arrow.up.right").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }.disabled(resolving)
            }
            if query.isEmpty {
                if !editingOrigin && !planner.recentPlaces.isEmpty {
                    Text("最近目的地").font(.subheadline.weight(.semibold)).padding(.top, 8)
                    ForEach(planner.recentPlaces) { place in placeButton(place, symbol: "clock") }
                }
                if !editingOrigin {
                    HStack(spacing: 8) {
                        ForEach(["臺北車站", "臺北101", "西門町"], id: \.self) { name in
                            Button(name) { query = name; resolve(text: name) }.font(.subheadline)
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(Color.accentColor.opacity(0.08), in: Capsule())
                        }
                    }.padding(.top, 8)
                }
            }
            if !search.places.isEmpty {
                Text("地點搜尋結果").font(.subheadline.weight(.semibold)).padding(.top, 8)
                ForEach(search.places) { place in placeButton(place, symbol: "mappin.circle.fill") }
            }
            if !search.suggestions.isEmpty && search.places.isEmpty { Text("地點").font(.subheadline.weight(.semibold)).padding(.top, 8) }
            ForEach(Array((search.places.isEmpty ? Array(search.suggestions.prefix(6)) : []).enumerated()), id: \.offset) { _, completion in
                Button { resolve(text: completion.title, completion: completion) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle").font(.title2).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(completion.title).font(.body.weight(.medium))
                            Text(completion.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0); Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(resolving)
                Divider()
            }
            let stations = Array(model.stations(query: query).prefix(query.isEmpty ? 3 : 12))
            if !stations.isEmpty { Text("公車站牌").font(.subheadline.weight(.semibold)).padding(.top, 8) }
            ForEach(StationSearch.groups(stations)) { group in
                Text(group.name).font(.subheadline.weight(.semibold)).padding(.top, 8)
                ForEach(group.stations) { station in
                    Button {
                        choose(TravelPlace(name: station.name, address: "\(station.bearingLabel) · \(station.address)", coordinate: station.coordinate))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "bus.fill").foregroundStyle(Color.accentColor).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(station.bearingLabel.isEmpty ? station.name : station.bearingLabel).font(.subheadline.weight(.medium))
                                Text(station.address.isEmpty ? station.name : station.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.frame(minHeight: 52).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(resolving)
                }
            }
        }
    }
    private func placeButton(_ place: TravelPlace, symbol: String) -> some View {
        Button { choose(place) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name).font(.body.weight(.medium))
                    if !place.address.isEmpty { Text(place.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if !place.coordinate.isInServiceArea { Text("公車規劃範圍外").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.frame(minHeight: 58).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(resolving)
    }
    private func edit(origin: Bool) {
        expand()
        resolveTask?.cancel(); resolveToken = UUID(); search.cancel(); resolving = false
        editingOrigin = origin; editingDestination = !origin; query = ""; searchError = nil; focused = true
        search.setContext(planner.origin?.coordinate ?? location.usableCoordinate)
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
    }
}

private struct JourneyMapPreviewView: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var body: some View {
        if let option = planner.selected {
            if let ride = option.rides.first { JourneyBoardingView(model: model, ride: ride) }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("步行即可抵達", systemImage: "figure.walk").font(.title3.weight(.semibold))
                    Text(option.walkingTimeLabel).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A flat boarding display shared by the sheet and the edge of the map.
struct JourneyBoardingView: View {
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            JourneyBoardingContent(model: model, ride: ride, date: timeline.date)
        }
    }
}

private struct JourneyBoardingContent: View {
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let date: Date
    @State private var showTimingInfo = false
    private var guide: BoardingGuide { BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headline
            platform
            HStack {
                Text("各車估算").font(.caption).foregroundStyle(.secondary)
                Button { showTimingInfo = true } label: { Image(systemName: "info.circle").font(.caption).frame(width: 28, height: 28) }
                    .accessibilityLabel("到站時間說明")
                    .popover(isPresented: $showTimingInfo) {
                        Text("官方時間是這條路線的到站預估，沒有指定車牌。各車時間依位置、近期移動和中途停靠估算。定位不足時不顯示時間。")
                            .font(.subheadline).padding(20).frame(maxWidth: 300).presentationCompactAdaptation(.popover)
                    }
                Spacer()
            }
            .padding(.bottom, -10)
            if guide.approaches.isEmpty { Text("暫無車輛位置").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6) }
            VStack(spacing: 0) {
                ForEach(Array(guide.approaches.prefix(3))) { approach in
                    BoardingVehicleRow(model: model, ride: ride, approach: approach, date: date)
                    if approach.id != guide.approaches.prefix(3).last?.id { Divider() }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ride.route.name).font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.accentColor).lineLimit(1).minimumScaleFactor(0.65)
                Text("往 " + ride.route.destination(direction: ride.direction)).font(.subheadline).lineLimit(1)
                if ride.route.displayName != ride.route.name { Text(ride.route.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(guide.arrivalShortLabel).font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                Text(guide.estimateSeconds == nil ? "暫無預估" : "官方到站").font(.caption).foregroundStyle(.secondary)
            }.layoutPriority(1)
        }
    }
    private var platform: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill").foregroundStyle(Color.accentColor)
                Text("上車 · " + ride.boarding.name).font(.body.weight(.semibold)).lineLimit(2)
                if let station = guide.station { Text(station.bearingLabel).font(.caption).foregroundStyle(.secondary) }
            }
            if let station = guide.station, !station.address.isEmpty { Text(station.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Text("下車 · " + ride.alighting.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct BoardingVehicleRow: View {
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    let approach: VehicleApproach
    let date: Date
    private var selected: Bool { model.selectedVehicleID == approach.id }
    private var nextStop: String? {
        model.metadata.journey(routeID: approach.vehicle.routeID, direction: approach.vehicle.direction)?
            .upcoming(vehicle: approach.vehicle, at: date).first?.stop.name
    }
    var body: some View {
        Button { model.trackApproachingVehicle(approach.vehicle) } label: {
            HStack(spacing: 12) {
                Circle().fill(selected ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(approach.vehicle.plate).font(.subheadline.weight(.semibold)).monospaced()
                    Text(nextStop ?? "位置待確認").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(model.arrivalEstimate(approach, ride: ride, at: date).label)
                    .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "scope").font(.body).foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }.frame(minHeight: 48).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityHint("點一下追蹤這輛公車")
            .accessibilityValue(selected ? "追蹤中" : "")
    }
}

struct JourneyArrivalDock: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let showJourney: () -> Void
    var body: some View {
        if let option = planner.selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(planner.destination?.name ?? "目的地").font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer()
                    Button("方案", action: showJourney).font(.subheadline).frame(minHeight: 36)
                    Button { planner.finish(); model.clearSelection() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 36, height: 36) }
                        .accessibilityLabel("結束查詢")
                }
                if let ride = option.rides.first { JourneyBoardingView(model: model, ride: ride) }
                else { Text(option.walkingTimeLabel).font(.title3.weight(.semibold)) }
                HStack(spacing: 12) {
                    Button { planner.navigateWalk(0) } label: {
                        Label("步行", systemImage: "figure.walk").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                    if let ride = option.rides.first {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            let next = BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: timeline.date).approaches.first { $0.alongDistance != nil }
                            Button { if let next { model.trackApproachingVehicle(next.vehicle) } } label: {
                                Label(model.following && next?.id == model.selectedVehicleID ? "追蹤中" : "追蹤下一輛", systemImage: "scope")
                                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(next == nil)
                        }
                    }
                }
            }.padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 16)
                .phoneGlass(in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
                .padding(.horizontal, -24).padding(.bottom, -12)
        }
    }
}

struct JourneyOptionsView: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let collapse: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if planner.planning || model.loading {
                HStack(spacing: 12) { ProgressView(); Text("查詢中").font(.subheadline) }.padding(.vertical, 16)
            }
            if let message = planner.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            ForEach(planner.options) { option in
                Button { planner.select(option); collapse() } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            if option.walkingOnly { Label("步行即可", systemImage: "figure.walk").font(.headline) }
                            else {
                                ForEach(option.rides) { ride in RouteBadge(name: ride.route.name) }
                                Text(option.rides.count == 1 ? "直達" : "轉乘 1 次").font(.subheadline.weight(.medium))
                            }
                            Spacer(minLength: 0)
                            Image(systemName: option.id == planner.selectedID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(option.id == planner.selectedID ? Color.accentColor : Color.secondary)
                        }
                        if let first = option.rides.first, let last = option.rides.last {
                            Text("在「\(first.boarding.name)」上車").font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text("搭 \(first.route.displayName)，往 \(first.route.destination(direction: first.direction))")
                                .font(.subheadline).lineLimit(2)
                            Text("在「\(last.alighting.name)」下車" + (option.rides.count > 1 ? " · 途中轉乘 1 次" : ""))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                                Text("官方預估：\(BoardingGuide(ride: first, metadata: model.metadata, snapshot: model.snapshot, at: timeline.date).arrivalLabel)")
                                    .font(.subheadline.weight(.medium)).monospacedDigit()
                            }
                        }
                        HStack {
                            Text(option.walkingTimeLabel).font(.caption).foregroundStyle(.secondary)
                            if option.id == planner.selectedID && planner.checkingWalks { ProgressView().controlSize(.small) }
                        }
                        if let issue = option.walkIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Divider()
            }
            if planner.selected != nil {
                DisclosureGroup("查看步行與乘車詳情") {
                    JourneyItineraryView(model: model, planner: planner)
                }.font(.subheadline)
            }
            if planner.destination != nil {
                Button { planner.openAppleTransit() } label: {
                                    Label("其他交通方式", systemImage: "map").font(.subheadline).frame(minHeight: 44)
                }
            }
        }
    }
}

private struct JourneyStartButton: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let begin: () -> Void
    var body: some View {
        if let option = planner.selected {
            let ride = option.rides.first
            let unavailable = planner.unavailableBoarding(option)
            VStack(spacing: 8) {
                if let walk = option.walks.first {
                    Text(planner.checkingWalks ? "確認步行路線中" :
                         walk.timeLabel + (walk.distance.map { " · " + distanceLabel($0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let ride, let walk = option.walks.first {
                    TimelineView(.periodic(from: .now, by: 15)) { timeline in
                        if let eta = model.snapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: timeline.date),
                           eta >= 0, let duration = walk.duration, duration > Double(eta) + 45 {
                            Text("這班可能趕不上，請留意下一班或其他方案").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                HStack(spacing: 12) {
                    Button(action: begin) {
                        Label("步行", systemImage: "figure.walk")
                            .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                        .disabled(planner.planning || planner.checkingWalks || option.walkIssue != nil || unavailable != nil)
                    if let ride {
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            let next = BoardingGuide(ride: ride, metadata: model.metadata, snapshot: model.snapshot, at: timeline.date).approaches.first { $0.alongDistance != nil }
                            Button { if let next { model.trackApproachingVehicle(next.vehicle) } } label: {
                                Label(model.following && next?.id == model.selectedVehicleID ? "追蹤中" : "追蹤下一輛", systemImage: "scope")
                                    .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(next == nil)
                        }
                    }
                }
                if let unavailable {
                    Text("\(unavailable.route) 上車站：\(EstimateFeed.label(unavailable.status))").font(.caption).foregroundStyle(.secondary)
                }
                if let issue = option.walkIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

struct JourneyItineraryView: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var body: some View {
        if let option = planner.selected {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(option.walks.indices, id: \.self) { index in
                    let walk = option.walks[index]
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "figure.walk").font(.title3).foregroundStyle(.secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(index < option.rides.count ? "走到 \(option.rides[index].boarding.name)" : "走到 \(planner.destination?.name ?? "目的地")")
                                .font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(walk.timeLabel + (walk.distance.map { " · \(distanceLabel($0))" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button { planner.navigateWalk(index) } label: { Image(systemName: "arrow.triangle.turn.up.right.diamond").font(.title3).frame(width: 44, height: 44) }
                            .accessibilityLabel("步行導航到\(index < option.rides.count ? option.rides[index].boarding.name : planner.destination?.name ?? "目的地")")
                    }
                    if index < option.rides.count {
                        let ride = option.rides[index]
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 12) {
                                RouteBadge(name: ride.route.name)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("往 \(ride.route.destination(direction: ride.direction))").font(.subheadline.weight(.semibold))
                                    Text("搭 \(ride.stopCount) 站，在「\(ride.alighting.name)」下車").font(.subheadline).lineLimit(2)
                                }
                            }
                            if ride.route.displayName != ride.route.name { Text(ride.route.displayName).font(.caption).foregroundStyle(.secondary) }
                            JourneyArrivalView(model: model, ride: ride, walk: walk)
                            HStack {
                                Button {
                                    if let station = model.metadata.stations[ride.boarding.stationID] { model.selectStation(station) }
                                } label: { Text("看上車站預估").frame(minHeight: 44) }
                                Spacer()
                                Button { model.selectRoute(ride.route, direction: ride.direction, variantOnly: true) } label: {
                                    Label("看公車", systemImage: "bus.fill").frame(minHeight: 44)
                                }
                            }.font(.subheadline)
                        }.padding(14).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18))
                    }
                }
            }.padding(.top, 6)
        }
    }
}

struct JourneyArrivalView: View {
    @ObservedObject var model: TransitAppModel
    let ride: TransitRide
    var walk: WalkingLeg?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let eta = model.snapshot.estimates.value(routeID: ride.route.parentID, stopID: ride.boarding.id, at: timeline.date)
            VStack(alignment: .leading, spacing: 4) {
                Text("路線到站：\(EstimateFeed.label(eta))").font(.subheadline.weight(.medium)).monospacedDigit()
                if model.metadata.variants(routeID: ride.route.id).count > 1 {
                    Text("上車前請確認「\(ride.route.displayName)」走法。").font(.caption).foregroundStyle(.secondary)
                }
                if let eta, eta >= 0, let duration = walk?.duration, duration > Double(eta) + 45 {
                    Text("步行時間較長，這班可能趕不上。").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

struct JourneyGuideCard: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let showJourney: () -> Void
    var body: some View {
        if let option = planner.selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button(action: showJourney) {
                        Label(planner.destination?.name ?? "行程", systemImage: "flag.checkered")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(planner.arrived ? "完成" : "\(min(planner.stepIndex + 1, planner.steps.count)) / \(planner.steps.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button { planner.finish(); model.clearSelection() } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }
                        .accessibilityLabel("結束行程")
                }
                if planner.arrived {
                    Text("已抵達目的地").font(.title2.weight(.bold))
                } else if let step = planner.currentStep {
                    switch step {
                    case .walk(let index):
                        let walk = option.walks[index]
                        let target = index < option.rides.count ? option.rides[index].boarding.name : planner.destination?.name ?? "目的地"
                        Text("走到 \(target)").font(.title2.weight(.bold)).lineLimit(2)
                        Text(walk.timeLabel + (walk.distance.map { " · \(distanceLabel($0))" } ?? "")).font(.subheadline).foregroundStyle(.secondary)
                        if index < option.rides.count {
                            let ride = option.rides[index]
                            HStack(spacing: 10) {
                                RouteBadge(name: ride.route.name)
                                Text("往 \(ride.route.destination(direction: ride.direction))").font(.subheadline)
                            }
                            JourneyArrivalView(model: model, ride: ride, walk: walk)
                        }
                        HStack(spacing: 10) {
                            Button { planner.navigateWalk(index) } label: {
                                Label("步行導航", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                    .frame(maxWidth: .infinity, minHeight: 46)
                            }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                            Button(index < option.rides.count ? "已到站牌" : "已抵達") { planner.advance() }
                                .font(.subheadline.weight(.medium)).frame(minHeight: 46)
                        }
                    case .ride(let index):
                        let ride = option.rides[index]
                        Text("在 \(ride.alighting.name) 下車").font(.title2.weight(.bold)).lineLimit(2)
                        HStack(spacing: 10) { RouteBadge(name: ride.route.name); Text("往 \(ride.route.destination(direction: ride.direction)) · \(ride.stopCount) 站").font(.subheadline) }
                        HStack {
                            Button { model.selectRoute(ride.route, direction: ride.direction, variantOnly: true) } label: {
                                Label("看公車", systemImage: "bus.fill").frame(minHeight: 44)
                            }
                            Spacer()
                            Button("已下車") { planner.advance() }.frame(minHeight: 44).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        }
                    }
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .phoneGlass(in: RoundedRectangle(cornerRadius: 25))
                .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
        }
    }
}
