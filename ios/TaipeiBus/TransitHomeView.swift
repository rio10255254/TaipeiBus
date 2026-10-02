import SwiftUI
import MapKit
import TransitCore

struct TransitHomeView: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject private var location: LocationService
    @ObservedObject private var planner: JourneyPlannerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSearch = false
    @State private var showDetails = false
    @State private var showInformation = false
    @State private var showJourney = false
    @State private var pendingJourneyDetail = false
    @State private var bottomControlsHeight: CGFloat = 210
    @StateObject private var selectionOverlay = MapSelectionOverlay()

    init(model: TransitAppModel) {
        self.model = model
        location = model.location
        planner = model.planner
    }

    private var hasSelection: Bool { model.selectedStationID != nil || model.selectedRouteID != nil || planner.selected != nil }
    private var nearbyStations: [Station] {
        guard !hasSelection, let position = location.usableCoordinate, position.isInServiceArea else { return [] }
        return model.metadata.stations.values.filter { $0.coordinate.distance(to: position) <= 800 }
            .sorted { $0.coordinate.distance(to: position) < $1.coordinate.distance(to: position) }.prefix(2).map { $0 }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                NativeBusMap(model: model, planner: planner, location: location.usableCoordinate,
                             bottomInset: showDetails ? geometry.size.height * 0.48 + 50 : bottomControlsHeight + geometry.safeAreaInsets.bottom + 24,
                             topInset: geometry.safeAreaInsets.top + 64,
                             reduceMotion: reduceMotion, selectionOverlay: selectionOverlay)
                    .ignoresSafeArea()
                    .accessibilityLabel("台北公車地圖")
                if !showDetails && !showSearch && !showJourney {
                    MapContextLabels(model: model, overlay: selectionOverlay) { showDetails = true }
                }
                HStack(alignment: .top, spacing: 12) {
                    SourceStatusView(snapshot: model.snapshot, loading: model.loading || model.refreshing) {
                        if model.loadError != nil { model.retry() }
                        else { Task { await model.refresh() } }
                    }
                    Spacer(minLength: 0)
                    Button { showInformation = true } label: {
                        Image(systemName: "info.circle").font(.title3).frame(width: 46, height: 46)
                    }
                    .phoneGlass(in: Circle())
                    .accessibilityLabel("資料來源與地圖設定")
                }
                .padding(.horizontal, 16).padding(.top, 8)

                if !showDetails, !planner.started, model.selectedVehicleID == nil, model.selectedStationID == nil, let route = model.selectedRoute {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.selectedRouteName ?? route.name).font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.accentColor).lineLimit(2)
                        HStack(spacing: 10) {
                            Text("往 \(route.destination(direction: model.direction))").font(.subheadline)
                            if model.routeDirections.count > 1 {
                                Button { model.switchDirection() } label: {
                                    Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44)
                                }.phoneGlass(in: Circle()).accessibilityLabel("切換路線方向")
                            }
                        }
                        Button { showDetails = true } label: {
                            Text("\(model.routeVehicles().filter { $0.hasReliablePosition(at: Date()) }.count) 輛可定位 · 查看公車")
                                .font(.subheadline.weight(.medium)).frame(minHeight: 44)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .white, radius: 4)
                    .padding(.horizontal, 24).padding(.top, 104)
                }
                if model.selectedVehicleID != nil, model.selectedVehicle == nil {
                    Button { showDetails = true } label: {
                        Label("此車目前沒有定位 · 查看路線車輛", systemImage: "location.slash")
                            .font(.subheadline).padding(.horizontal, 14).padding(.vertical, 12)
                    }
                    .phoneGlass(in: Capsule()).padding(.top, 100)
                }
                VStack(spacing: 0) {
                    Spacer()
                PhoneGlassGroup {
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        Button {
                            model.clearSelection()
                            if let position = location.usableCoordinate, position.isInServiceArea { model.focusMap(.coordinate(position)) }
                            location.request()
                        } label: {
                            Group {
                                if location.requesting { ProgressView() }
                                else { Image(systemName: "location.fill").font(.title3) }
                            }.frame(width: 48, height: 48)
                        }
                        .phoneGlass(in: Circle())
                        .accessibilityLabel("尋找我的位置與附近站牌")
                    }
                    if let message = location.message {
                        Text(message).font(.caption).padding(10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    if planner.started {
                        JourneyGuideCard(model: model, planner: planner) { showJourney = true }
                    } else {
                        Button { showJourney = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "magnifyingglass").foregroundStyle(Color.accentColor)
                                Text("你想去哪裡？").font(.body.weight(.semibold))
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                            }.padding(.horizontal, 20).frame(minHeight: 58)
                        }.buttonStyle(PhonePressStyle()).phoneGlass(in: Capsule())
                    }
                    if !nearbyStations.isEmpty, let position = location.usableCoordinate {
                        HStack(spacing: 10) {
                            ForEach(nearbyStations) { station in
                                Button { model.selectStation(station) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(station.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text("\(station.bearingLabel) · 直線 \(distanceLabel(position.distance(to: station.coordinate)))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .buttonStyle(PhonePressStyle()).phoneGlass(in: Capsule())
                                .accessibilityLabel("附近站牌 \(station.name) \(station.bearingLabel)，直線距離 \(distanceLabel(position.distance(to: station.coordinate)))")
                            }
                        }.transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    HStack(spacing: 4) {
                        Button { model.mode = .stops; showSearch = true } label: {
                            Label("站牌", systemImage: "mappin.and.ellipse").font(.subheadline.weight(.medium))
                                .padding(.horizontal, 18).frame(minHeight: 56)
                        }.buttonStyle(PhonePressStyle())
                        Spacer(minLength: 0)
                        if let bus = model.selectedVehicle {
                            Button {
                                model.following.toggle()
                                UISelectionFeedbackGenerator().selectionChanged()
                                if model.following { model.focusMap(.vehicle(bus.id)) }
                            } label: {
                                Image(systemName: model.following ? "scope" : "bus.fill")
                                    .font(.title3).frame(width: 50, height: 50)
                                    .foregroundStyle(model.following ? Color.accentColor : Color.primary)
                                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            }.accessibilityLabel(model.following ? "停止跟車" : "跟車")
                        } else {
                            Button { model.mode = .routes; showSearch = true } label: {
                                Label("路線", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                    .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 50)
                            }
                        }
                        if model.selectedRouteID != nil || model.selectedStationID != nil {
                            Button { model.clearSelection() } label: {
                                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 50, height: 50)
                            }.accessibilityLabel("關閉選取")
                        }
                    }
                    .padding(.horizontal, 6)
                    .phoneGlass(in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
                    .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86), value: hasSelection)
                }
                }
                .background {
                    GeometryReader { controls in Color.clear.preference(key: MapBottomControlsHeightKey.self, value: controls.size.height) }
                }
                }
                .padding(.horizontal, 24).padding(.bottom, 12)
                .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: nearbyStations.map(\.id))
                if let error = model.mapError ?? model.loadError {
                    Text(error).font(.caption).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.top, 96).padding(.horizontal, 16)
                }
            }
        }
        .tint(Color(red: 0.12, green: 0.39, blue: 0.90))
        .onPreferenceChange(MapBottomControlsHeightKey.self) { bottomControlsHeight = $0 }
        .sheet(isPresented: $showSearch) {
            TransitPanel(model: model, location: location, showInformation: $showInformation, browseOnly: true)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showDetails) {
            TransitPanel(model: model, location: location, showInformation: $showInformation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showJourney, onDismiss: {
            if pendingJourneyDetail { pendingJourneyDetail = false; showDetails = true }
        }) {
            JourneyPlanningView(model: model, planner: planner, location: location)
                .presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(30)
        }
        .sheet(isPresented: $showInformation) { AppInformationView(model: model) }
        .onChange(of: location.coordinate) { _, position in
            guard let position else { return }
            planner.locationArrived(position, metadata: model.metadata)
            if position.isInServiceArea, !hasSelection { model.focusMap(.coordinate(position)) }
        }
        .onChange(of: planner.mapRevision) { _, _ in
            let coordinates = planner.mapCoordinates
            if !showDetails {
                model.clearSelection()
                if !coordinates.isEmpty { model.focusMap(.journey(coordinates)) }
            }
#if DEBUG
            model.markJourneyPreviewReady()
            if ProcessInfo.processInfo.arguments.contains("--preview-destination"), planner.selected != nil { showJourney = !planner.started }
#endif
        }
        .onChange(of: model.loading) { _, loading in
            if !loading, planner.destination != nil, planner.options.isEmpty { planner.plan(metadata: model.metadata) }
        }
        .onChange(of: model.selectionRevision) { _, _ in
            selectionOverlay.update(nil)
            showSearch = false
            showDetails = false
            if showJourney { pendingJourneyDetail = true; showJourney = false }
            else if planner.started { showDetails = true }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-details") { showDetails = true }
#endif
        }
#if DEBUG
        .onChange(of: model.query) { _, value in
            if ProcessInfo.processInfo.arguments.contains("--preview-route-search") { showSearch = true }
        }
        .onChange(of: model.mode) { _, _ in
            if ProcessInfo.processInfo.arguments.contains("--preview-route-search") { showSearch = true }
        }
        .onChange(of: model.loading) { _, loading in
            if !loading && ProcessInfo.processInfo.arguments.contains("--preview-journey-search") { showJourney = true }
        }
#endif
    }
}

