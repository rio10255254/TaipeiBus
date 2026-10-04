import SwiftUI
import Combine
import UIKit
import TransitCore

enum BrowseMode: String, CaseIterable, Identifiable {
    case stops = "站牌", routes = "路線"
    var id: Self { self }
}

enum MapFocus {
    case coordinate(Coordinate)
    case station(String)
    case userLocation
    case route(String)
    case vehicle(String)
    case journey([Coordinate])
    case cityOverview
    case returnToCity
    case leaveCity
}

enum UserMapMode: String { case free, north, heading }

private actor StationLookup {
    private var results: [String: [Station]] = [:]
    private var order: [String] = []
    func search(metadata: TransitMetadata, query: String, near point: Coordinate, favorites: Set<String>, recent: [String],
                limit: Int, settingsRevision: Int, vocabulary: SearchVocabulary) -> [Station] {
        let key = "\(metadata.revision):\(settingsRevision):\(query):\(point.latitude):\(point.longitude):\(favorites.sorted()):\(recent):\(limit)"
        if let value = results[key] { return value }
        let value = metadata.stationSearch.search(query, near: point, favorites: favorites, recent: recent, limit: limit, vocabulary: vocabulary)
        results[key] = value; order.append(key)
        if order.count > 24 { results.removeValue(forKey: order.removeFirst()) }
        return value
    }
}

@MainActor
final class TransitAppModel: ObservableObject {
    @Published private(set) var metadata = TransitMetadata()
    @Published private(set) var snapshot = TransitSnapshot()
    @Published private(set) var loading = true
    @Published private(set) var loadError: String?
    @Published private(set) var metadataNotice: String?
    @Published private(set) var isActive = false
    @Published private(set) var refreshing = false
    @Published var mode: BrowseMode = .stops
    @Published var query = ""
    @Published var selectedStationID: String?
    @Published var selectedRouteID: String?
    @Published private(set) var allRouteVariants = true
    @Published var selectedVehicleID: String?
    struct BoardedVehicle {
        let rideID: String
        let vehicleID: String
        let plate: String
    }
    @Published private(set) var boardedVehicle: BoardedVehicle?
    private var boardedAt: Date?
    @Published var direction = "0"
    @Published var following = false
    @Published private(set) var cityFleetMode = false
    @Published var highlightVehicle = true
    @Published var sheetDetent: PresentationDetent = .height(330)
    @Published var focus: MapFocus?
    @Published var focusRevision = 0
    @Published var selectionRevision = 0
    @Published var mapError: String?
    @Published var mapWasMoved = false
    @Published private(set) var userMapMode: UserMapMode = .free
    @Published var stationBrowsing = false
    @Published private(set) var stationBrowseCenter: Coordinate?
    @Published var stationMapResults: [Station] = []
    private var browseQuery = ""
    private(set) var mapCenter: Coordinate?
    @Published private(set) var favorites: Set<String>
    @Published private(set) var recentStationIDs: [String]
    @Published private(set) var recentRouteIDs: [String]
    @Published private(set) var liveSettings = LiveSettings.defaults
    @Published private(set) var language = AppLanguage.current
    var presentationSettings: LiveSettings {
        var settings = liveSettings; settings.language = language; return settings
    }
    func setLanguage(_ value: AppLanguage) {
        guard value != language else { return }
#if DEBUG
        debugActions.append("language:" + value.rawValue)
#endif
        defaults.set(value.rawValue, forKey: AppLanguage.preferenceKey)
        language = value
        location.updateSettings(presentationSettings)
    }
    private(set) var vocabulary = SearchVocabulary()

    let location = LocationService()
    let planner = JourneyPlannerModel()
    private let service = TransitService()
    private var updateTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private let liveService: LiveSettingsService
    private let stationLookup = StationLookup()
    private let defaults = UserDefaults.standard
    private var arrivalForecast = VehicleArrivalForecast()
#if DEBUG
    private(set) var debugActions: [String] = []
    func recordMapTap(_ value: String) { debugActions.append(value) }
    private var previewSelectionApplied = false
    private var cityFixtureTask: Task<Void, Never>?
    @Published private(set) var previewNotice: String?
#endif

