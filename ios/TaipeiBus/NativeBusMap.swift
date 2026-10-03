import SwiftUI
import MapLibre
import MetalKit
import TransitCore

struct NativeBusMap: UIViewRepresentable {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    let location: Coordinate?
    let bottomInset: CGFloat
    let topInset: CGFloat
    let reduceMotion: Bool
    let selectionOverlay: MapSelectionOverlay

    func makeCoordinator() -> Coordinator { Coordinator(model: model, overlay: selectionOverlay) }

    func makeUIView(context: Context) -> MLNMapView {
        let style = Bundle.main.url(forResource: "taipei", withExtension: "json")
        let map = MLNMapView(frame: .zero, styleURL: style)
        map.delegate = context.coordinator
        map.maximumZoomLevel = 20
        map.minimumZoomLevel = 9
        map.automaticallyAdjustsContentInset = false
        map.showsUserLocation = false // A single Core Location service owns permission and location requests.
        map.showsLogoView = false
        map.attributionButtonPosition = .bottomLeft
        map.attributionButtonMargins = CGPoint(x: 16, y: 12)
        map.compassViewPosition = .topRight
        map.compassViewMargins = CGPoint(x: 16, y: 12)
        // An altitude camera needs a laid-out viewport; zoom is safe before SwiftUI sizes the view.
        map.setCenter(Coordinate.taipei.locationCoordinate, zoomLevel: 17.2, animated: false)
        context.coordinator.attach(map)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectBus(_:)))
        tap.delegate = context.coordinator
        // Let the map's double-tap zoom win, while a single tap can select a 3D vehicle.
        for recognizer in map.gestureRecognizers ?? [] {
            if let existing = recognizer as? UITapGestureRecognizer, existing.numberOfTapsRequired == 2 { tap.require(toFail: existing) }
        }
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.model = model
        context.coordinator.reduceMotion = reduceMotion
        let inset = UIEdgeInsets(top: topInset, left: 12, bottom: bottomInset, right: 12)
        let viewportChanged = map.contentInset != inset
        if viewportChanged { map.contentInset = inset }
        context.coordinator.update(location: location, viewportChanged: viewportChanged)
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        coordinator.stop()
        map.delegate = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var model: TransitAppModel
        var reduceMotion = false
        private weak var map: MLNMapView?
        private var buses: NativeBusLayer?
        private var displayLink: CADisplayLink?
        private var lastSnapshotRevision = -1
        private var lastRouteKey = ""
        private var lastFocusRevision = -1
        private var lastFollowTime: CFTimeInterval = 0
        private var lastTickTime: CFTimeInterval = 0
        private var followSuspendedUntil: CFTimeInterval = 0
        private var lastPowerCheck: CFTimeInterval = 0
        private var lastMotionSetting: Bool?
        private var lastNearbyUpdate: CFTimeInterval = 0
        private var lastNearbyCenter: Coordinate?
        private var lastStationSearchKey = ""
        private var buildingOpacity = 1.0
        private var buildingOpacityTarget = 1.0
        private var buildingLayer: MLNFillExtrusionStyleLayer?
        private var lastStationID: String?
        private var lastLocation: Coordinate?
        private var pendingLocation: Coordinate?
        private var routeSource: MLNShapeSource?
        private var walkingSource: MLNShapeSource?
        private var tripStopsSource: MLNShapeSource?
        private var stationSource: MLNShapeSource?
        private var locationSource: MLNShapeSource?
        private var nearbySource: MLNShapeSource?
        private let overlay: MapSelectionOverlay
        private var lastMetadataCount = -1
        private var positionedInitialCamera = false
        private var lastAppearance: LiveSettings.Appearance?
#if DEBUG
        private var lastPreviewCameraSignature = ""
