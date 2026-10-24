import SwiftUI
import MapKit
import TransitCore

struct TransitHomeView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject private var location: LocationService
    @ObservedObject private var planner: JourneyPlannerModel
    @ObservedObject private var purchases: ProPurchases
    @ObservedObject private var commutes: CommuteLibrary
    @ObservedObject private var stationWalk: StationWalkingNavigation
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }
    private var journeyPreviewDetent: PresentationDetent {
        if dynamicTypeSize.isAccessibilitySize || live.appearance.textScale > 1.25 { return .fraction(0.82) }
        return .height(viewportHeight > 0 && viewportHeight < 760 ? 420 : 510)
    }
    @State private var viewportHeight: CGFloat = 0
    @State private var showSearch = false
    @State private var showDetails = false
    @State private var showInformation = false
    @State private var showJourney = false
    @State private var showJourneyItinerary = false
    @State private var journeyDetent: PresentationDetent = .large
    @State private var journeyPanelHeight: CGFloat = 510
    @State private var pendingJourneyDetail = false
    @State private var stationWalkReturnDetails = false
    @State private var stationWalkReturnSearch = false
    @State private var bottomControlsHeight: CGFloat = 210
    @State private var bannerHeight: CGFloat = 0
    @State private var lastLocationFocus: Coordinate?
    @State private var lastJourneyOptionID: String?
    @State private var lastJourneyStep: JourneyStep?
    // Retain the reference here; only the label/probe children observe frame updates.
    @State private var selectionOverlay = MapSelectionOverlay()

    init(model: TransitAppModel) {
        self.model = model
        location = model.location
        planner = model.planner
        purchases = model.purchases; commutes = model.commutes
        stationWalk = model.stationWalk
    }

    private var hasTransitSelection: Bool { model.selectedStationID != nil || model.selectedRouteID != nil || model.selectedVehicleID != nil }
    /// The metro is part of what is on screen: a trip that rides it, a metro station or a metro line.
    private var metroInView: Bool {
        planner.selected?.rides.contains { $0.route.mode != .bus } == true || model.selectedStation?.mode == .metro ||
            model.selectedRoute.map { $0.mode != .bus } == true
    }
    private var hasSelection: Bool { hasTransitSelection || planner.selected != nil || stationWalk.isActive }
    private var routeMapPreview: Bool { showJourney && !planner.started && planner.selected != nil }
    /// The navigation instruction sits above the map whenever a trip is on the map itself.
    private var showsBanner: Bool {
        (planner.started || stationWalk.isActive) && !showDetails && !showSearch && !showJourney && !pendingJourneyDetail
    }
    private var bannerOffset: CGFloat { showsBanner ? bannerHeight + 10 : 0 }
    private var nearbyStations: [Station] {
        guard live.display.nearbyStops, !model.cityFleetMode, !hasSelection, let position = location.usableCoordinate, position.isInServiceArea else { return [] }
        return model.metadata.stations.values.filter { $0.coordinate.distance(to: position) <= 800 }
            .sorted { $0.coordinate.distance(to: position) < $1.coordinate.distance(to: position) }.prefix(2).map { $0 }
    }

    private func mapBottomInset(_ geometry: GeometryProxy) -> CGFloat {
        let panel: CGFloat
        if showJourney {
            // A page update can briefly report the hosting content's ideal height.
            // Fixed detents already tell us which part of the map the sheet covers.
            if journeyDetent == .height(420) { panel = 420 }
            else if journeyDetent == .height(510) { panel = 510 }
            else if journeyDetent == .height(560) { panel = 560 }
            else { panel = min(journeyPanelHeight, geometry.size.height) }
        }
        else if showDetails || pendingJourneyDetail || (showSearch && hasTransitSelection) { panel = model.sheetDetent == .height(520) ? 520 : 330 }
        else if showSearch { panel = 390 }
        else { panel = bottomControlsHeight }
        return panel + geometry.safeAreaInsets.bottom + 24
    }

    private var mapContent: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                NativeBusMap(model: model, planner: planner, stationWalk: stationWalk, location: location.displayCoordinate,
                             bottomInset: mapBottomInset(geometry),
                             topInset: geometry.safeAreaInsets.top + 64 + bannerOffset,
                             reduceMotion: reduceMotion, selectionOverlay: selectionOverlay)
                    .ignoresSafeArea()
                    .accessibilityLabel(live.text("台北公車地圖"))
#if DEBUG
                    .accessibilityIdentifier("native-map").accessibilityValue(selectionOverlay.cameraState)
#endif
                if !showDetails && !showSearch && !showJourney && !pendingJourneyDetail && !stationWalk.isActive {
                    MapContextLabels(model: model, overlay: selectionOverlay, bottomClearance: bottomControlsHeight, topClearance: bannerOffset) { showDetails = true }
                }
                topChrome
                if routeMapPreview, geometry.size.height - journeyPanelHeight > 220 {
                    VStack {
                        Spacer()
                        HStack { Spacer(); MapLocationControl(model:model,location:location) }
                    }.padding(.trailing,16).padding(.bottom,mapBottomInset(geometry) + 10)
                }
#if DEBUG
                Text(model.rideActivityDebug).font(.system(size: 1)).foregroundStyle(.clear)
                    .frame(width: 1, height: 1).accessibilityIdentifier("debug-live-activity").allowsHitTesting(false)
                if ProcessInfo.processInfo.arguments.contains("--test-navigation-readiness") {
                    let state: [String: Any] = ["started": planner.started, "step": planner.stepIndex,
                        "background": location.backgroundNavigation, "pro": purchases.hasPro,
                        "notifications": model.navigationReadiness.notifications.rawValue,
                        "reminderReady": model.alightReminderActive, "liveActivity": model.liveActivityRunning]
                    let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                    Text(data.map { String(decoding: $0, as: UTF8.self) } ?? "")
                        .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                        .accessibilityIdentifier("navigation-readiness-state").allowsHitTesting(false)
                }
                if ProcessInfo.processInfo.arguments.contains("--test-journey-selection") {
                    Text(planner.selectedID ?? "").font(.system(size: 1)).foregroundStyle(.clear)
                        .frame(width: 1, height: 1).accessibilityIdentifier("journey-selected-state").allowsHitTesting(false)
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let records: [[String: Any]] = planner.options.map { option in
                            let timing = model.journeyDuration(option, at: timeline.date)
                            return ["id": option.id, "verified": option.verified, "can_start": planner.canUse(option), "label": planner.optionLabels[option.id] ?? "",
                                "transfers": max(0, option.rides.count - 1),
                                "bike_legs": option.walks.indices.filter { option.walks[$0].bike != nil },
                                "bike_ride_minutes": option.walks.compactMap { $0.bike?.ridingMinutes },
                                "modes": option.rides.map { $0.route.mode == .bus ? "bus" : "metro" },
                                "boarding_name": option.rides.first?.boarding.name ?? "", "ride_stop_count": option.rides.first?.stopCount ?? 0,
                                "total": timing?.totalSeconds ?? -1, "travel": timing?.travelSeconds ?? -1,
                                "walking": timing?.walkingSeconds ?? -1, "waiting": timing?.waitingSeconds ?? -1,
                                "riding": timing?.ridingSeconds ?? -1, "unknown": timing?.unknownWaits ?? -1,
                                "duration_label": timing?.label ?? "", "waiting_label": timing?.waitingLabel ?? "",
                                "arrival_label": timing?.arrivalLabel ?? ""]
                        }
                        let value: [String: Any] = ["itinerary": showJourneyItinerary, "route_panel_open": showJourney, "planning": planner.planning, "checking": planner.checkingWalks, "message": planner.message ?? "", "empty_message": planner.emptyOptionsMessage ?? "", "origin_ready": planner.origin != nil, "metadata_routes": model.metadata.routes.count, "selected": planner.selectedID ?? "", "started": planner.started, "step": planner.stepIndex, "suggestion": model.journeySuggestion?.id ?? "", "comparison_changed": planner.comparisonChanged, "options": records]
                        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                        Text(data.map { String(decoding: $0, as: UTF8.self) } ?? "")
                            .font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                            .accessibilityIdentifier("journey-timing-state").allowsHitTesting(false)
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--test-map-controls") {
                    DebugMapCameraText(overlay: selectionOverlay)
                }
                if ProcessInfo.processInfo.arguments.contains("--test-zoom-performance") {
                    DebugZoomPerformanceControls().padding(.top, 146)
                }
                if let notice = model.previewNotice {
                    Text(live.text(notice)).liveFont(.caption, weight: .semibold).padding(8)
                        .dynamicTypeSize(...DynamicTypeSize.large)
                        .background(Color.orange.opacity(0.9), in: Capsule()).padding(.top, 80 * CGFloat(live.appearance.spacingScale))
                }
