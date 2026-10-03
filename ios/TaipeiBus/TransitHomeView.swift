import SwiftUI
import MapKit
import TransitCore

struct TransitHomeView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject private var location: LocationService
    @ObservedObject private var planner: JourneyPlannerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSearch = false
    @State private var showDetails = false
    @State private var showInformation = false
    @State private var showJourney = false
    @State private var journeyDetent: PresentationDetent = .large
    @State private var pendingJourneyDetail = false
    @State private var bottomControlsHeight: CGFloat = 210
    @State private var lastLocationFocus: Coordinate?
    @State private var lastJourneyOptionID: String?
    @State private var lastJourneyStep: JourneyStep?
    @StateObject private var selectionOverlay = MapSelectionOverlay()

    init(model: TransitAppModel) {
        self.model = model
        location = model.location
        planner = model.planner
    }

    private var hasTransitSelection: Bool { model.selectedStationID != nil || model.selectedRouteID != nil || model.selectedVehicleID != nil }
    private var hasSelection: Bool { hasTransitSelection || planner.selected != nil }
    private var nearbyStations: [Station] {
        guard live.display.nearbyStops, !hasSelection, let position = location.usableCoordinate, position.isInServiceArea else { return [] }
        return model.metadata.stations.values.filter { $0.coordinate.distance(to: position) <= 800 }
            .sorted { $0.coordinate.distance(to: position) < $1.coordinate.distance(to: position) }.prefix(2).map { $0 }
    }

    private var mapContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                NativeBusMap(model: model, planner: planner, location: location.displayCoordinate,
                             bottomInset: (showJourney && planner.selected != nil ? 460 : showDetails || pendingJourneyDetail || (showSearch && hasTransitSelection) ? 330 : showSearch ? 390 : bottomControlsHeight) + geometry.safeAreaInsets.bottom + 24,
                             topInset: geometry.safeAreaInsets.top + 64,
                             reduceMotion: reduceMotion, selectionOverlay: selectionOverlay)
                    .ignoresSafeArea()
                    .accessibilityLabel(live.text("台北公車地圖"))
#if DEBUG
                    .accessibilityIdentifier("native-map").accessibilityValue(selectionOverlay.cameraState)
#endif
                if !showDetails && !showSearch && !showJourney && !pendingJourneyDetail {
                    MapContextLabels(model: model, overlay: selectionOverlay) { showDetails = true }
                }
                HStack(alignment: .top, spacing: 12) {
                    SourceStatusView(snapshot: model.snapshot, loading: model.loading || model.refreshing, compact: planner.selected != nil) {
                        if model.loadError != nil { model.retry() }
                        else { Task { await model.refresh() } }
                    }
                    Spacer(minLength: 0)
                    Button { showInformation = true } label: {
                        Image(systemName: "info.circle").liveFont(.title3).frame(width: 46, height: 46)
                    }
                    .phoneGlass(in: Circle())
                    .accessibilityLabel(live.text("資料來源與地圖設定"))
                }
                .padding(.horizontal, 16 * CGFloat(live.appearance.spacingScale)).padding(.top, 8 * CGFloat(live.appearance.spacingScale))
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--test-map-controls") {
                    Text(selectionOverlay.cameraState).font(.system(size: 1)).foregroundStyle(.clear)
                        .frame(width: 1, height: 1).accessibilityIdentifier("map-camera-state").allowsHitTesting(false)
                }
                if let notice = model.previewNotice {
                    Text(notice).liveFont(.caption, weight: .semibold).padding(8)
                        .background(Color.orange.opacity(0.9), in: Capsule()).padding(.top, 80 * CGFloat(live.appearance.spacingScale))
                }