#endif

        init(model: TransitAppModel, overlay: MapSelectionOverlay) { self.model = model; self.overlay = overlay }
        func attach(_ map: MLNMapView) {
            self.map = map
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            let rate = Float(map.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: rate, preferred: rate)
            map.preferredFramesPerSecond = MLNMapViewPreferredFramesPerSecond(rawValue: Int(rate))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        func stop() { displayLink?.invalidate(); displayLink = nil }
        deinit { displayLink?.invalidate() }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            lastAppearance = nil
            buildingLayer = style.layer(withIdentifier: "building-3d") as? MLNFillExtrusionStyleLayer
            buildingOpacity = 1; buildingOpacityTarget = 1
            let route = MLNShapeSource(identifier: "selected-route", shape: nil, options: nil)
            style.addSource(route); routeSource = route
            let line = MLNLineStyleLayer(identifier: "selected-route-line", source: route)
            line.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
            line.lineWidth = NSExpression(forConstantValue: 4)
            line.lineOpacity = NSExpression(forConstantValue: 0.5)
            if let building = style.layer(withIdentifier: "building-3d") { style.insertLayer(line, below: building) }
            else { style.addLayer(line) }
            let walking = MLNShapeSource(identifier: "journey-walking", shape: nil, options: nil)
            style.addSource(walking); walkingSource = walking
            let walkingLine = MLNLineStyleLayer(identifier: "journey-walking-line", source: walking)
            walkingLine.lineColor = NSExpression(forConstantValue: UIColor.systemOrange)
            walkingLine.lineWidth = NSExpression(forConstantValue: 3)
            walkingLine.lineDashPattern = NSExpression(forConstantValue: [2, 2])
            if let building = style.layer(withIdentifier: "building-3d") { style.insertLayer(walkingLine, below: building) }
            else { style.addLayer(walkingLine) }
            let tripStops = MLNShapeSource(identifier: "journey-stops", shape: nil, options: nil)
            style.addSource(tripStops); tripStopsSource = tripStops
            let tripDots = MLNCircleStyleLayer(identifier: "journey-stop-dots", source: tripStops)
            tripDots.circleColor = NSExpression(forConstantValue: UIColor.systemBlue)
            tripDots.circleRadius = NSExpression(forConstantValue: 6)
            tripDots.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            tripDots.circleStrokeWidth = NSExpression(forConstantValue: 2)
            style.addLayer(tripDots)
            let tripNames = MLNSymbolStyleLayer(identifier: "journey-stop-names", source: tripStops)
            tripNames.text = NSExpression(forKeyPath: "name")
            tripNames.textFontSize = NSExpression(forConstantValue: 12)
            tripNames.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
            tripNames.textColor = NSExpression(forConstantValue: UIColor.darkGray)
            tripNames.textHaloColor = NSExpression(forConstantValue: UIColor.white)
            tripNames.textHaloWidth = NSExpression(forConstantValue: 2)
            tripNames.textTranslation = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: -16)))
            style.addLayer(tripNames)

            let layer = NativeBusLayer(identifier: "native-buses")
            layer.onError = { [weak self] message in
                DispatchQueue.main.async { self?.model.mapError = message }
            }
            layer.onSelectedPoint = { [weak self, weak mapView] point in
                guard let self, let mapView, self.model.selectedVehicleID != nil else { return }
                let global = point.map { mapView.convert($0, to: nil) }
                DispatchQueue.main.async { [weak self] in self?.overlay.update(global) }
            }
            style.addLayer(layer); buses = layer
            stationSource = addPointLayer(id: "selected-station", color: .systemBlue, radius: 7, style: style)
            locationSource = addPointLayer(id: "device-location", color: .systemBlue, radius: 5, style: style)
            let nearby = MLNShapeSource(identifier: "nearby-stations", shape: nil, options: nil)
            style.addSource(nearby); nearbySource = nearby
            let dots = MLNCircleStyleLayer(identifier: "nearby-station-dots", source: nearby)
            dots.minimumZoomLevel = 15.7
            dots.circleColor = NSExpression(forConstantValue: UIColor.systemBlue)
            dots.circleRadius = NSExpression(forConstantValue: 3)
            dots.circleStrokeWidth = NSExpression(forConstantValue: 1.5)
            dots.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            style.addLayer(dots)
            let names = MLNSymbolStyleLayer(identifier: "nearby-station-names", source: nearby)
            names.minimumZoomLevel = 15.7
            names.text = NSExpression(forKeyPath: "name")
            names.textFontSize = NSExpression(forConstantValue: 12)
            names.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
            names.textColor = NSExpression(forConstantValue: UIColor.darkGray)
            names.textHaloColor = NSExpression(forConstantValue: UIColor.white)
            names.textHaloWidth = NSExpression(forConstantValue: 2)
            names.textTranslation = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 13)))
            style.addLayer(names)
            lastSnapshotRevision = -1; lastRouteKey = ""; lastFocusRevision = -1
            lastStationID = nil; lastLocation = nil
            update(location: pendingLocation)
            updateNearbyStations(force: true)
        }

        private func addPointLayer(id: String, color: UIColor, radius: Double, style: MLNStyle) -> MLNShapeSource {
            let source = MLNShapeSource(identifier: id, shape: nil, options: nil)
            style.addSource(source)
            let layer = MLNCircleStyleLayer(identifier: "\(id)-dot", source: source)
            layer.circleColor = NSExpression(forConstantValue: color)
            layer.circleRadius = NSExpression(forConstantValue: radius)
            layer.circleStrokeWidth = NSExpression(forConstantValue: 3)
            layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            style.addLayer(layer)
            return source
        }

        func update(location: Coordinate?, viewportChanged: Bool = false) {
            pendingLocation = location
            displayLink?.isPaused = !model.isActive
            guard let map else { return }
            if !positionedInitialCamera, map.bounds.width > 0, map.bounds.height > 0 {
                positionedInitialCamera = true
                let first = location?.isInServiceArea == true ? location! : Coordinate.taipei
                map.setCamera(MLNMapCamera(lookingAtCenter: first.locationCoordinate,
                                          altitude: 650, pitch: 54, heading: 0), animated: false)
            }
            // Finish an explicit focus even when panels resize during the animation or tiles are still loading.
            let refit = viewportChanged && !model.mapWasMoved && model.selectedVehicleID == nil && model.focus != nil
            if (lastFocusRevision != model.focusRevision || refit), map.bounds.width > 0, map.bounds.height > 0 {
                focus(model.focus, map: map, animated: lastFocusRevision != model.focusRevision)
                lastFocusRevision = model.focusRevision
            }
            guard buses != nil else { return }
            if let style = map.style, lastAppearance != model.liveSettings.appearance {
                applyAppearance(style); lastAppearance = model.liveSettings.appearance
            }
            guard let buses else { return }
            if lastMetadataCount != model.metadata.stations.count {
                updateNearbyStations(force: true); lastMetadataCount = model.metadata.stations.count
            }
            let stationKey = "\(model.stationBrowsing):\(model.query):\(model.stationMapResults.map(\.id))"
            if stationKey != lastStationSearchKey { lastStationSearchKey = stationKey; updateNearbyStations(force: true) }
            let routeKey = "\(model.selectedRouteID ?? "all"):\(model.selectedRouteID == nil ? "all" : model.direction):\(model.allRouteVariants):trip\(model.planner.mapRevision):walk\(model.walkingMapIndex.map { String($0) } ?? "all")"
            if lastSnapshotRevision != model.snapshot.revision || routeKey != lastRouteKey || lastMotionSetting != reduceMotion {
                var vehicles = model.snapshot.vehicles
                if model.selectedRoute != nil { vehicles = model.routeVehicles() }
                else if let trip = model.planner.selected {
                    let rides = model.planner.started ? model.planner.activeRide.map { [$0] } ?? [] : trip.rides
                    vehicles = vehicles.filter { bus in rides.contains { $0.route.id == bus.routeID && $0.direction == bus.direction } }
                }
                if reduceMotion { vehicles = vehicles.map { var bus = $0; bus.path = [bus.coordinate]; return bus } }
                buses.ingest(vehicles, time: CACurrentMediaTime())
                lastSnapshotRevision = model.snapshot.revision
                lastMotionSetting = reduceMotion
            }
            if routeKey != lastRouteKey {
                let tripRides = model.planner.started ? model.planner.activeRide.map { [$0] } ?? [] : model.planner.selected?.rides ?? []
                let paths: [[Coordinate]] = model.selectedRouteID != nil ? model.routePaths : tripRides.map(\.coordinates).filter { $0.count >= 2 }
                let features = paths.map { path -> MLNPolylineFeature in
                    var coordinates = path.map(\.locationCoordinate)
                    return MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                }
                routeSource?.shape = features.isEmpty ? nil : MLNShapeCollectionFeature(shapes: features)
                var displayedWalks = model.planner.selected?.walks ?? []
                if let index = model.walkingMapIndex, displayedWalks.indices.contains(index) { displayedWalks = [displayedWalks[index]] }
                else if model.planner.started {
                    if case .walk(let index) = model.planner.currentStep { displayedWalks = [displayedWalks[index]] }
                    else { displayedWalks = [] }
                }
                let walks = displayedWalks.filter { $0.coordinates.count >= 2 }.map { walk -> MLNPolylineFeature in
                    var coordinates = walk.coordinates.map(\.locationCoordinate)
                    return MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                }
                walkingSource?.shape = walks.isEmpty ? nil : MLNShapeCollectionFeature(shapes: walks)
                updateTripStops()
                lastRouteKey = routeKey
            }
            buses.selectedID = model.selectedVehicleID
            buses.highlightSelected = model.highlightVehicle
            buses.reduceMotion = reduceMotion
            // Station dots remain tappable; their names must not cover the vehicle's anchored information.
            let hasVehicle = model.selectedVehicle != nil
            map.style?.layer(withIdentifier: "nearby-station-names")?.isVisible = !hasVehicle && model.planner.selected == nil
            buildingOpacityTarget = model.highlightVehicle && hasVehicle ? 0.26 : 1
            if reduceMotion {
                buildingOpacity = buildingOpacityTarget
                buildingLayer?.fillExtrusionOpacity = NSExpression(forConstantValue: buildingOpacity)
            }
            if lastStationID != model.selectedStationID {
                stationSource?.shape = point(model.selectedStation?.coordinate)
                lastStationID = model.selectedStationID
            }
            if model.selectedVehicleID == nil && model.selectedStationID == nil { overlay.update(nil) }
            if lastLocation != location {
                locationSource?.shape = point(location)
                lastLocation = location
            }
            buses.setNeedsDisplay()
            updateStationAnchor()
        }

        private func updateTripStops() {
            guard let option = model.planner.selected else { tripStopsSource?.shape = nil; return }
            var features: [String: MLNPointFeature] = [:]
            func add(_ coordinate: Coordinate, id: String, title: String) {
                let feature = MLNPointFeature(); feature.coordinate = coordinate.locationCoordinate
                feature.attributes = ["name": title, "stationID": id]; features[id] = feature
            }
            let visibleRides = option.rides.enumerated().filter { _, ride in
                !model.planner.started || model.planner.activeRide?.id == ride.id
            }
            for (index, ride) in visibleRides {
                add(ride.boarding.coordinate, id: ride.boarding.stationID, title: "\(index == 0 ? "上車" : "轉乘") · \(ride.boarding.name)")
                add(ride.alighting.coordinate, id: ride.alighting.stationID,
                    title: "\(index == option.rides.count - 1 ? "下車" : "轉乘") · \(ride.alighting.name)")
            }
            if let destination = model.planner.destination,
               model.planner.activeRide == nil || (!model.planner.started && (option.rides.last?.alighting.coordinate.distance(to: destination.coordinate) ?? 100) > 35) {
                add(destination.coordinate, id: "destination", title: destination.name)
            }
            tripStopsSource?.shape = MLNShapeCollectionFeature(shapes: features.keys.sorted().compactMap { features[$0] })
        }

        private func updateNearbyStations(force: Bool = false) {
            guard let map, nearbySource != nil else { return }
            let center = Coordinate(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
            let time = CACurrentMediaTime()
            if !force, let previous = lastNearbyCenter,
               time - lastNearbyUpdate < 0.5 || previous.distance(to: center) < 20 { return }
            lastNearbyCenter = center; lastNearbyUpdate = time
            let stations: [Station]
            if model.stationBrowsing, !model.query.isEmpty { stations = model.stationMapResults }
            else {
                stations = Array(model.metadata.stations.values.filter { $0.coordinate.distance(to: center) < 1_000 }
                    .sorted { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) }.prefix(model.stationBrowsing ? 32 : 18))
            }
            let features = stations.map { station -> MLNPointFeature in
                let feature = MLNPointFeature()
                feature.coordinate = station.coordinate.locationCoordinate
                feature.attributes = ["stationID": station.id, "name": "\(station.name) \(station.bearingLabel)"]
                return feature
            }
            nearbySource?.shape = MLNShapeCollectionFeature(shapes: features)
        }

        private func updateStationAnchor() {
            guard let map, let station = model.selectedStation else { return }
            let point = map.convert(station.coordinate.locationCoordinate, toPointTo: map)
            let visible = map.bounds.insetBy(dx: -20, dy: -20).contains(point)
            let global = visible ? map.convert(point, to: nil) : nil
            DispatchQueue.main.async { [weak self] in self?.overlay.update(global) }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            updateNearbyStations(force: true)
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            DispatchQueue.main.async { [weak self] in self?.model.mapCenterChanged(center) }
        }
        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
            if !positionedInitialCamera, mapView.bounds.width > 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.update(location: self.pendingLocation)
                }
            }
            updateStationAnchor()