#endif

                selectionCapsules
                if !showDetails && !showSearch && !showJourney && !pendingJourneyDetail {
                    bottomChrome
                }
                if model.metadata.routes.isEmpty, model.loadError != nil {
                    // Without any route data the app cannot plan; say it plainly instead of "updating".
                    Text(live.text("路線資料暫時無法取得，請稍後再試")).liveFont(.caption).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14 * CGFloat(live.appearance.cornerScale)))
                        .padding(.top, 96 * CGFloat(live.appearance.spacingScale)).padding(.horizontal, 16 * CGFloat(live.appearance.spacingScale))
                }
            }.onChange(of: geometry.size.height, initial: true) { _, height in
                if abs(viewportHeight - height) > 1 { viewportHeight = height }
            }
        }
    }

    @ViewBuilder private var topChrome: some View {
        VStack(spacing: 10) {
        if showsBanner {
            Group {
                if stationWalk.isActive { StationWalkBanner(navigation: stationWalk) }
                else { JourneyInstructionBanner(model: model, planner: planner) }
            }
                .background { GeometryReader { banner in Color.clear.preference(key: InstructionBannerHeightKey.self, value: banner.size.height) } }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                SourceStatusView(snapshot: model.snapshot, arrivalFeed: model.busArrivals, positionsNeeded: model.visibleBusDataNeeds.positions,
                                 arrivalsNeeded: model.visibleBusDataNeeds.arrivals) {
                    if model.loadError != nil { model.retry() }
                    else { Task { await model.refresh() } }
                }
                // Live train positions are Pro; where the metro matters, a free user can take a look.
                if !model.hasProAccess, metroInView, !stationWalk.isActive {
                    LiveTrainsChip(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
                }
                if model.cityFleetMode, planner.selected == nil, !stationWalk.isActive {
                    Label(AppText.text("全城 %@", model.cityVehicles.count), systemImage: "globe.asia.australia.fill")
                        .liveFont(.subheadline, weight: .semibold).monospacedDigit()
                        .padding(.horizontal, 14 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 40)
                        .phoneGlass(in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topLeading)))
                }
            }
            Spacer(minLength: 0)
            MapControlStack(model: model, location: location, showsCityFleet: planner.selected == nil && !stationWalk.isActive,
                            showsLocation: !routeMapPreview) {
                showInformation = true
            }
        }
        }
        .overlay(alignment: .bottom) {
            ProNoteBanner(model: model).padding(.top, 8).offset(y: 64).padding(.horizontal, 2)
        }
        .padding(.horizontal, 16 * CGFloat(live.appearance.spacingScale)).padding(.top, 8 * CGFloat(live.appearance.spacingScale))
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86), value: model.cityFleetMode)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.proNote)
        .animation(reduceMotion ? nil : .spring(response: 0.44, dampingFraction: 0.88), value: showsBanner)
    }

    @ViewBuilder private var selectionCapsules: some View {
        if !stationWalk.isActive, !showDetails, !showSearch, !planner.started, planner.selected == nil, model.selectedVehicleID == nil, model.selectedStationID == nil, let route = model.selectedRoute {
            HStack(spacing: 10) {
                RouteBadge(name: model.selectedRouteName ?? route.localizedName, tintName: route.name, compact: true)
                Text(AppText.text("往 %@", route.localizedDestination(direction: model.direction))).liveFont(.subheadline, weight: .medium).lineLimit(1)
                Spacer(minLength: 0)
                if model.routeDirections.count > 1 {
                    Button { model.switchDirection() } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 44, height: 44) }
                        .accessibilityLabel(AppText.text("切換路線方向"))
                }
                Button { showDetails = true } label: {
                    Label(route.mode == .bus ? String(model.routeVehicles().filter { $0.hasReliablePosition(at: Date()) }.count) : AppText.text("列車"), systemImage: route.mode == .bus ? "bus.fill" : "tram.fill")
                        .liveFont(.subheadline, weight: .medium).monospacedDigit().frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(AppText.text("查看此路線公車")).accessibilityIdentifier("route-map-vehicles")
            }.padding(.leading, 10).padding(.trailing, 8).phoneGlass(in: Capsule())
                .padding(.leading, 16 * CGFloat(live.appearance.spacingScale)).padding(.trailing, 76)
                .padding(.top, 60 * CGFloat(live.appearance.spacingScale))
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if model.selectedVehicleID != nil, model.selectedVehicle == nil {
            Button { showDetails = true } label: {
                Label(live.text("此車目前沒有定位 · 查看路線車輛"), systemImage: "location.slash")
                    .liveFont(.subheadline).padding(.horizontal, 14 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 12 * CGFloat(live.appearance.spacingScale))
            }
            .phoneGlass(in: Capsule()).padding(.leading, 16).padding(.trailing, 76).padding(.top, 60 * CGFloat(live.appearance.spacingScale) + bannerOffset)
        }
    }

    private var bottomChrome: some View {
    VStack(spacing: 0) {
        Spacer()
    PhoneGlassGroup {
    VStack(spacing: 10) {
        if let message = location.message, !hasSelection {
            Text(live.text(message)).liveFont(.caption).padding(.horizontal, 14).padding(.vertical, 9)
                .phoneGlass(in: Capsule())
        }
        Group {
        if stationWalk.isActive {
            StationWalkingDock(model: model, navigation: stationWalk)
        } else if planner.started {
            if let suggestion = model.visibleJourneySuggestion {
                JourneyAlternativePrompt(model: model, suggestion: suggestion)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            JourneyGuideCard(model: model, planner: planner) { showJourneyItinerary = true; journeyDetent = .large; showJourney = true }
        }
        }
        .smoothChanges(planner.currentStep)
        .smoothChanges(planner.started)
        .smoothChanges(model.journeySuggestion?.id)
        .smoothChanges(planner.selectedID)
        .smoothChanges(model.language)
        if let bike = model.selectedBikeStation, !hasSelection {
            BikeStationCard(model: model, station: bike,
                            distance: location.usableCoordinate.map { $0.distance(to: bike.coordinate) },
                            close: { model.selectedBikeStationID = nil }, returning: model.selectedBikeStationReturning)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if let place = model.tappedPlace, !hasSelection {
            MapPlaceCard(place: place, distance: location.usableCoordinate.map { $0.distance(to: place.coordinate) },
                         route: { routeToPlace(place) }, close: { model.tappedPlace = nil })
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if !nearbyStations.isEmpty, let position = location.usableCoordinate {
            HStack(spacing: 10) {
                ForEach(nearbyStations) { station in
                    Button { model.selectStation(station) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: station.mode == .bus ? "bus.fill" : "tram.fill").liveFont(.caption, weight: .semibold)
                                .foregroundStyle(RouteTint.color(for: ""))
                                .frame(width: 28, height: 28)
                                .background(Circle().strokeBorder(RouteTint.color(for: ""), lineWidth: 1.6))
                            VStack(alignment: .leading, spacing: 2) {
                                BilingualName(station).liveFont(.subheadline, weight: .semibold).lineLimit(1)
                                Text(AppText.text("%@ · 直線 %@", station.localizedBearing, distanceLabel(position.distance(to: station.coordinate))))
                                    .liveFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 8 * CGFloat(live.appearance.spacingScale))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(PhonePressStyle()).foregroundStyle(.primary).phoneGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .accessibilityIdentifier("nearby-station-" + station.id)
                    .accessibilityLabel(AppText.text("附近站牌 %@ %@，直線距離 %@", station.localizedName, station.localizedBearing, distanceLabel(position.distance(to: station.coordinate))))
                }
            }.transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        if planner.selected == nil && !stationWalk.isActive {
            // Saved shortcuts stay usable after Pro ends; only saving new ones and preferences need Pro.
            if !hasSelection, !commutes.journeys.isEmpty {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:8) {
                        ForEach(commutes.journeys) { saved in
                            Button {
                                model.previewSavedJourney(saved); showJourneyItinerary = false
                                journeyDetent = journeyPreviewDetent; showJourney = true
                            } label: {
                                Label(saved.title,systemImage:saved.symbol).liveFont(.subheadline,weight:.semibold)
                                    .padding(.horizontal,14).frame(minHeight:44)
                            }.buttonStyle(MapActionStyle()).accessibilityIdentifier("commute-shortcut-"+saved.id.uuidString)
                        }
                    }
                }.accessibilityIdentifier("commute-shortcuts")
            }
            HomeSearchRow(model: model, hasSelection: hasSelection,
                          search: { showJourneyItinerary = false; journeyDetent = .large; showJourney = true },
                          browse: openBrowse,
                          voice: OnDeviceJourneyAssistant.plannerUnavailableReason() == nil ? { model.assistant.listen() } : nil)
        }
    }
    }
    .background {
        GeometryReader { controls in Color.clear.preference(key: MapBottomControlsHeightKey.self, value: controls.size.height) }
    }
    }
    .padding(.horizontal, 16 * CGFloat(live.appearance.spacingScale)).padding(.bottom, 10 * CGFloat(live.appearance.spacingScale))
    .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: nearbyStations.map(\.id))
    .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: model.tappedPlace)
    .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: model.selectedBikeStationID)
    }

    /// A tapped place becomes the trip destination, like Apple Maps' Directions button.
    private func routeToPlace(_ place: MapPlaceSelection) {
        model.tappedPlace = nil
        planner.setDestination(TravelPlace(name: place.name, address: "", coordinate: place.coordinate, englishName: place.englishName),
                               metadata: model.metadata, currentLocation: location.usableCoordinate)
        showJourneyItinerary = false
        journeyDetent = planner.origin == nil ? .large : journeyPreviewDetent
        showJourney = true
    }


    private var presentedMap: some View {
        mapContent
        .tint(Color(liveHex: live.appearance.accentColor))
        .onPreferenceChange(MapBottomControlsHeightKey.self) { bottomControlsHeight = $0 }
        .onPreferenceChange(InstructionBannerHeightKey.self) { height in if abs(height - bannerHeight) > 0.5 { bannerHeight = height } }
        .onChange(of: purchases.hasPro) { _,_ in model.applyPersonalPreferences() }
        .onChange(of: commutes.preference) { _,_ in model.applyPersonalPreferences() }
        .sheet(isPresented: $showSearch, onDismiss: { model.stationBrowsing = false; restoreJourneyMap() }) {
            TransitPanel(model: model, location: location, showInformation: $showInformation, browseOnly: !hasTransitSelection)
                .sheet(isPresented: $model.showingProPlans) { ProPurchaseView(purchases: model.purchases) }
                .presentationDetents(hasTransitSelection ? [.height(330), .height(520), .large] : model.mode == .stops ? [.height(390), .large] : [.large], selection: $model.sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(390)))
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showDetails, onDismiss: restoreJourneyMap) {
            TransitPanel(model: model, location: location, showInformation: $showInformation)
                .sheet(isPresented: $model.showingProPlans) { ProPurchaseView(purchases: model.purchases) }
                .presentationDetents([.height(330), .height(520), .large], selection: $model.sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(520)))
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
        }
        .sheet(isPresented: $showJourney, onDismiss: {
            if pendingJourneyDetail { pendingJourneyDetail = false; showDetails = true }
        }) {
            JourneyPlanningView(model: model, planner: planner, location: location,
                                showingItinerary: $showJourneyItinerary,
                                compact: journeyDetent == journeyPreviewDetent,
                                expand: { withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)) { journeyDetent = .large } },
                                collapse: { withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)) { journeyDetent = journeyPreviewDetent } })
                .environment(\.dynamicTypeSize, dynamicTypeSize)
                .sheet(isPresented: $model.showingProPlans) { ProPurchaseView(purchases: model.purchases) }
                .presentationDetents(planner.destination == nil || planner.started ? [.large] : [journeyPreviewDetent, .height(560), .large], selection: $journeyDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .height(560)))
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible).presentationCornerRadius(30).presentationBackground(.regularMaterial)
                .interactiveDismissDisabled(!planner.started && planner.destination != nil)
                .background {
                    GeometryReader { panel in Color.clear.preference(key: JourneyPanelHeightKey.self, value: panel.size.height) }
                }
                .onPreferenceChange(JourneyPanelHeightKey.self) { height in
                    if height > 0, abs(height - journeyPanelHeight) > 1 { journeyPanelHeight = height }
                }
        }
        .sheet(isPresented: $showInformation) { AppInformationView(model: model) }
        .onChange(of: model.resumeJourneyRequested) { _, requested in
            guard requested else { return }
            model.resumeJourneyRequested = false
            showInformation = false; showDetails = false; showSearch = false
            showJourney = false; showJourneyItinerary = false; pendingJourneyDetail = false
            restoreJourneyMap()
        }
        .bikeStationDetails(model: model, active: hasSelection && !showJourney && !showDetails && !showSearch && !showInformation)
        .sheet(isPresented: $model.showingProPlans) { ProPurchaseView(purchases: model.purchases) }
        // A sentence said to Siri opens the route panel, which understands and plans it.
        .onReceive(NotificationCenter.default.publisher(for: AssistantLaunch.notification)) { _ in takeAssistantLaunch() }
        // The home mic opens the voice screen over the map; the route panel follows with the result.
        .modifier(HomeVoiceHost(session: model.assistant, enabled: !showJourney && !showDetails && !showSearch && !showInformation) { forSheet in
            showJourneyItinerary = false
            journeyDetent = forSheet || planner.destination == nil ? .large : journeyPreviewDetent
            showJourney = true
        })
        .onAppear { takeAssistantLaunch() }
        .onChange(of: model.showSavedJourneyRequested) { _, requested in
            guard requested else { return }
            model.showSavedJourneyRequested = false
            showInformation = false
            // Present the route panel once the Settings sheet has finished dismissing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                showJourneyItinerary = false; journeyDetent = journeyPreviewDetent; showJourney = true
            }
        }
        .sheet(isPresented: $model.showingArrivingVehicles) {
            if let ride = planner.activeRide { VehicleArrivalsView(model: model, ride: ride) }
        }
    }

    var body: some View {
        presentedMap
        .onChange(of: journeyPreviewDetent) { before, after in
            if journeyDetent == before { journeyDetent = after }
        }
        .onChange(of: location.revision, initial: true) { before, after in
            if before == after {
                model.updateWalkingLocation()
                model.anchorBoardedVehicle()
            }
            if let position = location.usableCoordinate { planner.locationArrived(position, metadata: model.metadata) }
            if model.userMapMode != .free, let position = location.displayCoordinate, lastLocationFocus != position {
                lastLocationFocus = position; model.focusMap(.userLocation)
            }
            if let position = location.displayCoordinate, position.isInServiceArea, !hasSelection,
               model.userMapMode == .free, !model.cityFleetMode, !model.stationBrowsing, !model.mapWasMoved, lastLocationFocus != position {
                lastLocationFocus = position; model.focusMap(.coordinate(position))
            }
        }
        .onChange(of: planner.mapRevision) { _, _ in
            guard !stationWalk.isActive else { return }
            // While the voice screen is up it opens the panel itself, after its check mark.
            if planner.selected != nil, !planner.started, !showJourney, !showDetails, !showSearch, !pendingJourneyDetail,
               !model.assistant.voiceActive {
                showJourneyItinerary = false; journeyDetent = journeyPreviewDetent; showJourney = true
            }
            if planner.selected != nil, model.cityFleetMode { model.leaveCityForJourney() }
            let coordinates = planner.mapCoordinates
            let userChangedJourney = lastJourneyOptionID != planner.selectedID || lastJourneyStep != planner.currentStep
            lastJourneyOptionID = planner.selectedID; lastJourneyStep = planner.currentStep
            if !showDetails && !pendingJourneyDetail && !(showSearch && hasTransitSelection),
               userChangedJourney || model.userMapMode == .free {
                let sameVehicle = model.selectedVehicle.map { bus in
                    planner.activeRide.map { model.metadata.canServe($0, vehicle: bus) } == true
                } == true || model.hasConfirmedOnboardFollow
                let sameTrain = model.metroTrain(model.selectedTrainID).map { report in
                    planner.activeRide.map { model.metadata.metro.canServe($0, patternID: report.patternID, direction: report.direction, destinationStationID: report.destinationStationID) } == true
                } ?? false
                if let index = model.walkingMapIndex, !userChangedJourney,
                   planner.selected?.walks.indices.contains(index) == true {
                    if !model.mapWasMoved { model.showWalkOnMap(index) }
                } else if model.walkingMapIndex != nil, case .ride = planner.currentStep, sameVehicle, let bus = model.selectedVehicle {
                    model.clearWalkingMap(); model.following = model.beginFollowing(bus.id); model.focusMap(.vehicle(bus.id))
                } else if (!planner.started && userChangedJourney) || (!sameVehicle && !sameTrain) {
                    model.clearWalkingMap()
                    model.clearSelection()
                    if !coordinates.isEmpty, userChangedJourney || !model.mapWasMoved { model.focusMap(.journey(coordinates)) }
                }
            }
#if DEBUG
            model.markJourneyPreviewReady()
            if ProcessInfo.processInfo.arguments.contains("--preview-destination"), planner.selected != nil {
                showJourney = !planner.started
                journeyDetent = ProcessInfo.processInfo.arguments.contains("--preview-journey-expanded") || model.language == .english ? .large : .height(560)
            }
#endif
        }
        .onChange(of: model.walkingMapIndex) { _, index in
            model.updateWalkingLocation()
            if index != nil {
                pendingJourneyDetail = false; showDetails = false; showSearch = false
                if planner.started { showJourney = false }
                else { showJourneyItinerary = false; journeyDetent = journeyPreviewDetent; showJourney = true }
            }
        }
        .onChange(of: showDetails) { _, visible in
            if !visible, !pendingJourneyDetail, !showSearch, planner.selected != nil, !planner.started {
                showJourneyItinerary = false; journeyDetent = journeyPreviewDetent; showJourney = true
            }
        }
        .onChange(of: stationWalk.isActive) { _, active in
            if active {
                stationWalkReturnDetails = showDetails; stationWalkReturnSearch = showSearch
                showDetails = false; showSearch = false; showJourney = false
            } else {
                showDetails = stationWalkReturnDetails; showSearch = stationWalkReturnSearch
            }
        }
        .onChange(of: stationWalk.routeRevision) { _, _ in
            model.updateWalkingLocation()
            if !model.mapWasMoved { model.showStationWalkOverview() }
        }
        .onChange(of: planner.currentStep) { _, _ in model.updateWalkingLocation() }
        .onChange(of: hasSelection) { _, selected in if selected { model.tappedPlace = nil; model.selectedBikeStationID = nil } }
        .onChange(of: planner.walkingRouteRevision) { _, _ in
            if let index = model.activeWalkingIndex, !model.mapWasMoved {
                model.focusMap(.journey(planner.walkingCoordinates(at: index)))
            }
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

    private func takeAssistantLaunch() {
        guard let text = AssistantLaunch.take() else { return }
        model.pendingAssistantRequest = text
        showInformation = false; showDetails = false; showSearch = false
        showJourneyItinerary = false; journeyDetent = .large; showJourney = true
    }
    private func restoreJourneyMap() {
        guard !stationWalk.isActive, planner.selected != nil else { return }
        if model.hasConfirmedOnboardFollow, model.selectedVehicle == nil { return }
        if planner.started, case .ride = planner.currentStep, let ride = planner.activeRide,
           let bus = model.onboardVehicle(for: ride), model.selectedVehicleID != bus.id {
            model.trackApproachingVehicle(bus, userInitiated: false); return
        }
        if let index = model.walkingMapIndex {
            let relevantBus = model.selectedVehicle.map { bus in
                planner.activeRide.map { model.metadata.canServe($0, vehicle: bus) } == true
            } ?? false
            if !relevantBus { model.clearSelection() }
            model.showWalkOnMap(index); return
        }
        if let bus = model.selectedVehicle, let ride = planner.activeRide,
           model.metadata.canServe(ride, vehicle: bus) {
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

private struct InstructionBannerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct MapBottomControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 210
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct JourneyPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Native Liquid Glass follows system appearance and accessibility preferences on iOS 26.
// Earlier systems keep the same control shapes with the system material.
private struct PhoneGlassBackground<S: Shape>: ViewModifier {
    @Environment(\.liveSettings) private var live
    let shape: S
    /// Interactive glass reacts to touches itself, so it is only used on a single
    /// control. Groups of buttons keep plain glass and let each button take its tap.
    var interactive = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || live.appearance.solidSurfaces {
            content.background(Color(uiColor: .systemBackground), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }

}

extension View {
    func phoneGlass<S: Shape>(in shape: S, interactive: Bool = true) -> some View { modifier(PhoneGlassBackground(shape: shape, interactive: interactive)) }
}

struct PhoneGlassGroup<Content: View>: View {
    @Environment(\.liveSettings) private var live
    private let content: Content
    private let spacing: CGFloat
    /// Glass shapes closer than `spacing` blend into one Liquid Glass surface.
    init(spacing: CGFloat = 3, @ViewBuilder content: () -> Content) { self.spacing = spacing; self.content = content() }
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) { GlassEffectContainer(spacing: spacing) { content } }
        else { content }
    }
}

struct PhonePressStyle: ButtonStyle {
    @Environment(\.liveSettings) private var live
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle()).scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.74), value: configuration.isPressed)
    }
}