#endif

                if !showDetails, !showSearch, !planner.started, planner.selected == nil, model.selectedVehicleID == nil, model.selectedStationID == nil, let route = model.selectedRoute {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.selectedRouteName ?? route.name).liveFont(.largeTitle, weight: .bold, design: .rounded)
                            .foregroundStyle(Color(liveHex: live.appearance.accentColor)).lineLimit(2)
                        HStack(spacing: 10) {
                            Text("往 \(route.destination(direction: model.direction))").liveFont(.subheadline)
                            if model.routeDirections.count > 1 {
                                Button { model.switchDirection() } label: {
                                    Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44)
                                }.phoneGlass(in: Circle()).accessibilityLabel(live.text("切換路線方向"))
                            }
                        }
                        Button { showDetails = true } label: {
                            Text("\(model.routeVehicles().filter { $0.hasReliablePosition(at: Date()) }.count) 輛可定位 · 查看公車")
                                .liveFont(.subheadline, weight: .medium).frame(minHeight: 44)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .white, radius: 4)
                    .padding(.horizontal, 24 * CGFloat(live.appearance.spacingScale)).padding(.top, 104 * CGFloat(live.appearance.spacingScale))
                }
                if model.selectedVehicleID != nil, model.selectedVehicle == nil {
                    Button { showDetails = true } label: {
                        Label(live.text("此車目前沒有定位 · 查看路線車輛"), systemImage: "location.slash")
                            .liveFont(.subheadline).padding(.horizontal, 14 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 12 * CGFloat(live.appearance.spacingScale))
                    }
                    .phoneGlass(in: Capsule()).padding(.top, 100 * CGFloat(live.appearance.spacingScale))
                }
                if !showDetails && !showSearch && !showJourney && !pendingJourneyDetail {
                VStack(spacing: 0) {
                    Spacer()
                PhoneGlassGroup {
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        Button {
                            model.cycleUserTracking()
                        } label: {
                            Group {
                                if location.requesting { ProgressView() }
                                else { Image(systemName: model.userMapMode == .heading ? "location.north.line.fill" : model.userMapMode == .north ? "location.fill" : "location").liveFont(.title3) }
                            }.frame(width: 48, height: 48)
                        }
                        .phoneGlass(in: Circle())
                        .accessibilityIdentifier("map-location")
                        .accessibilityLabel(live.text("定位與地圖方向"))
                        .accessibilityValue(model.userMapMode == .heading ? "手機方向" : model.userMapMode == .north ? "北朝上" : "自由瀏覽")
                        .accessibilityHint(model.userMapMode == .north ? "切換為手機方向" : "回到目前位置並朝北")
                    }
                    if let message = location.message, !hasSelection {
                        Text(message).liveFont(.caption).padding(10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    if planner.started || planner.selected?.walkingOnly == true {
                        JourneyGuideCard(model: model, planner: planner) { journeyDetent = .large; showJourney = true }
                    } else if planner.selected != nil {
                        JourneyArrivalDock(model: model, planner: planner) { journeyDetent = .height(460); showJourney = true }
                    } else {
                        Button { journeyDetent = .large; showJourney = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "magnifyingglass").foregroundStyle(Color(liveHex: live.appearance.accentColor))
                                Text(live.text("搜尋目的地")).liveFont(.body, weight: .semibold)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").liveFont(.subheadline, weight: .semibold).foregroundStyle(Color(liveHex: live.appearance.accentColor))
                            }.padding(.horizontal, 20 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 58)
                                .contentShape(Capsule())
                        }.buttonStyle(PhonePressStyle()).phoneGlass(in: Capsule())
                    }
                    if !nearbyStations.isEmpty, let position = location.usableCoordinate {
                        HStack(spacing: 10) {
                            ForEach(nearbyStations) { station in
                                Button { model.selectStation(station) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(station.name).liveFont(.subheadline, weight: .semibold).lineLimit(1)
                                        Text("\(station.bearingLabel) · 直線 \(distanceLabel(position.distance(to: station.coordinate)))")
                                            .liveFont(.caption).foregroundStyle(.secondary)
                                    }.padding(.horizontal, 14 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 10 * CGFloat(live.appearance.spacingScale)).frame(maxWidth: .infinity, minHeight: 48)
                                }
                                .buttonStyle(PhonePressStyle()).phoneGlass(in: Capsule())
                                .accessibilityIdentifier("nearby-station-" + station.id)
                                .accessibilityLabel("附近站牌 \(station.name) \(station.bearingLabel)，直線距離 \(distanceLabel(position.distance(to: station.coordinate)))")
                            }
                        }.transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if planner.selected == nil {
                    HStack(spacing: 4) {
                        if live.display.stationShortcut || hasSelection {
                        Button { openBrowse(.stops) } label: {
                            Label(live.text("站牌"), systemImage: "mappin.and.ellipse").liveFont(.subheadline, weight: .medium)
                                .padding(.horizontal, 18 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 56)
                        }.buttonStyle(PhonePressStyle())
                        }
                        Spacer(minLength: 0)
                        if let bus = model.selectedVehicle {
                            Button {
                                model.following.toggle()
                                UISelectionFeedbackGenerator().selectionChanged()
                                if model.following { model.focusMap(.vehicle(bus.id)) }
                            } label: {
                                Image(systemName: model.following ? "scope" : "bus.fill")
                                    .liveFont(.title3).frame(width: 50, height: 50)
                                    .foregroundStyle(model.following ? Color(liveHex: live.appearance.accentColor) : Color.primary)
                                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                            }.accessibilityLabel(model.following ? "停止跟車" : "跟車")
                        } else if live.display.routeShortcut || hasSelection {
                            Button { openBrowse(.routes) } label: {
                                Label(live.text("路線"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                    .liveFont(.subheadline, weight: .medium).padding(.horizontal, 12 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 50)
                            }
                        }
                        if model.selectedRouteID != nil || model.selectedStationID != nil {
                            Button { model.clearSelection() } label: {
                                Image(systemName: "xmark").liveFont(.subheadline, weight: .semibold).frame(width: 50, height: 50)
                            }.accessibilityLabel(live.text("關閉選取"))
                        }
                    }
                    .padding(.horizontal, 6 * CGFloat(live.appearance.spacingScale))
                    .phoneGlass(in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
                    .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86), value: hasSelection)
                    }
                }
                }
                .background {
                    GeometryReader { controls in Color.clear.preference(key: MapBottomControlsHeightKey.self, value: controls.size.height) }
                }
                }
                .padding(.horizontal, 24 * CGFloat(live.appearance.spacingScale)).padding(.bottom, 12 * CGFloat(live.appearance.spacingScale))
                .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: nearbyStations.map(\.id))
                }
                if let error = model.mapError ?? model.loadError {
                    Text(error).liveFont(.caption).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14 * CGFloat(live.appearance.cornerScale)))
                        .padding(.top, 96 * CGFloat(live.appearance.spacingScale)).padding(.horizontal, 16 * CGFloat(live.appearance.spacingScale))
                }
            }
        }
    }

    var body: some View {
        mapContent
        .tint(Color(liveHex: live.appearance.accentColor))
        .onPreferenceChange(MapBottomControlsHeightKey.self) { bottomControlsHeight = $0 }
        .sheet(isPresented: $showSearch, onDismiss: { model.stationBrowsing = false; restoreJourneyMap() }) {
            TransitPanel(model: model, location: location, showInformation: $showInformation, browseOnly: !hasTransitSelection)
                .presentationDetents(hasTransitSelection ? [.height(330), .large] : model.mode == .stops ? [.height(390), .large] : [.large], selection: $model.sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(390)))
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showDetails, onDismiss: restoreJourneyMap) {
            TransitPanel(model: model, location: location, showInformation: $showInformation)
                .presentationDetents([.height(330), .large], selection: $model.sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(330)))
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showJourney, onDismiss: {
            if pendingJourneyDetail { pendingJourneyDetail = false; showDetails = true }
        }) {
            JourneyPlanningView(model: model, planner: planner, location: location,
                                compact: journeyDetent != .large,
                                expand: { withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)) { journeyDetent = .large } },
                                collapse: { withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)) { journeyDetent = .height(460) } })
                .presentationDetents(planner.destination == nil || planner.started ? [.large] : [.height(460), .large], selection: $journeyDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(460)))
                .presentationDragIndicator(.visible).presentationCornerRadius(30)
        }
        .sheet(isPresented: $showInformation) { AppInformationView(model: model) }
        .onChange(of: location.revision, initial: true) { _, _ in
            if let position = location.usableCoordinate { planner.locationArrived(position, metadata: model.metadata) }
            if model.userMapMode != .free, let position = location.displayCoordinate, lastLocationFocus != position {
                lastLocationFocus = position; model.focusMap(.userLocation)
            }
            if let position = location.displayCoordinate, position.isInServiceArea, !hasSelection,
               model.userMapMode == .free, !model.stationBrowsing, !model.mapWasMoved, lastLocationFocus != position {
                lastLocationFocus = position; model.focusMap(.coordinate(position))
            }
        }
        .onChange(of: planner.mapRevision) { _, _ in
            let coordinates = planner.mapCoordinates
            let userChangedJourney = lastJourneyOptionID != planner.selectedID || lastJourneyStep != planner.currentStep
            lastJourneyOptionID = planner.selectedID; lastJourneyStep = planner.currentStep
            if !showDetails && !pendingJourneyDetail && !(showSearch && hasTransitSelection),
               userChangedJourney || model.userMapMode == .free {
                let sameVehicle = model.selectedVehicle.map { bus in
                    planner.activeRide.map { $0.route.id == bus.routeID && $0.direction == bus.direction } == true
                } ?? false
                if let index = model.walkingMapIndex, !userChangedJourney,
                   planner.selected?.walks.indices.contains(index) == true {
                    if !model.mapWasMoved { model.showWalkOnMap(index) }
                } else if model.walkingMapIndex != nil, case .ride = planner.currentStep, sameVehicle, let bus = model.selectedVehicle {
                    model.clearWalkingMap(); model.following = true; model.focusMap(.vehicle(bus.id))
                } else if !sameVehicle {
                    model.clearWalkingMap()
                    model.clearSelection()
                    if !coordinates.isEmpty, userChangedJourney || !model.mapWasMoved { model.focusMap(.journey(coordinates)) }
                }
            }
#if DEBUG
            model.markJourneyPreviewReady()
            if ProcessInfo.processInfo.arguments.contains("--preview-destination"), planner.selected != nil {
                showJourney = !planner.started
                journeyDetent = ProcessInfo.processInfo.arguments.contains("--preview-journey-expanded") ? .large : .height(460)
            }
#endif
        }
        .onChange(of: model.loading) { _, loading in
            if !loading, planner.destination != nil, planner.options.isEmpty { planner.plan(metadata: model.metadata) }
        }
        .onChange(of: model.selectionRevision) { _, _ in
            let wasShowingDetails = showDetails
            selectionOverlay.update(nil)
            if showJourney { showDetails = false; pendingJourneyDetail = true; showJourney = false }
            else if showSearch {
                withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)) { model.sheetDetent = .height(330) }
            }
            else { showDetails = planner.started || wasShowingDetails }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-details") { showDetails = true }