    init() {
        let saved = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey).flatMap(AppLanguage.init(rawValue:))
        var chosen = saved ?? AppLanguage.deviceDefault(Locale.preferredLanguages)
#if DEBUG
        let languageArguments = ProcessInfo.processInfo.arguments
        if let index = languageArguments.firstIndex(of: "--test-language"), languageArguments.indices.contains(index + 1),
           let forced = AppLanguage(rawValue: languageArguments[index + 1]) { chosen = forced }
#endif
        UserDefaults.standard.set(chosen.rawValue, forKey: AppLanguage.preferenceKey)
        language = chosen
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteStations") ?? [])
        recentStationIDs = UserDefaults.standard.stringArray(forKey: "recentStations") ?? []
        recentRouteIDs = UserDefaults.standard.stringArray(forKey: "recentRoutes") ?? []
        var source = LiveSettingsService.productionURL
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--preview-config-url"), arguments.indices.contains(index + 1),
           let url = URL(string: arguments[index + 1]),
           url.absoluteString.hasPrefix("https://raw.githubusercontent.com/rio10255254/TaipeiBus/") { source = url }
#endif
        liveService = LiveSettingsService(url: source,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.2",
            cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveSettings"))
    }
    var selectedStation: Station? { selectedStationID.flatMap { metadata.stations[$0] } }
    var selectedRoute: BusRoute? { selectedRouteID.flatMap { metadata.route($0) } }
    var selectedVehicle: BusVehicle? { snapshot.vehicles.first { $0.id == selectedVehicleID } }
    var selectedRouteName: String? { selectedRoute.map { allRouteVariants ? $0.localizedName : $0.localizedDisplayName } }
    var routeVariants: [BusRoute] { selectedRouteID.map { metadata.variants(routeID: $0) } ?? [] }
    var routeDirections: [String] {
        selectedRouteID.map { metadata.directions(routeID: $0, allVariants: allRouteVariants) } ?? ["0", "1"]
    }
    var routeStops: [BusStop] {
        selectedRouteID.map { metadata.displayStops(routeID: $0, direction: direction, allVariants: allRouteVariants) } ?? []
    }
    var routePaths: [[Coordinate]] {
        selectedRouteID.map { metadata.displayPaths(routeID: $0, direction: direction, allVariants: allRouteVariants) } ?? []
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        location.setActive(active)
        if !active { updateTask?.cancel(); updateTask = nil; settingsTask?.cancel(); settingsTask = nil; return }
        settingsTask = Task { [weak self] in
            guard let self else { return }
            if let cached = await liveService.cached() { await applyLiveSettings(cached) }
            while !Task.isCancelled {
                if let packet = await liveService.refresh(current: liveSettings), !Task.isCancelled { await applyLiveSettings(packet) }
                var interval = liveSettings.refresh.settingsSeconds
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--preview-live-update") { interval = 5 }
#endif
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let cached = await service.cachedMetadata() { metadata = cached; loading = false; loadError = nil }
                async let prepared = service.prepare()
                if !metadata.routes.isEmpty {
                    let current = await service.refresh(onPartial: { [weak self] value in await self?.receivePartialSnapshot(value) })
                    guard !Task.isCancelled else { return }
                    applySnapshot(current)
                }
                metadata = try await prepared
                metadataNotice = await service.metadataNotice
                loading = false; loadError = nil
                while !Task.isCancelled {
                    location.requestIfAuthorized()
                    let requestStartedAt = ProcessInfo.processInfo.systemUptime
                    let result = await service.refresh(onPartial: { [weak self] value in await self?.receivePartialSnapshot(value) })
                    guard !Task.isCancelled else { return }
                    applySnapshot(result)
#if DEBUG
                    applyPreviewSelection()
#endif
                    let interval = min(liveSettings.refresh.vehicleSeconds, liveSettings.refresh.trackingSeconds)
                    let elapsed = ProcessInfo.processInfo.systemUptime - requestStartedAt
                    try await Task.sleep(for: .seconds(max(0.25, interval - elapsed)))
                    // prepare() returns immediately while its daily metadata cache is fresh.
                    metadata = try await service.prepare()
                    metadataNotice = await service.metadataNotice
                }
            } catch {
                if !Task.isCancelled { loading = false; loadError = "無法取得路線與站牌，請檢查網路後重試" }
            }
        }
    }

    func retry() { setActive(false); setActive(true) }
    private func applyLiveSettings(_ packet: LiveSettingsPacket) async {
        guard packet.settings.revision >= liveSettings.revision else { return }
        vocabulary = packet.vocabulary
        liveSettings = packet.settings
        location.updateSettings(packet.settings)
        planner.updateSettings(packet.settings)
        await service.updateSettings(packet.settings)
#if DEBUG
        markLiveSettingsPreview()
#endif
    }
    func refresh() async {
        guard !loading, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let packet = liveService.refresh(current: liveSettings)
        let result = await service.refresh(onPartial: { [weak self] value in await self?.receivePartialSnapshot(value) })
        if !Task.isCancelled, isActive { applySnapshot(result) }
        if let update = await packet, !Task.isCancelled, isActive { await applyLiveSettings(update) }
    }

    private func receivePartialSnapshot(_ result: TransitSnapshot) {
        guard isActive else { return }
        applySnapshot(result)
    }

    private func applySnapshot(_ result: TransitSnapshot) {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--usability-fixture"), previewNotice != nil { return }
#endif
        guard result.revision > snapshot.revision else { return }
        snapshot = result
        arrivalForecast.ingest(result.vehicles, metadata: metadata, at: Date())
        planner.updateSnapshot(result, forecast: arrivalForecast)
#if DEBUG
        markLiveSettingsPreview()
#endif
        guard let id = selectedVehicleID else { return }
        guard let bus = result.vehicles.first(where: { $0.id == id }) else { following = false; return }
        // Follow a physical bus through a return trip or branch change, keeping its current route visible.
        if selectedRouteID != bus.routeID { selectedRouteID = bus.routeID }
        allRouteVariants = false
        if direction != bus.direction { direction = bus.direction }
    }