/// Apple Maps shows nothing while data is healthy. The status capsule only
/// appears for the first load, a delay or a failed request, and retries on tap.
private struct SourceStatusView: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: TransitSnapshot
    let arrivalFeed: EstimateFeed
    let positionsNeeded: Bool
    let arrivalsNeeded: Bool
    let refresh: () -> Void
    static var clockStyle: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .shortened,
            locale: AppLanguage.current.locale, timeZone: TimeZone(identifier: "Asia/Taipei")!)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if let status = BusDataStatus.evaluate(snapshot, positions: positionsNeeded, arrivals: arrivalsNeeded,
                                                   at: timeline.date, arrivalFeed: arrivalFeed) {
                let waiting = status.state == .updating
                let age = status.updatedAt.map { timeline.date.timeIntervalSince($0) }
                Button(action: refresh) {
                    HStack(spacing: 7) {
                        // A static dot: a spinner would animate for as long as data is unavailable.
                        // Loading stays quiet; data that is actually late says so, with its age, and
                        // a tap retries. An old position is never presented as merely "updating".
                        Circle().fill(waiting ? Color.secondary : Color.orange).frame(width: 7, height: 7)
                        if dynamicTypeSize.isAccessibilitySize {
                            Label(AppText.text(waiting ? "更新中" : "稍後更新"), systemImage: status.source == .arrivals ? "clock" : "bus.fill")
                                .liveFont(.caption, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                        } else { Text(label(status)).liveFont(.subheadline, weight: .semibold) }
                        if !dynamicTypeSize.isAccessibilitySize, !waiting, let age, age >= 120 {
                            Text(AppText.text("· %@ 分鐘前", Int(age / 60))).liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 14 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 48)
                    .phoneGlass(in: Capsule())
                }
                .buttonStyle(PhonePressStyle()).foregroundStyle(.primary)
                .accessibilityIdentifier("bus-data-status")
                .accessibilityLabel(label(status))
                .accessibilityHint(AppText.text("點一下重新取得定位與到站資料"))
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topLeading)))
            }
        }
    }
    private func label(_ status: BusDataStatus) -> String {
        switch (status.source, status.state) {
        case (.positions, .updating): return AppText.text("公車位置更新中")
        case (.arrivals, .updating): return AppText.text("到站時間更新中")
        case (.both, .updating): return AppText.text("公車資料更新中")
        case (.positions, .delayed): return AppText.text("公車位置稍後更新 · 重試")
        case (.arrivals, .delayed): return AppText.text("到站時間稍後更新 · 重試")
        case (.both, .delayed): return AppText.text("公車資料稍後更新 · 重試")
        }
    }
}