#endif
        }
#if DEBUG
        .onChange(of: model.query) { _, value in
            if ProcessInfo.processInfo.arguments.contains("--preview-route-search") { model.sheetDetent = .large; showSearch = true }
        }
        .onChange(of: model.mode) { _, _ in
            if ProcessInfo.processInfo.arguments.contains("--preview-route-search") { model.sheetDetent = .large; showSearch = true }
        }
        .onChange(of: model.loading) { _, loading in
            if !loading && ProcessInfo.processInfo.arguments.contains("--preview-journey-search") { showJourney = true }
        }
#endif
    }

    private func restoreJourneyMap() {
        guard planner.selected != nil else { return }
        if let index = model.walkingMapIndex {
            let relevantBus = model.selectedVehicle.map { bus in
                planner.activeRide.map { $0.route.id == bus.routeID && $0.direction == bus.direction } == true
            } ?? false
            if !relevantBus { model.clearSelection() }
            model.showWalkOnMap(index); return
        }
        if let bus = model.selectedVehicle, let ride = planner.activeRide,
           bus.routeID == ride.route.id, bus.direction == ride.direction {
            if model.following { model.focusMap(.vehicle(bus.id)) }
        } else {
            model.clearSelection()
            let coordinates = planner.mapCoordinates
            if !coordinates.isEmpty { model.focusMap(.journey(coordinates)) }
        }
    }
    private func openBrowse(_ mode: BrowseMode) {
        model.clearSelection(); model.query = ""; model.mode = mode
        if mode == .stops { model.beginStationBrowsing() }
        else { model.stationBrowsing = false; model.sheetDetent = .large }
        showSearch = true
    }
}

