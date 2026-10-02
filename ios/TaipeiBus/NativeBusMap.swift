import SwiftUI
import MapLibre
import MetalKit
import TransitCore

extension Coordinate {
    var locationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct NativeBusMap: UIViewRepresentable {
    @ObservedObject var model: TransitAppModel
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
        map.minimumZoomLevel = 11
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
        private var buildingOpacity = 1.0
        private var buildingOpacityTarget = 1.0
        private var buildingLayer: MLNFillExtrusionStyleLayer?
        private var lastStationID: String?
        private var lastLocation: Coordinate?
        private var pendingLocation: Coordinate?
        private var routeSource: MLNShapeSource?
        private var stationSource: MLNShapeSource?
        private var locationSource: MLNShapeSource?
        private var nearbySource: MLNShapeSource?
        private let overlay: MapSelectionOverlay
        private var lastMetadataCount = -1
        private var positionedInitialCamera = false

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
                map.setCamera(MLNMapCamera(lookingAtCenter: Coordinate.taipei.locationCoordinate,
                                          altitude: 650, pitch: 54, heading: 0), animated: false)
            }
            guard let buses else { return }
            if lastMetadataCount != model.metadata.stations.count {
                updateNearbyStations(force: true); lastMetadataCount = model.metadata.stations.count
            }
            let routeKey = "\(model.selectedRouteID ?? "all"):\(model.selectedRouteID == nil ? "all" : model.direction):\(model.allRouteVariants)"
            if lastSnapshotRevision != model.snapshot.revision || routeKey != lastRouteKey || lastMotionSetting != reduceMotion {
                var vehicles = model.snapshot.vehicles
                if model.selectedRoute != nil { vehicles = model.routeVehicles() }
                if reduceMotion { vehicles = vehicles.map { var bus = $0; bus.path = [bus.coordinate]; return bus } }
                buses.ingest(vehicles, time: CACurrentMediaTime())
                lastSnapshotRevision = model.snapshot.revision
                lastMotionSetting = reduceMotion
            }
            if routeKey != lastRouteKey {
                let features = model.routePaths.map { path -> MLNPolylineFeature in
                    var coordinates = path.map(\.locationCoordinate)
                    return MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                }
                routeSource?.shape = features.isEmpty ? nil : MLNShapeCollectionFeature(shapes: features)
                lastRouteKey = routeKey
            }
            buses.selectedID = model.selectedVehicleID
            buses.highlightSelected = model.highlightVehicle
            buses.reduceMotion = reduceMotion
            // Station dots remain tappable; their names must not cover the vehicle's anchored information.
            let hasVehicle = model.selectedVehicle != nil
            map.style?.layer(withIdentifier: "nearby-station-names")?.isVisible = !hasVehicle
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
            // Opening a sheet changes the viewport and can cancel an in-flight bounds animation.
            // Refit a selected route after that change; keep ordinary updates from resetting the camera.
            let refitRoute = viewportChanged && model.selectedRoute != nil && model.selectedVehicleID == nil
            if (lastFocusRevision != model.focusRevision || refitRoute), map.bounds.width > 0 {
                focus(model.focus, map: map)
                lastFocusRevision = model.focusRevision
            }
            buses.setNeedsDisplay()
            updateStationAnchor()
        }

        private func updateNearbyStations(force: Bool = false) {
            guard let map, nearbySource != nil else { return }
            let center = Coordinate(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
            let time = CACurrentMediaTime()
            if !force, let previous = lastNearbyCenter,
               time - lastNearbyUpdate < 0.5 || previous.distance(to: center) < 20 { return }
            lastNearbyCenter = center; lastNearbyUpdate = time
            let stations = model.metadata.stations.values.filter { $0.coordinate.distance(to: center) < 1_000 }
                .sorted { $0.coordinate.distance(to: center) < $1.coordinate.distance(to: center) }.prefix(18)
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

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) { updateNearbyStations() }
        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
            if !positionedInitialCamera, mapView.bounds.width > 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.update(location: self.pendingLocation)
                }
            }
            updateStationAnchor()
        }

        private func point(_ coordinate: Coordinate?) -> MLNPointFeature? {
            guard let coordinate else { return nil }
            let feature = MLNPointFeature()
            feature.coordinate = coordinate.locationCoordinate
            return feature
        }

        private func focus(_ focus: MapFocus?, map: MLNMapView) {
            guard let focus else { return }
            switch focus {
            case .coordinate(let position):
                map.setCenter(position.locationCoordinate, zoomLevel: 17.3, animated: !reduceMotion)
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
                guard let first = coordinates.first else { return }
                let south = coordinates.map(\.latitude).min() ?? first.latitude
                let north = coordinates.map(\.latitude).max() ?? first.latitude
                let west = coordinates.map(\.longitude).min() ?? first.longitude
                let east = coordinates.map(\.longitude).max() ?? first.longitude
                if south == north && west == east { map.setCenter(first.locationCoordinate, zoomLevel: 15, animated: !reduceMotion) }
                else {
                    let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: south, longitude: west),
                                                     ne: CLLocationCoordinate2D(latitude: north, longitude: east))
                    map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 24, left: 30, bottom: 24, right: 30), animated: !reduceMotion, completionHandler: nil)
                }
            }
        }

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
            if !reason.intersection(gestures).isEmpty, model.following {
                DispatchQueue.main.async { [weak self] in self?.model.following = false }
            }
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            DispatchQueue.main.async { [weak self] in self?.model.mapError = "底圖載入失敗，仍可查站牌與到站資訊" }
        }

        @objc func selectBus(_ gesture: UITapGestureRecognizer) {
            guard let map, let buses else { return }
            let point = gesture.location(in: map)
            guard let id = buses.hitTest(point), let bus = model.snapshot.vehicles.first(where: { $0.id == id }) else {
                let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
                let features = map.visibleFeatures(in: rect, styleLayerIdentifiers: Set(["nearby-station-dots", "nearby-station-names"]))
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