#if DEBUG
            recordPreviewCamera(mapView, fullyRendered: fullyRendered)
            if ProcessInfo.processInfo.arguments.contains("--test-map-controls"), fullyRendered {
                let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
                let state: [String: Any] = ["latitude": center.latitude, "longitude": center.longitude, "zoom": mapView.zoomLevel,
                    "heading": mapView.direction, "pitch": mapView.camera.pitch, "mode": model.userMapMode.rawValue,
                    "station": model.selectedStationID ?? "", "stationDistance": model.selectedStation.map { center.distance(to: $0.coordinate) } ?? -1,
                    "queryMarkers": model.stationMapResults.count, "browsing": model.stationBrowsing]
                DispatchQueue.main.async { [weak self] in self?.overlay.recordCamera(state) }
            }
#endif
        }

        private func point(_ coordinate: Coordinate?) -> MLNPointFeature? {
            guard let coordinate else { return nil }
            let feature = MLNPointFeature()
            feature.coordinate = coordinate.locationCoordinate
            return feature
        }

        private func focus(_ focus: MapFocus?, map: MLNMapView, animated: Bool = true) {
            guard let focus else { return }
            switch focus {
            case .coordinate(let position):
                showPoint(position, altitude: 700, heading: 0, pitch: 0, map: map, animated: animated)
            case .station(let id):
                guard let station = model.metadata.stations[id] else { return }
                showPoint(station.coordinate, altitude: 480, heading: 0, pitch: 0, map: map, animated: animated)
            case .userLocation:
                guard let point = model.location.displayCoordinate, point.isInServiceArea else { return }
                let heading = model.userMapMode == .heading ? model.location.currentHeading ?? map.direction : 0
                showPoint(point, altitude: 600, heading: heading, pitch: model.userMapMode == .heading ? 45 : 0,
                          map: map, animated: animated)
            case .vehicle(let id):
                guard let bus = model.snapshot.vehicles.first(where: { $0.id == id }) else { return }
                let position = buses?.pose(id: id, time: CACurrentMediaTime(), now: Date())?.coordinate ?? bus.coordinate
                followSuspendedUntil = CACurrentMediaTime() + (reduceMotion ? 0 : 0.7)
                map.setCamera(MLNMapCamera(lookingAtCenter: position.locationCoordinate,
                                          altitude: 245, pitch: 57, heading: map.direction),
                              withDuration: reduceMotion ? 0 : 0.65,
                              animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut), completionHandler: nil)
            case .route(let id):
                var coordinates = model.metadata.displayPaths(routeID: id, direction: model.direction,
                                                               allVariants: model.allRouteVariants).flatMap { $0 }
                if coordinates.isEmpty {
                    coordinates = model.metadata.displayStops(routeID: id, direction: model.direction,
                                                               allVariants: model.allRouteVariants).map(\.coordinate)
                }
                if coordinates.isEmpty { coordinates = model.routeVehicles().map(\.coordinate) }
                fit(coordinates, map: map)
            case .journey(let coordinates): fit(coordinates, map: map)
            }
        }

        private func showPoint(_ point: Coordinate, altitude: Double, heading: Double, pitch: Double,
                               map: MLNMapView, animated: Bool) {
            followSuspendedUntil = CACurrentMediaTime() + (animated && !reduceMotion ? 0.65 : 0)
            map.setCamera(MLNMapCamera(lookingAtCenter: point.locationCoordinate, altitude: altitude, pitch: pitch, heading: heading),
                withDuration: animated && !reduceMotion ? 0.6 : 0,
                animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut), completionHandler: nil)
        }

        private func fit(_ coordinates: [Coordinate], map: MLNMapView) {
            guard let overview = RouteOverview(coordinates: coordinates,
                viewportWidth: Double(map.bounds.width - map.contentInset.left - map.contentInset.right),
                viewportHeight: Double(map.bounds.height - map.contentInset.top - map.contentInset.bottom)) else { return }
            map.setCamera(MLNMapCamera(lookingAtCenter: overview.center.locationCoordinate,
                                      altitude: 1000, pitch: 35, heading: 0), animated: false)
            map.setCenter(overview.center.locationCoordinate, zoomLevel: overview.zoom, animated: false)
        }

