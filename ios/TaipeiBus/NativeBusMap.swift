import SwiftUI
import MapLibre
import MetalKit
import TransitCore

struct NativeBusMap: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: TransitAppModel
    @ObservedObject var planner: JourneyPlannerModel
    @ObservedObject var stationWalk: StationWalkingNavigation
    let location: Coordinate?
    let bottomInset: CGFloat
    let topInset: CGFloat
    let reduceMotion: Bool
    let selectionOverlay: MapSelectionOverlay

    func makeCoordinator() -> Coordinator { Coordinator(model: model, overlay: selectionOverlay) }

    func makeUIView(context: Context) -> MLNMapView {
        let style = Bundle.main.url(forResource: "taipei", withExtension: "json")
        let map = MLNMapView(frame: .zero, styleURL: style)
        context.coordinator.darkMode = colorScheme == .dark
        map.delegate = context.coordinator
        map.maximumZoomLevel = 20
        map.minimumZoomLevel = 9
        map.automaticallyAdjustsContentInset = false
        map.showsUserLocation = false // A single Core Location service owns permission and location requests.
        map.showsLogoView = false
        map.attributionButtonPosition = .bottomLeft
        map.attributionButtonMargins = CGPoint(x: 16, y: 12)
        // Keep the OpenStreetMap credit, but as quiet as Apple's legal link.
        map.attributionButton.tintColor = .tertiaryLabel
        // The compass appears under the right-hand control stack, as in Apple Maps.
        map.compassViewPosition = .topRight
        map.compassViewMargins = CGPoint(x: 20, y: 116)
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
        context.coordinator.darkMode = colorScheme == .dark
        let inset = UIEdgeInsets(top: topInset, left: 12, bottom: bottomInset, right: 12)
        let viewportChanged = context.coordinator.requestInset(inset, map: map)
        context.coordinator.update(location: location, viewportChanged: viewportChanged)
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        coordinator.stop()
        map.delegate = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {
        var model: TransitAppModel
        var reduceMotion = false
        var darkMode = false
        private weak var map: MLNMapView?
        private var buses: NativeBusLayer?
        private var displayLink: CADisplayLink?
        private var lastSnapshotRevision = -1
        private var lastRouteKey = ""
        private var lastVehicleKey = ""
        private var lastFocusRevision = -1
        private var lastFollowTime: CFTimeInterval = 0
        private var lastTickTime: CFTimeInterval = 0
        private var followSuspendedUntil: CFTimeInterval = 0
        private var cameraMoving = false
        private var cameraMoveToken = 0
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
        private var cityCamera: MLNMapCamera?
        private var beforeCityCamera: MLNMapCamera?
        private var lastCameraTarget: MLNMapCamera?
        private var lastCameraTargetRevision = -1
        private var lastFocusWasLeavingCity = false
        private var insetWork: DispatchWorkItem?
        private var pendingInset: UIEdgeInsets?
        private var lastVisibilityCheck: CFTimeInterval = 0
        private var lastVisibilityTarget: Coordinate?
        private var visibilityVehicleID: String?
        private var visibilityAdjustments = 0
        private var consecutiveVisibilityAdjustments = 0
        private var lastVisibilityAdjustmentAt: CFTimeInterval = 0
#if DEBUG
        private var lastTestCameraAt: CFTimeInterval = 0
        private let zoomProbe = ZoomPerformanceProbe()
        private var zoomProbeObserver: NSObjectProtocol?
        private var zoomProbeVisibility: [String: Bool] = [:]
        private var zoomProbeCamera: MLNMapCamera?
        private var zoomProbeMode = "baseline"
        private struct CameraTransitionTrace {
            let started: CFTimeInterval
            let revision: Int
            var duration: Double
            var targetZoom: Double
            var samples: [[String: Double]] = []
        }
        private var cameraTransitions: [CameraTransitionTrace] = []
#endif
        private var positionedInitialCamera = false
        private var lastAppearance: LiveSettings.Appearance?
        private var lastDarkMode: Bool?
        private var lastLanguage: AppLanguage?
        private var dayPaints: [String: [String: NSExpression]] = [:]
#if DEBUG
        private var lastPreviewCameraSignature = ""
#endif

        init(model: TransitAppModel, overlay: MapSelectionOverlay) { self.model = model; self.overlay = overlay }
        func attach(_ map: MLNMapView) {
            self.map = map
            map.addSubview(locationMarker)
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            let rate = Float(fullFrameRate)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: rate, preferred: rate)
            map.preferredFramesPerSecond = MLNMapViewPreferredFramesPerSecond(rawValue: Int(rate))
            link.add(to: .main, forMode: .common)
            displayLink = link
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--test-zoom-performance") {
                zoomProbeObserver = NotificationCenter.default.addObserver(forName: Notification.Name("zoom-performance-control"),
                    object: nil, queue: .main) { [weak self] note in
                    guard let mode = note.object as? String else { return }
                    self?.setZoomProbeMode(mode)
                }
            }
#endif
        }
        /// ProMotion screens run the map, the 3D buses and the camera at up to 120 Hz.
        private var fullFrameRate: Int { min(120, max(60, UIScreen.main.maximumFramesPerSecond)) }
        func stop() {
            insetWork?.cancel(); insetWork = nil; pendingInset = nil
            displayLink?.invalidate(); displayLink = nil
#if DEBUG
            if let zoomProbeObserver { NotificationCenter.default.removeObserver(zoomProbeObserver) }
            zoomProbeObserver = nil
#endif
        }
        deinit { displayLink?.invalidate() }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            lastAppearance = nil; lastDarkMode = nil
            installRelief(style)
            captureDayPalette(style)
            buildingLayer = style.layer(withIdentifier: "building-3d") as? MLNFillExtrusionStyleLayer
            buildingOpacity = 1; buildingOpacityTarget = 1
            let route = MLNShapeSource(identifier: "selected-route", shape: nil, options: nil)
            style.addSource(route); routeSource = route
            // Apple Maps style transit line: a white casing, the route's own sign
            // colour, and direction chevrons once the street is readable.
            func zoomed(_ stops: [(Double, Double)]) -> NSExpression {
                var json: [Any] = ["interpolate", ["linear"], ["zoom"]]
                for (zoom, value) in stops { json.append(zoom); json.append(value) }
                return NSExpression(mglJSONObject: json)
            }
            let line = MLNLineStyleLayer(identifier: "selected-route-line", source: route)
            line.lineColor = NSExpression(mglJSONObject: ["to-color", ["coalesce", ["get", "color"], RouteTint.general]])
            line.lineWidth = zoomed([(11, 3), (14, 5), (17, 7), (20, 10)])
            line.lineCap = NSExpression(forConstantValue: NSValue(mlnLineCap: .round))
            line.lineJoin = NSExpression(forConstantValue: NSValue(mlnLineJoin: .round))
            let routeCasing = MLNLineStyleLayer(identifier: "selected-route-casing", source: route)
            routeCasing.lineWidth = zoomed([(11, 5.5), (14, 8), (17, 11), (20, 15)])
            routeCasing.lineColor = NSExpression(forConstantValue: UIColor.white)
            routeCasing.lineCap = NSExpression(forConstantValue: NSValue(mlnLineCap: .round))
            routeCasing.lineJoin = NSExpression(forConstantValue: NSValue(mlnLineJoin: .round))
            style.addLayer(routeCasing); style.addLayer(line)
            style.setImage(routeChevron(), forName: "route-chevron")
            let chevrons = MLNSymbolStyleLayer(identifier: "selected-route-arrows", source: route)
            chevrons.minimumZoomLevel = 14.5
            chevrons.symbolPlacement = NSExpression(forConstantValue: NSValue(mlnSymbolPlacement: .line))
            chevrons.symbolSpacing = NSExpression(forConstantValue: 90)
            chevrons.iconImageName = NSExpression(forConstantValue: "route-chevron")
            chevrons.iconRotationAlignment = NSExpression(forConstantValue: NSValue(mlnIconRotationAlignment: .map))
            chevrons.iconAllowsOverlap = NSExpression(forConstantValue: true)
            chevrons.iconIgnoresPlacement = NSExpression(forConstantValue: true)
            chevrons.iconScale = zoomed([(14.5, 0.7), (17, 0.95), (20, 1.3)])
            style.addLayer(chevrons)
            let walking = MLNShapeSource(identifier: "journey-walking", shape: nil, options: nil)
            style.addSource(walking); walkingSource = walking
            // Round caps on a zero-length dash draw Apple Maps style walking dots.
            // Both layers repeat every 12 pt so each dot keeps a white rim.
            let walkingLine = MLNLineStyleLayer(identifier: "journey-walking-line", source: walking)
            walkingLine.lineColor = NSExpression(forConstantValue: UIColor(liveHex: MapChrome.walkingLight))
            walkingLine.lineWidth = NSExpression(forConstantValue: 6)
            walkingLine.lineDashPattern = NSExpression(forConstantValue: [0, 2])
            walkingLine.lineCap = NSExpression(forConstantValue: NSValue(mlnLineCap: .round))
            walkingLine.lineJoin = NSExpression(forConstantValue: NSValue(mlnLineJoin: .round))
            let walkingCasing = MLNLineStyleLayer(identifier: "journey-walking-casing", source: walking)
            walkingCasing.lineWidth = NSExpression(forConstantValue: 9)
            walkingCasing.lineDashPattern = NSExpression(forConstantValue: [0, 12.0 / 9.0])
            walkingCasing.lineColor = NSExpression(forConstantValue: UIColor.white)
            walkingCasing.lineCap = NSExpression(forConstantValue: NSValue(mlnLineCap: .round))
            walkingCasing.lineJoin = NSExpression(forConstantValue: NSValue(mlnLineJoin: .round))
            // Walking guidance must remain legible over roofs and dense road colours.
            style.addLayer(walkingCasing); style.addLayer(walkingLine)
            let tripStops = MLNShapeSource(identifier: "journey-stops", shape: nil, options: nil)
            style.addSource(tripStops); tripStopsSource = tripStops
            installMarkerImages(style)
            let tripDots = MLNSymbolStyleLayer(identifier: "journey-stop-dots", source: tripStops)
            tripDots.predicate = NSPredicate(format: "waypoint != 1")
            tripDots.iconImageName = NSExpression(forKeyPath: "icon")
            tripDots.iconAllowsOverlap = NSExpression(forConstantValue: true)
            style.addLayer(tripDots)
            // Boarding, transfer and alighting stops always show. Intermediate stops appear once
            // the street is close enough and only where they do not crowd each other or an endpoint.
            let waypointDots = MLNSymbolStyleLayer(identifier: "journey-waypoint-dots", source: tripStops)
            waypointDots.predicate = NSPredicate(format: "waypoint == 1")
            waypointDots.minimumZoomLevel = 12.5
            waypointDots.iconImageName = NSExpression(forKeyPath: "icon")
            waypointDots.iconAllowsOverlap = NSExpression(forConstantValue: false)
            waypointDots.iconPadding = NSExpression(forConstantValue: 4)
            style.insertLayer(waypointDots, below: tripDots)
            let tripNames = MLNSymbolStyleLayer(identifier: "journey-stop-names", source: tripStops)
            tripNames.predicate = NSPredicate(format: "waypoint == 0")
            tripNames.text = NSExpression(forKeyPath: "name")
            tripNames.textFontSize = NSExpression(forConstantValue: 12)
            tripNames.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
            tripNames.textColor = NSExpression(forConstantValue: UIColor.darkGray)
            tripNames.textHaloColor = NSExpression(forConstantValue: UIColor.white)
            tripNames.textHaloWidth = NSExpression(forConstantValue: 2)
            tripNames.textTranslation = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: -16)))
            style.addLayer(tripNames)
            let waypointNames = MLNSymbolStyleLayer(identifier: "journey-waypoint-names", source: tripStops)
            waypointNames.predicate = NSPredicate(format: "waypoint == 1")
            waypointNames.minimumZoomLevel = 14.5
            waypointNames.text = NSExpression(forKeyPath: "name")
            waypointNames.textFontSize = NSExpression(forConstantValue: 11)
            waypointNames.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
            waypointNames.textTranslation = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: -12)))
            // Boarding and alighting names take priority over intermediate labels.
            style.insertLayer(waypointNames, below: tripNames)
            let destinationNames = MLNSymbolStyleLayer(identifier: "journey-destination-name", source: tripStops)
            destinationNames.predicate = NSPredicate(format: "waypoint == 2")
            destinationNames.minimumZoomLevel = 13
            destinationNames.text = NSExpression(forKeyPath: "name")
            destinationNames.textFontSize = NSExpression(forConstantValue: 12)
            destinationNames.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
            destinationNames.textTranslation = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: -16)))
            style.insertLayer(destinationNames, below: tripNames)

            let layer = NativeBusLayer(identifier: "native-buses")
            layer.onError = { [weak self] message in
                DispatchQueue.main.async { self?.model.mapError = message }
            }
            layer.onSelectedPoint = { [weak self, weak mapView] point in
                guard let self, let mapView, self.model.selectedVehicleID != nil else { return }
                let global = point.map { mapView.convert($0, to: nil) }
                DispatchQueue.main.async { [weak self] in self?.overlay.update(global, zoom: mapView.zoomLevel) }
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

        private var markerBlue: UIColor { UIColor(liveHex: darkMode ? MapChrome.walkingDark : RouteTint.general) }

        /// Street-level stop: a white disc with a blue rim and bus glyph, like Apple Maps transit stops.
        private func stationIcon(size: CGFloat, symbol: String = "bus.fill") -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: size + 6, height: size + 6)).image { context in
                let rect = CGRect(x: 3, y: 3, width: size, height: size)
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: UIColor.black.withAlphaComponent(0.25).cgColor)
                let disc = UIBezierPath(ovalIn: rect)
                UIColor(liveHex: darkMode ? "#2C2C2E" : "#FFFFFF").setFill(); disc.fill()
                context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                markerBlue.setStroke(); disc.lineWidth = max(1.5, size * 0.09); disc.stroke()
                let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size * 0.48, weight: .semibold))?
                    .withTintColor(markerBlue, renderingMode: .alwaysOriginal)
                glyph?.draw(in: rect.insetBy(dx: size * 0.25, dy: size * 0.25))
            }
        }

        /// A teardrop pin whose tip sits at the image centre, so every symbol layer
        /// can keep its default centre anchor and existing hit testing.
        private func pinIcon(symbol: String, color: UIColor, width: CGFloat = 30) -> UIImage {
            let height = width * 1.3
            return UIGraphicsImageRenderer(size: CGSize(width: width + 6, height: height * 2)).image { context in
                let tip = CGPoint(x: 3 + width / 2, y: height)
                let radius = width / 2
                let center = CGPoint(x: tip.x, y: tip.y - height + radius + 1)
                let path = UIBezierPath()
                path.move(to: tip)
                path.addCurve(to: CGPoint(x: center.x - radius, y: center.y), controlPoint1: CGPoint(x: tip.x - radius * 0.35, y: tip.y - radius * 0.45),
                              controlPoint2: CGPoint(x: center.x - radius, y: center.y + radius * 0.75))
                path.addArc(withCenter: center, radius: radius, startAngle: .pi, endAngle: 0, clockwise: true)
                path.addCurve(to: tip, controlPoint1: CGPoint(x: center.x + radius, y: center.y + radius * 0.75),
                              controlPoint2: CGPoint(x: tip.x + radius * 0.35, y: tip.y - radius * 0.45))
                path.close()
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: UIColor.black.withAlphaComponent(0.3).cgColor)
                color.setFill(); path.fill()
                context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
                let glyphSize = radius * 1.05
                UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: glyphSize, weight: .bold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: center.x - glyphSize / 2, y: center.y - glyphSize / 2, width: glyphSize, height: glyphSize))
            }
        }

        private func journeyStopIcon(color: UIColor? = nil) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 14, height: 14)).image { _ in
                let circle = UIBezierPath(ovalIn: CGRect(x: 2.5, y: 2.5, width: 9, height: 9))
                UIColor(liveHex: darkMode ? "#2C2C2E" : "#FFFFFF").setFill(); circle.fill()
                (color ?? markerBlue).setStroke(); circle.lineWidth = 2.2; circle.stroke()
            }
        }
        /// Stop markers take the colour of the route that serves them, like its line.
        private var tintedTripIcons: Set<String> = []
        private func tripIcon(_ kind: String, route: String) -> String {
            let hex = RouteTint.mapHex(for: route, dark: darkMode)
            let name = "journey-\(kind)-\(hex)"
            guard !tintedTripIcons.contains(name), let style = map?.style else { return name }
            let color = UIColor(liveHex: hex)
            let image = kind == "waypoint" ? journeyStopIcon(color: color)
                : journeyEndpointIcon(symbol: kind == "alighting" ? "arrow.down" : "bus.fill", color: color)
            style.setImage(image, forName: name); tintedTripIcons.insert(name)
            return name
        }

        private func journeyEndpointIcon(symbol: String, color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
                let circle = UIBezierPath(ovalIn: CGRect(x: 4, y: 4, width: 22, height: 22))
                context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: UIColor.black.withAlphaComponent(0.28).cgColor)
                color.setFill(); circle.fill()
                context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
                UIColor.white.setStroke(); circle.lineWidth = 2; circle.stroke()
                UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 9.5, y: 9.5, width: 11, height: 11))
            }
        }

        /// Direction marks drawn along the selected line; the image points along +x.
        private func routeChevron() -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { _ in
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 4, y: 2.5)); path.addLine(to: CGPoint(x: 8.5, y: 6)); path.addLine(to: CGPoint(x: 4, y: 9.5))
                UIColor.white.setStroke(); path.lineWidth = 2; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
            }
        }

        /// Point-of-interest categories, coloured like Apple Maps. Keep in sync with taipei.json.
        static let poiCategories: [(name: String, symbol: String, hex: String, darkHex: String, classes: [String])] = [
            ("poi-food", "fork.knife", "#E8730C", "#FF9F45", ["restaurant", "fast_food", "bar", "beer", "bakery", "ice_cream"]),
            ("poi-cafe", "cup.and.saucer.fill", "#E8730C", "#FF9F45", ["cafe"]),
            ("poi-shop", "bag.fill", "#C99700", "#F2C94C", ["shop", "clothing_store", "alcohol_shop", "butcher", "jewelry", "books", "mobile_phone", "music"]),
            ("poi-grocery", "cart.fill", "#C99700", "#F2C94C", ["grocery"]),
            ("poi-health", "cross.fill", "#E0405E", "#FF7A93", ["hospital", "pharmacy", "dentist", "doctors", "veterinary"]),
            ("poi-education", "graduationcap.fill", "#9A6B3F", "#D4A373", ["school", "college", "library", "kindergarten"]),
            ("poi-park", "leaf.fill", "#3E9B4F", "#6FCF7F", ["park", "garden", "playground", "zoo"]),
            ("poi-culture", "star.fill", "#C2479C", "#E889CB", ["museum", "art_gallery", "attraction", "monument", "castle", "theatre", "cinema"]),
            ("poi-lodging", "bed.double.fill", "#7B61D9", "#A99BFF", ["lodging"]),
            ("poi-service", "building.columns.fill", "#6E7C91", "#A7B3C6", ["bank", "post", "town_hall", "police", "fire_station"]),
            ("poi-worship", "building.fill", "#8A8A8E", "#B8B8BD", ["place_of_worship"]),
            ("poi-rail", "tram.fill", "#2F7BE5", "#6EA8FF", ["railway"]),
        ]
        /// Category colours lifted for the dark map, matched on the place class.
        static let poiDarkTextColor: NSExpression = {
            var match: [Any] = ["match", ["get", "class"]]
            for category in poiCategories { match.append(category.classes); match.append(category.darkHex) }
            match.append("#C7C9CF")
            return NSExpression(mglJSONObject: ["to-color", match])
        }()
        private func poiIcon(symbol: String, color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
                let disc = UIBezierPath(ovalIn: CGRect(x: 1.5, y: 1.5, width: 21, height: 21))
                color.setFill(); disc.fill()
                UIColor.white.setStroke(); disc.lineWidth = 1.5; disc.stroke()
                let configuration = UIImage.SymbolConfiguration(pointSize: 10.5, weight: .bold)
                if let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(.white, renderingMode: .alwaysOriginal) {
                    glyph.draw(in: CGRect(x: 12 - glyph.size.width / 2, y: 12 - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height))
                }
            }
        }
        private func installMarkerImages(_ style: MLNStyle) {
            tintedTripIcons = []
            for category in Self.poiCategories {
                style.setImage(poiIcon(symbol: category.symbol, color: UIColor(liveHex: darkMode ? category.darkHex : category.hex)), forName: category.name)
            }
            style.setImage(stationIcon(size: 22), forName: "station-marker")
            style.setImage(pinIcon(symbol: "bus.fill", color: markerBlue), forName: "selected-station-marker")
            style.setImage(pinIcon(symbol: "flag.fill", color: UIColor(liveHex: darkMode ? "#FF6961" : "#D93636"), width: 26), forName: "destination-marker")
            style.setImage(journeyStopIcon(), forName: "journey-waypoint")
            style.setImage(journeyEndpointIcon(symbol: "bus.fill", color: markerBlue), forName: "journey-boarding")
            style.setImage(journeyEndpointIcon(symbol: "arrow.down", color: markerBlue), forName: "journey-alighting")
            style.setImage(pinIcon(symbol: "flag.fill", color: UIColor(liveHex: darkMode ? "#FF6961" : "#D93636"), width: 26), forName: "journey-destination")
        }

        func requestInset(_ inset: UIEdgeInsets, map: MLNMapView) -> Bool {
            if pendingInset == inset, !reduceMotion { return false }
            insetWork?.cancel(); insetWork = nil; pendingInset = nil
            guard map.contentInset != inset else { return false }
            if map.contentInset == .zero || reduceMotion {
                map.setContentInset(inset, animated: false)
                return true
            }
            // Geometry reports every frame while a panel animates. Apply the final
            // viewport once, so those updates cannot continually cancel camera motion.
            pendingInset = inset
            let work = DispatchWorkItem { [weak self, weak map] in
                guard let self, let map, self.pendingInset == inset else { return }
                self.insetWork = nil
                self.applyPendingInset(map)
            }
            insetWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
            return false
        }

        private func applyPendingInset(_ map: MLNMapView) {
            guard !cameraMoving, insetWork == nil, let inset = pendingInset else { return }
            pendingInset = nil
            // Padding and a camera flight must not run competing native animations.
            // Refit once after the explicit movement and panel layout have settled.
            map.setContentInset(inset, animated: false)
            update(location: pendingLocation, viewportChanged: true)
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
            let refit = viewportChanged && !model.mapWasMoved && model.focus != nil &&
                (model.selectedVehicleID == nil || model.following)
            if (lastFocusRevision != model.focusRevision || refit), map.bounds.width > 0, map.bounds.height > 0 {
                focus(model.focus, map: map, duration: lastFocusRevision != model.focusRevision ? 0.65 : 0.28)
                lastFocusRevision = model.focusRevision
            }
            guard buses != nil else { return }
            if let style = map.style, lastAppearance != model.liveSettings.appearance || lastDarkMode != darkMode {
                applyAppearance(style); lastAppearance = model.liveSettings.appearance; lastDarkMode = darkMode
            }
            if let style = map.style, lastLanguage != model.language {
                applyLabelLanguage(style)
                updateNearbyStations(force: true); updateTripStops()
                lastLanguage = model.language
            }
            guard let buses else { return }
            buses.darkAppearance = darkMode
            if lastMetadataCount != model.metadata.stations.count {
                updateNearbyStations(force: true); lastMetadataCount = model.metadata.stations.count
            }
            let stationKey = "\(model.stationBrowsing):\(model.query):\(model.stationMapResults.map(\.id))"
            if stationKey != lastStationSearchKey { lastStationSearchKey = stationKey; updateNearbyStations(force: true) }
            let routeKey = "dark\(darkMode):\(model.selectedRouteID ?? "all"):\(model.selectedRouteID == nil ? "all" : model.direction):\(model.allRouteVariants):city\(model.cityFleetMode):trip\(model.planner.mapRevision):walk\(model.walkingMapIndex.map { String($0) } ?? "all"):progress\(model.planner.walkingRevision):stationwalk\(model.stationWalk.revision)"
            let vehicleKey = "\(model.selectedRouteID ?? "all"):\(model.direction):\(model.allRouteVariants):\(model.cityFleetMode):\(model.planner.mapRevision):\(model.selectedVehicleID == nil):anchor\(model.anchorRevision)"
            if lastSnapshotRevision != model.snapshot.revision || vehicleKey != lastVehicleKey || lastMotionSetting != reduceMotion {
                var vehicles = model.snapshot.vehicles
                if model.cityFleetMode { vehicles = model.cityVehicles }
                else if model.selectedRoute != nil {
                    vehicles = model.selectedVehicleID == nil && model.planner.selected == nil ? model.routeMapVehicles : model.routeVehicles()
                }
                else if let trip = model.planner.selected {
                    let rides = model.planner.started ? model.planner.activeRide.map { [$0] } ?? [] : trip.rides
                    let services = rides.map { ($0.direction, model.metadata.routeIDs(serving: $0)) }
                    vehicles = vehicles.filter { bus in services.contains { $0.0 == bus.direction && $0.1.contains(bus.routeID) } }
                }
                if reduceMotion { vehicles = vehicles.map { var bus = $0; bus.path = [bus.coordinate]; return bus } }
                buses.ingest(vehicles, time: CACurrentMediaTime())
                lastSnapshotRevision = model.snapshot.revision
                lastMotionSetting = reduceMotion
                lastVehicleKey = vehicleKey
            }
            if routeKey != lastRouteKey {
                let tripRides = model.planner.started ? model.planner.activeRide.map { [$0] } ?? [] : model.planner.selected?.rides ?? []
                let lines: [(path: [Coordinate], name: String)] = model.selectedRouteID != nil
                    ? model.routePaths.map { (path: $0, name: model.selectedRoute?.name ?? "") }
                    : tripRides.filter { $0.coordinates.count >= 2 }.map { (path: $0.coordinates, name: $0.route.name) }
                let features = lines.map { line -> MLNPolylineFeature in
                    var coordinates = line.path.map(\.locationCoordinate)
                    let feature = MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                    feature.attributes = ["color": RouteTint.mapHex(for: line.name, dark: darkMode)]
                    return feature
                }
                routeSource?.shape = features.isEmpty ? nil : MLNShapeCollectionFeature(shapes: features)
                var displayedWalks = model.planner.selected?.walks ?? []
                if let index = model.walkingMapIndex, displayedWalks.indices.contains(index) { displayedWalks = [displayedWalks[index]] }
                else if model.planner.started {
                    if case .walk(let index) = model.planner.currentStep { displayedWalks = [displayedWalks[index]] }
                    else { displayedWalks = [] }
                }
                let visibleWalks = model.stationWalk.isActive ? [model.stationWalk.coordinates] : model.activeWalkingIndex.map { [model.planner.walkingCoordinates(at: $0)] } ?? displayedWalks.map(\.coordinates)
                let walks = visibleWalks.filter { $0.count >= 2 }.map { walk -> MLNPolylineFeature in
                    var coordinates = walk.map(\.locationCoordinate)
                    return MLNPolylineFeature(coordinates: &coordinates, count: UInt(coordinates.count))
                }
                walkingSource?.shape = walks.isEmpty ? nil : MLNShapeCollectionFeature(shapes: walks)
                updateTripStops()
                lastRouteKey = routeKey
            }
            buses.selectedID = model.selectedVehicleID
            buses.emphasizedIDs = model.selectedRouteID != nil && model.selectedVehicleID == nil && model.planner.selected == nil ? Set(model.routeVehicles().map(\.id)) : []
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
            let nextBuildingOpacity = model.highlightVehicle && hasVehicle ? 0.26 : 1.0
            if nextBuildingOpacity != buildingOpacityTarget || reduceMotion && buildingOpacity != nextBuildingOpacity {
                buildingOpacityTarget = nextBuildingOpacity
                buildingOpacity = buildingOpacityTarget
                buildingLayer?.fillExtrusionOpacityTransition = MLNTransition(duration: reduceMotion ? 0 : 0.25, delay: 0)
                buildingLayer?.fillExtrusionOpacity = NSExpression(forConstantValue: buildingOpacity)
            }
            if lastStationID != model.mapLabelStation?.id {
                stationSource?.shape = point(model.mapLabelStation?.coordinate)
                lastStationID = model.mapLabelStation?.id
                updateNearbyStations(force: true)
            }
            if model.stationWalk.isActive || model.selectedVehicleID == nil && model.mapLabelStation == nil { overlay.update(nil) }
            buses.setNeedsDisplay()
            updateStationAnchor()
        }

        private func updateTripStops() {
            if let station = model.stationWalk.target {
                let feature = MLNPointFeature(); feature.coordinate = station.coordinate.locationCoordinate
                feature.attributes = ["name": station.bilingualName, "stationID": station.id, "icon": "destination-marker", "waypoint": 0]
                tripStopsSource?.shape = MLNShapeCollectionFeature(shapes: [feature]); return
            }
            guard let option = model.planner.selected else { tripStopsSource?.shape = nil; return }
            var features: [String: MLNPointFeature] = [:]
            func add(_ coordinate: Coordinate, id: String, title: String, waypoint: Bool = false) {
                let feature = MLNPointFeature(); feature.coordinate = coordinate.locationCoordinate
                feature.attributes = ["name": title, "stationID": id, "icon": waypoint ? "journey-waypoint" : id == "destination" ? "journey-destination" : "journey-boarding", "waypoint": waypoint ? 1 : id == "destination" ? 2 : 0]; features[id] = feature
            }
            let visibleRides = option.rides.enumerated().filter { _, ride in
                !model.planner.started || model.planner.activeRide?.id == ride.id
            }
            for (index, ride) in visibleRides {
                let route = ride.route.name
                for stop in ride.stops.dropFirst().dropLast() where features[stop.stationID] == nil {
                    add(stop.coordinate, id: stop.stationID, title: stop.bilingualName, waypoint: true)
                    features[stop.stationID]?.attributes["icon"] = tripIcon("waypoint", route: route)
                }
                add(ride.boarding.coordinate, id: ride.boarding.stationID, title: AppText.text(index == 0 ? "上車" : "轉乘") + " · " + ride.boarding.bilingualName)
                features[ride.boarding.stationID]?.attributes["icon"] = tripIcon("boarding", route: route)
                add(ride.alighting.coordinate, id: ride.alighting.stationID,
                    title: AppText.text(index == option.rides.count - 1 ? "下車" : "轉乘") + " · " + ride.alighting.bilingualName)
                features[ride.alighting.stationID]?.attributes["icon"] = tripIcon("alighting", route: route)
            }
            if let destination = model.planner.destination,
               model.planner.activeRide == nil || (!model.planner.started && (option.rides.last?.alighting.coordinate.distance(to: destination.coordinate) ?? 100) > 35) {
                add(destination.coordinate, id: "destination", title: destination.localizedName)
            }
            tripStopsSource?.shape = MLNShapeCollectionFeature(shapes: features.keys.sorted().compactMap { features[$0] })
        }

        private func updateNearbyStations(force: Bool = false) {
            guard let map, nearbySource != nil else { return }
            // Hidden station labels need no distance scan, sort, or symbol-layout
            // update while the camera is zooming through the city view.
            guard model.stationBrowsing || map.zoomLevel >= 15.5 else { return }
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
                feature.attributes = ["stationID": station.id, "name": station.id == model.mapLabelStation?.id ? "" : station.bilingualName + " · " + station.localizedBearing]
                return feature
            }
            nearbySource?.shape = MLNShapeCollectionFeature(shapes: features)
        }

        private func updateStationAnchor() {
            guard !model.stationWalk.isActive, let map, let station = model.mapLabelStation else { return }
            let point = map.convert(station.coordinate.locationCoordinate, toPointTo: map)
            let visible = map.bounds.insetBy(dx: -20, dy: -20).contains(point)
            let global = visible ? map.convert(point, to: nil) : nil
            DispatchQueue.main.async { [weak self] in self?.overlay.update(global, zoom: map.zoomLevel) }
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            updateNearbyStations()
            let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
            DispatchQueue.main.async { [weak self] in self?.model.mapCenterChanged(center) }
            if model.cityFleetMode, model.selectedVehicleID == nil, model.selectedRouteID == nil, model.selectedStationID == nil,
               lastFocusRevision == model.focusRevision {
                cityCamera = savedCamera(mapView.camera)
            }
        }
        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool) {
#if DEBUG
            zoomProbe.frame(zoom: mapView.zoomLevel, busEncode: buses?.lastEncodeMilliseconds ?? 0)
#endif
            if !positionedInitialCamera, mapView.bounds.width > 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.update(location: self.pendingLocation)
                }
            }
            updateStationAnchor()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--test-transitions") { recordCameraSample(mapView) }
            recordPreviewCamera(mapView, fullyRendered: fullyRendered)
            recordTestCamera(mapView)