private struct MapBottomControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 210
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// Native Liquid Glass follows system appearance and accessibility preferences on iOS 26.
// Earlier systems keep the same control shapes with the system material.
private struct PhoneGlassBackground<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .systemBackground), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    func phoneGlass<S: Shape>(in shape: S) -> some View { modifier(PhoneGlassBackground(shape: shape)) }
}

struct PhoneGlassGroup<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 10) { content } }
        else { content }
    }
}

struct PhonePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.74), value: configuration.isPressed)
    }
}

private struct SourceStatusView: View {
    let snapshot: TransitSnapshot
    let loading: Bool
    let refresh: () -> Void
    static let clockStyle = Date.FormatStyle(date: .omitted, time: .shortened,
        locale: Locale(identifier: "zh_TW"), timeZone: TimeZone(identifier: "Asia/Taipei")!)

    var body: some View {
        Button(action: refresh) {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let age = snapshot.sourceUpdatedAt.map { timeline.date.timeIntervalSince($0) }
            let estimateAge = snapshot.estimates.updatedAt.map { timeline.date.timeIntervalSince($0) }
            let healthy = snapshot.vehicleError == nil && age.map { (-60...120).contains($0) } == true &&
                snapshot.estimates.error == nil && estimateAge.map { (-60...120).contains($0) } == true
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(healthy ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(loading || (snapshot.sourceUpdatedAt == nil && snapshot.vehicleError == nil) ? "更新中" : healthy ? "臺北市公車" : "資料延遲 · 點此重試")
                        .font(.subheadline.weight(.semibold))
                }
                if let date = snapshot.sourceUpdatedAt {
                    HStack(spacing: 4) {
                        Text("更新"); Text(date.formatted(Self.clockStyle))
                        if let age, age >= 120 { Text("· \(Int(age / 60)) 分鐘前") }
                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else { Text("定位與到站預估").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        }.buttonStyle(.plain).accessibilityHint("點一下重新取得定位與到站資料")
    }
}

private struct TransitPanel: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var location: LocationService
    @Binding var showInformation: Bool
    var browseOnly = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !browseOnly && (model.selectedStationID != nil || model.selectedRouteID != nil) {
                detailHeader
            } else {
                browseHeader
            }
            if model.loading {
                VStack(spacing: 12) {
                    ProgressView(); Text("取得站牌與路線中").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.loadError {
                ContentUnavailableView {
                    Label("無法連線", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: { Button("重試") { model.retry() }.buttonStyle(.borderedProminent) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if browseOnly { browseResults }
                        else if let station = model.selectedStation { StationDetails(model: model, station: station) }
                        else if let vehicle = model.selectedVehicle { VehicleDetails(model: model, vehicle: vehicle) }
                        else if let route = model.selectedRoute { RouteDetails(model: model, route: route) }
                        else { browseResults }
                    }.padding(.horizontal, 18).padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await model.refresh() }
            }
        }
        .padding(.top, 16)
        .onAppear {
            if browseOnly {
                searchFocused = model.mode != .routes || !model.query.isEmpty
#if DEBUG
                // Route screenshots do not need the simulator's first-use keyboard tutorial.
                if ProcessInfo.processInfo.arguments.contains("--preview-route-search") { searchFocused = false }
#endif
            }
        }
        .onChange(of: model.mode) { _, mode in
            if mode == .routes && model.query.isEmpty { searchFocused = false }
        }
        .onChange(of: searchFocused) { _, focused in if focused { model.sheetDetent = .large } }
        .onChange(of: model.selectedStationID) { _, _ in searchFocused = false }
        .onChange(of: model.selectedRouteID) { _, _ in searchFocused = false }
        .onChange(of: model.selectedVehicleID) { _, _ in searchFocused = false }
    }

    private var browseTitle: String {
        switch model.mode {
        case .stops: return location.usableCoordinate?.isInServiceArea == true ? "附近站牌" : "選擇站牌"
        case .routes: return "公車路線"
        }
    }

    private var browseHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(browseTitle)
                    .font(.title2.weight(.bold))
                Spacer()
                if model.mode == .routes, !model.loading {
                    Text("\(model.metadata.routeCatalog.groups.count) 條")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                if model.mode == .stops {
                    Button { location.request() } label: { Label("定位", systemImage: "location.fill") }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                }
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜尋站牌或路線", text: $model.query)
                    .focused($searchFocused).submitLabel(.search).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { searchFocused = false }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .frame(width: 36, height: 40).accessibilityLabel("清除搜尋")
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 48)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13))
            Picker("查詢類型", selection: $model.mode) {
                ForEach(BrowseMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if let message = location.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 18).padding(.bottom, 12)
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { model.clearSelection() } label: { Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44) }
                .accessibilityLabel("返回搜尋")
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedStation?.name ?? model.selectedVehicle?.routeName ?? model.selectedRouteName ?? "公車動態")
                    .font(.title2.weight(.bold)).lineLimit(2)
                if let station = model.selectedStation { Text(station.bearingLabel).font(.caption).foregroundStyle(.secondary) }
                else if let vehicle = model.selectedVehicle { Text(vehicle.plate).font(.subheadline).foregroundStyle(.secondary).monospaced() }
                else { Text("路線動態").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if let station = model.selectedStation {
                Button { model.toggleFavorite(station) } label: {
                    Image(systemName: model.favorites.contains(station.id) ? "star.fill" : "star")
                        .font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel(model.favorites.contains(station.id) ? "移除收藏站牌" : "收藏站牌")
            }
        }.padding(.leading, 6).padding(.trailing, 12).padding(.bottom, 12)
    }