#if DEBUG
        private func recordPreviewCamera(_ map: MLNMapView, fullyRendered: Bool) {
            let arguments = ProcessInfo.processInfo.arguments
            guard fullyRendered, (model.selectedRoute != nil || model.planner.selected != nil), model.selectedVehicleID == nil,
                  lastFocusRevision == model.focusRevision,
                  let index = arguments.firstIndex(of: "--preview-capture"), arguments.indices.contains(index + 1) else { return }
            let center = map.centerCoordinate
            let signature = "\(model.focusRevision):\(map.contentInset.bottom):\(center.latitude):\(center.longitude):\(map.zoomLevel)"
            guard signature != lastPreviewCameraSignature else { return }
            let coordinates: [Coordinate]
            if case .journey(let points) = model.focus { coordinates = points }
            else { coordinates = model.routePaths.flatMap { $0 } }
            let expected = RouteOverview(coordinates: coordinates,
                viewportWidth: Double(map.bounds.width - map.contentInset.left - map.contentInset.right),
                viewportHeight: Double(map.bounds.height - map.contentInset.top - map.contentInset.bottom))
            let state: [String: Any] = ["token": arguments[index + 1], "route": model.selectedRouteName ?? model.planner.destination?.name ?? "",
                "latitude": center.latitude, "longitude": center.longitude, "zoom": map.zoomLevel, "fully_rendered": true,
                "expected_latitude": expected?.center.latitude ?? center.latitude,
                "expected_longitude": expected?.center.longitude ?? center.longitude,
                "expected_zoom": expected?.zoom ?? map.zoomLevel]
            guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
            try? data.write(to: directory.appendingPathComponent("transit-preview-map.json"), options: .atomic)
            lastPreviewCameraSignature = signature
        }