#endif
        }

#if DEBUG
        func mapViewDidFinishRenderingFrame(_ mapView: MLNMapView, fullyRendered: Bool,
            frameEncodingTime: Double, frameRenderingTime: Double) {
            zoomProbe.renderer(encoding: frameEncodingTime, rendering: frameRenderingTime)
        }

        private func setZoomProbeMode(_ mode: String) {
            guard let map, let style = map.style else { return }
            if mode == "begin" { zoomProbe.begin(mode: zoomProbeMode); return }
            if mode == "end" { zoomProbe.end(); return }
            zoomProbe.end()
            if zoomProbeCamera == nil { zoomProbeCamera = savedCamera(map.camera) }
            if zoomProbeVisibility.isEmpty {
                zoomProbeVisibility = Dictionary(uniqueKeysWithValues: style.layers.map { ($0.identifier, $0.isVisible) })
            }
            zoomProbeMode = mode
            for layer in style.layers {
                var visible = zoomProbeVisibility[layer.identifier] ?? layer.isVisible
                if mode == "no-poi", layer.identifier.hasPrefix("poi") { visible = false }
                if mode == "no-text", layer is MLNSymbolStyleLayer { visible = false }
                if mode == "no-3d", layer is MLNFillExtrusionStyleLayer { visible = false }
                if mode == "no-bus", layer === buses { visible = false }
                if mode == "old-labels", layer.identifier == "poi_dense_street" { visible = false }
                layer.isVisible = visible
            }
            if let camera = zoomProbeCamera { map.setCamera(savedCamera(camera), animated: false) }
            lastTestCameraAt = 0
        }

        private func recordTestCamera(_ mapView: MLNMapView) {
            if ProcessInfo.processInfo.arguments.contains("--test-map-controls"), mapView.style != nil,
               CACurrentMediaTime() - lastTestCameraAt >= 0.5 {
                lastTestCameraAt = CACurrentMediaTime()
                let center = Coordinate(latitude: mapView.centerCoordinate.latitude, longitude: mapView.centerCoordinate.longitude)
                var state: [String: Any] = ["latitude": center.latitude, "longitude": center.longitude, "zoom": mapView.zoomLevel,
                    "heading": mapView.direction, "pitch": mapView.camera.pitch, "mode": model.userMapMode.rawValue,
                    "station": model.selectedStationID ?? "", "stationDistance": model.selectedStation.map { center.distance(to: $0.coordinate) } ?? -1,
                    "queryMarkers": model.stationMapResults.count, "browsing": model.stationBrowsing,
                    "userMarkerVisible": !locationMarker.isHidden, "userHeadingVisible": locationMarker.headingVisible,
                    "userMarkerX": locationMarker.center.x, "userMarkerY": locationMarker.center.y,
                    "userFanAngle": locationMarker.directionAngle,
                    "stationSymbol": mapView.style?.layer(withIdentifier: "nearby-station-dots") is MLNSymbolStyleLayer]
                state["cityMode"] = model.cityFleetMode
                state["selectedVehicle"] = model.selectedVehicleID ?? ""
                state["following"] = model.following
                state["cameraMoving"] = cameraMoving || pendingInset != nil
                state["language"] = model.language.rawValue
                state["selectedJourney"] = model.planner.selectedID ?? ""
                state["actions"] = Array(model.debugActions.suffix(12))
                if ProcessInfo.processInfo.arguments.contains("--test-transitions") {
                    state["reduceMotion"] = reduceMotion
                    state["transitions"] = cameraTransitions.map { trace in
                        ["duration": trace.duration, "targetZoom": trace.targetZoom, "samples": trace.samples] as [String: Any]
                    }
                }
                state["darkMode"] = darkMode
                state["themeBackground"] = darkMode ? "#1C1D20" : "light"
                state["pid"] = ProcessInfo.processInfo.processIdentifier
                state["fleetInput"] = buses?.inputVehicleCount ?? 0
                state["fleetSampled"] = buses?.sampledVehicleCount ?? 0
                state["routeFleetEmphasized"] = buses?.emphasizedIDs.count ?? 0
                state["routeBoardingStop"] = model.routeBoardingStopID ?? ""
                state["routeBoardingStation"] = model.routeBoardingStop?.stationID ?? ""
                state["stationLabelCompact"] = overlay.compactStation
                state["stationWalkActive"] = model.stationWalk.isActive
                state["stationWalkPoints"] = model.stationWalk.coordinates.count
                state["stationWalkTarget"] = model.stationWalk.target?.id ?? ""
                state["autoVisibilityAdjustments"] = visibilityAdjustments
                state["walkingActive"] = model.activeWalkingIndex != nil
                state["walkingAccuracyConfigured"] = model.location.walkingAccuracyConfigured
                state["walkingConfirmed"] = model.planner.walkingProgress?.locationConfirmed ?? false
                state["walkingRemainingMeters"] = model.planner.walkingProgress?.remainingDistance ?? -1
                state["walkingRecalculating"] = model.planner.walkingRecalculating
                state["walkingLineColor"] = darkMode ? MapChrome.walkingDark : MapChrome.walkingLight
                state["walkingPointCount"] = model.activeWalkingIndex.map { model.planner.walkingCoordinates(at: $0).count } ?? 0
                let layerIDs = mapView.style?.layers.map(\.identifier) ?? []
                state["walkingAboveBuildings"] = (layerIDs.firstIndex(of: "journey-walking-line") ?? 0) > (layerIDs.firstIndex(of: "building-3d") ?? 0)
                state["fleetVisible"] = buses?.renderedVehicleCount ?? 0
                state["fleetModels"] = buses?.modelVehicleCount ?? 0
                state["fleetCompactModels"] = buses?.compactVehicleCount ?? 0
                state["fleetDetailedModels"] = buses?.detailedVehicleCount ?? 0
                state["fleetEncodeMs"] = buses?.lastEncodeMilliseconds ?? 0
                state["fleetDenseFrames"] = buses?.denseFrameCount ?? 0
                state["fleetEncodeP95Ms"] = buses?.denseEncodeP95 ?? 0
                state["fleetFrameMedianMs"] = buses?.denseFrameMedian ?? 0
                state["fleetFrameP95Ms"] = buses?.denseFrameP95 ?? 0
                if let pose = buses?.testMotionPose() {
                    state["fleetProbeID"] = pose.id; state["fleetProbeLongitude"] = pose.coordinate.longitude
                    state["fleetProbeObservedAt"] = pose.observedAt.timeIntervalSince1970
                    state["fleetProbeFrameTime"] = CACurrentMediaTime()
                }
                if let observation = buses?.testMotionObservation() {
                    state["fleetProbeSourceLongitude"] = observation.coordinate.longitude
                    state["fleetProbeSourceObservedAt"] = observation.observedAt.timeIntervalSince1970
                }
                state["gpsSourceUpdatedAt"] = model.snapshot.sourceUpdatedAt?.timeIntervalSince1970 ?? 0
                state["vehicleRefreshSeconds"] = min(model.liveSettings.refresh.vehicleSeconds, model.liveSettings.refresh.trackingSeconds)
                state["vehicle"] = model.selectedVehicleID ?? ""
                if let point = buses?.testVisiblePoint(in: mapView.bounds.inset(by: mapView.contentInset).insetBy(dx: 32, dy: 32)) {
                    state["busHitID"] = point.id; state["busHitX"] = point.point.x; state["busHitY"] = point.point.y
                }
                if model.stationBrowsing {
                    let visible = mapView.bounds.inset(by: mapView.contentInset).insetBy(dx: 24, dy: 24)
                    let markers = mapView.visibleFeatures(in: visible, styleLayerIdentifiers: Set(["nearby-station-dots"]))
                    if let id = markers.first?.attribute(forKey: "stationID") as? String, let station = model.metadata.stations[id] {
                        let pixel = mapView.convert(station.coordinate.locationCoordinate, toPointTo: mapView)
                        state["markerX"] = pixel.x; state["markerY"] = pixel.y; state["markerID"] = id
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--test-zoom-performance") {
                    state["zoomPerformance"] = zoomProbe.summary
                    state["zoomMode"] = zoomProbeMode
                }
                DispatchQueue.main.async { [weak self] in self?.overlay.recordCamera(state) }
                if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                   let bytes = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
                    try? bytes.write(to: folder.appendingPathComponent("appearance-probe.json"), options: .atomic)
                }
            }
        }