private struct MapBottomControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 210
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// Native Liquid Glass follows system appearance and accessibility preferences on iOS 26.
// Earlier systems keep the same control shapes with the system material.
private struct PhoneGlassBackground<S: Shape>: ViewModifier {
    @Environment(\.liveSettings) private var live
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || live.appearance.solidSurfaces {
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
    @Environment(\.liveSettings) private var live
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: 10) { content } }
        else { content }
    }
}

struct PhonePressStyle: ButtonStyle {
    @Environment(\.liveSettings) private var live
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.74), value: configuration.isPressed)
    }
}

private struct SourceStatusView: View {
    @Environment(\.liveSettings) private var live
    let snapshot: TransitSnapshot
    let loading: Bool
    var compact = false
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
                    Text(loading || (snapshot.sourceUpdatedAt == nil && snapshot.vehicleError == nil) ? "更新中" : healthy ? (compact ? "即時" : "臺北市公車") : "資料延遲 · 重試")
                        .liveFont(.subheadline, weight: .semibold)
                }
                if !compact, let date = snapshot.sourceUpdatedAt {
                    HStack(spacing: 4) {
                        Text(live.text("更新")); Text(date.formatted(Self.clockStyle))
                        if let age, age >= 120 { Text("· \(Int(age / 60)) 分鐘前") }
                    }.liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else if !compact { Text(live.text("定位與到站預估")).liveFont(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 13 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 10 * CGFloat(live.appearance.spacingScale))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18 * CGFloat(live.appearance.cornerScale)))
        }
        }.buttonStyle(.plain).accessibilityHint("點一下重新取得定位與到站資料")
    }
}