    @Published private(set) var walkingMapIndex: Int?
    func clearWalkingMap() { walkingMapIndex = nil }
    func focusMap(_ target: MapFocus) {
        if case .userLocation = target {} else { stopUserTracking() }
        mapWasMoved = false; focus = target; focusRevision += 1
    }
    func stopUserTracking() { userMapMode = .free }
    func cycleUserTracking() {
        cityFleetMode = false
        let next: UserMapMode = userMapMode == .north ? .heading : .north
        if planner.selected == nil { clearSelection() }
        following = false; walkingMapIndex = nil
        userMapMode = next
        location.request(); focusMap(.userLocation)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func beginStationBrowsing() {
        stationBrowsing = true
        let point = [location.usableCoordinate, mapCenter].compactMap { $0 }.first { $0.isInServiceArea } ?? .taipei
        stationBrowseCenter = point
        focusNearbyStations(around: point); sheetDetent = .height(390)
    }
    func focusNearbyStations(around point: Coordinate) {
        let nearby = metadata.stations.values.filter { $0.coordinate.distance(to: point) <= 800 }
            .sorted { $0.coordinate.distance(to: point) < $1.coordinate.distance(to: point) }
        focusMap(.journey([point] + nearby.prefix(8).map(\.coordinate)))
    }
    func mapCenterChanged(_ point: Coordinate) {
        mapCenter = point
        if stationBrowsing, stationBrowseCenter.map({ $0.distance(to: point) > 30 }) ?? true { stationBrowseCenter = point }
    }
    func browseNearMe() {
        location.request()
        if let point = location.displayCoordinate, point.isInServiceArea {
            query = ""; stationBrowseCenter = point; focusNearbyStations(around: point)
        }
        sheetDetent = .height(390)
    }
    func returnToBrowse() {
        clearSelection(); query = browseQuery
        stationBrowsing = mode == .stops
        sheetDetent = mode == .stops ? .height(390) : .large
    }
    func showWalkOnMap(_ index: Int) {
        guard let option = planner.selected, option.walks.indices.contains(index) else { return }
        let walk = option.walks[index]
        walkingMapIndex = index
        following = false
        focusMap(.journey(walk.coordinates.isEmpty ? [walk.from, walk.to] : walk.coordinates))
    }
    func selectStation(_ station: Station) {
        if selectedStationID == nil { browseQuery = query }
        stationBrowsing = false
        recentStationIDs = [station.id] + Array(recentStationIDs.filter { $0 != station.id }.prefix(7))
        defaults.set(recentStationIDs, forKey: "recentStations")
        selectedStationID = station.id
        selectedRouteID = nil; allRouteVariants = true; selectedVehicleID = nil; following = false; query = ""
        focusMap(.station(station.id)); sheetDetent = .height(330)
        selectionRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func selectRoute(_ route: BusRoute, direction: String = "0", variantOnly: Bool = false) {
        recentRouteIDs = [route.parentID] + Array(recentRouteIDs.filter { $0 != route.parentID }.prefix(7))
        defaults.set(recentRouteIDs, forKey: "recentRoutes")
        if selectedRouteID == nil { browseQuery = query }
        stationBrowsing = false
        selectedRouteID = route.id; allRouteVariants = !variantOnly
        let available = metadata.directions(routeID: route.id, allVariants: !variantOnly)
        self.direction = available.contains(direction) ? direction : available.first ?? "0"
        selectedStationID = nil; selectedVehicleID = nil; following = false; query = ""
        focusMap(.route(route.id)); sheetDetent = .height(330)
        selectionRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func selectVehicle(_ vehicle: BusVehicle) {
        selectedVehicleID = vehicle.id; selectedRouteID = vehicle.routeID; allRouteVariants = false
        selectedStationID = nil; direction = vehicle.direction; following = true; query = ""
        focusMap(.vehicle(vehicle.id)); sheetDetent = .height(330)
        selectionRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func toggleCityFleet() {
        if cityFleetMode {
            cityFleetMode = false; clearSelection(); focusMap(.leaveCity)
        } else {
            clearSelection(); stationBrowsing = false; cityFleetMode = true
            focusMap(.cityOverview)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func leaveCityForJourney() { cityFleetMode = false }
    var cityVehicles: [BusVehicle] {
        let now = Date()
        return snapshot.vehicles.filter { $0.hasReliablePosition(at: now) }
    }
    func changeRouteVariant(_ variant: BusRoute?) {
        guard let selected = selectedRoute else { return }
        let route = variant ?? metadata.parents[selected.parentID] ?? selected
        selectedRouteID = route.id; allRouteVariants = variant == nil
        let available = metadata.directions(routeID: route.id, allVariants: allRouteVariants)
        if !available.contains(direction) { direction = available.first ?? "0" }
        selectedVehicleID = nil; following = false
        focusMap(.route(route.id))
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func clearSelection() {
#if DEBUG
        debugActions.append("clear-selection")
#endif
        let returningToCity = cityFleetMode && (selectedVehicleID != nil || selectedRouteID != nil || selectedStationID != nil)
        selectedVehicleID = nil; selectedRouteID = nil; allRouteVariants = true; selectedStationID = nil; following = false
        sheetDetent = .height(330)
        if returningToCity { focusMap(.returnToCity) }
    }
    func toggleFavorite(_ station: Station) {
        if favorites.contains(station.id) { favorites.remove(station.id) } else { favorites.insert(station.id) }
        defaults.set(Array(favorites), forKey: "favoriteStations")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func stations(query: String) -> [Station] {
        let position = location.usableCoordinate?.isInServiceArea == true ? location.usableCoordinate! : .taipei
        return metadata.stationSearch.search(query, near: position, favorites: favorites, recent: recentStationIDs, vocabulary: vocabulary)
    }
    var stationSearchContextKey: String {
        "\(metadata.revision):\(liveSettings.revision):\(location.revision):\(favorites.sorted()):\(recentStationIDs):\(stationBrowsing):\(stationBrowseCenter?.latitude ?? 0):\(stationBrowseCenter?.longitude ?? 0)"
    }
    func findStations(query: String, limit: Int = 40) async -> [Station] {
        let userPoint = location.displayCoordinate.flatMap { $0.isInServiceArea ? $0 : nil } ?? .taipei
        let point = stationBrowsing ? stationBrowseCenter ?? userPoint : userPoint
        let results = await stationLookup.search(metadata: metadata, query: query, near: point, favorites: favorites,
            recent: recentStationIDs, limit: limit, settingsRevision: liveSettings.revision, vocabulary: vocabulary)
        if stationBrowsing, query.isEmpty {
            return results.filter { favorites.contains($0.id) || recentStationIDs.contains($0.id) || $0.coordinate.distance(to: point) <= 1_000 }
        }
        return results
    }

    func arrivalEstimate(_ approach: VehicleApproach, ride: TransitRide, at date: Date) -> VehicleArrivalEstimate {
        arrivalForecast.estimate(approach, ride: ride, metadata: metadata, at: date)
    }

    func arrivalPrediction(_ vehicle: BusVehicle, stopID: String, at date: Date, onboard: Bool = false) -> VehicleArrivalPrediction? {
        arrivalForecast.prediction(vehicle, stopID: stopID, metadata: metadata, at: date, allowTypicalWhenStopped: onboard)
    }

    func arrivalDisplay(_ vehicle: BusVehicle, stopID: String, at date: Date, onboard: Bool = false) -> VehicleArrivalDisplay {
        let official = onboard ? nil : snapshot.estimates.value(routeID: vehicle.parentRouteID, stopID: stopID, at: date)
        return arrivalForecast.display(vehicle, stopID: stopID, metadata: metadata, at: date,
            officialSeconds: official, allowTypicalWhenStopped: onboard)
    }

    func journeyDuration(_ option: JourneyOption, at date: Date) -> JourneyDuration? {
        guard option.verified, option.walkIssue == nil else { return nil }
        if option.id != planner.selectedID || (!planner.started && walkingMapIndex == nil) {
            return planner.duration(option, at: date)
        }
        if planner.arrived { return JourneyDuration(riding: [], walking: [0], arrivals: [], at: date) }
        let index: Int
        let onboard: Bool
        switch planner.currentStep {
        case .ride(let i): index = i; onboard = true
        case .walk(let i): index = i; onboard = false
        case nil: return planner.duration(option, at: date)
        }
        let remainingRides = Array(option.rides.dropFirst(index))
        var riding = remainingRides.map { arrivalForecast.ridingSeconds($0, metadata: metadata, at: date) }
        var walking = Array(option.walks.dropFirst(index)).compactMap(\.duration)
        if !onboard, option.walks.indices.contains(index), !walking.isEmpty,
           planner.started || planner.usingLocation,
           let point = location.usableCoordinate, let line = option.walks[index].road, line.length > 1,
           let match = line.match(point, heading: nil), match.distance < 45 {
            walking[0] *= max(0, min(1, (line.length - match.along) / line.length))
        }
        var arrivals = remainingRides.map { snapshot.estimates.value(routeID: $0.route.parentID, stopID: $0.boarding.id, at: date) }
        var positionUncertain = false
        if onboard, let first = remainingRides.first, !riding.isEmpty {
            if let bus = onboardVehicle(for: first), bus.hasReliablePosition(at: date),
               let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction),
               let progress = journey.progress(stopID: first.alighting.id, vehicle: bus, at: date) {
                if progress.distance < -20 { riding[0] = 0 }
                else if let prediction = arrivalForecast.prediction(bus, stopID: first.alighting.id, metadata: metadata, at: date, allowTypicalWhenStopped: true) {
                    riding[0] = prediction.seconds
                } else if let board = journey.anchors.first(where: { $0.stop.id == first.boarding.id }),
                          let alight = journey.anchors.first(where: { $0.stop.id == first.alighting.id }) {
                    let total = abs(alight.match.along - board.match.along)
                    if total > 1 { riding[0] *= min(1.5, max(0, progress.distance / total)) }
                }
            } else if let boardedAt {
                riding[0] = max(60, riding[0] - max(0, date.timeIntervalSince(boardedAt)))
                positionUncertain = true
            } else {
                positionUncertain = true
            }
            walking[0] = 0; arrivals[0] = 0
        }
        var duration = JourneyDuration(riding: riding, walking: walking, arrivals: arrivals,
            minimumServiceWaits: remainingRides.map { $0.route.minimumServiceWait(direction: $0.direction, at: date, fullRouteSeconds: $0.fullRouteSeconds) },
            services: remainingRides.map { $0.route.servicePlans[$0.direction]?.service(at: date) },
            boardingOffsets: remainingRides.map(\.boardingOffsetSeconds), at: date)
        duration.positionUncertain = positionUncertain
        return duration
    }

    func boardCurrentRide() {
        guard let ride = planner.activeRide else { return }
#if DEBUG
        debugActions.append("board:" + (selectedVehicle?.plate ?? "none") + ":" + String(selectedVehicle.map { metadata.canServe(ride, vehicle: $0) } ?? false))
#endif
        boardedAt = Date()
        boardedVehicle = nil
        if let bus = selectedVehicle, metadata.canServe(ride, vehicle: bus) {
            confirmBoardedVehicle(bus, ride: ride)
        }
        planner.boardCurrentRide()
    }

    func confirmBoardedVehicle(_ bus: BusVehicle, ride: TransitRide) {
        guard metadata.canServe(ride, vehicle: bus) else { return }
        boardedVehicle = BoardedVehicle(rideID: ride.id, vehicleID: bus.id, plate: bus.plate)
        trackApproachingVehicle(bus)
    }

    func onboardVehicle(for ride: TransitRide) -> BusVehicle? {
        guard let boardedVehicle, boardedVehicle.rideID == ride.id else { return nil }
        return snapshot.vehicles.first { $0.id == boardedVehicle.vehicleID && metadata.canServe(ride, vehicle: $0) }
    }

    func onboardPlate(for ride: TransitRide) -> String? {
        boardedVehicle.flatMap { $0.rideID == ride.id ? $0.plate : nil }
    }

    /// Boarding is confirmed by the rider. A delayed GPS fix must not put the
    /// boarding platform back into the remaining stops or continue past alighting.
    func onboardStops(for ride: TransitRide, at date: Date) -> [BusStop] {
        let planned = Array(ride.stops.dropFirst())
        guard let bus = onboardVehicle(for: ride), bus.hasReliablePosition(at: date),
              let journey = metadata.journey(routeID: bus.routeID, direction: bus.direction),
              journey.progress(stopID: ride.alighting.id, vehicle: bus, at: date) != nil else { return planned }
        // Keep unmapped intermediate platforms in the list until a later known
        // platform is passed. Missing geometry must not silently remove a stop.
        let passed = planned.indices.filter { index in
            journey.progress(stopID: planned[index].id, vehicle: bus, at: date).map { $0.distance < -20 } == true
        }
        return Array(planned.dropFirst((passed.max() ?? -1) + 1))
    }
    func onboardTimeLabel(_ bus: BusVehicle, ride: TransitRide, stopID: String, at date: Date) -> String {
        let display = arrivalDisplay(bus, stopID: stopID, at: date, onboard: true)
        guard let index = onboardStops(for: ride, at: date).firstIndex(where: { $0.id == stopID }) else { return display.label }
        let count = AppText.remainingStops(index + 1)
        return count + " · " + onboardEstimateLabel(bus, stopID: stopID, at: date)
    }
    func onboardEstimateLabel(_ bus: BusVehicle, stopID: String, at date: Date) -> String {
        let display = arrivalDisplay(bus, stopID: stopID, at: date, onboard: true)
        return display.prediction != nil ? display.label : AppText.text("時間待確認")
    }

    func returnToWaiting() {
        boardedVehicle = nil; planner.returnToWaiting()
        boardedAt = nil
    }
    func alight() { boardedVehicle = nil; boardedAt = nil; following = false; planner.advance() }
    func finishJourney() { boardedVehicle = nil; boardedAt = nil; planner.finish(); clearSelection() }

    /// Keep the boarding card visible while following the specific physical vehicle the user chose.
    func trackApproachingVehicle(_ vehicle: BusVehicle) {
#if DEBUG
        debugActions.append("track:" + vehicle.plate)
#endif
        walkingMapIndex = nil
        selectedVehicleID = vehicle.id; selectedRouteID = vehicle.routeID; allRouteVariants = false
        selectedStationID = nil; direction = vehicle.direction; following = true
        focusMap(.vehicle(vehicle.id))
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func routes(query: String) -> [RouteSearchResult] {
        var seen = Set<String>()
        let terms = [query] + (vocabulary.placeQueries(StationSearch.cleanQuery(query)) ?? [])
        return terms.flatMap { metadata.routeCatalog.search($0) }.filter { seen.insert($0.id).inserted }
    }
    var browsingRoutes: [RouteSearchResult] {
        let results = routes(query: query)
        guard query.isEmpty else { return results }
        let recent = recentRouteIDs.compactMap { id in results.first { $0.id == id } }
        return recent + results.filter { !recentRouteIDs.contains($0.id) }
    }
    var upcomingStops: [StopProgress] {
        guard let vehicle = selectedVehicle else { return [] }
        return metadata.journey(routeID: vehicle.routeID, direction: vehicle.direction)?.upcoming(vehicle: vehicle, at: Date()) ?? []
    }
    func switchDirection() {
        guard let route = selectedRoute, let next = routeDirections.first(where: { $0 != direction }) else { return }
        selectRoute(route, direction: next, variantOnly: !allRouteVariants)
    }
    func oppositeStations(to station: Station) -> [Station] {
        metadata.stations.values.filter {
            $0.id != station.id && $0.name == station.name && $0.bearing != station.bearing &&
            $0.coordinate.distance(to: station.coordinate) < 250
        }.sorted { $0.coordinate.distance(to: station.coordinate) < $1.coordinate.distance(to: station.coordinate) }
    }
    func routeVehicles() -> [BusVehicle] {
        guard let id = selectedRouteID else { return [] }
        if let ride = planner.activeRide, metadata.routeIDs(serving: ride).contains(id), direction == ride.direction {
            return BoardingGuide.vehicles(ride: ride, metadata: metadata, snapshot: snapshot, at: Date(), approachingOnly: false).map(\.vehicle)
        }
        return metadata.vehicles(routeID: id, direction: direction, allVariants: allRouteVariants, in: snapshot.vehicles)
    }

#if DEBUG
    private func markLiveSettingsPreview() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--preview-live-update"), !metadata.stations.isEmpty, liveSettings.revision >= 1,
              let index = arguments.firstIndex(of: "--preview-capture"), arguments.indices.contains(index + 1),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let aliases = metadata.stationSearch.search("內湖月台", near: .taipei, vocabulary: vocabulary)
        let data: [String: Any] = [
            "token": arguments[index + 1], "pid": ProcessInfo.processInfo.processIdentifier,
            "content_revision": liveSettings.revision, "accent": liveSettings.appearance.accentColor,
            "search_label": liveSettings.text("搜尋目的地"), "station_label": liveSettings.text("公車站牌"),
            "alias_stations": aliases.map { ["id": $0.id, "name": $0.name] },
            "location_ready": location.usableCoordinate != nil,
            "first_location_milliseconds": location.firstUsableMilliseconds ?? -1,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "fixture": true
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: directory.appendingPathComponent("live-settings-state.json"), options: .atomic)
        }
    }

    // Simulator-only launch arguments let cloud builds capture real-data map states.
    // Release builds have no preview selection behavior.
    private func applyPreviewSelection() {
        guard !previewSelectionApplied else { return }
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if arguments.contains("--city-fleet-fixture") {
            previewSelectionApplied = true
            previewNotice = "2500 輛壓力測試資料"
            updateCityFixture(tick: 0)
            cityFixtureTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    let seconds = arguments.contains("--continuous-gps-fixture") ? 5.0 : 2.0
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    guard let self, self.isActive else { return }
                    tick += 1; self.updateCityFixture(tick: tick)
                }
            }
        } else if let id = value(after: "--preview-station"), let station = metadata.stations[id] {
            selectStation(station); previewSelectionApplied = true
        } else if let name = value(after: "--preview-route"), let result = metadata.routeCatalog.search(name).first {
            selectRoute(result.route, direction: value(after: "--preview-direction") ?? "0", variantOnly: result.matchedVariant != nil)
            previewSelectionApplied = true
        } else if let text = value(after: "--preview-route-search") {
            mode = .routes; query = text; previewSelectionApplied = true
        } else if arguments.contains("--preview-place-audit") {
            previewSelectionApplied = true
            Task { await auditPlaces(token: value(after: "--preview-capture") ?? "", group: value(after: "--preview-audit-group") ?? "transit") }
            return
        } else if arguments.contains("--preview-neihu-planning") {
            guard let station = metadata.stationSearch.search("內湖站", near: Coordinate(latitude: 25.0837, longitude: 121.5947)).first else { return }
            planner.setOrigin(TravelPlace(name: station.name, address: station.bearingLabel, coordinate: station.coordinate, englishName: station.englishName), metadata: metadata)
            let target = Coordinate(latitude: 25.0416, longitude: 121.5438)
            let english = metadata.stationSearch.search("捷運忠孝復興站", near: target).first?.englishName
            planner.setDestination(TravelPlace(name: "忠孝復興站", address: "", coordinate: target, englishName: english), metadata: metadata, currentLocation: nil)
            previewSelectionApplied = true
        } else if arguments.contains("--preview-boarding-fixture") || arguments.contains("--preview-browse-fixture") {
            previewSelectionApplied = prepareBoardingFixture(track: arguments.contains("--preview-track-next"),
                transfer: arguments.contains("--preview-transfer-fixture"), cooperated: arguments.contains("--preview-cooperated-fixture"),
                browse: arguments.contains("--preview-browse-fixture"))
            if let token = value(after: "--preview-capture"), previewSelectionApplied,
               let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? Data(token.utf8).write(to: directory.appendingPathComponent("transit-preview-ready"), options: .atomic)
            }
            return
        } else if arguments.contains("--preview-journey-search") {
            previewSelectionApplied = true
        } else if let name = value(after: "--preview-destination") {
            previewSelectionApplied = true
            let origin = Coordinate.taipei
            planner.useLocation(origin, metadata: metadata)
            if let id = value(after: "--preview-origin-station"), let station = metadata.stations[id] {
                planner.setOrigin(TravelPlace(name: station.name, address: station.bearingLabel, coordinate: station.coordinate, englishName: station.englishName), metadata: metadata)
            }
            Task {
                let search = PlaceSearch()
                if let place = try? await search.resolve(text: name) {
                    planner.setDestination(place, metadata: metadata, currentLocation: origin)
                }
            }
        } else if let name = value(after: "--preview-vehicle-route") {
            let vehicles = snapshot.vehicles.filter {
                (name == "__live__" || $0.routeName == name) && $0.isFresh(at: Date())
            }
            let moving = vehicles.filter { $0.speed >= 5 && metadata.line($0.routeID, direction: $0.direction) != nil }
            if let vehicle = (moving.isEmpty ? vehicles : moving)
                .min(by: { $0.coordinate.distance(to: .taipei) < $1.coordinate.distance(to: .taipei) }) {
                selectVehicle(vehicle); previewSelectionApplied = true
            }
        }
        if arguments.contains("--preview-destination") { return }
        let requestedSelection = ["--preview-station", "--preview-route", "--preview-route-search", "--preview-journey-search", "--preview-vehicle-route"]
            .contains(where: { arguments.contains($0) })
        // A unique capture token prevents cloud screenshots from racing live-feed preparation.
        if (!requestedSelection || previewSelectionApplied), let token = value(after: "--preview-capture"),
           let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? Data(token.utf8).write(to: directory.appendingPathComponent("transit-preview-ready"), options: .atomic)
        }
    }

    private func updateCityFixture(tick: Int) {
        let now = Date()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei"); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: now)
        var fixtureMetadata = TransitMetadata()
        for row in 0..<50 {
            let latitude = 25.015 + Double(row) * 0.0015
            fixtureMetadata.lines["route:CITY-\(row)"] = RouteLine(coordinates: [
                Coordinate(latitude: latitude, longitude: 121.44), Coordinate(latitude: latitude, longitude: 121.64)])
        }
        let rows: [[String: Any]] = (0..<2500).map { index in
            let latitude = 25.015 + Double(index / 50) * 0.0015
            let distance = ProcessInfo.processInfo.arguments.contains("--continuous-gps-fixture") ? 0.00006 : 0.000025
            let longitude = 121.45 + Double(index % 50) * 0.003 + Double(tick) * distance
            return ["BusID": "CITY-\(index)", "CarID": "CITY-\(index)", "RouteID": "CITY-\(index / 50)", "GoBack": "0",
                    "Latitude": latitude, "Longitude": longitude, "Azimuth": 90, "Speed": 5,
                    "DutyStatus": "1", "BusStatus": "0", "CarType": "1", "DataTime": timestamp]
        }
        let payload: [String: Any] = ["EssentialInfo": ["UpdateTime": timestamp], "BusInfo": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let decoded = try? FeedDecoder.vehicles(data, metadata: fixtureMetadata,
                    previous: snapshot.vehicles.filter { $0.plate.hasPrefix("CITY-") }, now: now) else { return }
        snapshot = TransitSnapshot(vehicles: decoded.vehicles, sourceUpdatedAt: now, receivedAt: now,
                                   estimates: EstimateFeed(), revision: snapshot.revision + 1)
    }
    func markJourneyPreviewReady() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--preview-destination"), !planner.planning, !planner.checkingWalks,
              planner.selected != nil, let index = arguments.firstIndex(of: "--preview-capture"),
              arguments.indices.contains(index + 1),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        if arguments.contains("--preview-journey-start"), !planner.started {
            planner.begin()
            if let step = arguments.firstIndex(of: "--preview-journey-step"), arguments.indices.contains(step + 1),
               let count = Int(arguments[step + 1]), count > 0 {
                for _ in 0..<min(count, planner.steps.count) { planner.advance() }
            }
        }
        guard !arguments.contains("--preview-journey-start") || planner.started, let option = planner.selected else { return }
        let phase: String
        if !planner.started { phase = "planning" }
        else {
            switch planner.currentStep {
            case .walk(_)?: phase = "walking"
            case .ride(_)?: phase = "riding"
            case nil: phase = "arrived"
            }
        }
        let state: [String: Any] = [
            "token": arguments[index + 1], "phase": phase, "started": planner.started,
            "destination": planner.destination?.name ?? "", "using_location": planner.usingLocation,
            "origin": planner.origin?.name ?? "",
            "rides": option.rides.map { ["route": $0.route.displayName, "direction": $0.direction,
                                        "boarding": $0.boarding.name, "alighting": $0.alighting.name,
                                        "boarding_eta_seconds": snapshot.estimates.value(routeID: $0.route.parentID, stopID: $0.boarding.id, at: Date()).map { String($0) } ?? "unknown"] },
            "walks": option.walks.map { ["verified": $0.verified, "points": $0.coordinates.count,
                                        "distance": $0.distance ?? -1, "seconds": $0.duration ?? -1] as [String: Any] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("transit-preview-journey.json"), options: .atomic)
        }
        try? Data(arguments[index + 1].utf8).write(to: directory.appendingPathComponent("transit-preview-ready"), options: .atomic)
    }

    private func auditPlaces(token: String, group: String) async {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let search = PlaceSearch()
        search.setRules(vocabulary: vocabulary, settings: liveSettings.search, revision: liveSettings.revision)
        var results: [[String: Any]] = []
        var failure: String?
        let queries: [String]
        switch group {
        case "expanded": queries = ["內湖捷運站", "我要去內湖站", "Neihu Station", "七張站", "南港展覽館站"]
        case "landmarks": queries = ["臺北車站", "臺北101", "台大", "三總", "小巨蛋"]
        case "addresses": queries = ["忠孝東路四段100號", "内湖站", "台北 內湖站"]
        default: queries = ["內湖站", "東湖站", "港墘站", "西門站"]
        }
        for query in queries {
            do {
                let hints = metadata.stationSearch.search(query, near: .taipei, limit: 4, vocabulary: vocabulary)
                search.setStationHints(hints)
                let places = try await search.find(text: query)
                let stations = metadata.stationSearch.search(query, near: .taipei, limit: 4)
                results.append(["query": query, "places": places.map { ["name": $0.name, "address": $0.address, "transit": $0.isTransitPlace ?? false, "latitude": $0.coordinate.latitude,
                    "longitude": $0.coordinate.longitude] as [String: Any] }, "stations": stations.map(\.name)])
                if places.isEmpty { failure = "Missing Apple results for \(query)" }
            } catch { failure = error.localizedDescription; break }
        }
        let result: [String: Any] = ["token": token, "group": group, "results": results, "error": failure ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("place-search-audit.json"), options: .atomic)
        }
        try? Data(token.utf8).write(to: directory.appendingPathComponent("transit-preview-ready"), options: .atomic)
    }

    private func prepareBoardingFixture(track: Bool, transfer: Bool = false, cooperated: Bool = false, browse: Bool = false) -> Bool {
        var planningMetadata = metadata
        if cooperated {
            planningMetadata.routes = metadata.routes.filter { $0.value.name == "630" }
            planningMetadata.rebuildRouteCatalog()
        }
        let network = TripPlanner(metadata: planningMetadata)
        var chosen: TransitTrip?
        if transfer {
            let destinations = [Coordinate(latitude: 25.0838, longitude: 121.5942),
                Coordinate(latitude: 25.0478, longitude: 121.5172), Coordinate(latitude: 25.1362, longitude: 121.4598)]
            for destination in destinations {
                chosen = network.plan(from: .taipei, to: destination, maximumWalk: 800, limit: 80).first { trip in
                    guard trip.rides.count == 2, let ride = trip.rides.first,
                          let pattern = metadata.journey(routeID: ride.route.id, direction: ride.direction),
                          let boarding = pattern.anchors.first(where: { $0.stop.id == ride.boarding.id }) else { return false }
                    return (boarding.match.along - pattern.anchors[0].match.along) * Double(pattern.direction) > 1_000
                }
                if chosen != nil { break }
            }
        } else {
        for route in metadata.variants(routeID: metadata.routeCatalog.search(cooperated ? "630" : "307").first?.route.id ?? "") {
            guard let journey = metadata.journey(routeID: route.id, direction: cooperated ? "1" : "0"), journey.anchors.count > 10 else { continue }
            let middle = journey.anchors.count / 2
            let trips = network.plan(from: journey.anchors[middle].stop.coordinate,
                to: journey.anchors[min(middle + 4, journey.anchors.count - 1)].stop.coordinate, maximumWalk: 20)
            chosen = trips.first { trip in
                guard trip.rides.count == 1, let ride = trip.rides.first,
                      let pattern = metadata.journey(routeID: ride.route.id, direction: ride.direction),
                      let boarding = pattern.anchors.first(where: { $0.stop.id == ride.boarding.id }) else { return false }
                if cooperated && !metadata.routeIDs(serving: ride).contains(where: {
                    $0 != ride.route.id && metadata.routes[$0] != nil && metadata.journey(routeID: $0, direction: ride.direction) != nil
                }) { return false }
                return (boarding.match.along - pattern.anchors[0].match.along) * Double(pattern.direction) > 1_000
            }
            if chosen != nil { break }
        }
        }
        guard let trip = chosen, let ride = trip.rides.first,
              let journey = metadata.journey(routeID: ride.route.id, direction: ride.direction),
              let line = metadata.line(ride.route.id, direction: ride.direction),
              let boarding = journey.anchors.first(where: { $0.stop.id == ride.boarding.id }) else { return false }
        let date = Date()
        let alternate = metadata.routeIDs(serving: ride).sorted().first {
            $0 != ride.route.id && metadata.routes[$0] != nil && metadata.journey(routeID: $0, direction: ride.direction) != nil
        }
        if cooperated && alternate == nil { return false }
        let vehicleRouteID = cooperated ? alternate! : ride.route.id
        let vehicleJourney = metadata.journey(routeID: vehicleRouteID, direction: ride.direction) ?? journey
        let vehicleLine = metadata.line(vehicleRouteID, direction: ride.direction) ?? line
        let vehicleBoarding = vehicleJourney.anchors.first { $0.stop.id == ride.boarding.id } ?? boarding
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 28_800); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let integrity = ProcessInfo.processInfo.arguments.contains("--preview-arrival-integrity")
        let distances = integrity ? [100.0, 800, 2_400, 3_000] : [100.0, 450, 900, 950]
        let rows = distances.enumerated().map { index, distance -> [String: Any] in
            let sample = vehicleLine.sample(fraction: (vehicleBoarding.match.along - distance * Double(vehicleJourney.direction)) / vehicleLine.length)
            return ["BusID": "TEST-0\(index + 1)", "CarID": "preview-\(index)", "RouteID": vehicleRouteID,
                "GoBack": ride.direction, "Latitude": sample.0.latitude, "Longitude": sample.0.longitude,
                "Speed": 25, "Azimuth": (sample.1 + (vehicleJourney.direction < 0 ? 180 : 0)).truncatingRemainder(dividingBy: 360),
                "BusStatus": "0", "DutyStatus": "0", "DataTime": formatter.string(from: date)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["BusInfo": rows,
            "EssentialInfo": ["UpdateTime": formatter.string(from: date)]]),
              let result = try? FeedDecoder.vehicles(data, metadata: metadata, previous: [], now: date) else { return false }
        if integrity {
            // One moving bus with three genuine timed observations; the other buses have only one fix.
            arrivalForecast = VehicleArrivalForecast()
            for age in [180.0, 90] {
                let past = date.addingTimeInterval(-age)
                let sample = vehicleLine.sample(fraction: (vehicleBoarding.match.along -
                    (distances[2] + age * (600 / 180.0)) * Double(vehicleJourney.direction)) / vehicleLine.length)
                var row = rows[2]
                row["Latitude"] = sample.0.latitude; row["Longitude"] = sample.0.longitude
                row["Speed"] = 12
                row["Azimuth"] = (sample.1 + (vehicleJourney.direction < 0 ? 180 : 0)).truncatingRemainder(dividingBy: 360)
                row["DataTime"] = formatter.string(from: past)
                guard let bytes = try? JSONSerialization.data(withJSONObject: ["BusInfo": [row],
                    "EssentialInfo": ["UpdateTime": formatter.string(from: past)]]),
                      let history = try? FeedDecoder.vehicles(bytes, metadata: metadata, previous: [], now: past) else { return false }
                arrivalForecast.ingest(history.vehicles, metadata: metadata, at: past)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-onboard-time-fixture") {
            for age in [90.0, 45] {
                let past = date.addingTimeInterval(-age)
                let sample = vehicleLine.sample(fraction: (vehicleBoarding.match.along -
                    (distances[0] + age * 5) * Double(vehicleJourney.direction)) / vehicleLine.length)
                var row = rows[0]
                row["Latitude"] = sample.0.latitude; row["Longitude"] = sample.0.longitude
                row["DataTime"] = formatter.string(from: past)
                guard let bytes = try? JSONSerialization.data(withJSONObject: ["BusInfo": [row],
                    "EssentialInfo": ["UpdateTime": formatter.string(from: past)]]),
                      let history = try? FeedDecoder.vehicles(bytes, metadata: metadata, previous: [], now: past) else { return false }
                arrivalForecast.ingest(history.vehicles, metadata: metadata, at: past)
            }
        }
        let estimates = EstimateFeed(seconds: Dictionary(uniqueKeysWithValues: trip.rides.map {
            ("\($0.route.parentID):\($0.boarding.id)", integrity ? 750 : 120)
        }), updatedAt: date)
        applySnapshot(TransitSnapshot(vehicles: result.vehicles, sourceUpdatedAt: date, receivedAt: date,
                                      estimates: estimates, revision: snapshot.revision + 1))
        previewNotice = "介面驗證用資料 · 非即時車輛"
        if browse {
            if let bus = snapshot.vehicles.first(where: { $0.plate == "TEST-01" }) { selectVehicle(bus) }
            return true
        }
        planner.prepareBoardingPreview(trip)
        if track, let vehicle = BoardingGuide(ride: ride, metadata: metadata, snapshot: snapshot, at: date).approaches.first?.vehicle {
            trackApproachingVehicle(vehicle)
        }
        return true
    }
#endif
}
