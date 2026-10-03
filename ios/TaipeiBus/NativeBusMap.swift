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
        map.compassView.accessibilityIdentifier = "map-compass"
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
        private var lastStationBrowsing: Bool?
        private var buildingOpacity = 1.0
        private var buildingOpacityTarget = 1.0
        private var buildingLayer: MLNFillExtrusionStyleLayer?
        private var lastStationID: String?
        private var pendingLocation: Coordinate?
        private var routeSource: MLNShapeSource?
        private var walkingSource: MLNShapeSource?
        private var tripStopsSource: MLNShapeSource?
        private var stationSource: MLNShapeSource?
        private let locationMarker = DeviceLocationMarker()
        private var locationMotion = DeviceLocationMotion()
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
            map.addSubview(locationMarker)
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
            style.setImage(stationIcon(size: 20), forName: "station-marker")
            style.setImage(stationIcon(size: 26), forName: "selected-station-marker")
            style.setImage(stationIcon(size: 22, symbol: "flag.fill"), forName: "destination-marker")
            let tripDots = MLNSymbolStyleLayer(identifier: "journey-stop-dots", source: tripStops)
            tripDots.iconImageName = NSExpression(forKeyPath: "icon")
            tripDots.iconAllowsOverlap = NSExpression(forConstantValue: true)
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
            stationSource = addStationLayer(id: "selected-station", style: style)
            let nearby = MLNShapeSource(identifier: "nearby-stations", shape: nil, options: nil)
            style.addSource(nearby); nearbySource = nearby
            let dots = MLNSymbolStyleLayer(identifier: "nearby-station-dots", source: nearby)
            dots.minimumZoomLevel = 15.7
            dots.iconImageName = NSExpression(forConstantValue: "station-marker")
            dots.iconScale = NSExpression(forConstantValue: 0.85)
            dots.iconAllowsOverlap = NSExpression(forConstantValue: true)
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
            lastStationBrowsing = nil
            lastStationID = nil
            update(location: pendingLocation)
            updateNearbyStations(force: true)
        }

        private func addStationLayer(id: String, style: MLNStyle) -> MLNShapeSource {
            let source = MLNShapeSource(identifier: id, shape: nil, options: nil)
            style.addSource(source)
            let layer = MLNSymbolStyleLayer(identifier: "\(id)-dot", source: source)
            layer.iconImageName = NSExpression(forConstantValue: "selected-station-marker")
            layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
            style.addLayer(layer)
            return source
        }

        private func stationIcon(size: CGFloat, symbol: String = "bus.fill") -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: size + 4, height: size + 4)).image { _ in
                let rect = CGRect(x: 2, y: 2, width: size, height: size)
                let shape = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.25)
                UIColor.white.setFill(); shape.fill()
                UIColor(red: 0.36, green: 0.46, blue: 0.57, alpha: 0.55).setStroke(); shape.lineWidth = 1; shape.stroke()
                let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.57, weight: .medium))?
                    .withTintColor(UIColor(red: 0.28, green: 0.40, blue: 0.53, alpha: 1), renderingMode: .alwaysOriginal)
                glyph?.draw(in: rect.insetBy(dx: size * 0.23, dy: size * 0.23))
            }
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
            if lastStationBrowsing != model.stationBrowsing {
                let minimumZoom: Float = model.stationBrowsing ? 9.0 : 15.7
                map.style?.layer(withIdentifier: "nearby-station-dots")?.minimumZoomLevel = minimumZoom
                map.style?.layer(withIdentifier: "nearby-station-names")?.minimumZoomLevel = minimumZoom
                (map.style?.layer(withIdentifier: "nearby-station-dots") as? MLNSymbolStyleLayer)?.iconScale =
                    NSExpression(forConstantValue: model.stationBrowsing ? 1.0 : 0.85)
                lastStationBrowsing = model.stationBrowsing
            }
            map.style?.layer(withIdentifier: "nearby-station-names")?.isVisible = model.stationBrowsing || (!hasVehicle && model.planner.selected == nil)
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
            buses.setNeedsDisplay()
            updateStationAnchor()
        }

        private func updateTripStops() {
            guard let option = model.planner.selected else { tripStopsSource?.shape = nil; return }
            var features: [String: MLNPointFeature] = [:]
            func add(_ coordinate: Coordinate, id: String, title: String) {
                let feature = MLNPointFeature(); feature.coordinate = coordinate.locationCoordinate
                feature.attributes = ["name": title, "stationID": id, "icon": id == "destination" ? "destination-marker" : "station-marker"]; features[id] = feature
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
            updateNearbyStations()
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
                var state: [String: Any] = ["latitude": center.latitude, "longitude": center.longitude, "zoom": mapView.zoomLevel,
                    "heading": mapView.direction, "pitch": mapView.camera.pitch, "mode": model.userMapMode.rawValue,
                    "station": model.selectedStationID ?? "", "stationDistance": model.selectedStation.map { center.distance(to: $0.coordinate) } ?? -1,
                    "queryMarkers": model.stationMapResults.count, "browsing": model.stationBrowsing,
                    "userMarkerVisible": !locationMarker.isHidden, "userHeadingVisible": locationMarker.headingVisible,
                    "userMarkerX": locationMarker.center.x, "userMarkerY": locationMarker.center.y,
                    "userFanAngle": locationMarker.directionAngle,
                    "stationSymbol": mapView.style?.layer(withIdentifier: "nearby-station-dots") is MLNSymbolStyleLayer]
                if model.stationBrowsing {
                    let visible = mapView.bounds.inset(by: mapView.contentInset).insetBy(dx: 24, dy: 24)
                    let markers = mapView.visibleFeatures(in: visible, styleLayerIdentifiers: Set(["nearby-station-dots"]))
                    if let id = markers.first?.attribute(forKey: "stationID") as? String, let station = model.metadata.stations[id] {
                        let pixel = mapView.convert(station.coordinate.locationCoordinate, toPointTo: mapView)
                        state["markerX"] = pixel.x; state["markerY"] = pixel.y; state["markerID"] = id
                    }
                }
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
                                      altitude: 1000, pitch: model.stationBrowsing ? 0 : 35, heading: 0), animated: false)
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
            guard model.isActive, let map else { return }
            let now = CACurrentMediaTime(), date = Date()
            let dt = lastTickTime > 0 ? min(0.1, max(0.001, now - lastTickTime)) : 1 / 60
            lastTickTime = now
            updateLocationMarker(map, elapsed: dt)
            guard let buses else { return }
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

        private func updateLocationMarker(_ map: MLNMapView, elapsed: Double) {
            locationMotion.update(coordinate: model.location.displayCoordinate, heading: model.location.currentHeading,
                                  elapsed: elapsed, reduceMotion: reduceMotion)
            guard let point = locationMotion.coordinate else { locationMarker.isHidden = true; return }
            let screen = map.convert(point.locationCoordinate, toPointTo: map)
            guard screen.x.isFinite, screen.y.isFinite else { locationMarker.isHidden = true; return }
            locationMarker.isHidden = !map.bounds.insetBy(dx: -48, dy: -48).contains(screen)
            locationMarker.center = screen
            var angle: Double?
            if let bearing = locationMotion.heading {
                let radians = bearing * .pi / 180
                let ahead = Coordinate(latitude: point.latitude + cos(radians) * 30 / 111_320,
                                       longitude: point.longitude + sin(radians) * 30 / (111_320 * cos(point.latitude * .pi / 180)))
                let target = map.convert(ahead.locationCoordinate, toPointTo: map)
                angle = atan2(Double(target.x - screen.x), Double(screen.y - target.y))
            }
            locationMarker.update(direction: angle, accuracy: model.location.headingAccuracy ?? 20)
        }

        func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureTilt, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom, .resetNorth]
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
            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let features = map.visibleFeatures(in: rect, styleLayerIdentifiers: Set(["nearby-station-dots", "nearby-station-names", "journey-stop-dots", "journey-stop-names"]))
            let station = features.compactMap { feature -> Station? in
                guard let id = feature.attribute(forKey: "stationID") as? String else { return nil }
                return model.metadata.stations[id]
            }.min { a, b in
                let x = map.convert(a.coordinate.locationCoordinate, toPointTo: map)
                let y = map.convert(b.coordinate.locationCoordinate, toPointTo: map)
                return hypot(x.x - point.x, x.y - point.y) < hypot(y.x - point.x, y.y - point.y)
            }
            if model.stationBrowsing, let station { model.selectStation(station); return }
            guard let id = buses.hitTest(point), let bus = model.snapshot.vehicles.first(where: { $0.id == id }) else {
                if let station { model.selectStation(station) }
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

/// A device dot is circular; every bus stop uses a bus symbol. This view does not intercept map gestures.
private final class DeviceLocationMarker: UIView {
    private let fan = CALayer()
    private var bands: [CAShapeLayer] = []
    private var lastAccuracy = -1.0
    private(set) var headingVisible = false
    private(set) var directionAngle = 0.0

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        isUserInteractionEnabled = false; isAccessibilityElement = false; isHidden = true
        backgroundColor = .clear
        fan.frame = bounds; layer.addSublayer(fan)
        for opacity in [0.05, 0.08, 0.12] {
            let band = CAShapeLayer(); band.frame = bounds
            band.fillColor = UIColor.systemBlue.withAlphaComponent(opacity).cgColor
            fan.addSublayer(band); bands.append(band)
        }
        let halo = CAShapeLayer()
        halo.path = UIBezierPath(ovalIn: CGRect(x: 34, y: 34, width: 28, height: 28)).cgPath
        halo.fillColor = UIColor.systemBlue.withAlphaComponent(0.1).cgColor; layer.addSublayer(halo)
        let dot = CAShapeLayer()
        dot.path = UIBezierPath(ovalIn: CGRect(x: 41, y: 41, width: 14, height: 14)).cgPath
        dot.fillColor = UIColor.systemBlue.cgColor; dot.strokeColor = UIColor.white.cgColor; dot.lineWidth = 3
        dot.shadowColor = UIColor.black.cgColor; dot.shadowOpacity = 0.18; dot.shadowRadius = 3; dot.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(dot)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(direction: Double?, accuracy: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        headingVisible = direction != nil; fan.isHidden = !headingVisible
        if let direction { directionAngle = direction; fan.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(direction))) }
        if abs(accuracy - lastAccuracy) > 1 {
            let halfAngle = CGFloat(min(48, max(25, accuracy + 20))) * .pi / 180
            for (index, band) in bands.enumerated() {
                let path = UIBezierPath(); path.move(to: CGPoint(x: 48, y: 48))
                path.addArc(withCenter: CGPoint(x: 48, y: 48), radius: CGFloat(46 - index * 11),
                            startAngle: -.pi / 2 - halfAngle, endAngle: -.pi / 2 + halfAngle, clockwise: true)
                path.close(); band.path = path.cgPath
            }
            lastAccuracy = accuracy
        }
        CATransaction.commit()
    }
}