private struct TransitPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var location: LocationService
    @Binding var showInformation: Bool
    var browseOnly = false
    @FocusState private var searchFocused: Bool
    @State private var stationResults: [Station] = []
    @State private var stationResultQuery = ""
    @State private var systemRouteKeyboard = false
    private var isBrowsing: Bool { model.selectedStationID == nil && model.selectedRouteID == nil }
    private var stationRequestKey: String { model.mode.rawValue + ":" + model.query + ":" + model.stationSearchContextKey }

    private var panelContent: some View {
        VStack(spacing: 0) {
            if !isBrowsing {
                detailHeader
            } else {
                browseHeader
            }
            if model.loading {
                VStack(spacing: 12) {
                    ProgressView(); Text(live.text("取得站牌與路線中")).liveFont(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.loadError {
                ContentUnavailableView {
                    Label(live.text("無法連線"), systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: { Button(live.text("重試")) { model.retry() }.buttonStyle(.borderedProminent) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isBrowsing { browseResults }
                        else if let station = model.selectedStation { StationDetails(model: model, station: station) }
                        else if let vehicle = model.selectedVehicle { VehicleDetails(model: model, vehicle: vehicle) }
                        else if let route = model.selectedRoute { RouteDetails(model: model, route: route) }
                        else { browseResults }
                    }.padding(.horizontal, 18 * CGFloat(live.appearance.spacingScale)).padding(.bottom, 24 * CGFloat(live.appearance.spacingScale))
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await model.refresh() }
            }
            if isBrowsing, model.mode == .routes, !systemRouteKeyboard {
                RouteSearchKeypad(query: $model.query) { systemRouteKeyboard = true; searchFocused = true }
            }
        }
        .padding(.top, 16 * CGFloat(live.appearance.spacingScale))
    }

    var body: some View {
        panelContent
        .onAppear {
            if browseOnly {
                searchFocused = false
#if DEBUG
                // Route screenshots do not need the simulator's first-use keyboard tutorial.
                if ProcessInfo.processInfo.arguments.contains("--preview-route-search") { searchFocused = false }
#endif
            }
        }
        .onChange(of: model.mode) { _, mode in
            searchFocused = false; model.query = ""
            if mode == .stops { model.beginStationBrowsing() }
            else { model.stationBrowsing = false; model.sheetDetent = .large }
        }
        .onChange(of: searchFocused) { _, focused in if focused { model.sheetDetent = .large } }
        .onChange(of: model.selectedStationID) { _, _ in searchFocused = false }
        .onChange(of: model.selectedRouteID) { _, _ in searchFocused = false }
        .onChange(of: model.selectedVehicleID) { _, _ in searchFocused = false }
        .task(id: stationRequestKey) { await refreshStationResults() }
    }

    @MainActor private func refreshStationResults() async {
        guard model.mode == .stops else { return }
        let query = model.query
        let results = await model.findStations(query: query)
        guard !Task.isCancelled else { return }
        stationResults = results; stationResultQuery = query
        model.stationMapResults = results
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
                    .liveFont(.title2, weight: .bold)
                Spacer()
                if model.mode == .stops {
                    Button { searchFocused = false; model.browseNearMe() } label: { Image(systemName: "location.fill") }
                        .accessibilityLabel("回到我附近").accessibilityIdentifier("browse-near-me")
                        .liveFont(.subheadline, weight: .semibold).frame(minHeight: 44)
                    Button {
                        searchFocused = false; model.sheetDetent = .height(390)
                        if !model.query.isEmpty { model.focusMap(.journey(stationResults.map(\.coordinate))) }
                    } label: { Image(systemName: "map") }.frame(width: 44, height: 44)
                        .accessibilityLabel("在地圖查看站牌").accessibilityIdentifier("station-results-map")
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }.frame(width: 36, height: 44)
                    .accessibilityLabel("返回地圖")
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                if model.mode == .routes && !systemRouteKeyboard {
                    Button { systemRouteKeyboard = true; searchFocused = true } label: {
                        Text(model.query.isEmpty ? "搜尋路線／起訖站" : model.query)
                            .foregroundStyle(model.query.isEmpty ? Color.secondary : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("route-query").buttonStyle(.plain)
                } else {
                TextField(model.mode == .routes ? "搜尋路線／起訖站" : "搜尋站牌", text: $model.query)
                    .focused($searchFocused).submitLabel(.search).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("transit-search-field")
                    .onAppear { if systemRouteKeyboard { searchFocused = true } }
                }
                if model.mode == .routes, systemRouteKeyboard {
                    Button { searchFocused = false; systemRouteKeyboard = false } label: { Image(systemName: "number") }
                        .frame(width: 40, height: 44).accessibilityLabel("路線專用鍵盤")
                }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .frame(width: 36, height: 40).accessibilityLabel(live.text("清除搜尋"))
                }
            }
            .padding(.horizontal, 12 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 48)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13 * CGFloat(live.appearance.cornerScale)))
            Picker("查詢類型", selection: $model.mode) {
                ForEach(BrowseMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if let message = location.message { Text(message).liveFont(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 18 * CGFloat(live.appearance.spacingScale)).padding(.bottom, 12 * CGFloat(live.appearance.spacingScale))
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { model.returnToBrowse() } label: { Image(systemName: "chevron.left").liveFont(.body, weight: .semibold).frame(width: 44, height: 44) }
                .accessibilityLabel(live.text("返回搜尋"))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedStation?.name ?? model.selectedVehicle?.routeName ?? model.selectedRouteName ?? "公車動態")
                    .liveFont(.title2, weight: .bold).lineLimit(2)
                if let station = model.selectedStation { Text(station.bearingLabel).liveFont(.caption).foregroundStyle(.secondary) }
                else if let vehicle = model.selectedVehicle { Text(vehicle.plate).liveFont(.subheadline).foregroundStyle(.secondary).monospaced() }
                else { Text(live.text("路線動態")).liveFont(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            if let station = model.selectedStation {
                Button { model.toggleFavorite(station) } label: {
                    Image(systemName: model.favorites.contains(station.id) ? "star.fill" : "star")
                        .liveFont(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel(model.favorites.contains(station.id) ? "移除收藏站牌" : "收藏站牌")
            }
        }.padding(.leading, 6 * CGFloat(live.appearance.spacingScale)).padding(.trailing, 12 * CGFloat(live.appearance.spacingScale)).padding(.bottom, 12 * CGFloat(live.appearance.spacingScale))
    }

    @ViewBuilder private var browseResults: some View {
        if model.mode == .stops {
            let stations = stationResultQuery == model.query ? stationResults : []
            if stations.isEmpty { emptyResult }
            ForEach(stations) { station in
                if model.query.isEmpty, let first = stations.first(where: { !model.recentStationIDs.contains($0.id) && !model.favorites.contains($0.id) }), first.id == station.id {
                    Text("地圖附近").liveFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.top, 12)
                } else if model.query.isEmpty, stations.first?.id == station.id {
                    Text("收藏與最近查看").liveFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.top, 12)
                }
                Button { model.selectStation(station) } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: model.favorites.contains(station.id) ? "star.fill" : model.recentStationIDs.contains(station.id) ? "clock" : "mappin.circle.fill")
                            .foregroundStyle(model.favorites.contains(station.id) ? Color.orange : Color(liveHex: live.appearance.accentColor))
                            .liveFont(.title2).frame(width: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(station.name).liveFont(.body, weight: .semibold); Text(station.bearingLabel).liveFont(.caption).foregroundStyle(.secondary) }
                            Text(station.address.isEmpty ? "站牌 \(station.id)" : station.address).liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if let position = location.usableCoordinate, position.isInServiceArea {
                            Text(distanceLabel(position.distance(to: station.coordinate))).liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Image(systemName: "chevron.right").liveFont(.caption, weight: .semibold).foregroundStyle(.tertiary)
                    }.padding(.vertical, 15 * CGFloat(live.appearance.spacingScale)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("station-result-" + station.id)
                Divider()
            }
        } else if model.mode == .routes {
            let routes = model.browsingRoutes
            if routes.isEmpty { emptyResult }
            ForEach(routes) { result in
                if model.query.isEmpty, routes.first?.id == result.id {
                    Text(model.recentRouteIDs.isEmpty ? "公車路線" : "最近查看").liveFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.top, 8)
                } else if model.query.isEmpty, let first = routes.first(where: { !model.recentRouteIDs.contains($0.id) }), first.id == result.id {
                    Text("其他路線").liveFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.top, 12)
                }
                let route = result.route
                Button { model.selectRoute(route, variantOnly: result.matchedVariant != nil) } label: {
                    HStack(spacing: 12) {
                        RouteBadge(name: route.name)
                        VStack(alignment: .leading, spacing: 4) {
                            if result.matchedVariant != nil {
                                Text(result.name).liveFont(.subheadline, weight: .semibold).lineLimit(2)
                            }
                            Text("\(route.departure) → \(route.destination)").liveFont(.subheadline).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical, 12 * CGFloat(live.appearance.spacingScale)).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("route-result-" + route.id)
                Divider()
            }
        }
    }

    private var emptyResult: some View {
        Text(live.text(model.mode == .stops && model.query.isEmpty ? "這附近沒有站牌，試著移動地圖" : "找不到符合的資料，試試其他名稱"))
            .liveFont(.subheadline).foregroundStyle(.secondary).padding(.vertical, 24 * CGFloat(live.appearance.spacingScale))
    }
}

private struct RouteSearchKeypad: View {
    @Binding var query: String
    let useKeyboard: () -> Void
    private let keys = [["紅", "藍", "1", "2", "3"], ["棕", "綠", "4", "5", "6"],
                        ["橘", "小", "7", "8", "9"], ["通勤", "幹線", "F", "0", "⌫"]]
    private func color(_ key: String) -> Color {
        switch key { case "紅": return .red; case "藍": return .blue; case "棕": return .brown
        case "綠": return .green; case "橘": return .orange; default: return .primary }
    }
    private func enter(_ key: String) {
        if key == "⌫" { if !query.isEmpty { query.removeLast() } }
        else if ["紅", "藍", "棕", "綠", "橘", "小"].contains(key) {
            query = key + query.filter(\.isNumber)
        } else if key.count > 1 { query = key }
        else { query += key }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(["A", "L", "E", "黃", "快", "內科", "市民", "南軟", "貓空", "懷恩", "區", "副"], id: \.self) { key in
                            Button(key) { enter(key) }.frame(minWidth: 28, minHeight: 40)
                        }
                    }
                }
                Button(action: useKeyboard) { Image(systemName: "keyboard").frame(width: 44, height: 40) }
                    .accessibilityLabel("一般文字鍵盤").accessibilityIdentifier("route-text-keyboard")
            }.liveFont(.subheadline, weight: .medium)
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 7) {
                    ForEach(row, id: \.self) { key in
                        Button { enter(key) } label: {
                            Group {
                                if key == "⌫" { Image(systemName: "delete.left") }
                                else { Text(key) }
                            }.liveFont(.title3, weight: .medium).frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(color(key)).background(color(key).opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }.buttonStyle(PhonePressStyle()).accessibilityIdentifier("route-key-" + key)
                            .accessibilityLabel(key == "⌫" ? "刪除一字" : key)
                    }
                }
            }
        }.padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8).background(.regularMaterial)
    }
}

