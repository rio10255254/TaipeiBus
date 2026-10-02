import SwiftUI
import Combine
import UIKit
import TransitCore

enum BrowseMode: String, CaseIterable, Identifiable {
    case stops = "站牌", routes = "路線", vehicles = "車牌"
    var id: Self { self }
}

enum MapFocus {
    case coordinate(Coordinate)
    case route(String)
    case vehicle(String)
}

@MainActor
final class TransitAppModel: ObservableObject {
    @Published private(set) var metadata = TransitMetadata()
    @Published private(set) var snapshot = TransitSnapshot()
    @Published private(set) var loading = true
    @Published private(set) var loadError: String?
    @Published private(set) var metadataNotice: String?
    @Published private(set) var isActive = false
    @Published var mode: BrowseMode = .stops
    @Published var query = ""
    @Published var selectedStationID: String?
    @Published var selectedRouteID: String?
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

    let location = LocationService()
    private let service = TransitService()
    private var updateTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
#if DEBUG
    private var previewSelectionApplied = false
#endif

    init() { favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteStations") ?? []) }
    var selectedStation: Station? { selectedStationID.flatMap { metadata.stations[$0] } }
    var selectedRoute: BusRoute? { selectedRouteID.flatMap { metadata.route($0) } }
    var selectedVehicle: BusVehicle? { snapshot.vehicles.first { $0.id == selectedVehicleID } }

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
                    snapshot = result
                    if let id = selectedVehicleID, !snapshot.vehicles.contains(where: { $0.id == id }) { following = false }
#if DEBUG
                    applyPreviewSelection()
#endif
                    try await Task.sleep(for: .seconds(15))
                    // prepare() returns immediately while its daily metadata cache is fresh.
                    metadata = try await service.prepare()
                }
            } catch {
                if !Task.isCancelled { loading = false; loadError = "無法取得路線與站牌，請檢查網路後重試" }
            }
        }
    }

    func retry() { setActive(false); setActive(true) }
    func refresh() async {
        guard !loading else { return }
        snapshot = await service.refresh()
    }

    func focusMap(_ target: MapFocus) { focus = target; focusRevision += 1 }
    func selectStation(_ station: Station) {
        selectedStationID = station.id
        selectedRouteID = nil; selectedVehicleID = nil; following = false; query = ""
        focusMap(.coordinate(station.coordinate)); sheetDetent = .height(330)
        selectionRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func selectRoute(_ route: BusRoute, direction: String = "0") {
        selectedRouteID = route.id; self.direction = direction
        selectedStationID = nil; selectedVehicleID = nil; following = false; query = ""
        focusMap(.route(route.id)); sheetDetent = .height(330)
        selectionRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func selectVehicle(_ vehicle: BusVehicle) {
        selectedVehicleID = vehicle.id; selectedRouteID = vehicle.routeID
        selectedStationID = nil; direction = vehicle.direction; following = true; query = ""
        defaults.set(vehicle.id, forKey: "lastVehicleID")
        focusMap(.vehicle(vehicle.id)); sheetDetent = .height(330)
        selectionRevision += 1
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func clearSelection() {
        selectedVehicleID = nil; selectedRouteID = nil; selectedStationID = nil; following = false
        sheetDetent = .height(330)
    }
    func toggleFavorite(_ station: Station) {
        if favorites.contains(station.id) { favorites.remove(station.id) } else { favorites.insert(station.id) }
        defaults.set(Array(favorites), forKey: "favoriteStations")
        UISelectionFeedbackGenerator().selectionChanged()
    }
    func restoreVehicle() {
        guard let id = defaults.string(forKey: "lastVehicleID"),
              let bus = snapshot.vehicles.first(where: { $0.id == id }) else { return }
        selectVehicle(bus)
    }

    func stations(query: String) -> [Station] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let position = location.coordinate?.isInServiceArea == true ? location.coordinate! : .taipei
        return metadata.stations.values.filter {
            text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) || $0.address.localizedCaseInsensitiveContains(text)
        }.sorted {
            if text.isEmpty, favorites.contains($0.id) != favorites.contains($1.id) { return favorites.contains($0.id) }
            return $0.coordinate.distance(to: position) < $1.coordinate.distance(to: position)
        }.prefix(40).map { $0 }
    }
    func routes(query: String) -> [BusRoute] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return metadata.parents.values.filter {
            text.isEmpty || $0.name.localizedCaseInsensitiveContains(text) || $0.departure.contains(text) || $0.destination.contains(text)
        }.sorted {
            if $0.name == text || $1.name == text { return $0.name == text }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.prefix(60).map { $0 }
    }
    func vehicles(query: String) -> [BusVehicle] {
        snapshot.vehicles.filter { query.isEmpty || $0.plate.localizedCaseInsensitiveContains(query) || $0.routeName.contains(query) }
            .sorted { $0.observedAt > $1.observedAt }.prefix(60).map { $0 }
    }
    func routeVehicles() -> [BusVehicle] {
        guard let route = selectedRoute else { return [] }
        return snapshot.vehicles.filter { $0.parentRouteID == route.parentID && $0.direction == direction }
            .sorted { $0.observedAt > $1.observedAt }
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
        } else if let name = value(after: "--preview-vehicle-route") {
            let vehicles = snapshot.vehicles.filter { $0.routeName == name && $0.isFresh(at: Date()) }
            let moving = vehicles.filter { $0.speed >= 5 && metadata.line($0.routeID) != nil }
            if let vehicle = (moving.isEmpty ? vehicles : moving)
                .min(by: { $0.coordinate.distance(to: .taipei) < $1.coordinate.distance(to: .taipei) }) {
                selectVehicle(vehicle); previewSelectionApplied = true
            }
        }
    }
#endif
}