#endif

        private func point(_ coordinate: Coordinate?) -> MLNPointFeature? {
            guard let coordinate else { return nil }
            let feature = MLNPointFeature()
            feature.coordinate = coordinate.locationCoordinate
            return feature
        }

        private func focus(_ focus: MapFocus?, map: MLNMapView, duration: Double = 0.65) {
            guard let focus else { return }
            let wasLeavingCity = lastFocusWasLeavingCity
            if case .leaveCity = focus { lastFocusWasLeavingCity = true }
            else { lastFocusWasLeavingCity = false }
            switch focus {
            case .coordinate(let position):
                showPoint(position, altitude: 700, heading: 0, pitch: 0, map: map, duration: duration)
            case .station(let id):
                guard let station = model.metadata.stations[id] else { return }
                showPoint(station.coordinate, altitude: 480, heading: 0, pitch: 0, map: map, duration: duration)
            case .userLocation:
                guard let point = model.location.displayCoordinate, point.isInServiceArea else { return }
                let heading = model.userMapMode == .heading ? model.location.currentHeading ?? map.direction : 0
                let walking = model.activeWalkingIndex != nil || model.stationWalk.isActive
                showPoint(point, altitude: walking ? 350 : 600, heading: heading,
                          pitch: walking ? 0 : model.userMapMode == .heading ? 45 : 0,
                          map: map, duration: duration)
            case .vehicle(let id):
                guard let bus = model.snapshot.vehicles.first(where: { $0.id == id }) else { return }
                let position = buses?.pose(id: id, time: CACurrentMediaTime(), now: Date())?.coordinate ?? bus.coordinate
                if model.cityFleetMode, cityCamera == nil { cityCamera = savedCamera(map.camera) }
                moveCamera(MLNMapCamera(lookingAtCenter: position.locationCoordinate,
                                          altitude: 245, pitch: 57, heading: map.direction),
                           map: map, duration: duration)
            case .route(let id):
                var coordinates = model.metadata.displayPaths(routeID: id, direction: model.direction,
                                                               allVariants: model.allRouteVariants).flatMap { $0 }
                if coordinates.isEmpty {
                    coordinates = model.metadata.displayStops(routeID: id, direction: model.direction,
                                                               allVariants: model.allRouteVariants).map(\.coordinate)
                }
                if coordinates.isEmpty { coordinates = model.routeVehicles().map(\.coordinate) }
                if model.planner.selected == nil { coordinates += model.routeMapVehicles.filter { $0.hasReliablePosition(at: Date()) }.map(\.coordinate) }
                if let camera = fittedCamera(coordinates, map: map) { moveCamera(camera, map: map, duration: duration) }
            case .journey(let coordinates):
                if let camera = fittedCamera(coordinates, map: map) { moveCamera(camera, map: map, duration: duration) }
            case .cityOverview:
                if beforeCityCamera == nil {
                    beforeCityCamera = savedCamera(wasLeavingCity ? lastCameraTarget ?? map.camera : map.camera)
                }
                cityCamera = nil
                let points = model.cityVehicles.map(\.coordinate)
                let defaults = [Coordinate(latitude: 24.99, longitude: 121.43), Coordinate(latitude: 25.15, longitude: 121.68)]
                if let camera = fittedCamera(points.isEmpty ? defaults : points, map: map, pitch: 0) {
                    cityCamera = savedCamera(camera)
                    moveCamera(camera, map: map, duration: duration)
                }
            case .returnToCity:
                let target = lastCameraTargetRevision == model.focusRevision ? lastCameraTarget : cityCamera
                if let target { moveCamera(savedCamera(target), map: map, duration: duration) }
            case .leaveCity:
                // A panel can finish resizing after restoration has started. Keep
                // its target even after clearing the city browsing session.
                let target = lastCameraTargetRevision == model.focusRevision ? lastCameraTarget : beforeCityCamera
                if let target { moveCamera(savedCamera(target), map: map, duration: duration) }
                cityCamera = nil; beforeCityCamera = nil
            }
        }
        private func savedCamera(_ camera: MLNMapCamera) -> MLNMapCamera {
            MLNMapCamera(lookingAtCenter: camera.centerCoordinate, altitude: camera.altitude, pitch: camera.pitch, heading: camera.heading)
        }

        private func showPoint(_ point: Coordinate, altitude: Double, heading: Double, pitch: Double,
                               map: MLNMapView, duration: Double) {
            moveCamera(MLNMapCamera(lookingAtCenter: point.locationCoordinate, altitude: altitude, pitch: pitch, heading: heading),
                       map: map, duration: duration)
        }

        private func moveCamera(_ camera: MLNMapCamera, map: MLNMapView, duration: Double) {
            lastCameraTarget = savedCamera(camera); lastCameraTargetRevision = model.focusRevision
            let targetZoom = MLNZoomLevelForAltitude(camera.altitude, camera.pitch, camera.centerCoordinate.latitude, map.bounds.size)
            let travel = min(1.4, abs(targetZoom - map.zoomLevel) * 0.14 + 0.2)
            let seconds = reduceMotion ? 0 : max(duration, travel)
            cameraMoveToken += 1
            let token = cameraMoveToken
            cameraMoving = seconds > 0
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--test-transitions") {
                if let index = cameraTransitions.indices.last, cameraTransitions[index].revision == model.focusRevision {
                    cameraTransitions[index].duration = reduceMotion ? 0 : CACurrentMediaTime() - cameraTransitions[index].started + seconds
                    cameraTransitions[index].targetZoom = targetZoom
                } else {
                    cameraTransitions.append(CameraTransitionTrace(started: CACurrentMediaTime(), revision: model.focusRevision,
                        duration: seconds, targetZoom: targetZoom))
                }
                if cameraTransitions.count > 8 { cameraTransitions.removeFirst() }
                recordCameraSample(map)
            }