/// Apple Maps-style place card: what was tapped, how far it is, and one tap to get there.
private struct MapPlaceCard: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.colorScheme) private var colorScheme
    let place: MapPlaceSelection
    let distance: Double?
    let route: () -> Void
    let close: () -> Void
    private var category: (name: String, symbol: String, hex: String, darkHex: String, classes: [String])? {
        NativeBusMap.Coordinator.placeCategory(place.kind)
    }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category?.symbol ?? "mappin").liveFont(.subheadline, weight: .semibold).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(liveHex: colorScheme == .dark ? category?.darkHex ?? "#A7B3C6" : category?.hex ?? "#6E7C91")))
            VStack(alignment: .leading, spacing: 2) {
                Text(place.localizedName).liveFont(.headline, weight: .semibold).lineLimit(1)
                Text([category.map { live.text(Self.categoryNames[$0.name] ?? "地點") } ?? live.text("地點"),
                      distance.map { distanceLabel($0) }].compactMap { $0 }.joined(separator: " · "))
                    .liveFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: route) {
                Label(live.text("路線"), systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .liveFont(.subheadline, weight: .semibold).labelStyle(.titleAndIcon)
                    .padding(.horizontal, 14).frame(minHeight: 40)
            }
            .buttonStyle(MapActionStyle(prominent: true, tint: MapChrome.go))
            .accessibilityIdentifier("place-card-route")
            Button(action: close) {
                Image(systemName: "xmark").liveFont(.caption, weight: .bold).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).background(Circle().fill(Color.secondary.opacity(0.14)))
            }.buttonStyle(.plain).accessibilityLabel(live.text("關閉")).frame(width: 36, height: 44)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 10)
        .phoneGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityIdentifier("place-card")
    }
    static let categoryNames: [String: String] = [
        "poi-food": "餐廳", "poi-cafe": "咖啡廳", "poi-shop": "商店", "poi-grocery": "超市", "poi-health": "醫療",
        "poi-education": "學校", "poi-park": "公園", "poi-culture": "文化景點", "poi-lodging": "住宿",
        "poi-service": "公共服務", "poi-worship": "宗教場所", "poi-rail": "車站"
    ]
}

/// Apple Maps keeps one search field at the bottom of the map. Stops and the
/// route keypad sit beside it; a selection adds follow and close controls.
private struct HomeSearchRow: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }
    @ObservedObject var model: TransitAppModel
    let hasSelection: Bool
    let search: () -> Void
    let browse: (BrowseMode) -> Void
    /// Speak instead of type: the first thing on the home screen, like a voice assistant.
    var voice: (() -> Void)? = nil
    private var accent: Color { Color(liveHex: live.appearance.accentColor) }
    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol).liveFont(.title3).frame(width: 56, height: 56).contentShape(Circle())
    }
    var body: some View {
        HStack(spacing: 10) {
            Button(action: search) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").liveFont(.body, weight: .semibold).foregroundStyle(.secondary)
                    if !hasSelection {
                        Text(live.text("搜尋目的地")).liveFont(.body).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, hasSelection ? 0 : 18 * CGFloat(live.appearance.spacingScale))
                .frame(maxWidth: hasSelection ? 56 : .infinity, minHeight: 56).frame(width: hasSelection ? 56 : nil)
                .contentShape(Capsule())
            }
            .buttonStyle(PhonePressStyle())
            .phoneGlass(in: Capsule())
            .accessibilityLabel(live.text("搜尋目的地"))
            .accessibilityIdentifier("home-destination-search")
            if !hasSelection, let voice {
                // Speaking is the first way to plan: a tinted glass button of its own, never content
                // inside the search glass (there it rendered as a blurred glow on phones).
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    voice()
                } label: {
                    Image(systemName: "mic.fill").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 56, height: 56).contentShape(Circle())
                }
                .buttonStyle(VoicePressStyle())
                .modifier(TintedGlassCircle(tint: accent))
                .accessibilityLabel(live.text("用說的規劃"))
                .accessibilityIdentifier("home-voice")
            }
            if hasSelection { Spacer(minLength: 0) }
            // Touching circles blend into one capsule inside the bottom glass container.
            HStack(spacing: 0) {
                if live.display.stationShortcut || hasSelection {
                    Button { browse(.stops) } label: { circle("mappin.and.ellipse") }
                        .foregroundStyle(.primary).phoneGlass(in: Circle()).accessibilityLabel(live.text("站牌"))
                }
                if let bus = model.selectedVehicle {
                    Button {
                        model.following.toggle()
                        UISelectionFeedbackGenerator().selectionChanged()
                        if model.following { model.focusMap(.vehicle(bus.id)) }
                    } label: {
                        circle(model.following ? "scope" : "bus.fill")
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                    .foregroundStyle(model.following ? accent : Color.primary)
                    .phoneGlass(in: Circle())
                    .accessibilityLabel(model.following ? AppText.text("停止跟車") : AppText.text("跟車"))
                } else if live.display.routeShortcut || hasSelection {
                    Button { browse(.routes) } label: { circle("point.topleft.down.to.point.bottomright.curvepath") }
                        .foregroundStyle(.primary).phoneGlass(in: Circle()).accessibilityLabel(live.text("路線"))
                }
                if model.selectedRouteID != nil || model.selectedStationID != nil {
                    Button {
                        if model.canReturnToRouteOverview { model.returnToRouteOverview() }
                        else if model.canReturnToRouteStation { model.returnToRouteStation() }
                        else { model.clearSelection() }
                    } label: {
                        Image(systemName: "xmark").liveFont(.subheadline, weight: .bold).frame(width: 56, height: 56).contentShape(Circle())
                    }
                    .foregroundStyle(.secondary)
                    .phoneGlass(in: Circle())
                    .accessibilityLabel(model.canReturnToRouteOverview ? AppText.text("返回路線") : model.canReturnToRouteStation ? AppText.text("返回站牌") : live.text("關閉選取"))
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86), value: hasSelection)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), value: model.selectedVehicleID)
    }
}

/// The right-hand control stack: map settings, the city fleet and location,
/// grouped in one glass column like Apple Maps.
private struct MapControlStack: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }
    @ObservedObject var model: TransitAppModel
    @ObservedObject var location: LocationService
    let showsCityFleet: Bool
    var showsLocation = true
    let showInformation: () -> Void
    private var accent: Color { Color(liveHex: live.appearance.accentColor) }
    var body: some View {
        // Each control keeps its own interactive glass, exactly as the 1.1.9
        // top bar did, without a shared glass container.
        VStack(spacing: 8) {
                Button(action: showInformation) {
                    Image(systemName: "map").liveFont(.title3).frame(width: MapChrome.controlSize, height: MapChrome.controlSize)
                }
                .foregroundStyle(.primary)
                .phoneGlass(in: Circle())
                .accessibilityLabel(live.text("資料來源與地圖設定"))
                if showsCityFleet {
                    Button { model.toggleCityFleet() } label: {
                        Image(systemName: model.cityFleetMode ? "globe.asia.australia.fill" : "globe.asia.australia")
                            .liveFont(.title3).frame(width: MapChrome.controlSize, height: MapChrome.controlSize)
                    }
                    .foregroundStyle(model.cityFleetMode ? accent : Color.primary)
                    .phoneGlass(in: Circle())
                    .accessibilityIdentifier("city-fleet-toggle")
                    .accessibilityLabel(model.cityFleetMode ? AppText.text("離開全城公車") : AppText.text("查看全城公車"))
                    .accessibilityValue(model.cityFleetMode ? AppText.text("已開啟") : AppText.text("已關閉"))
                }
                if showsLocation { MapLocationControl(model:model,location:location) }
            }
    }
}