private struct StationDetails: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let station: Station

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let rows = StationArrival.rows(station: station, metadata: model.metadata, snapshot: model.snapshot, now: timeline.date)
            VStack(alignment: .leading, spacing: 0) {
                Text(station.address).liveFont(.caption).foregroundStyle(.secondary).padding(.bottom, 12 * CGFloat(live.appearance.spacingScale))
                ForEach(model.oppositeStations(to: station)) { opposite in
                    Button { model.selectStation(opposite) } label: {
                        Label("改看\(opposite.bearingLabel)站牌", systemImage: "arrow.left.arrow.right")
                            .liveFont(.subheadline).frame(minHeight: 44)
                    }
                }
                Button {
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: station.coordinate.locationCoordinate))
                    item.name = station.name
                    item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                } label: { Label(live.text("步行到這個站牌"), systemImage: "figure.walk").liveFont(.subheadline, weight: .medium).frame(minHeight: 44) }
                    .padding(.bottom, 12 * CGFloat(live.appearance.spacingScale))
                HStack {
                    Text(live.text("官方到站預估")).liveFont(.subheadline, weight: .semibold)
                    Spacer()
                    if let time = model.snapshot.estimates.updatedAt {
                        Text(time.formatted(SourceStatusView.clockStyle)).liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }.padding(.bottom, 8 * CGFloat(live.appearance.spacingScale))
                if rows.isEmpty { Text(live.text("此站暫無路線資訊")).foregroundStyle(.secondary).padding(.vertical) }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            if let route = row.route { model.selectRoute(route, direction: row.stop.direction) }
                        } label: {
                            HStack(spacing: 12) {
                                RouteBadge(name: row.route?.name ?? row.stop.routeID)
                                Text("往 \(row.route?.destination(direction: row.stop.direction) ?? "方向未提供")")
                                    .liveFont(.subheadline).lineLimit(2)
                                Spacer(minLength: 4)
                                Text(EstimateFeed.label(row.estimateSeconds))
                                    .liveFont(.body, weight: .semibold).monospacedDigit()
                                    .foregroundStyle((row.estimateSeconds ?? -1) >= 0 ? Color(liveHex: live.appearance.accentColor) : Color.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).frame(minHeight: 44)
                        if !row.approaches.isEmpty {
                            Text(live.text("同方向車輛")).liveFont(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(row.approaches) { approach in
                                    Button { model.selectVehicle(approach.vehicle) } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(approach.vehicle.plate).liveFont(.caption, weight: .semibold).monospaced()
                                            Text(approach.alongDistance.map { $0 <= 25 ? "站牌附近" : "沿線 \(distanceLabel($0))" }
                                                 ?? "GPS 直線 \(distanceLabel(approach.directDistance))").liveFont(.caption2).foregroundStyle(.secondary)
                                        }.padding(.horizontal, 12 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 6 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 48)
                                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }.padding(.vertical, 12 * CGFloat(live.appearance.spacingScale))
                    Divider()
                }
                Text(live.text("軌跡可確認時排除已通過車輛；沿線距離依 GPS 推估。官方時間未綁定車牌。")).liveFont(.caption).foregroundStyle(.secondary).padding(.top, 14 * CGFloat(live.appearance.spacingScale))
            }
        }
    }
}