#endif

        @objc private func tick(_ link: CADisplayLink) {
            guard model.isActive, let map, let buses else { return }
            let now = CACurrentMediaTime(), date = Date()
            let dt = lastTickTime > 0 ? min(0.1, max(0.001, now - lastTickTime)) : 1 / 60
            lastTickTime = now
            if now - lastPowerCheck > 1 {
                let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                let maximum = map.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
                let rate = lowPower || reduceMotion ? 30 : maximum
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(rate), preferred: Float(rate))
                map.preferredFramesPerSecond = MLNMapViewPreferredFramesPerSecond(rawValue: rate)
                lastPowerCheck = now
            }
            if buses.isAnimating(time: now, now: date) { buses.setNeedsDisplay() }
            if abs(buildingOpacityTarget - buildingOpacity) > 0.001 {
                buildingOpacity += (buildingOpacityTarget - buildingOpacity) * (1 - exp(-dt / 0.13))
                if abs(buildingOpacityTarget - buildingOpacity) < 0.003 { buildingOpacity = buildingOpacityTarget }
                buildingLayer?.fillExtrusionOpacity = NSExpression(forConstantValue: buildingOpacity)
            }
            if model.userMapMode != .free, now >= followSuspendedUntil,
               let point = model.location.displayCoordinate, point.isInServiceArea {
                let camera = map.camera
                let center = Coordinate(latitude: camera.centerCoordinate.latitude, longitude: camera.centerCoordinate.longitude)
                let heading = model.userMapMode == .north ? 0 : model.location.currentHeading ?? camera.heading
                let delta = (heading - camera.heading + 540).truncatingRemainder(dividingBy: 360) - 180
                if center.distance(to: point) > 0.2 || abs(delta) > 0.15 {
                    let fraction = reduceMotion ? 1 : 1 - exp(-dt / 0.18)
                    camera.centerCoordinate = center.interpolate(to: point, fraction: fraction).locationCoordinate
                    camera.heading = (camera.heading + delta * fraction + 360).truncatingRemainder(dividingBy: 360)
                    map.setCamera(camera, animated: false)
                }
            }
            if model.following, now >= followSuspendedUntil, let id = model.selectedVehicleID,
               !reduceMotion || now - lastFollowTime > 0.25,
               let pose = buses.pose(id: id, time: now, now: date), !pose.stale {
                let center = Coordinate(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
                if center.distance(to: pose.coordinate) > (reduceMotion ? 0.5 : 0.015) {
                    let camera = map.camera
                    let target = center.interpolate(to: pose.coordinate, fraction: reduceMotion ? 1 : 1 - exp(-dt / 0.10))
                    camera.centerCoordinate = target.locationCoordinate
                    map.setCamera(camera, animated: false)
                }
                lastFollowTime = now
            }
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureTilt, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom]
            if !reason.intersection(gestures).isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.model.mapWasMoved = true
                    self?.model.following = false
                    self?.model.stopUserTracking()
                }
            }
        }

        private func applyAppearance(_ style: MLNStyle) {
            let theme = model.liveSettings.appearance
            let accent = NSExpression(forConstantValue: UIColor(liveHex: theme.accentColor))
            (style.layer(withIdentifier: "selected-route-line") as? MLNLineStyleLayer)?.lineColor = accent
            (style.layer(withIdentifier: "journey-stop-dots") as? MLNCircleStyleLayer)?.circleColor = accent
            (style.layer(withIdentifier: "selected-station-dot") as? MLNCircleStyleLayer)?.circleColor = accent
            (style.layer(withIdentifier: "journey-walking-line") as? MLNLineStyleLayer)?.lineColor = NSExpression(forConstantValue: UIColor(liveHex: theme.walkingColor))
            (style.layer(withIdentifier: "water") as? MLNFillStyleLayer)?.fillColor = NSExpression(forConstantValue: UIColor(liveHex: theme.waterColor))
            if let park = style.layer(withIdentifier: "park") as? MLNFillStyleLayer {
                let color = NSExpression(forConstantValue: UIColor(liveHex: theme.parkColor))
                park.fillColor = color; park.fillOutlineColor = color
            }
            let building = NSExpression(forConstantValue: UIColor(liveHex: theme.buildingColor))
            (style.layer(withIdentifier: "building") as? MLNFillStyleLayer)?.fillColor = building
            (style.layer(withIdentifier: "building-3d") as? MLNFillExtrusionStyleLayer)?.fillExtrusionColor = building
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            DispatchQueue.main.async { [weak self] in self?.model.mapError = "底圖載入失敗，仍可查站牌與到站資訊" }
        }

        @objc func selectBus(_ gesture: UITapGestureRecognizer) {
            guard let map, let buses else { return }
            let point = gesture.location(in: map)
            guard let id = buses.hitTest(point), let bus = model.snapshot.vehicles.first(where: { $0.id == id }) else {
                let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
                let features = map.visibleFeatures(in: rect, styleLayerIdentifiers: Set(["nearby-station-dots", "nearby-station-names", "journey-stop-dots", "journey-stop-names"]))
                if let stationID = features.first?.attribute(forKey: "stationID") as? String,
                   let station = model.metadata.stations[stationID] { model.selectStation(station) }
                return
            }
            // Without highlight mode, don't select a mesh behind a rendered building.
            if !(model.highlightVehicle && model.selectedVehicleID == id),
               !map.visibleFeatures(at: point, styleLayerIdentifiers: Set(["building-3d"])).isEmpty { return }
            model.selectVehicle(bus)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