private struct MapLocationControl: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject var location: LocationService
    private var accent: Color { Color(liveHex:live.appearance.accentColor) }
    var body: some View {
                Button {
                    model.cycleUserTracking()
                } label: {
                    Group {
                        if location.requesting { ProgressView() }
                        else {
                            Image(systemName: model.userMapMode == .heading ? "location.north.line.fill" : model.userMapMode == .north ? "location.fill" : "location")
                                .liveFont(.title3)
                        }
                    }.frame(width: MapChrome.controlSize, height: MapChrome.controlSize)
                }
                .foregroundStyle(model.userMapMode == .free ? Color.primary : accent)
                .phoneGlass(in: Circle())
                .accessibilityIdentifier("map-location")
                .accessibilityLabel(live.text("定位與地圖方向"))
                .accessibilityValue(model.userMapMode == .heading ? AppText.text("手機方向") : model.userMapMode == .north ? AppText.text("北朝上") : AppText.text("自由瀏覽"))
                .accessibilityHint(model.userMapMode == .north ? AppText.text("切換為手機方向") : AppText.text("回到目前位置並朝北"))
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
            } else if model.loadError != nil, model.metadata.routes.isEmpty {
                VStack(spacing:12) {
                    Text(live.text("更新中")).liveFont(.subheadline).foregroundStyle(.secondary)
                    Button(live.text("重新整理")) { model.retry() }.buttonStyle(.bordered)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
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
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.top, 16 * CGFloat(live.appearance.spacingScale))
    }

    var body: some View {
        // Search and details swap as whole pages. Letting the header, list and keypad each
        // transition on their own made the old results slide over the search field mid-way.
        ZStack(alignment: .top) {
            panelContent
                .id(isBrowsing)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.05)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
        }
        .smoothChanges(model.mode)
        .smoothChanges(systemRouteKeyboard)
        .smoothChanges(isBrowsing)
        .smoothChanges(model.language)
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
        let firstNearbyResults = stationResults.isEmpty && query.isEmpty && !results.isEmpty && model.stationBrowsing && !model.mapWasMoved
        stationResults = results; stationResultQuery = query
        model.stationMapResults = results
        if firstNearbyResults, let point = model.stationBrowseCenter { model.focusNearbyStations(around: point) }
    }

    private var browseTitle: String {
        switch model.mode {
        case .stops: return location.usableCoordinate?.isInServiceArea == true ? "附近站牌" : "選擇站牌"
        case .routes: return "公車／捷運路線"
        }
    }

    private var browseHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(live.text(browseTitle))
                    .liveFont(.title2, weight: .bold)
                Spacer()
                if model.mode == .stops {
                    Button { searchFocused = false; model.browseNearMe() } label: { Image(systemName: "location.fill") }
                        .accessibilityLabel(AppText.text("回到我附近")).accessibilityIdentifier("browse-near-me")
                        .liveFont(.subheadline, weight: .semibold).frame(minHeight: 44)
                    Button {
                        searchFocused = false; model.sheetDetent = .height(390)
                        if !model.query.isEmpty { model.focusMap(.journey(stationResults.map(\.coordinate))) }
                    } label: { Image(systemName: "map") }.frame(width: 44, height: 44)
                        .accessibilityLabel(AppText.text("在地圖查看站牌")).accessibilityIdentifier("station-results-map")
                        .disabled(stationResultQuery != model.query || stationResults.isEmpty)
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }.frame(width: 36, height: 44)
                    .accessibilityLabel(AppText.text("返回地圖"))
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                if model.mode == .routes && !systemRouteKeyboard {
                    Button { systemRouteKeyboard = true; searchFocused = true } label: {
                        Text(model.query.isEmpty ? AppText.text("搜尋路線／起訖站") : model.query)
                            .foregroundStyle(model.query.isEmpty ? Color.secondary : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("route-query").buttonStyle(.plain)
                } else {
                TextField(model.mode == .routes ? AppText.text("搜尋路線／起訖站") : AppText.text("搜尋站牌"), text: $model.query)
                    .focused($searchFocused).submitLabel(.search).autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("transit-search-field")
                    .onAppear { if systemRouteKeyboard { searchFocused = true } }
                }
                if model.mode == .routes, systemRouteKeyboard {
                    Button { searchFocused = false; systemRouteKeyboard = false } label: { Image(systemName: "number") }
                        .frame(width: 40, height: 44).accessibilityLabel(AppText.text("路線專用鍵盤"))
                }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .frame(width: 36, height: 40).accessibilityLabel(live.text("清除搜尋"))
                }
            }
            .padding(.horizontal, 12 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 48)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13 * CGFloat(live.appearance.cornerScale)))
            Picker(AppText.text("查詢類型"), selection: $model.mode) {
                ForEach(BrowseMode.allCases) { Text(live.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            if let message = location.message { Text(live.text(message)).liveFont(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 18 * CGFloat(live.appearance.spacingScale)).padding(.bottom, 12 * CGFloat(live.appearance.spacingScale))
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { if model.canReturnToRouteOverview { model.returnToRouteOverview() } else if model.canReturnToRouteStation { model.returnToRouteStation() } else { model.returnToBrowse() } } label: { Image(systemName: "chevron.left").liveFont(.body, weight: .semibold).frame(width: 44, height: 44) }
                .accessibilityLabel(model.canReturnToRouteOverview ? AppText.text("返回路線") : model.canReturnToRouteStation ? AppText.text("返回站牌") : live.text("返回搜尋"))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectedStation?.localizedName ?? model.selectedVehicle?.localizedRouteName ?? model.selectedRouteName ?? AppText.text("公車動態"))
                    .liveFont(.title2, weight: .bold).lineLimit(2)
                if let station = model.selectedStation { Text(station.localizedBearing).liveFont(.caption).foregroundStyle(.secondary) }
                else if let vehicle = model.selectedVehicle { Text(vehicle.plate).liveFont(.subheadline).foregroundStyle(.secondary).monospaced() }
                else { Text(live.text("路線動態")).liveFont(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                .accessibilityLabel(AppText.text("返回地圖")).accessibilityIdentifier("transit-details-close")
            if let station = model.selectedStation {
                Button { model.toggleFavorite(station) } label: {
                    Image(systemName: model.favorites.contains(station.id) ? "star.fill" : "star")
                        .liveFont(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel(model.favorites.contains(station.id) ? AppText.text("移除收藏站牌") : AppText.text("收藏站牌"))
            }
        }.padding(.leading, 6 * CGFloat(live.appearance.spacingScale)).padding(.trailing, 12 * CGFloat(live.appearance.spacingScale)).padding(.bottom, 12 * CGFloat(live.appearance.spacingScale))
    }

    @ViewBuilder private var browseResults: some View {
        if model.mode == .stops {
            let stations = stationResultQuery == model.query ? stationResults : []
            if stations.isEmpty { emptyResult }
            ForEach(stations) { station in
                if model.query.isEmpty, let first = stations.first(where: { !model.recentStationIDs.contains($0.id) && !model.favorites.contains($0.id) }), first.id == station.id {
                    Text(AppText.text("地圖附近")).liveFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.top, 12)
                } else if model.query.isEmpty, stations.first?.id == station.id {
                    Text(AppText.text("收藏與最近查看")).liveFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.top, 12)
                }
                Button { model.selectStation(station) } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: model.favorites.contains(station.id) ? "star.fill" : model.recentStationIDs.contains(station.id) ? "clock" : station.mode == .bus ? "mappin.circle.fill" : "tram.circle.fill")
                            .foregroundStyle(model.favorites.contains(station.id) ? Color.orange : Color(liveHex: live.appearance.accentColor))
                            .liveFont(.title2).frame(width: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { BilingualName(station).liveFont(.body, weight: .semibold); Text(station.localizedBearing).liveFont(.caption).foregroundStyle(.secondary) }
                            Text(station.mode != .bus ? model.metadata.metro.station(station.id)?.code ?? "" : station.address.isEmpty ? AppText.text("站牌 %@", station.id) : station.address).liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if let position = location.usableCoordinate, position.isInServiceArea {
                            Text(distanceLabel(position.distance(to: station.coordinate))).liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Image(systemName: "chevron.right").liveFont(.caption, weight: .semibold).foregroundStyle(.tertiary)
                    }.padding(.vertical, 15 * CGFloat(live.appearance.spacingScale)).contentShape(Rectangle())
                }.buttonStyle(PhonePressStyle()).accessibilityIdentifier("station-result-" + station.id)
                Divider()
            }
        } else if model.mode == .routes {
            let routes = model.browsingRoutes
            if routes.isEmpty { emptyResult }
            ForEach(routes) { result in
                if model.query.isEmpty, routes.first?.id == result.id {
                    Text(model.recentRouteIDs.isEmpty ? AppText.text("公車／捷運路線") : AppText.text("最近查看")).liveFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.top, 8)
                } else if model.query.isEmpty, let first = routes.first(where: { !model.recentRouteIDs.contains($0.id) }), first.id == result.id {
                    Text(AppText.text("其他路線")).liveFont(.caption, weight: .semibold).foregroundStyle(.secondary).padding(.top, 12)
                }
                let route = result.route
                Button { model.selectRoute(route, variantOnly: result.matchedVariant != nil) } label: {
                    HStack(spacing: 12) {
                        RouteBadge(name: route.localizedName, tintName: route.name)
                        VStack(alignment: .leading, spacing: 4) {
                            if result.matchedVariant != nil {
                                Text(result.localizedName).liveFont(.subheadline, weight: .semibold).lineLimit(2)
                            }
                            Text(route.localizedDestination(direction: "1") + " → " + route.localizedDestination(direction: "0")).liveFont(.subheadline).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
                    }.padding(.vertical, 12 * CGFloat(live.appearance.spacingScale)).contentShape(Rectangle())
                }.buttonStyle(PhonePressStyle()).accessibilityIdentifier("route-result-" + route.id)
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
            query = AppText.text(key) + query.filter(\.isNumber)
        } else if key.count > 1 { query = AppText.text(key) }
        else { query += key }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(["A", "L", "E", "黃", "快", "內科", "市民", "南軟", "貓空", "懷恩", "區", "副"], id: \.self) { key in
                            Button(AppText.text(key)) { enter(key) }.frame(minWidth: 28, minHeight: 40)
                        }
                    }
                }
                Button(action: useKeyboard) { Image(systemName: "keyboard").frame(width: 44, height: 40) }
                    .accessibilityLabel(AppText.text("一般文字鍵盤")).accessibilityIdentifier("route-text-keyboard")
            }.liveFont(.subheadline, weight: .medium)
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 7) {
                    ForEach(row, id: \.self) { key in
                        Button { enter(key) } label: {
                            Group {
                                if key == "⌫" { Image(systemName: "delete.left") }
                                else { Text(AppText.text(key)).lineLimit(1).minimumScaleFactor(0.6) }
                            }.liveFont(.title3, weight: .medium).frame(maxWidth: .infinity, minHeight: 48)
                                .foregroundStyle(color(key)).background(color(key).opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }.buttonStyle(PhonePressStyle()).accessibilityIdentifier("route-key-" + key)
                            .accessibilityLabel(key == "⌫" ? AppText.text("刪除一字") : AppText.text(key))
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
                HStack(spacing: 8) {
                    Button { model.startStationWalk(station) } label: {
                        Label(live.text("步行"), systemImage: "figure.walk")
                    }
                    .buttonStyle(MapTileStyle(prominent: true))
                    .accessibilityLabel(live.text("步行到這個站牌")).accessibilityIdentifier("station-start-walk")
                    ForEach(model.oppositeStations(to: station)) { opposite in
                        Button { model.selectStation(opposite) } label: {
                            Label(opposite.localizedBearing, systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(MapTileStyle())
                        .accessibilityLabel(AppText.text("改看%@站牌", opposite.localizedBearing))
                        .accessibilityIdentifier("station-opposite-" + opposite.id)
                    }
                }.padding(.bottom, 18 * CGFloat(live.appearance.spacingScale))
                HStack {
                    Text(station.mode == .bus ? live.text("官方到站預估") : live.text("列車方向")).liveFont(.subheadline, weight: .semibold)
                    Spacer()
                    if let time = station.mode == .bus ? model.busArrivals.updatedAt : model.snapshot.estimates.updatedAt {
                        Text(time.formatted(SourceStatusView.clockStyle)).liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }.padding(.bottom, 8 * CGFloat(live.appearance.spacingScale))
                if rows.isEmpty { Text(live.text("此站暫無路線資訊")).foregroundStyle(.secondary).padding(.vertical) }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            if let route = row.route { model.selectRoute(route, direction: row.stop.direction, boardingStopID: row.stop.id) }
                        } label: {
                            HStack(spacing: 12) {
                                RouteBadge(name: row.route.map { $0.mode == .bus ? $0.localizedName : $0.lineCode } ?? row.stop.routeID, tintName: row.route?.name ?? row.stop.routeID)
                                Text(AppText.text("往 %@", row.route?.localizedDestination(direction: row.stop.direction) ?? "方向未提供"))
                                    .liveFont(.subheadline).lineLimit(2)
                                Spacer(minLength: 4)
                                Text(row.stop.mode == .bus || row.estimateSeconds != nil ? EstimateFeed.label(row.estimateSeconds) :
                                        model.metroStationWaitLabel(serviceID: row.stop.serviceID, direction: row.stop.direction, stationID: row.stop.stationID, at: timeline.date))
                                    .liveFont(.body, weight: .semibold).monospacedDigit()
                                    .foregroundStyle((row.estimateSeconds ?? -1) >= 0 ? Color(liveHex: live.appearance.accentColor) : Color.secondary)
                                Image(systemName: "chevron.right").liveFont(.caption, weight: .semibold).foregroundStyle(.tertiary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).frame(minHeight: 44).accessibilityIdentifier("station-route-" + row.stop.routeID)
                        if row.stop.mode != .bus, let window = model.metadata.metro.boardingWindow(routeID: row.stop.serviceID, direction: row.stop.direction, stationID: row.stop.stationID) {
                            Text(AppText.text("首班 %@ · 末班 %@", String(format:"%02d:%02d",window.firstMinute / 60,window.firstMinute % 60), String(format:"%02d:%02d",window.lastMinute / 60,window.lastMinute % 60)))
                                .liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if !row.approaches.isEmpty {
                            Text(live.text("同方向車輛")).liveFont(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                ForEach(row.approaches) { approach in
                                    Button { model.selectVehicle(approach.vehicle) } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(approach.vehicle.plate).liveFont(.caption, weight: .semibold).monospaced()
                                            Text(approach.alongDistance.map { $0 <= 25 ? AppText.text("站牌附近") : AppText.text("沿線 %@", distanceLabel($0)) }
                                                 ?? AppText.text("GPS 直線 %@", distanceLabel(approach.directDistance))).liveFont(.caption2).foregroundStyle(.secondary)
                                        }.padding(.horizontal, 12 * CGFloat(live.appearance.spacingScale)).padding(.vertical, 6 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 48)
                                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }.padding(.vertical, 12 * CGFloat(live.appearance.spacingScale))
                    Divider()
                }
                if station.mode == .bus {
                    Text(live.text("軌跡可確認時排除已通過車輛；沿線距離依 GPS 推估。官方時間未綁定車牌。")).liveFont(.caption).foregroundStyle(.secondary).padding(.top, 14 * CGFloat(live.appearance.spacingScale))
                } else {
                    Text(AppText.text("依官方班距估計")).liveFont(.caption).foregroundStyle(.secondary)
                    ForEach(model.metadata.metro.station(station.id)?.exits ?? []) { exit in
                        HStack { Label(AppLanguage.current == .english ? exit.englishName : exit.name, systemImage: exit.accessible ? "figure.roll" : "door.left.hand.open"); Spacer() }
                            .liveFont(.subheadline).padding(.vertical, 6)
                    }
                }
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
                                Label(variant.localizedDisplayName, systemImage: "checkmark")
                            } else { Text(variant.localizedDisplayName) }
                        }
                    }
                } label: {
                    HStack {
                        Text(model.allRouteVariants ? AppText.text("全部走法 · %@", model.routeVariants.count) : route.localizedDisplayName)
                            .liveFont(.subheadline, weight: .semibold).lineLimit(2)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down").liveFont(.caption, weight: .semibold)
                    }.padding(.horizontal, 14 * CGFloat(live.appearance.spacingScale)).frame(minHeight: 48)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13 * CGFloat(live.appearance.cornerScale)))
                }.accessibilityLabel(live.text("選擇路線走法"))
            }
            if model.routeDirections.count > 1 {
                Picker(AppText.text("行駛方向"), selection: $model.direction) {
                    ForEach(model.routeDirections, id: \.self) { direction in
                        Text(AppText.text("往 %@", route.localizedDestination(direction: direction))).tag(direction)
                    }
                }.pickerStyle(.segmented)
            } else {
                Text(AppText.text("往 %@", route.localizedDestination(direction: model.direction))).liveFont(.subheadline).foregroundStyle(.secondary)
            }
            boardingStopSelector
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                if route.mode != .bus {
                    if let stop = model.routeBoardingStop {
                        let stops = model.metadata.orderedStops(routeID: route.id, direction: model.direction)
                        if let index = stops.firstIndex(where: { $0.id == stop.id }), index < stops.count - 1 {
                            let ride = TransitRide(route: route, direction: model.direction, stops: Array(stops[index...]), coordinates: [])
                            MetroBoardingRows(model: model, ride: ride, date: timeline.date)
                        }
                    }
                } else {
                let buses = model.routeVehicles()
                if let stop = model.routeBoardingStop {
                    let group = RouteBoardingVehicles(stop: stop, vehicles: buses, metadata: model.metadata, at: timeline.date)
                    TimelineView(.periodic(from: .now, by: 1)) { clock in
                        HStack(alignment: .firstTextBaseline) {
                            Text(AppText.text("官方下一班")).liveFont(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text(EstimateFeed.label(model.snapshot.estimates.value(routeID: route.parentID, stopID: stop.id, at: clock.date)))
                                .liveFont(.title2, weight: .bold).monospacedDigit()
                        }.accessibilityElement(children: .combine).accessibilityIdentifier("route-stop-official-arrival")
                    }
                    if group.approaching.isEmpty {
                        Text(AppText.text("往此站的車輛位置待確認")).liveFont(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text(AppText.text("往此站的公車")).liveFont(.subheadline, weight: .semibold)
                        ForEach(Array(group.approaching.prefix(3).enumerated()), id: \.element.id) { index, approach in
                            boardingVehicle(approach, stop: stop, nearest: index == 0, at: timeline.date)
                        }
                        if group.approaching.count > 3 {
                            DisclosureGroup(AppText.text("後續 %@ 輛", group.approaching.count - 3)) {
                                ForEach(Array(group.approaching.dropFirst(3))) { boardingVehicle($0, stop: stop, nearest: false, at: timeline.date) }
                            }.liveFont(.subheadline)
                        }
                    }
                    if !group.other.isEmpty {
                        DisclosureGroup(AppText.text("其他公車 · %@", group.other.count)) {
                            ForEach(group.other) { entry in
                                HStack {
                                    Button { model.selectVehicle(entry.vehicle) } label: {
                                        HStack {
                                            Text(entry.vehicle.plate).monospaced().liveFont(.subheadline, weight: .medium)
                                            Spacer()
                                            Text(otherReason(entry.reason)).liveFont(.caption).foregroundStyle(.secondary)
                                            Image(systemName: "chevron.right").liveFont(.caption)
                                        }.frame(minHeight: 44).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.liveFont(.subheadline).accessibilityIdentifier("route-other-vehicles")
                    }
                } else {
                    DisclosureGroup(AppText.text("沿線公車 · %@", buses.count)) {
                        ForEach(buses) { bus in VehicleRow(vehicle: bus) { model.selectVehicle(bus) } }
                    }.liveFont(.subheadline)
                }
                }
            }
            Text(route.mode != .bus ? AppText.text("沿線車站") : model.allRouteVariants && model.routeVariants.count > 1 ? AppText.text("主要站序") : AppText.text("沿線站牌"))
                .liveFont(.headline).padding(.top, 8 * CGFloat(live.appearance.spacingScale))
            if model.allRouteVariants && model.routeVariants.count > 1 {
                Text(live.text("切換上方走法，可看各支線停靠站。")).liveFont(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                ForEach(model.routeStops) { stop in
                    Button {
                        model.chooseRouteBoardingStop(stop)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.routeBoardingStopID == stop.id ? "checkmark.circle.fill" : "circle").foregroundStyle(model.routeBoardingStopID == stop.id ? Color.accentColor : .secondary).frame(width: 26)
                            BilingualName(stop).liveFont(.subheadline)
                            Spacer(minLength: 8)
                            Text(route.mode == .bus ? EstimateFeed.label(model.snapshot.estimates.value(routeID: route.parentID, stopID: stop.id, at: timeline.date)) : model.metadata.metro.station(stop.stationID)?.code ?? "")
                                .liveFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                        }.frame(minHeight: 50).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("route-boarding-stop-" + stop.id)
                    Divider()
                }
            }
        }
    }
    private var boardingStopSelector: some View {
        Menu {
            ForEach(model.routeStops) { stop in
                Button { model.chooseRouteBoardingStop(stop) } label: {
                    if model.routeBoardingStopID == stop.id { Label(stop.bilingualName, systemImage: "checkmark") }
                    else { Text(stop.bilingualName) }
                }
            }
        } label: {
            HStack {
                Image(systemName: "mappin.circle.fill")
                if let stop = model.routeBoardingStop { BilingualName(stop).lineLimit(2) }
                else { Text(AppText.text("選擇上車站")) }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").liveFont(.caption)
            }.liveFont(.subheadline, weight: .semibold).frame(maxWidth: .infinity, minHeight: 44)
        }.secondaryAction().accessibilityIdentifier("route-boarding-selector")
    }
    private func boardingVehicle(_ approach: VehicleApproach, stop: BusStop, nearest: Bool, at date: Date) -> some View {
        let display = model.arrivalDisplay(approach.vehicle, stopID: stop.id, at: date)
        return Button { model.selectVehicle(approach.vehicle) } label: {
            HStack(spacing: 12) {
                Image(systemName: nearest ? "bus.fill" : "bus").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(approach.vehicle.plate).liveFont(.subheadline, weight: .semibold).monospaced()
                    Text(nearest ? AppText.text("沿線最近") : AppText.text("後續車輛")).liveFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(display.prediction != nil ? display.label : AppText.text("時間待確認")).liveFont(.subheadline, weight: .medium).monospacedDigit()
                    Text(AppText.text("追蹤")).liveFont(.caption).foregroundStyle(Color.accentColor)
                }
                Image(systemName: "scope").foregroundStyle(Color.accentColor)
            }.frame(minHeight: 54).contentShape(Rectangle())
        }.buttonStyle(PhonePressStyle()).accessibilityIdentifier("route-approaching-" + approach.vehicle.plate)
    }
    private func otherReason(_ reason: RouteBoardingVehicles.OtherReason) -> String {
        switch reason {
        case .passed: return AppText.text("已過此站")
        case .differentPattern: return AppText.text("不經此站")
        case .positionUnknown: return AppText.text("位置待確認")
        case .notRunning: return AppText.text("尚未行駛")
        }
    }
}

private struct VehicleDetails: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    let vehicle: BusVehicle

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(AppText.text("往 %@", vehicle.localizedDestination)).liveFont(.headline)
            if !model.planner.started, let next = model.upcomingStops.first {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(live.text("官方下一班")).liveFont(.caption).foregroundStyle(.secondary)
                            BilingualName(next.stop).liveFont(.subheadline, weight: .semibold).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Text(EstimateFeed.label(model.snapshot.estimates.value(routeID: vehicle.parentRouteID, stopID: next.stop.id, at: timeline.date)))
                            .liveFont(.title, weight: .semibold).monospacedDigit().lineLimit(2).minimumScaleFactor(0.75)
                            .accessibilityIdentifier("browse-hero-official-arrival")
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let fresh = vehicle.hasReliablePosition(at: timeline.date)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(fresh && vehicle.hasSpeed ? "\(Int(vehicle.speed))" : "—").liveFont(.subheadline, weight: .semibold, design: .rounded).monospacedDigit()
                        Text(live.text("GPS 回報 km/h")).liveFont(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(fresh ? vehicle.statusLabel : vehicle.trackingLabel(at: timeline.date) ?? AppText.text("定位已延遲")).liveFont(.subheadline, weight: .semibold).foregroundStyle(fresh ? Color.primary : Color.orange)
                        Text(AppText.text("%@ 秒前回報", max(0, Int(timeline.date.timeIntervalSince(vehicle.observedAt))))).liveFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if vehicle.lowFloor { Label(live.text("低底盤"), systemImage: "figure.roll").liveFont(.caption) }
                    }
                }
            }
            if let provider = vehicle.localizedProvider { Text(provider).liveFont(.subheadline).foregroundStyle(.secondary) }
            Toggle(AppText.text("淡化建築、凸顯這輛車"), isOn: $model.highlightVehicle).liveFont(.subheadline)
            HStack(spacing: 10) {
                Button {
                    model.following = model.beginFollowing(vehicle.id); model.focusMap(.vehicle(vehicle.id))
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
                Text(live.text("官方到站預估")).liveFont(.subheadline, weight: .semibold)
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                ForEach(Array(upcoming.prefix(3)), id: \.stop.id) { progress in
                    Button {
                        if let station = model.metadata.stations[progress.stop.stationID] { model.selectStation(station) }
                    } label: {
                        HStack {
                            BilingualName(progress.stop).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(EstimateFeed.label(model.snapshot.estimates.value(routeID: vehicle.parentRouteID, stopID: progress.stop.id, at: timeline.date)))
                                .foregroundStyle(.secondary).monospacedDigit().accessibilityIdentifier("browse-official-arrival-" + progress.stop.id)
                        }.liveFont(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                }
                Text(live.text("官方時間為路線下一班，未指定車牌。")).liveFont(.caption).foregroundStyle(.secondary)
            }
            let stops = model.metadata.orderedStops(routeID: vehicle.routeID, direction: vehicle.direction)
                .sorted { $0.coordinate.distance(to: vehicle.rawCoordinate) < $1.coordinate.distance(to: vehicle.rawCoordinate) }
            if upcoming.isEmpty, let stop = stops.first {
                Divider()
                Text(AppText.text("最後 GPS 附近 · %@", stop.localizedName)).liveFont(.subheadline, weight: .semibold)
                Text(AppText.text("GPS 直線距離 %@", distanceLabel(vehicle.rawCoordinate.distance(to: stop.coordinate))))
                    .liveFont(.caption).foregroundStyle(.secondary)
                Button {
                    if let station = model.metadata.stations[stop.stationID] { model.selectStation(station) }
                } label: { Label(live.text("查看此站到站預估"), systemImage: "mappin.and.ellipse").frame(minHeight: 44) }
                    .secondaryAction()
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
                    Text(AppText.text("%@ · 往 %@", vehicle.localizedRouteName, vehicle.localizedDestination)).liveFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 6)
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    let reliable = vehicle.hasReliablePosition(at: timeline.date)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(reliable ? vehicle.speedLabel : vehicle.trackingIssue == .missing ? AppText.text("訊號暫缺") : vehicle.trackingIssue == .rejected ? AppText.text("確認中") : AppText.text("延遲"))
                            .foregroundStyle(reliable ? Color.secondary : Color.orange)
                        Text(AppText.text("%@ 秒前", max(0, Int(timeline.date.timeIntervalSince(vehicle.observedAt))))).foregroundStyle(.secondary)
                    }.liveFont(.caption).monospacedDigit()
                }
                Image(systemName: "chevron.right").liveFont(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 14 * CGFloat(live.appearance.spacingScale)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// A route sign: white text on the route family's colour, as on Taipei bus
/// signs and Apple Maps transit badges.
struct RouteBadge: View {
    @Environment(\.liveSettings) private var live
    let name: String
    /// The official Chinese name decides the colour when `name` is translated.
    var tintName: String? = nil
    var compact = false
    var body: some View {
        Text(name).liveFont(compact ? .subheadline : .headline, weight: .bold).lineLimit(compact ? 1 : 2).minimumScaleFactor(compact ? 0.75 : 0.9)
            .monospacedDigit()
            .padding(.horizontal, (compact ? 7 : 10) * CGFloat(live.appearance.spacingScale))
            .padding(.vertical, (compact ? 3 : 6) * CGFloat(live.appearance.spacingScale)).frame(minWidth: compact ? 34 : 52)
            .foregroundStyle(RouteTint.signInk(for: tintName ?? name))
            .background(RouteTint.color(for: tintName ?? name), in: RoundedRectangle(cornerRadius: (compact ? 7 : 10) * CGFloat(live.appearance.cornerScale), style: .continuous))
    }
}

private struct AppInformationView: View {
    @Environment(\.liveSettings) private var live
    @ObservedObject var model: TransitAppModel
    @ObservedObject private var diagnostics = JourneyDiagnostics.shared
    @Environment(\.dismiss) private var dismiss
    @State private var testerBuild = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ProSettingsView(model:model) } label: {
                        Label(AppText.text("台北公車 Pro"),systemImage:"star.circle")
                    }.accessibilityIdentifier("settings-pro")
                }
                Section(live.text("語言")) {
                    Toggle("English", isOn: Binding(get: { model.language == .english }, set: { model.setLanguage($0 ? .english : .traditionalChinese) }))
                        .accessibilityIdentifier("app-language-toggle")
                }
                CommuteHabitSettings(habits: model.commuteHabits)
                if OnlineJourneyReader.configured { OnlineUnderstandingSettings() }
                if OnDeviceJourneyAssistant.plannerUnavailableReason() == nil { VoiceStyleSettings() }
                Section(AppText.text("即時資料")) {
                    Text(AppText.text("%@ 條路線 · %@ 個走法", model.metadata.routeCatalog.groups.count, model.metadata.routes.count))
                    Text(live.text("臺北市公共運輸處公開資料，每 5 秒檢查定位。個別公車回報時間以車輛資訊為準。"))
                    if let error = model.snapshot.vehicleError { Label(live.text(error), systemImage: "wifi.exclamationmark") }
                    if let error = model.snapshot.estimates.error { Text(live.text(error)) }
                    if let notice = model.metadataNotice { Text(live.text(notice)) }
                    Text(live.text("官方到站預估沒有車牌資訊；請以站牌的路線預估為準。"))
                    Text(live.text("回到 App 時立即更新；背景暫停畫面與輪詢。官方車輛資料會持續產生。"))
                    Link(AppText.text("公開資料說明"), destination: URL(string: "https://pto.gov.taipei/News_Content.aspx?n=A1DF07A86105B6BB&s=55E8ADD164E4F579&sms=2479B630A6BD8079")!)
                    Text(AppText.text("站間車程來自交通部運輸資料流通服務平臺（TDX）；來源不足時仍標示估計。"))
                    Link("TDX", destination: URL(string: "https://tdx.transportdata.tw/")!)
                    Text(AppText.text("捷運路線、出口與車程採用官方資料。即時列車資料未啟用時，候車標示為班距估計。"))
                    Link(AppText.text("捷運資料說明"),destination:URL(string:"https://www.metro.taipei/cp.aspx?n=BDEB860F2BE3E249")!)
                    Text(AppText.text("YouBike 站點內建於 App。App 使用期間會預先載入臺北市公開的車輛與空位資料，供自行車路線比較，並保留近期報告供再次開啟使用。資料約每分鐘更新，實際借還以現場為準。目前不含新北市站點。"))
                    Text(AppText.text("路線規劃會在借車站有車、還車站有空位時才提出 YouBike 方案；沒有即時車位資料就不提出。"))
                    Link(AppText.text("YouBike 資料說明"), destination: URL(string: "https://data.taipei/dataset/detail?id=c6bc8aed-557d-41d5-bfb1-8da24f78f2fb")!)
                }
                Section(AppText.text("地圖")) {
                    Toggle(AppText.text("選車時淡化建築"), isOn: $model.highlightVehicle)
                    if live.display.bikeStations {
                        Toggle(AppText.text("顯示 YouBike 站點"), isOn: $model.bikeStationsOn)
                            .accessibilityIdentifier("bike-stations-toggle")
                        Text(live.text("放大到街道尺度時顯示 YouBike 2.0 站點，點站點可看可借車輛與可還空位。"))
                    }
                    Text(live.text("原生 MapLibre / Metal 地圖，使用 OpenFreeMap 底圖；地形陰影以 AWS Terrain Tiles 預先製作並內建於 App。道路匹配受 GPS 與軌跡精度影響。"))
                    Link("OpenFreeMap", destination: URL(string: "https://openfreemap.org")!)
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    NavigationLink(AppText.text("開源授權")) { LicenseView() }
                }
                Section(AppText.text("定位")) {
                    Text(live.text("定位只在使用期間尋找附近站牌，可直接手動搜尋；位置不會傳到公車資料來源。"))
                    Button(live.text("開啟系統設定")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section {
                    NavigationLink(AppText.text("交通公告")) { OfficialNoticesView() }
                        .accessibilityIdentifier("official-service-notices")
                }
                Section(AppText.text("隱私")) {
                    NavigationLink(AppText.text("隱私權說明")) { PrivacyExplanationView() }
                    Link(AppText.text("完整隱私政策"), destination: URL(string: "https://rio10255254.github.io/TaipeiBus/privacy.html")!)
                        .accessibilityIdentifier("app-privacy-policy")
                    Link(AppText.text("支援與聯絡"), destination: URL(string: "https://rio10255254.github.io/TaipeiBus/support.html")!)
                        .accessibilityIdentifier("app-support")
                    ShareLink(item:diagnostics.report) {
                        Label(AppText.text("分享路線規劃紀錄"),systemImage:"square.and.arrow.up")
                    }.accessibilityIdentifier("share-journey-diagnostics")
                }
                if testerBuild {
                    Section {
                        NavigationLink(AppText.text("AI 測試")) { JourneyBenchmarkView() }
                            .accessibilityIdentifier("settings-ai-benchmark")
                    } footer: { Text(AppText.text("只在測試版顯示。")) }
                }
            }
            .task { testerBuild = await JourneyBenchmark.testerBuild() }
            .smoothChanges(model.language)
            .navigationTitle(AppText.text("資訊與設定")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(live.text("完成")) { dismiss() } } }
        }
    }
}