private struct RouteDetails: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let route: BusRoute

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.routeVariants.count > 1 {
                Menu {
                    Button { model.changeRouteVariant(nil) } label: {
                        Label(live.text("全部走法"), systemImage: model.allRouteVariants ? "checkmark" : "point.topleft.down.to.point.bottomright.curvepath")
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
                            .liveFont(.subheadline, weight: .semibold).lineLimit(2)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down").liveFont(.caption, weight: .semibold)
                    }.padding(.horizontal, 14 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 48)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13 * CGFloat(live.appearance.cornerScale)))
                }.accessibilityLabel(live.text("選擇路線走法"))
            }
            if model.routeDirections.count > 1 {
                Picker("行駛方向", selection: $model.direction) {
                    ForEach(model.routeDirections, id: \.self) { direction in
                        Text("往 \(route.destination(direction: direction))").tag(direction)
                    }
                }.pickerStyle(.segmented)
            } else {
                Text("往 \(route.destination(direction: model.direction))").liveFont(.subheadline).foregroundStyle(.secondary)
            }
            let buses = model.routeVehicles()
            let count = buses.filter { $0.hasReliablePosition(at: Date()) }.count
            Text("\(count) 輛可定位" + (count < buses.count ? " · \(buses.count - count) 輛等待定位" : ""))
                .liveFont(.subheadline).foregroundStyle(.secondary)
            ForEach(buses) { bus in
                VehicleRow(vehicle: bus) { model.selectVehicle(bus) }
                Divider()
            }
            if buses.isEmpty { Text(live.text("目前沒有此方向的車輛回報")).liveFont(.subheadline).foregroundStyle(.secondary) }
            Text(model.allRouteVariants && model.routeVariants.count > 1 ? "主要站序" : "沿線站牌")
                .liveFont(.headline).padding(.top, 8 * CGFloat(live.appearance.spacingScale))
            if model.allRouteVariants && model.routeVariants.count > 1 {
                Text(live.text("切換上方走法，可看各支線停靠站。")).liveFont(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                ForEach(model.routeStops) { stop in
                    Button {
                        if let station = model.metadata.stations[stop.stationID] { model.selectStation(station) }
                    } label: {
                        HStack(spacing: 10) {
                            Text("\(stop.sequence)").liveFont(.caption).foregroundStyle(.secondary).frame(width: 26)
                            Text(stop.name).liveFont(.subheadline)
                            Spacer(minLength: 8)
                            Text(EstimateFeed.label(model.snapshot.estimates.value(routeID: route.parentID, stopID: stop.id, at: timeline.date)))
                                .liveFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                        }.frame(minHeight: 50).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

private struct VehicleDetails: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let vehicle: BusVehicle

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("往 \(vehicle.destination)").liveFont(.headline)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let fresh = vehicle.hasReliablePosition(at: timeline.date)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fresh && vehicle.hasSpeed ? "\(Int(vehicle.speed))" : "—").liveFont(.largeTitle, weight: .semibold, design: .rounded).monospacedDigit()
                        Text(live.text("GPS 回報 km/h")).liveFont(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(fresh ? vehicle.statusLabel : vehicle.trackingLabel(at: timeline.date) ?? "定位已延遲").liveFont(.subheadline, weight: .semibold).foregroundStyle(fresh ? Color.primary : Color.orange)
                        Text("\(max(0, Int(timeline.date.timeIntervalSince(vehicle.observedAt)))) 秒前回報").liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if vehicle.lowFloor { Label(live.text("低底盤"), systemImage: "figure.roll").liveFont(.caption) }
                    }
                }
            }
            if let provider = vehicle.provider { Text(provider).liveFont(.subheadline).foregroundStyle(.secondary) }
            Toggle("淡化建築、凸顯這輛車", isOn: $model.highlightVehicle).liveFont(.subheadline)
            HStack(spacing: 10) {
                Button {
                    model.following = true; model.focusMap(.vehicle(vehicle.id))
                } label: { Label(live.text("跟隨公車"), systemImage: "scope").frame(maxWidth: .infinity, minHeight: 36) }
                    .buttonStyle(.borderedProminent)
                Button {
                    if let route = model.metadata.route(vehicle.routeID) { model.selectRoute(route, direction: vehicle.direction, variantOnly: true) }
                } label: { Text(live.text("查看路線")).frame(maxWidth: .infinity, minHeight: 36) }.buttonStyle(.bordered)
            }
            if !vehicle.aligned { Text(live.text("目前顯示原始 GPS，尚未匹配道路軌跡")).liveFont(.caption).foregroundStyle(.secondary) }
            let upcoming = model.upcomingStops
            if !upcoming.isEmpty {
                Divider()
                Text(live.text("前方站牌")).liveFont(.subheadline, weight: .semibold)
                ForEach(Array(upcoming.prefix(3)), id: \.stop.id) { progress in
                    Button {
                        if let station = model.metadata.stations[progress.stop.stationID] { model.selectStation(station) }
                    } label: {
                        HStack {
                            Text(progress.stop.name).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(progress.distance <= 25 ? "站牌附近" : "沿線 \(distanceLabel(progress.distance))").foregroundStyle(.secondary).monospacedDigit()
                        }.liveFont(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Text(live.text("依目前 GPS 與路線順序推估，不是車輛到站時間。")).liveFont(.caption).foregroundStyle(.secondary)
            }
            let stops = model.metadata.orderedStops(routeID: vehicle.routeID, direction: vehicle.direction)
                .sorted { $0.coordinate.distance(to: vehicle.rawCoordinate) < $1.coordinate.distance(to: vehicle.rawCoordinate) }
            if upcoming.isEmpty, let stop = stops.first {
                Divider()
                Text("最後 GPS 附近 · \(stop.name)").liveFont(.subheadline, weight: .semibold)
                Text("GPS 直線距離 \(distanceLabel(vehicle.rawCoordinate.distance(to: stop.coordinate)))")
                    .liveFont(.caption).foregroundStyle(.secondary)
                Button {
                    if let station = model.metadata.stations[stop.stationID] { model.selectStation(station) }
                } label: { Label(live.text("查看此站到站預估"), systemImage: "mappin.and.ellipse").frame(minHeight: 44) }
            }
        }
    }
}

struct VehicleRow: View {
    @Environment(\.liveSettings) private var live
    let vehicle: BusVehicle
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "bus.fill").foregroundStyle(.secondary).liveFont(.title3).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(vehicle.plate).liveFont(.body, weight: .semibold).monospaced()
                    Text("\(vehicle.routeName) · 往 \(vehicle.destination)").liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    let reliable = vehicle.hasReliablePosition(at: timeline.date)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(reliable ? vehicle.speedLabel : vehicle.trackingIssue == .missing ? "訊號暫缺" : vehicle.trackingIssue == .rejected ? "確認中" : "延遲")
                            .foregroundStyle(reliable ? Color.secondary : Color.orange)
                        Text("\(max(0, Int(timeline.date.timeIntervalSince(vehicle.observedAt)))) 秒前").foregroundStyle(.secondary)
                    }.liveFont(.caption).monospacedDigit()
                }
                Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 14 * CGFloat(live.appearance.spacingScale)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct RouteBadge: View {
    @Environment(\.liveSettings) private var live
    let name: String
    var body: some View {
        Text(name).liveFont(.subheadline, weight: .bold).lineLimit(2)
            .padding(.horizontal, 10 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 8 * CGFloat(live.appearance.spacingScale)).frame(minWidth: 56)
            .foregroundStyle(Color(liveHex: live.appearance.accentColor))
            .background(Color(liveHex: live.appearance.accentColor).opacity(0.09), in: RoundedRectangle(cornerRadius: 11 * CGFloat(live.appearance.cornerScale)))
    }
}