#endif
            map.setCamera(camera, withDuration: seconds,
                animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut)) { [weak self, weak map] in
                guard let self, let map, self.cameraMoveToken == token else { return }
                self.cameraMoving = false
                self.followSuspendedUntil = CACurrentMediaTime() + 0.04
                self.applyPendingInset(map)
            }
        }

        private func fittedCamera(_ coordinates: [Coordinate], map: MLNMapView, pitch requestedPitch: Double? = nil) -> MLNMapCamera? {
            let pitch = requestedPitch ?? (model.stationBrowsing || model.activeWalkingIndex != nil || model.stationWalk.isActive ? 0 : 35)
            guard let overview = RouteOverview(coordinates: coordinates,
                viewportWidth: Double(map.bounds.width - map.contentInset.left - map.contentInset.right),
                viewportHeight: Double(map.bounds.height - map.contentInset.top - map.contentInset.bottom), pitch: pitch) else { return nil }
            // Convert the existing verified framing to one camera, so center, zoom,
            // tilt and padding travel together instead of two instantaneous moves.
            let altitude = MLNAltitudeForZoomLevel(overview.zoom, pitch, overview.center.latitude, map.bounds.size)
            return MLNMapCamera(lookingAtCenter: overview.center.locationCoordinate, altitude: altitude, pitch: pitch, heading: 0)
        }

