import SwiftUI
import MapKit
import TransitCore

struct JourneyPlanningView: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    @ObservedObject var location: LocationService
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
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                            JourneyOptionsView(model: model, planner: planner)
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if !searchingPlaces, !planner.started, planner.selected != nil {
                    JourneyStartButton(model: model, planner: planner) {
                        planner.begin()
                        if planner.started { dismiss() }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12).background(.regularMaterial)
                }
            }
            .navigationTitle(editingOrigin ? "從哪裡出發？" : searchingPlaces ? "你想去哪裡？" : "搭車方案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear {
            editingDestination = planner.destination == nil
            if planner.origin == nil && planner.usingLocation {
                planner.useLocation(location.usableCoordinate, metadata: model.metadata)
                if location.usableCoordinate == nil { location.request() }
            }
            focused = editingDestination
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-journey-search") { focused = false; query = "臺北車站" }
#endif
        }
        .onChange(of: query) { _, value in
            if resolving && value != resolvingQuery {
                resolveTask?.cancel(); resolveToken = UUID(); resolving = false; search.cancel()
            }
            searchError = nil; search.update(value)
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
                Text(editingOrigin ? "也可以選站牌出發" : "也可以選站牌當目的地").font(.subheadline.weight(.semibold)).padding(.top, 12)
            }
            ForEach(Array(search.suggestions.enumerated()), id: \.offset) { _, completion in
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
            let stations = Array(model.stations(query: query).prefix(query.isEmpty ? 3 : 4))
            if !query.isEmpty && !stations.isEmpty { Text("公車站牌").font(.subheadline.weight(.semibold)).padding(.top, 8) }
            ForEach(stations) { station in
                placeButton(TravelPlace(name: station.name, address: "\(station.bearingLabel) · \(station.address)", coordinate: station.coordinate), symbol: "bus.fill")
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
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.frame(minHeight: 58).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(resolving)
    }
    private func edit(origin: Bool) {
        resolveTask?.cancel(); resolveToken = UUID(); search.cancel(); resolving = false
        editingOrigin = origin; editingDestination = !origin; query = ""; searchError = nil; focused = true
    }
    private func resolve(text: String, completion: MKLocalSearchCompletion? = nil) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        resolveTask?.cancel(); resolveToken = UUID(); let token = resolveToken
        resolving = true; resolvingQuery = query; searchError = nil
        resolveTask = Task {
            do {
                let place = try await search.resolve(text: text, completion: completion)
                guard !Task.isCancelled, token == resolveToken else { return }
                resolving = false
                if let place { choose(place) }
                else { searchError = "沒有找到台北市區內的地點，請加上地址或選擇站牌。" }
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

struct JourneyOptionsView: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if planner.planning || model.loading {
                HStack(spacing: 12) { ProgressView(); Text("尋找附近可搭的站牌").font(.subheadline) }.padding(.vertical, 16)
            }
            if let message = planner.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
            ForEach(planner.options) { option in
                Button { planner.select(option) } label: {
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
                            Text("\(first.boarding.name) → \(last.alighting.name)").font(.subheadline.weight(.medium)).lineLimit(2)
                            if option.id == planner.selectedID {
                                Text("往 \(first.route.destination(direction: first.direction)) · \(option.rides.reduce(0) { $0 + $1.stopCount }) 站")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                                Text("路線到站：\(EstimateFeed.label(model.snapshot.estimates.value(routeID: first.route.parentID, stopID: first.boarding.id, at: timeline.date)))")
                                    .font(.subheadline.weight(.medium)).monospacedDigit()
                            }
                        }
                        HStack {
                            Text(option.walkingTimeLabel).font(.caption).foregroundStyle(.secondary)
                            if option.id == planner.selectedID && planner.checkingWalks { ProgressView().controlSize(.small) }
                        }
                        if let issue = option.walkIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(option.id == planner.selectedID ? Color.accentColor.opacity(0.06) : Color(uiColor: .secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(option.id == planner.selectedID ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1.5))
                }.buttonStyle(.plain)
            }
            if planner.selected != nil {
                DisclosureGroup("查看步行與乘車詳情") {
                    JourneyItineraryView(model: model, planner: planner)
                }.font(.subheadline)
            }
            if planner.destination != nil {
                Button { planner.openAppleTransit() } label: {
                    Label("用 Apple 地圖查看其他交通方式", systemImage: "map").font(.subheadline).frame(minHeight: 44)
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
            let eta = ride.flatMap { model.snapshot.estimates.value(routeID: $0.route.parentID, stopID: $0.boarding.id, at: Date()) }
            let closed = eta.map { [-2, -3, -4].contains($0) } ?? false
            VStack(spacing: 8) {
                if let walk = option.walks.first {
                    Text(planner.checkingWalks ? "確認步行路線中" :
                         "\(walk.timeLabel) · \(ride?.boarding.name ?? planner.destination?.name ?? "目的地")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button(action: begin) {
                    Label(option.walkingOnly ? "開始步行" : "開始行程", systemImage: "arrow.up.right")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 54)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(planner.planning || planner.checkingWalks || option.walkIssue != nil || closed)
                if closed { Text("此站目前無法上車：\(EstimateFeed.label(eta))").font(.caption).foregroundStyle(.secondary) }
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