private struct PrivacyExplanationView: View {
    @Environment(\.liveSettings) private var live
    var body: some View {
        List {
            Section(AppText.text("智慧輔助與相機")) {
                Text(AppText.text("開啟交通公告時會下載公運處公開新聞稿，不傳送位置或行程；重點摘錄在手機上進行，並保留全文與原文連結。"))
                Text(AppText.text("同意使用線上 AI 理解後，行程那一句話和日期會傳給 Groq 上的開源模型讀懂；未同意或沒有網路時，只在手機上理解。確認後的地點關鍵字與路線起終點仍由 Apple 地圖處理。"))
                Text(AppText.text("按麥克風或對 Siri 說出行程時，聲音只用來轉成文字（支援時在手機上辨識），不儲存錄音。最近說過的句子只存在這支手機，可長按移除。"))
                Text(AppText.text("掃描車牌才會請求相機權限；影像在手機辨識，不儲存或上傳。拒絕權限仍可手動選車。"))
                Text(AppText.text("通勤提示預設關閉。開啟後只在手機保存已儲存行程的識別碼與開始時間，最多 42 天；可在設定清除，關閉也會清除。"))
            }
            Section(AppText.text("你的位置")) {
                Text(AppText.text("定位為選用，只在使用 App 時尋找附近站牌、規劃行程與定位地圖。也能拒絕定位，手動選擇出發地、站牌或路線。App 不會將定位座標加入公車資料查詢。"))
                Text(AppText.text("地點搜尋與步行路線由 Apple 地圖提供；搜尋文字及路線起終點由 Apple 處理。"))
                Text(AppText.text("地圖供應者會收到目前畫面需要的圖磚請求及網路連線資訊，因此可能得知你正在查看的大致區域。"))
            }
            Section(AppText.text("內容更新")) {
                Text(AppText.text("搜尋別名、文字、外觀、既有搭車設定與共用車程資料會從 GitHub 下載。這個請求不包含定位或搜尋文字；GitHub 會收到一般網路連線資訊。"))
            }
            Section(AppText.text("保存在手機")) {
                Text(AppText.text("收藏站牌、最近目的地、最近查看與地圖偏好保存在此裝置。App 沒有帳號、廣告或跨 App 追蹤，也未加入分析 SDK。"))
                Text(AppText.text("常用行程與個人路線偏好也保存在手機。Pro 購買由 Apple 處理；App 只確認訂閱權限，不讀取付款卡片資料。"))
            }
            Section(AppText.text("網路服務")) {
                Text(AppText.text("公車資料來自臺北市公開資料服務；底圖由 OpenFreeMap 提供。服務商可能依自己的政策處理連線紀錄。"))
                Text(AppText.text("App 使用期間會預先取得臺北市全市即時車位，供自行車路線比較，並在手機保留近期報告。這個請求不包含你的位置、目的地或選取的站點。"))
                Link(AppText.text("OpenFreeMap 隱私政策"), destination: URL(string: "https://openfreemap.org/privacy/")!)
            }
            Section(AppText.text("測試回饋")) {
                Text(AppText.text("透過 TestFlight 主動回報時，Apple 與開發者可能收到你提交的內容、截圖及診斷資訊。分享前請留意截圖是否包含你的位置。"))
            }
            Section(AppText.text("管理權限")) {
                Text(AppText.text("可在 iPhone 系統設定關閉定位。刪除 App 可移除其本機收藏與偏好。"))
                Link(AppText.text("完整隱私政策"), destination: URL(string: "https://rio10255254.github.io/TaipeiBus/privacy.html")!)
                Link(AppText.text("支援與聯絡"), destination: URL(string: "https://rio10255254.github.io/TaipeiBus/support.html")!)
            }
        }
        .navigationTitle(AppText.text("隱私權說明")).navigationBarTitleDisplayMode(.inline)
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
            .navigationTitle(AppText.text("開源授權")).navigationBarTitleDisplayMode(.inline)
    }
}

