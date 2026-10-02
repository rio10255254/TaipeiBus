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
    case route(String)
    case vehicle(String)
    case journey([Coordinate])
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
    @Published var direction = "0"
    @Published var following = false
    @Published var highlightVehicle = true
    @Published var sheetDetent: PresentationDetent = .height(330)
    @Published var focus: MapFocus?
    @Published var focusRevision = 0
    @Published var selectionRevision = 0
    @Published var mapError: String?
    @Published private(set) var favorites: Set<String>
    @Published private(set) var recentStationIDs: [String]

    let location = LocationService()
    let planner = JourneyPlannerModel()
    private let service = TransitService()
    private var updateTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private var arrivalForecast = VehicleArrivalForecast()
#if DEBUG
    private var previewSelectionApplied = false
    @Published private(set) var previewNotice: String?
#endif

    init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteStations") ?? [])
        recentStationIDs = UserDefaults.standard.stringArray(forKey: "recentStations") ?? []
    }
    var selectedStation: Station? { selectedStationID.flatMap { metadata.stations[$0] } }
    var selectedRoute: BusRoute? { selectedRouteID.flatMap { metadata.route($0) } }
    var selectedVehicle: BusVehicle? { snapshot.vehicles.first { $0.id == selectedVehicleID } }
    var selectedRouteName: String? { selectedRoute.map { allRouteVariants ? $0.name : $0.displayName } }
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
        if !active { updateTask?.cancel(); updateTask = nil; return }
        location.requestIfAuthorized()
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                metadata = try await service.prepare()
                metadataNotice = await service.metadataNotice
                loading = false; loadError = nil
                while !Task.isCancelled {
                    let result = await service.refresh()
                    guard !Task.isCancelled else { return }
                    applySnapshot(result)
#if DEBUG
                    applyPreviewSelection()
#endif
                    try await Task.sleep(for: .seconds(15))
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
    func refresh() async {
        guard !loading, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let result = await service.refresh()
        if !Task.isCancelled, isActive { applySnapshot(result) }
    }

    private func applySnapshot(_ result: TransitSnapshot) {
        guard result.revision >= snapshot.revision else { return }
        snapshot = result
        arrivalForecast.ingest(result.vehicles, metadata: metadata, at: Date())
        planner.updateSnapshot(result)
        guard let id = selectedVehicleID else { return }
        guard let bus = result.vehicles.first(where: { $0.id == id }) else { following = false; return }
        // Follow a physical bus through a return trip or branch change, keeping its current route visible.
        if selectedRouteID != bus.routeID { selectedRouteID = bus.routeID }
        allRouteVariants = false
        if direction != bus.direction { direction = bus.direction }
    }

    func focusMap(_ target: MapFocus) { focus = target; focusRevision += 1 }
    func selectStation(_ station: Station) {
        recentStationIDs = [station.id] + Array(recentStationIDs.filter { $0 != station.id }.prefix(7))
        defaults.set(recentStationIDs, forKey: "recentStations")
        selectedStationID = station.id
        selectedRouteID = nil; allRouteVariants = true; selectedVehicleID = nil; following = false; query = ""
        focusMap(.coordinate(station.coordinate)); sheetDetent = .height(330)
        selectionRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func selectRoute(_ route: BusRoute, direction: String = "0", variantOnly: Bool = false) {
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
        selectedVehicleID = nil; selectedRouteID = nil; allRouteVariants = true; selectedStationID = nil; following = false
        sheetDetent = .height(330)
    }
    func toggleFavorite(_ station: Station) {
        if favorites.contains(station.id) { favorites.remove(station.id) } else { favorites.insert(station.id) }
        defaults.set(Array(favorites), forKey: "favoriteStations")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func stations(query: String) -> [Station] {
        let position = location.usableCoordinate?.isInServiceArea == true ? location.usableCoordinate! : .taipei
        return StationSearch.search(query, metadata: metadata, near: position, favorites: favorites, recent: recentStationIDs)
    }

    func arrivalEstimate(_ approach: VehicleApproach, ride: TransitRide, at date: Date) -> VehicleArrivalEstimate {
        arrivalForecast.estimate(approach, ride: ride, metadata: metadata, at: date)
    }

    /// Keep the boarding card visible while following the specific physical vehicle the user chose.
    func trackApproachingVehicle(_ vehicle: BusVehicle) {
        selectedVehicleID = vehicle.id; selectedRouteID = vehicle.routeID; allRouteVariants = false
        selectedStationID = nil; direction = vehicle.direction; following = true
        focusMap(.vehicle(vehicle.id))
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func routes(query: String) -> [RouteSearchResult] { metadata.routeCatalog.search(query) }
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
        return metadata.vehicles(routeID: id, direction: direction, allVariants: allRouteVariants, in: snapshot.vehicles)
    }

#if DEBUG
    // Simulator-only launch arguments let cloud builds capture real-data map states.
    // Release builds have no preview selection behavior.
    private func applyPreviewSelection() {
        guard !previewSelectionApplied else { return }
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        if let id = value(after: "--preview-station"), let station = metadata.stations[id] {
            selectStation(station); previewSelectionApplied = true
        } else if let name = value(after: "--preview-route"), let result = metadata.routeCatalog.search(name).first {
            selectRoute(result.route, direction: value(after: "--preview-direction") ?? "0", variantOnly: result.matchedVariant != nil)
            previewSelectionApplied = true
        } else if let text = value(after: "--preview-route-search") {
            mode = .routes; query = text; previewSelectionApplied = true
        } else if arguments.contains("--preview-place-audit") {
            previewSelectionApplied = true
            Task { await auditPlaces(token: value(after: "--preview-capture") ?? "") }
            return
        } else if arguments.contains("--preview-boarding-fixture") {
            previewSelectionApplied = prepareBoardingFixture(track: arguments.contains("--preview-track-next"))
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
                planner.setOrigin(TravelPlace(name: station.name, address: station.bearingLabel, coordinate: station.coordinate), metadata: metadata)
            }
            Task {
                let search = PlaceSearch()
                if let place = try? await search.resolve(text: name) {
                    planner.setDestination(place, metadata: metadata, currentLocation: origin)
                }
            }
        } else if let name = value(after: "--preview-vehicle-route") {
            let vehicles = snapshot.vehicles.filter { $0.routeName == name && $0.isFresh(at: Date()) }
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

    private func auditPlaces(token: String) async {
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let search = PlaceSearch()
        var results: [[String: Any]] = []
        var failure: String?
        for query in ["內湖站", "臺北車站", "臺北101"] {
            do {
                let places = try await search.find(text: query)
                let stations = Array(StationSearch.search(query, metadata: metadata, near: .taipei, limit: 4))
                results.append(["query": query, "places": places.map { ["name": $0.name, "latitude": $0.coordinate.latitude,
                    "longitude": $0.coordinate.longitude] as [String: Any] }, "stations": stations.map(\.name)])
                if places.isEmpty { failure = "Missing Apple results for \(query)" }
            } catch { failure = error.localizedDescription; break }
        }
        let result: [String: Any] = ["token": token, "results": results, "error": failure ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("place-search-audit.json"), options: .atomic)
        }
        try? Data(token.utf8).write(to: directory.appendingPathComponent("transit-preview-ready"), options: .atomic)
    }

    private func prepareBoardingFixture(track: Bool) -> Bool {
        let network = TripPlanner(metadata: metadata)
        var chosen: TransitTrip?
        for route in metadata.variants(routeID: metadata.routeCatalog.search("307").first?.route.id ?? "") {
            guard let journey = metadata.journey(routeID: route.id, direction: "0"), journey.anchors.count > 10 else { continue }
            let middle = journey.anchors.count / 2
            let trips = network.plan(from: journey.anchors[middle].stop.coordinate,
                to: journey.anchors[min(middle + 4, journey.anchors.count - 1)].stop.coordinate, maximumWalk: 20)
            chosen = trips.first { trip in
                guard trip.rides.count == 1, let ride = trip.rides.first,
                      let pattern = metadata.journey(routeID: ride.route.id, direction: ride.direction),
                      let boarding = pattern.anchors.first(where: { $0.stop.id == ride.boarding.id }) else { return false }
                return (boarding.match.along - pattern.anchors[0].match.along) * Double(pattern.direction) > 1_000
            }
            if chosen != nil { break }
        }
        guard let trip = chosen, let ride = trip.rides.first,
              let journey = metadata.journey(routeID: ride.route.id, direction: ride.direction),
              let line = metadata.line(ride.route.id, direction: ride.direction),
              let boarding = journey.anchors.first(where: { $0.stop.id == ride.boarding.id }) else { return false }
        let date = Date()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 28_800); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let rows = [100.0, 450, 900].enumerated().map { index, distance -> [String: Any] in
            let sample = line.sample(fraction: (boarding.match.along - distance * Double(journey.direction)) / line.length)
            return ["BusID": "TEST-0\(index + 1)", "CarID": "preview-\(index)", "RouteID": ride.route.id,
                "GoBack": ride.direction, "Latitude": sample.0.latitude, "Longitude": sample.0.longitude,
                "Speed": 25, "Azimuth": (sample.1 + (journey.direction < 0 ? 180 : 0)).truncatingRemainder(dividingBy: 360),
                "BusStatus": "0", "DutyStatus": "0", "DataTime": formatter.string(from: date)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["BusInfo": rows,
            "EssentialInfo": ["UpdateTime": formatter.string(from: date)]]),
              let result = try? FeedDecoder.vehicles(data, metadata: metadata, previous: [], now: date) else { return false }
        let estimates = EstimateFeed(seconds: ["\(ride.route.parentID):\(ride.boarding.id)": 240], updatedAt: date)
        applySnapshot(TransitSnapshot(vehicles: result.vehicles, sourceUpdatedAt: date, receivedAt: date,
                                      estimates: estimates, revision: snapshot.revision + 1))
        previewNotice = "介面驗證用資料 · 非即時車輛"
        planner.prepareBoardingPreview(trip)
        if track, let vehicle = BoardingGuide(ride: ride, metadata: metadata, snapshot: snapshot, at: date).approaches.first?.vehicle {
            trackApproachingVehicle(vehicle)
        }
        return true
    }
#endif
}
