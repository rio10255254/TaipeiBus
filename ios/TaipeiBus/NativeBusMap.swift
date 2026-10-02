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
        map.attributionButtonPosition = .topLeft
        map.attributionButtonMargins = CGPoint(x: 16, y: 104)
        map.compassViewPosition = .topRight
        map.compassViewMargins = CGPoint(x: 16, y: 104)
        map.setCamera(MLNMapCamera(lookingAtCenter: Coordinate.taipei.locationCoordinate,
                                 altitude: 650, pitch: 54, heading: 0), animated: false)
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
        map.contentInset = UIEdgeInsets(top: topInset, left: 12, bottom: bottomInset, right: 12)
        context.coordinator.update(location: location)
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
        private var lastPowerCheck: CFTimeInterval = 0
        private var lastStationID: String?
        private var lastLocation: Coordinate?
        private var pendingLocation: Coordinate?
        private var routeSource: MLNShapeSource?
        private var stationSource: MLNShapeSource?
        private var locationSource: MLNShapeSource?
        private var nearbySource: MLNShapeSource?
        private let overlay: MapSelectionOverlay
        private var lastMetadataCount = -1

        init(model: TransitAppModel, overlay: MapSelectionOverlay) { self.model = model; self.overlay = overlay }
        func attach(_ map: MLNMapView) {
            self.map = map
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        func stop() { displayLink?.invalidate(); displayLink = nil }
        deinit { displayLink?.invalidate() }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
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
            updateNearbyStations()
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

        func update(location: Coordinate?) {
            pendingLocation = location
            displayLink?.isPaused = !model.isActive
            guard let map, let buses else { return }
            if lastMetadataCount != model.metadata.stations.count {
                updateNearbyStations(); lastMetadataCount = model.metadata.stations.count
            }
            let routeKey = "\(model.selectedRoute?.parentID ?? "all"):\(model.selectedRouteID == nil ? "all" : model.direction)"
            if lastSnapshotRevision != model.snapshot.revision || routeKey != lastRouteKey {
                var vehicles = model.snapshot.vehicles
                if let route = model.selectedRoute {
                    vehicles = vehicles.filter { $0.parentRouteID == route.parentID && $0.direction == model.direction }
                }
                if reduceMotion { vehicles = vehicles.map { var bus = $0; bus.path = [bus.coordinate]; return bus } }
                buses.ingest(vehicles, time: CACurrentMediaTime())
                lastSnapshotRevision = model.snapshot.revision
            }
            if routeKey != lastRouteKey {
                routeSource?.shape = model.selectedRouteID.flatMap { model.metadata.line($0) }.flatMap { routeLine in
                    guard routeLine.coordinates.count >= 2 else { return nil }
                    var coordinates = routeLine.coordinates.map(\.locationCoordinate)
                    return MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                }
                lastRouteKey = routeKey
            }
            buses.selectedID = model.selectedVehicleID
            buses.highlightSelected = model.highlightVehicle
            if let buildings = map.style?.layer(withIdentifier: "building-3d") as? MLNFillExtrusionStyleLayer {
                buildings.fillExtrusionOpacity = NSExpression(forConstantValue: model.highlightVehicle && model.selectedVehicleID != nil ? 0.26 : 1.0)
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
            if lastFocusRevision != model.focusRevision, map.bounds.width > 0 {
                focus(model.focus, map: map)
                lastFocusRevision = model.focusRevision
            }
            buses.setNeedsDisplay()
            updateStationAnchor()
        }

        private func updateNearbyStations() {
            guard let map, nearbySource != nil else { return }
            let center = Coordinate(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
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
        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) { updateStationAnchor() }

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
                map.setCamera(MLNMapCamera(lookingAtCenter: bus.coordinate.locationCoordinate,
                                          altitude: 360, pitch: 54, heading: map.direction), animated: !reduceMotion)
            case .route(let id):
                let coordinates = model.metadata.line(id)?.coordinates ?? model.snapshot.vehicles
                    .filter { $0.parentRouteID == model.metadata.route(id)?.parentID }.map(\.coordinate)
                guard let first = coordinates.first else { return }
                let south = coordinates.map(\.latitude).min() ?? first.latitude
                let north = coordinates.map(\.latitude).max() ?? first.latitude
                let west = coordinates.map(\.longitude).min() ?? first.longitude
                let east = coordinates.map(\.longitude).max() ?? first.longitude
                if south == north && west == east { map.setCenter(first.locationCoordinate, zoomLevel: 15, animated: !reduceMotion) }
                else {
                    let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: south, longitude: west),
                                                     ne: CLLocationCoordinate2D(latitude: north, longitude: east))
                    map.setVisibleCoordinateBounds(bounds, edgePadding: UIEdgeInsets(top: 24, left: 30, bottom: 24, right: 30), animated: !reduceMotion)
                }
            }
        }

        @objc private func tick(_ link: CADisplayLink) {
            guard model.isActive, let map, let buses else { return }
            let now = CACurrentMediaTime(), date = Date()
            if now - lastPowerCheck > 1 {
                let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                let rate = lowPower ? 30.0 : 60.0
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(rate), preferred: Float(rate))
                map.preferredFramesPerSecond = MLNMapViewPreferredFramesPerSecond(rawValue: Int(rate))
                lastPowerCheck = now
            }
            if buses.isAnimating(time: now, now: date) { buses.setNeedsDisplay() }
            if model.following, let id = model.selectedVehicleID, now - lastFollowTime > 0.2,
               let pose = buses.pose(id: id, time: now, now: date), !pose.stale {
                let center = Coordinate(latitude: map.centerCoordinate.latitude, longitude: map.centerCoordinate.longitude)
                if center.distance(to: pose.coordinate) > 0.25 {
                    let camera = map.camera
                    camera.centerCoordinate = pose.coordinate.locationCoordinate
                    map.setCamera(camera, withDuration: reduceMotion ? 0 : 0.22, animationTimingFunction: CAMediaTimingFunction(name: .linear), completionHandler: nil)
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
                let rect = CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
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