func distanceLabel(_ meters: Double) -> String {
    meters >= 1_000 ? String(format: "%.1f km", meters / 1_000) : "\(Int(meters.rounded())) m"
}


#if DEBUG
private struct DebugZoomPerformanceControls: View {
    private let modes = ["baseline", "no-poi", "legacy-poi", "flat-view", "3d-view", "light-tick", "old-labels", "60hz", "begin", "end"]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 4), count: 5), spacing: 4) {
            ForEach(modes, id: \.self) { mode in
                Button(mode) { NotificationCenter.default.post(name: Notification.Name("zoom-performance-control"), object: mode) }
                    .font(.system(size: 9)).frame(width: 58, height: 30)
                    .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityIdentifier("zoom-probe-" + mode).buttonStyle(.plain)
            }
        }.frame(width: 306)
    }
}
#endif

/// A solid accent circle: tinted Liquid Glass on iOS 26, plain colour before or with reduced transparency.
private struct TintedGlassCircle: ViewModifier {
    let tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular.tint(tint).interactive(), in: Circle())
        } else {
            content.background(tint, in: Circle())
        }
    }
}

/// How the voice assistant looks: a glow around the edge over the map, or a full screen.
private struct VoiceStyleSettings: View {
    @AppStorage(VoiceStyle.key) private var style = VoiceStyle.glow.rawValue
    var body: some View {
        Section {
            Picker(AppText.text("語音助理樣式"), selection: $style) {
                ForEach(VoiceStyle.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityIdentifier("voice-style-picker")
        } header: {
            Text(AppText.text("語音助理樣式"))
        } footer: {
            Text(AppText.text("邊框光暈：螢幕邊緣發光，一邊看地圖一邊說，下方小卡片即時顯示聽到的話。全螢幕：專心說話的獨立畫面。"))
        }
    }
}

/// 線上理解: asked once before the first sentence goes online; changed here at any time.
private struct OnlineUnderstandingSettings: View {
    @AppStorage(OnlineJourneyReader.enabledKey) private var enabled = false
    var body: some View {
        Section {
            Toggle(AppText.text("使用線上 AI 理解"), isOn: $enabled).accessibilityIdentifier("online-understanding-toggle")
        } header: {
            Text(AppText.text("用一句話規劃"))
        } footer: {
            Text(AppText.text("開啟時，你說或打的那一句話、今天日期，以及需要時搜尋到的地點名稱與地址，會先傳給 Groq 上的開源模型（OpenAI gpt-oss）讀懂，不傳送位置、常用行程或帳號；沒有網路或額度用完時改用手機上的模型或規則。免費版每天 %@ 次，Pro 每天 %@ 次並使用更大的模型。",
                              "\(OnlineJourneyReader.dailyLimit(pro: false))", "\(OnlineJourneyReader.dailyLimit(pro: true))"))
        }
    }
}