#if DEBUG
        private func recordCameraSample(_ map: MLNMapView) {
            guard let index = cameraTransitions.indices.last else { return }
            let elapsed = CACurrentMediaTime() - cameraTransitions[index].started
            let last = cameraTransitions[index].samples.last
            let hasCompletion = (last?["t"] ?? -1) >= cameraTransitions[index].duration &&
                abs((last?["zoom"] ?? -100) - cameraTransitions[index].targetZoom) < 0.01
            guard elapsed <= cameraTransitions[index].duration + 0.3 || !hasCompletion else { return }
            let sample = ["t": elapsed, "zoom": map.zoomLevel,
                "latitude": map.centerCoordinate.latitude, "longitude": map.centerCoordinate.longitude,
                "pitch": map.camera.pitch]
            if cameraTransitions[index].samples.count >= 240 { cameraTransitions[index].samples.removeLast() }
            cameraTransitions[index].samples.append(sample)
        }

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
                viewportHeight: Double(map.bounds.height - map.contentInset.top - map.contentInset.bottom), pitch: Double(map.camera.pitch))
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
#if DEBUG
            let tickStarted = CACurrentMediaTime()
            defer { zoomProbe.tick(milliseconds: (CACurrentMediaTime() - tickStarted) * 1000) }
            if zoomProbeMode == "light-tick" {
                recordTestCamera(map)
                buses?.setNeedsDisplay()
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--test-transitions") { recordCameraSample(map) }
            recordTestCamera(map)
#endif
            let now = CACurrentMediaTime(), date = Date()
            let dt = lastTickTime > 0 ? min(0.1, max(0.001, now - lastTickTime)) : 1 / 60
            lastTickTime = now
            updateLocationMarker(map, elapsed: dt)
            guard let buses else { return }
            if now - lastPowerCheck > 1 {
                let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                // Low Power Mode and a hot device fall back to 60 Hz; motion stays smooth either way.
                var rate = lowPower ? 60 : fullFrameRate
#if DEBUG
                if zoomProbeMode == "60hz" { rate = 60 }
#endif
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: Float(rate), preferred: Float(rate))
                map.preferredFramesPerSecond = MLNMapViewPreferredFramesPerSecond(rawValue: rate)
                lastPowerCheck = now
            }
            if buses.isAnimating(time: now, now: date) { buses.setNeedsDisplay() }
            // Tile loading can delay a flight beyond its requested duration. Wait
            // for MapLibre's completion before following or avoiding buildings.
            guard !cameraMoving else { return }
            if now >= followSuspendedUntil { keepSelectedVehicleVisible(map, at: now) }
            guard !cameraMoving else { return }
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
            guard let point = locationMotion.coordinate else { locationMarker.isHidden = true; overlay.userPoint = nil; return }
            let screen = map.convert(point.locationCoordinate, toPointTo: map)
            guard screen.x.isFinite, screen.y.isFinite else { locationMarker.isHidden = true; return }
            locationMarker.isHidden = !map.bounds.insetBy(dx: -48, dy: -48).contains(screen)
            locationMarker.center = screen
            overlay.userPoint = locationMarker.isHidden ? nil : map.convert(screen, to: nil)
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
                lastFocusWasLeavingCity = false
                cameraMoveToken += 1; cameraMoving = false
                DispatchQueue.main.async { [weak self] in
                    self?.model.mapWasMoved = true
                    self?.model.following = false
                    self?.model.stopUserTracking()
                    if let self, let map = self.map { self.applyPendingInset(map) }
                }
            }
        }

        private func captureDayPalette(_ style: MLNStyle) {
            dayPaints = [:]
            for layer in style.layers {
                var paints: [String: NSExpression] = [:]
                if let layer = layer as? MLNBackgroundStyleLayer { paints["background"] = layer.backgroundColor }
                if let layer = layer as? MLNFillStyleLayer {
                    paints["fill"] = layer.fillColor; paints["outline"] = layer.fillOutlineColor
                    paints["pattern"] = layer.fillPattern
                }
                if let layer = layer as? MLNLineStyleLayer { paints["line"] = layer.lineColor }
                if let layer = layer as? MLNSymbolStyleLayer {
                    paints["text"] = layer.textColor; paints["halo"] = layer.textHaloColor
                    paints["labelField"] = layer.text
                }
                dayPaints[layer.identifier] = paints
            }
        }

        private func keepSelectedVehicleVisible(_ map: MLNMapView, at time: CFTimeInterval) {
            guard model.following, !model.mapWasMoved, model.userMapMode == .free,
                  let vehicle = model.selectedVehicle,
                  map.zoomLevel >= 15, map.camera.pitch > 1,
                  time - lastVisibilityCheck >= 1.5 else { return }
            let point = buses?.pose(id: vehicle.id, time: time, now: Date())?.coordinate ?? vehicle.coordinate
            if visibilityVehicleID == vehicle.id, let previous = lastVisibilityTarget,
               previous.distance(to: point) < 25, time - lastVisibilityCheck < 10 { return }
            lastVisibilityCheck = time; lastVisibilityTarget = point; visibilityVehicleID = vehicle.id
            func coordinates(_ polygon: MLNPolygon) -> [Coordinate] {
                var points = Array(repeating: CLLocationCoordinate2D(), count: Int(polygon.pointCount))
                polygon.getCoordinates(&points, range: NSRange(location: 0, length: points.count))
                return points.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
            }
            // Only buildings between the camera and the bus can hide it: on screen that is the
            // band below and beside the bus. Querying just that band keeps the check off the frame budget.
            let busPoint = map.convert(point.locationCoordinate, toPointTo: map)
            let band = CGRect(x: busPoint.x - 170, y: busPoint.y - 40, width: 340, height: map.bounds.maxY - busPoint.y + 40)
                .intersection(map.bounds)
            guard !band.isNull, !band.isEmpty else { return }
            let features = map.visibleFeatures(in: band, styleLayerIdentifiers: Set(["building-3d"]))
            var footprints = features.flatMap { feature -> [MapBuilding] in
                let value = feature.attribute(forKey: "render_height")
                let height = (value as? NSNumber)?.doubleValue ?? Double(value as? String ?? "") ?? 0
                let baseHeight = (feature.attribute(forKey: "render_min_height") as? NSNumber)?.doubleValue ?? 0
                guard height > 2 else { return [] }
                let polygons: [MLNPolygon]
                if let polygon = feature as? MLNPolygon { polygons = [polygon] }
                else if let multi = feature as? MLNMultiPolygon { polygons = multi.polygons }
                else { return [] }
                return polygons.map { polygon in
                    MapBuilding(rings: [coordinates(polygon)] + (polygon.interiorPolygons ?? []).map(coordinates), height: height, baseHeight: baseHeight)
                }
            }
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--test-occlusion"), visibilityAdjustments == 0 {
                let meters = 1 / 111_320.0
                footprints = [MapBuilding(rings: [[
                    Coordinate(latitude: point.latitude - 35 * meters, longitude: point.longitude - 12 * meters),
                    Coordinate(latitude: point.latitude - 35 * meters, longitude: point.longitude + 12 * meters),
                    Coordinate(latitude: point.latitude - 12 * meters, longitude: point.longitude + 12 * meters),
                    Coordinate(latitude: point.latitude - 12 * meters, longitude: point.longitude - 12 * meters)
                ]], height: 90)]
            }