    @ViewBuilder private var browseResults: some View {
        if model.mode == .stops {
            let stations = model.stations(query: model.query)
            if stations.isEmpty { emptyResult }
            ForEach(stations) { station in
                Button { model.selectStation(station) } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: model.favorites.contains(station.id) ? "star.fill" : model.recentStationIDs.contains(station.id) ? "clock" : "mappin.circle.fill")
                            .foregroundStyle(model.favorites.contains(station.id) ? Color.orange : Color.accentColor)
                            .font(.title2).frame(width: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(station.name).font(.body.weight(.semibold)); Text(station.bearingLabel).font(.caption).foregroundStyle(.secondary) }
                            Text(station.address.isEmpty ? "站牌 \(station.id)" : station.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if let position = location.usableCoordinate, position.isInServiceArea {
                            Text(distanceLabel(position.distance(to: station.coordinate))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.padding(.vertical, 15).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
        } else if model.mode == .routes {
            let routes = model.routes(query: model.query)
            let counts = RouteVehicleCounts(vehicles: model.snapshot.vehicles, at: Date())
            if routes.isEmpty { emptyResult }
            ForEach(routes) { result in
                let route = result.route
                Button { model.selectRoute(route, variantOnly: result.matchedVariant != nil) } label: {
                    HStack(spacing: 12) {
                        RouteBadge(name: route.name)
                        VStack(alignment: .leading, spacing: 4) {
                            if result.matchedVariant != nil {
                                Text(result.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                            }
                            Text("\(route.departure) → \(route.destination)").font(.subheadline).lineLimit(2)
                            Text("\(counts.count(route: route, allVariants: result.matchedVariant == nil)) 輛可定位" +
                                 (result.group.variants.count > 1 ? " · \(result.group.variants.count) 個走法" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical, 15).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var emptyResult: some View {
        Text("找不到符合的資料，試試其他名稱").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 24)
    }
}

private struct StationDetails: View {
    @ObservedObject var model: TransitAppModel
    let station: Station

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let rows = StationArrival.rows(station: station, metadata: model.metadata, snapshot: model.snapshot, now: timeline.date)
            VStack(alignment: .leading, spacing: 0) {
                Text(station.address).font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                ForEach(model.oppositeStations(to: station)) { opposite in
                    Button { model.selectStation(opposite) } label: {
                        Label("改看\(opposite.bearingLabel)站牌", systemImage: "arrow.left.arrow.right")
                            .font(.subheadline).frame(minHeight: 44)
                    }
                }
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: station.coordinate.locationCoordinate))
                    item.name = station.name
                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                } label: { Label("步行到這個站牌", systemImage: "figure.walk").font(.subheadline.weight(.medium)).frame(minHeight: 44) }
                    .padding(.bottom, 12)
                HStack {
                    Text("官方到站預估").font(.subheadline.weight(.semibold))
                    Spacer()
                    if let time = model.snapshot.estimates.updatedAt {
                        Text(time.formatted(SourceStatusView.clockStyle)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }.padding(.bottom, 8)
                if rows.isEmpty { Text("此站暫無路線資訊").foregroundStyle(.secondary).padding(.vertical) }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            if let route = row.route { model.selectRoute(route, direction: row.stop.direction) }
                        } label: {
                            HStack(spacing: 12) {
                                RouteBadge(name: row.route?.name ?? row.stop.routeID)
                                Text("往 \(row.route?.destination(direction: row.stop.direction) ?? "方向未提供")")
                                    .font(.subheadline).lineLimit(2)
                                Spacer(minLength: 4)
                                Text(EstimateFeed.label(row.estimateSeconds))
                                    .font(.body.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle((row.estimateSeconds ?? -1) >= 0 ? Color.accentColor : Color.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).frame(minHeight: 44)
                        if !row.approaches.isEmpty {
                            Text("同方向車輛").font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(row.approaches) { approach in
                                    Button { model.selectVehicle(approach.vehicle) } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(approach.vehicle.plate).font(.caption.weight(.semibold)).monospaced()
                                            Text(approach.alongDistance.map { $0 <= 25 ? "站牌附近" : "沿線 \(distanceLabel($0))" }
                                                 ?? "GPS 直線 \(distanceLabel(approach.directDistance))").font(.caption2).foregroundStyle(.secondary)
                                        }.padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 48)
                                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }.padding(.vertical, 12)
                    Divider()
                }
                Text("軌跡可確認時排除已通過車輛；沿線距離依 GPS 推估。官方時間未綁定車牌。").font(.caption).foregroundStyle(.secondary).padding(.top, 14)
            }
        }
    }
}

private struct RouteDetails: View {
    @ObservedObject var model: TransitAppModel
    let route: BusRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.routeVariants.count > 1 {
                Menu {
                    Button { model.changeRouteVariant(nil) } label: {
                        Label("全部走法", systemImage: model.allRouteVariants ? "checkmark" : "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    ForEach(model.routeVariants) { variant in
                        Button { model.changeRouteVariant(variant) } label: {
                            if !model.allRouteVariants && variant.id == route.id {
                                Label(variant.displayName, systemImage: "checkmark")
                            } else { Text(variant.displayName) }
                        }
                    }
                } label: {
                    HStack {
                        Text(model.allRouteVariants ? "全部走法 · \(model.routeVariants.count)" : route.displayName)
                            .font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                    }.padding(.horizontal, 14).frame(minHeight: 48)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13))
                }.accessibilityLabel("選擇路線走法")
            }
            if model.routeDirections.count > 1 {
                Picker("行駛方向", selection: $model.direction) {
                    ForEach(model.routeDirections, id: \.self) { direction in
                        Text("往 \(route.destination(direction: direction))").tag(direction)
                    }
                }.pickerStyle(.segmented)
            } else {
                Text("往 \(route.destination(direction: model.direction))").font(.subheadline).foregroundStyle(.secondary)
            }
            let buses = model.routeVehicles()
            let count = buses.filter { $0.hasReliablePosition(at: Date()) }.count
            Text("\(count) 輛可定位" + (count < buses.count ? " · \(buses.count - count) 輛等待定位" : ""))
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(buses) { bus in
                VehicleRow(vehicle: bus) { model.selectVehicle(bus) }
                Divider()
            }
            if buses.isEmpty { Text("目前沒有此方向的車輛回報").font(.subheadline).foregroundStyle(.secondary) }
            Text(model.allRouteVariants && model.routeVariants.count > 1 ? "主要站序" : "沿線站牌")
                .font(.headline).padding(.top, 8)
            if model.allRouteVariants && model.routeVariants.count > 1 {
                Text("切換上方走法，可看各支線停靠站。").font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                ForEach(model.routeStops) { stop in
                    Button {
                        if let station = model.metadata.stations[stop.stationID] { model.selectStation(station) }
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(stop.sequence)").font(.caption).foregroundStyle(.secondary).frame(width: 26)
                            Text(stop.name).font(.subheadline)
                            Spacer(minLength: 8)
                            Text(EstimateFeed.label(model.snapshot.estimates.value(routeID: route.parentID, stopID: stop.id, at: timeline.date)))
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.frame(minHeight: 50).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

private struct VehicleDetails: View {
    @ObservedObject var model: TransitAppModel
    let vehicle: BusVehicle

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("往 \(vehicle.destination)").font(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let fresh = vehicle.hasReliablePosition(at: timeline.date)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fresh && vehicle.hasSpeed ? "\(Int(vehicle.speed))" : "—").font(.system(.largeTitle, design: .rounded).weight(.semibold)).monospacedDigit()
                        Text("GPS 回報 km/h").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(fresh ? vehicle.statusLabel : vehicle.trackingLabel(at: timeline.date) ?? "定位已延遲").font(.subheadline.weight(.semibold)).foregroundStyle(fresh ? Color.primary : Color.orange)
                        Text("\(max(0, Int(timeline.date.timeIntervalSince(vehicle.observedAt)))) 秒前回報").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if vehicle.lowFloor { Label("低底盤", systemImage: "figure.roll").font(.caption) }
                    }
                }
            }
            if let provider = vehicle.provider { Text(provider).font(.subheadline).foregroundStyle(.secondary) }
            Toggle("淡化建築、凸顯這輛車", isOn: $model.highlightVehicle).font(.subheadline)
            HStack(spacing: 10) {
                Button {
                    model.following = true; model.focusMap(.vehicle(vehicle.id))
                } label: { Label("跟隨公車", systemImage: "scope").frame(maxWidth: .infinity, minHeight: 36) }
                    .buttonStyle(.borderedProminent)
                Button {
                    if let route = model.metadata.route(vehicle.routeID) { model.selectRoute(route, direction: vehicle.direction, variantOnly: true) }
                } label: { Text("查看路線").frame(maxWidth: .infinity, minHeight: 36) }.buttonStyle(.bordered)
            }
            if !vehicle.aligned { Text("目前顯示原始 GPS，尚未匹配道路軌跡").font(.caption).foregroundStyle(.secondary) }
            let upcoming = model.upcomingStops
            if !upcoming.isEmpty {
                Divider()
                Text("前方站牌").font(.subheadline.weight(.semibold))
                ForEach(Array(upcoming.prefix(3)), id: \.stop.id) { progress in
                    Button {
                        if let station = model.metadata.stations[progress.stop.stationID] { model.selectStation(station) }
                    } label: {
                        HStack {
                            Text(progress.stop.name).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(progress.distance <= 25 ? "站牌附近" : "沿線 \(distanceLabel(progress.distance))").foregroundStyle(.secondary).monospacedDigit()
                        }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text("依目前 GPS 與路線順序推估，不是車輛到站時間。").font(.caption).foregroundStyle(.secondary)
            }
            let stops = model.metadata.orderedStops(routeID: vehicle.routeID, direction: vehicle.direction)
                .sorted { $0.coordinate.distance(to: vehicle.rawCoordinate) < $1.coordinate.distance(to: vehicle.rawCoordinate) }
            if upcoming.isEmpty, let stop = stops.first {
                Divider()
                Text("最後 GPS 附近 · \(stop.name)").font(.subheadline.weight(.semibold))
                Text("GPS 直線距離 \(distanceLabel(vehicle.rawCoordinate.distance(to: stop.coordinate)))")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    if let station = model.metadata.stations[stop.stationID] { model.selectStation(station) }
                } label: { Label("查看此站到站預估", systemImage: "mappin.and.ellipse").frame(minHeight: 44) }
            }
        }
    }
}

struct VehicleRow: View {
    let vehicle: BusVehicle
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bus.fill").foregroundStyle(.secondary).font(.title3).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(vehicle.plate).font(.body.weight(.semibold)).monospaced()
                    Text("\(vehicle.routeName) · 往 \(vehicle.destination)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    let reliable = vehicle.hasReliablePosition(at: timeline.date)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(reliable ? vehicle.speedLabel : vehicle.trackingIssue == .missing ? "訊號暫缺" : vehicle.trackingIssue == .rejected ? "確認中" : "延遲")
                            .foregroundStyle(reliable ? Color.secondary : Color.orange)
                        Text("\(max(0, Int(timeline.date.timeIntervalSince(vehicle.observedAt)))) 秒前").foregroundStyle(.secondary)
                    }.font(.caption).monospacedDigit()
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 14).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct RouteBadge: View {
    let name: String
    var body: some View {
        Text(name).font(.subheadline.weight(.bold)).lineLimit(2)
            .padding(.horizontal, 10).padding(.vertical, 8).frame(minWidth: 56)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct AppInformationView: View {
    @ObservedObject var model: TransitAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("即時資料") {
                    Text("\(model.metadata.routeCatalog.groups.count) 條路線 · \(model.metadata.routes.count) 個走法")
                    Text("臺北市公共運輸處公開資料，每 15 秒重新取得。個別公車回報時間以車輛卡片為準。")
                    if let error = model.snapshot.vehicleError { Label(error, systemImage: "wifi.exclamationmark") }
                    if let error = model.snapshot.estimates.error { Text(error) }
                    if let notice = model.metadataNotice { Text(notice) }
                    Text("官方到站預估沒有車牌資訊；請以站牌的路線預估為準。")
                    Text("回到 App 時立即更新；背景暫停畫面與輪詢。官方車輛資料會持續產生。")
                    Link("公開資料說明", destination: URL(string: "https://pto.gov.taipei/News_Content.aspx?n=A1DF07A86105B6BB&s=55E8ADD164E4F579&sms=2479B630A6BD8079")!)
                }
                Section("地圖") {
                    Toggle("選車時淡化建築", isOn: $model.highlightVehicle)
                    Text("原生 MapLibre / Metal 地圖，使用 OpenFreeMap 底圖。道路匹配受 GPS 與軌跡精度影響。")
                    Link("OpenFreeMap", destination: URL(string: "https://openfreemap.org")!)
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    NavigationLink("開源授權") { LicenseView() }
                }
                Section("定位") {
                    Text("定位只在使用期間尋找附近站牌，可直接手動搜尋；位置不會傳到公車資料來源。")
                    Button("開啟系統設定") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("隱私") {
                    NavigationLink("隱私權說明") { PrivacyExplanationView() }
                }
            }
            .navigationTitle("資訊與設定").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct PrivacyExplanationView: View {
    var body: some View {
        List {
            Section("你的位置") {
                Text("定位為選用，只在使用 App 時尋找附近站牌、規劃行程與定位地圖。也能拒絕定位，手動選擇出發地、站牌或路線。App 不會將定位座標加入公車資料查詢。")
                Text("地點搜尋與步行路線由 Apple 地圖提供；搜尋文字及路線起終點由 Apple 處理。")
                Text("地圖供應者會收到目前畫面需要的圖磚請求及網路連線資訊，因此可能得知你正在查看的大致區域。")
            }
            Section("保存在手機") {
                Text("收藏站牌、最近目的地、最近查看與地圖偏好保存在此裝置。App 沒有帳號、廣告或跨 App 追蹤，也未加入分析 SDK。")
            }
            Section("網路服務") {
                Text("公車資料來自臺北市公開資料服務；底圖由 OpenFreeMap 提供。服務商可能依自己的政策處理連線紀錄。")
                Link("OpenFreeMap 隱私政策", destination: URL(string: "https://openfreemap.org/privacy/")!)
            }
            Section("測試回饋") {
                Text("透過 TestFlight 主動回報時，Apple 與開發者可能收到你提交的內容、截圖及診斷資訊。分享前請留意截圖是否包含你的位置。")
            }
            Section("管理權限") {
                Text("可在 iPhone 系統設定關閉定位。刪除 App 可移除其本機收藏與偏好。")
            }
        }
        .navigationTitle("隱私權說明").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseView: View {
    private var licenses: String {
        guard let url = Bundle.main.url(forResource: "Licenses", withExtension: "txt") else { return "授權文件未載入" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "授權文件未載入"
    }
    var body: some View {
        ScrollView { Text(licenses).font(.caption).textSelection(.enabled).padding() }
            .navigationTitle("開源授權").navigationBarTitleDisplayMode(.inline)
    }
}

func distanceLabel(_ meters: Double) -> String {
    meters >= 1_000 ? String(format: "%.1f km", meters / 1_000) : "\(Int(meters.rounded())) m"
}