private struct AppInformationView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("即時資料") {
                    Text("\(model.metadata.routeCatalog.groups.count) 條路線 · \(model.metadata.routes.count) 個走法")
                    Text(live.text("臺北市公共運輸處公開資料，每 15 秒重新取得。個別公車回報時間以車輛卡片為準。"))
                    if let error = model.snapshot.vehicleError { Label(error, systemImage: "wifi.exclamationmark") }
                    if let error = model.snapshot.estimates.error { Text(error) }
                    if let notice = model.metadataNotice { Text(notice) }
                    Text(live.text("官方到站預估沒有車牌資訊；請以站牌的路線預估為準。"))
                    Text(live.text("回到 App 時立即更新；背景暫停畫面與輪詢。官方車輛資料會持續產生。"))
                    Link("公開資料說明", destination: URL(string: "https://pto.gov.taipei/News_Content.aspx?n=A1DF07A86105B6BB&s=55E8ADD164E4F579&sms=2479B630A6BD8079")!)
                }
                Section("地圖") {
                    Toggle("選車時淡化建築", isOn: $model.highlightVehicle)
                    Text(live.text("原生 MapLibre / Metal 地圖，使用 OpenFreeMap 底圖。道路匹配受 GPS 與軌跡精度影響。"))
                    Link("OpenFreeMap", destination: URL(string: "https://openfreemap.org")!)
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    NavigationLink("開源授權") { LicenseView() }
                }
                Section("定位") {
                    Text(live.text("定位只在使用期間尋找附近站牌，可直接手動搜尋；位置不會傳到公車資料來源。"))
                    Button(live.text("開啟系統設定")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("隱私") {
                    NavigationLink("隱私權說明") { PrivacyExplanationView() }
                }
            }
            .navigationTitle("資訊與設定").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(live.text("完成")) { dismiss() } } }
        }
    }
}

private struct PrivacyExplanationView: View {
    @Environment(\.liveSettings) private var live
    var body: some View {
        List {
            Section("你的位置") {
                Text("定位為選用，只在使用 App 時尋找附近站牌、規劃行程與定位地圖。也能拒絕定位，手動選擇出發地、站牌或路線。App 不會將定位座標加入公車資料查詢。")
                Text("地點搜尋與步行路線由 Apple 地圖提供；搜尋文字及路線起終點由 Apple 處理。")
                Text("地圖供應者會收到目前畫面需要的圖磚請求及網路連線資訊，因此可能得知你正在查看的大致區域。")
            }
            Section("內容更新") {
                Text("搜尋別名、文字、外觀及既有搭車設定會從 GitHub 下載。這個請求不包含定位或搜尋文字；GitHub 會收到一般網路連線資訊。")
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
    @Environment(\.liveSettings) private var live
    private var licenses: String {
        guard let url = Bundle.main.url(forResource: "Licenses", withExtension: "txt") else { return "授權文件未載入" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "授權文件未載入"
    }
    var body: some View {
        ScrollView { Text(licenses).liveFont(.caption).textSelection(.enabled).padding() }
            .navigationTitle("開源授權").navigationBarTitleDisplayMode(.inline)
    }
}

func distanceLabel(_ meters: Double) -> String {
    meters >= 1_000 ? String(format: "%.1f km", meters / 1_000) : "\(Int(meters.rounded())) m"
}