#endif
            let camera = map.camera
            if footprints.isEmpty { lastVisibilityTarget = nil; return }
            guard CameraVisibility.isBlocked(target: point, altitude: camera.altitude, heading: camera.heading,
                                             pitch: camera.pitch, buildings: footprints) else { return }
            let angle = CameraVisibility.clearAngle(target: point, altitude: camera.altitude, heading: camera.heading,
                                                   pitch: camera.pitch, buildings: footprints)
            camera.heading = reduceMotion ? camera.heading : angle.heading
            consecutiveVisibilityAdjustments = time - lastVisibilityAdjustmentAt < 8 ? consecutiveVisibilityAdjustments + 1 : 1
            lastVisibilityAdjustmentAt = time; lastVisibilityTarget = nil
            camera.pitch = reduceMotion || consecutiveVisibilityAdjustments >= 3 ? 0 : angle.pitch
            camera.centerCoordinate = point.locationCoordinate
            camera.altitude = MLNAltitudeForZoomLevel(map.zoomLevel, camera.pitch, point.latitude, map.bounds.size)
            visibilityAdjustments += 1
            moveCamera(camera, map: map, duration: 0.5)
        }

        /// Terrain relief is baked ahead of time, as mainstream maps do, into one bundled
        /// Web-Mercator image for greater Taipei. Drawing it is a plain texture blend, so camera
        /// flights never wait on on-device elevation processing.
        private func installRelief(_ style: MLNStyle) {
            guard style.source(withIdentifier: "relief") == nil,
                  let url = Bundle.main.url(forResource: "hillshade-taipei", withExtension: "png"),
                  let image = UIImage(contentsOfFile: url.path) else { return }
            let quad = MLNCoordinateQuad(topLeft: CLLocationCoordinate2D(latitude: 25.36, longitude: 120.95),
                                         bottomLeft: CLLocationCoordinate2D(latitude: 24.55, longitude: 120.95),
                                         bottomRight: CLLocationCoordinate2D(latitude: 24.55, longitude: 122.10),
                                         topRight: CLLocationCoordinate2D(latitude: 25.36, longitude: 122.10))
            let source = MLNImageSource(identifier: "relief", coordinateQuad: quad, image: image)
            style.addSource(source)
            let layer = MLNRasterStyleLayer(identifier: "relief", source: source)
            layer.maximumZoomLevel = 15
            layer.rasterFadeDuration = NSExpression(forConstantValue: 0)
            if let water = style.layer(withIdentifier: "waterway_tunnel") { style.insertLayer(layer, below: water) }
            else { style.addLayer(layer) }
            reliefLayer = layer
            applyReliefAppearance()
        }
        private weak var reliefLayer: MLNRasterStyleLayer?
        private func applyReliefAppearance() {
            guard let layer = reliefLayer else { return }
            let peak = darkMode ? 0.55 : 0.9
            layer.rasterOpacity = NSExpression(mglJSONObject: ["interpolate", ["linear"], ["zoom"],
                6, 0, 7, peak, 12, peak * 0.85, 13.5, peak * 0.4, 14.5, 0])
            // Dark mode keeps the shadows but dims the highlights so slopes do not glow.
            layer.maximumRasterBrightness = NSExpression(forConstantValue: darkMode ? 0.35 : 1)
        }

        private func applyBasePalette(_ style: MLNStyle) {
            func color(_ value: String) -> NSExpression { NSExpression(forConstantValue: UIColor(liveHex: value)) }
            for (id, day) in dayPaints {
                guard let layer = style.layer(withIdentifier: id) else { continue }
                if let layer = layer as? MLNBackgroundStyleLayer {
                    layer.backgroundColor = darkMode ? color("#1C1D20") : day["background"]
                }
                if let layer = layer as? MLNFillStyleLayer {
                    let shade: String
                    if id.contains("water") { shade = "#1D3A52" }
                    else if ["park", "wood", "grass", "wetland", "cemetery", "pitch", "farmland"].contains(where: id.contains) { shade = "#21352A" }
                    else if id.contains("commercial") { shade = "#2B2826" }
                    else if id.contains("industrial") { shade = "#26252B" }
                    else if id.contains("building") { shade = "#2E3035" }
                    else if id.contains("hospital") { shade = "#33282B" }
                    else if id.contains("sand") { shade = "#2F2D25" }
                    else { shade = "#222327" }
                    layer.fillColor = darkMode ? color(shade) : day["fill"]
                    layer.fillOutlineColor = darkMode ? color(shade) : day["outline"]
                    // Only the road-area layer has a pattern. Writing a captured empty pattern
                    // back to ordinary fills stops them drawing, so water and parks vanished.
                    if id == "road_area_pattern" { layer.fillPattern = darkMode ? nil : day["pattern"] }
                }
                if let layer = layer as? MLNLineStyleLayer {
                    let shade: String
                    if id.contains("casing") { shade = "#151618" }
                    else if id.contains("water") { shade = "#24465F" }
                    else if id.contains("boundary") { shade = "#5A5D66" }
                    else if id.contains("motorway") { shade = "#7B6838" }
                    else if id.contains("trunk") { shade = "#5E5A4C" }
                    else if id.contains("rail") { shade = "#4A4C52" }
                    else { shade = "#45474D" }
                    layer.lineColor = darkMode ? color(shade) : day["line"]
                }
                if let layer = layer as? MLNSymbolStyleLayer {
                    if id.hasPrefix("poi") {
                        // Places keep their category colour, lifted for the dark map.
                        layer.textColor = darkMode ? Self.poiDarkTextColor : day["text"]
                    } else {
                        layer.textColor = darkMode ? color(id.contains("water") ? "#7FB2DA" : "#C7C9CF") : day["text"]
                    }
                    layer.textHaloColor = darkMode ? color("#1C1D20") : day["halo"]
                }
            }
        }

        private func applyAppearance(_ style: MLNStyle) {
            applyBasePalette(style)
            applyReliefAppearance()
            applyLabelLanguage(style)
            // Light map colours come from the bundled style; dark mode uses the
            // neutral palette in applyBasePalette. Route lines carry their own tint.
            (style.layer(withIdentifier: "selected-route-casing") as? MLNLineStyleLayer)?.lineColor = NSExpression(forConstantValue: UIColor(liveHex: darkMode ? "#101215" : "#FFFFFF"))
            (style.layer(withIdentifier: "journey-walking-line") as? MLNLineStyleLayer)?.lineColor = NSExpression(forConstantValue: UIColor(liveHex: darkMode ? MapChrome.walkingDark : MapChrome.walkingLight))
            (style.layer(withIdentifier: "journey-walking-casing") as? MLNLineStyleLayer)?.lineColor = NSExpression(forConstantValue: UIColor(liveHex: darkMode ? "#101215" : "#FFFFFF"))
            (style.layer(withIdentifier: "building-3d") as? MLNFillExtrusionStyleLayer)?.fillExtrusionColor = NSExpression(forConstantValue: UIColor(liveHex: darkMode ? "#34363C" : "#E6E3DB"))
            for id in ["journey-stop-names", "journey-waypoint-names", "journey-destination-name", "nearby-station-names"] {
                if let names = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer {
                    names.textColor = NSExpression(forConstantValue: UIColor(liveHex: darkMode ? "#F2F2F7" : "#1F3F66"))
                    names.textHaloColor = NSExpression(forConstantValue: UIColor(liveHex: darkMode ? "#1C1D20" : "#FFFFFF"))
                    names.textHaloWidth = NSExpression(forConstantValue: 2)
                }
            }
            installMarkerImages(style)
        }

        private func applyLabelLanguage(_ style: MLNStyle) {
            for (id, fields) in dayPaints {
                guard let layer = style.layer(withIdentifier: id) as? MLNSymbolStyleLayer,
                      let original = fields["labelField"], String(describing: original.mgl_jsonExpressionObject).contains("name:zh") else { continue }
                layer.text = model.language == .english
                    ? NSExpression(mglJSONObject: ["coalesce", ["get", "name:en"], ["get", "name_en"], ["get", "name:latin"], ["get", "name"]]) : original
            }
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            DispatchQueue.main.async { [weak self] in self?.model.mapError = "底圖載入失敗，仍可查站牌與到站資訊" }
        }

        @objc func selectBus(_ gesture: UITapGestureRecognizer) {
            guard let map, let buses else { return }
            let point = gesture.location(in: map)
#if DEBUG
            model.recordMapTap("map-tap:\(Int(point.x)),\(Int(point.y))")
#endif
            let rect = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let features = map.visibleFeatures(in: rect, styleLayerIdentifiers: Set(["nearby-station-dots", "nearby-station-names", "journey-stop-dots", "journey-waypoint-dots", "journey-stop-names"]))
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
#if DEBUG
                model.recordMapTap("map-tap:no-bus")
#endif
                if let station { model.selectStation(station) }
                return
            }
            // Only rendered 3D buildings can occlude a bus. Cached building
            // footprints must not block taps in the flat, zoomed-out city view.
            let buildings = map.style?.layer(withIdentifier: "building-3d")
            let buildingsVisible = buildings?.isVisible == true && buildingOpacity > 0.02 &&
                map.zoomLevel >= Double(buildings?.minimumZoomLevel ?? 15) &&
                map.zoomLevel < Double(buildings?.maximumZoomLevel ?? 24)
            let occluded = buildingsVisible && !(model.highlightVehicle && model.selectedVehicleID == id) &&
                !map.visibleFeatures(at: point, styleLayerIdentifiers: Set(["building-3d"])).isEmpty
#if DEBUG
            model.recordMapTap("map-hit:\(bus.plate):occluded=\(occluded)")
#endif
            if occluded { return }
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

#if DEBUG
/// Callback cadence is a simulator rendering measurement, not a physical-display FPS claim.
private final class ZoomPerformanceProbe {
    private var active = false
    private var mode = "baseline"
    private var began = 0.0
    private var lastFrame = 0.0
    private var frames = 0
    private var gaps: [Double] = []
    private var busTimes: [Double] = []
    private var tickTimes: [Double] = []
    private var encodingTimes: [Double] = []
    private var renderingTimes: [Double] = []
    private var minZoom = 99.0
    private var maxZoom = 0.0
    private(set) var summary: [String: Any] = ["complete": false]
    func begin(mode: String) {
        self.mode = mode; began = CACurrentMediaTime(); lastFrame = 0; frames = 0
        gaps.removeAll(keepingCapacity: true); busTimes.removeAll(keepingCapacity: true)
        tickTimes.removeAll(keepingCapacity: true); encodingTimes.removeAll(keepingCapacity: true)
        renderingTimes.removeAll(keepingCapacity: true); minZoom = 99; maxZoom = 0
        summary = ["mode": mode, "complete": false]; active = true
    }
    func frame(zoom: Double, busEncode: Double) {
        guard active else { return }
        let now = CACurrentMediaTime()
        if lastFrame > 0, gaps.count < 6000 { gaps.append((now - lastFrame) * 1000) }
        lastFrame = now; frames += 1; minZoom = min(minZoom, zoom); maxZoom = max(maxZoom, zoom)
        if busTimes.count < 6000 { busTimes.append(busEncode) }
    }
    func tick(milliseconds: Double) {
        if active, tickTimes.count < 6000 { tickTimes.append(milliseconds) }
    }
    func renderer(encoding: Double, rendering: Double) {
        guard active else { return }
        if encoding.isFinite, encoding >= 0, encodingTimes.count < 6000 { encodingTimes.append(encoding) }
        if rendering.isFinite, rendering >= 0, renderingTimes.count < 6000 { renderingTimes.append(rendering) }
    }
    func end() {
        guard active else { return }
        active = false
        let elapsed = CACurrentMediaTime() - began
        func stats(_ values: [Double]) -> [String: Any] {
            let ordered = values.sorted()
            func percentile(_ p: Double) -> Double {
                ordered.isEmpty ? 0 : ordered[min(ordered.count - 1, Int(Double(ordered.count - 1) * p))]
            }
            return ["samples": ordered.count, "median_ms": percentile(0.5), "p95_ms": percentile(0.95),
                "p99_ms": percentile(0.99), "max_ms": ordered.last ?? 0,
                "over_33ms": ordered.filter { $0 > 33.34 }.count, "over_100ms": ordered.filter { $0 > 100 }.count]
        }
        summary = ["mode": mode, "complete": true, "elapsed_seconds": elapsed, "render_callbacks": frames,
            "render_callbacks_per_second": Double(frames) / max(0.001, elapsed), "min_zoom": minZoom, "max_zoom": maxZoom,
            "callback_gap": stats(gaps), "bus_encode": stats(busTimes), "tick": stats(tickTimes),
            "map_encoding": stats(encodingTimes), "map_rendering": stats(renderingTimes)]
    }
}
#endif
