import CoreLocation
import Combine
import TransitCore

@MainActor
final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var coordinate: Coordinate?
    @Published private(set) var message: String?
    @Published private(set) var requesting = false
    @Published private(set) var accuracy: Double?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var revision = 0
    private(set) var heading: Double?
    private(set) var headingAccuracy: Double?
    private var headingTime = Date.distantPast
    private let manager = CLLocationManager()
    private var sample: LocationSample?
    private var active = false
    private var updating = false
    private var permissionRequested = false
    private var timeoutTask: Task<Void, Never>?
    private let cacheKey = "recentDeviceLocation.v1"
    private var settings = LiveSettings.defaults
    private var lastRestart = Date.distantPast
    private var walkingNavigation = false
    var permissionDenied: Bool { manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted }
    func setWalkingNavigation(_ enabled: Bool) {
        guard walkingNavigation != enabled else { return }
        walkingNavigation = enabled
        manager.desiredAccuracy = enabled ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = enabled ? 3 : 20
        manager.activityType = enabled ? .fitness : .otherNavigation
        manager.pausesLocationUpdatesAutomatically = !enabled
        if enabled, active, authorized { manager.startUpdatingLocation(); updating = true }
    }
#if DEBUG
    var walkingAccuracyConfigured: Bool { manager.desiredAccuracy == kCLLocationAccuracyBestForNavigation && manager.distanceFilter == 3 }
    private(set) var requestStartedAt: Date?
    private(set) var firstUsableMilliseconds: Double?
#endif
    private var authorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }
    var displayCoordinate: Coordinate? {
        guard authorized, let sample, sample.canDisplay(at: Date()) else { return nil }
        return sample.coordinate
    }
    var usableCoordinate: Coordinate? {
        guard authorized, let sample, sample.canPlan(at: Date()) else { return nil }
        return sample.coordinate
    }
    var currentHeading: Double? {
#if DEBUG
        if active, authorized, ProcessInfo.processInfo.arguments.contains("--test-device-heading") { return 90 }
#endif
        return active && authorized && Date().timeIntervalSince(headingTime) <= 60 ? heading : nil
    }
    private func updateHeadingActivity() {
        manager.headingOrientation = .portrait
        manager.headingFilter = 3
        if active, authorized, CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        else { manager.stopUpdatingHeading() }
#if DEBUG
        if active, authorized, ProcessInfo.processInfo.arguments.contains("--test-device-heading") {
            heading = 90; headingAccuracy = 5; headingTime = Date()
        }
#endif
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 20
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = true
    }
    func updateSettings(_ settings: LiveSettings) {
        self.settings = settings
        if let sample, sample.accuracy > 120, sample.canDisplay(at: Date()), sample.coordinate.isInServiceArea {
            message = AppText.text("位置約 ±%@ 公尺", Int(sample.accuracy.rounded()))
        } else if let value = message { message = settings.text(value) }
    }
    func setActive(_ active: Bool) {
        self.active = active
        if active { requestIfAuthorized(); updateHeadingActivity() }
        else {
            timeoutTask?.cancel(); timeoutTask = nil
            manager.stopUpdatingLocation(); updating = false; requesting = false
            manager.stopUpdatingHeading()
        }
    }
    func request() {
#if DEBUG
        if requestStartedAt == nil { requestStartedAt = Date() }
#endif
        switch manager.authorizationStatus {
        case .notDetermined:
            guard !permissionRequested else { return }
            permissionRequested = true; requesting = true; message = nil
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            permissionRequested = false
            // Start with recent positions already available to the app and the system.
            if let bytes = UserDefaults.standard.data(forKey: cacheKey),
               let cached = try? JSONDecoder().decode(LocationSample.self, from: bytes) { accept(cached) }
            if let cached = manager.location { accept(Self.sample(cached)) }
            requesting = displayCoordinate == nil
            if usableCoordinate != nil { message = nil }
            else if let sample, sample.canDisplay(at: Date()), Date().timeIntervalSince(sample.timestamp) > 60 { message = settings.text("上次位置，正在更新") }
            guard active else { return }
            if updating {
                guard Date().timeIntervalSince(updatedAt ?? .distantPast) > 30, Date().timeIntervalSince(lastRestart) > 10 else { return }
                manager.stopUpdatingLocation()
            }
            updating = true
            lastRestart = Date()
            manager.desiredAccuracy = walkingNavigation ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyHundredMeters
            manager.startUpdatingLocation()
            updateHeadingActivity()
            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.requesting = false
                if self.displayCoordinate == nil { self.message = self.settings.text("目前無法定位，可手動選擇出發地或站牌") }
                // Keep foreground updates available to recover from a temporarily missing fix.
            }
        case .restricted, .denied:
            permissionRequested = false; requesting = false; updating = false
            manager.stopUpdatingLocation(); timeoutTask?.cancel()
            manager.stopUpdatingHeading(); heading = nil
            sample = nil; coordinate = nil; accuracy = nil; updatedAt = nil; revision += 1
            message = settings.text("定位未開啟，可手動選擇出發地")
        @unknown default:
            requesting = false
            message = settings.text("目前無法定位，可手動選擇出發地或站牌")
        }
    }
    func requestIfAuthorized() { if authorized { request() } }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if authorized, active || permissionRequested { request() }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { request() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) { accept(Self.sample(location)) }
        if displayCoordinate != nil {
            requesting = false; timeoutTask?.cancel(); timeoutTask = nil
            // Refinement happens after publishing the first useful position.
            manager.desiredAccuracy = walkingNavigation ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyNearestTenMeters
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading value: CLHeading) {
        guard active, authorized else { return }
        guard value.headingAccuracy >= 0, value.headingAccuracy <= 45,
              abs(value.timestamp.timeIntervalSinceNow) <= 10 else { heading = nil; headingAccuracy = nil; return }
        let direction = value.trueHeading >= 0 ? value.trueHeading : value.magneticHeading
        guard direction.isFinite, direction >= 0 else { return }
        heading = direction.truncatingRemainder(dividingBy: 360); headingTime = value.timestamp; headingAccuracy = value.headingAccuracy
    }
    private static func sample(_ location: CLLocation) -> LocationSample {
        LocationSample(coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                       accuracy: location.horizontalAccuracy, timestamp: location.timestamp)
    }
    private func accept(_ value: LocationSample) {
        guard authorized, value.shouldReplace(sample, at: Date()) else { return }
        guard value != sample else { return }
        sample = value; coordinate = value.coordinate; accuracy = value.accuracy; updatedAt = value.timestamp
        if let bytes = try? JSONEncoder().encode(value) { UserDefaults.standard.set(bytes, forKey: cacheKey) }
        if !value.coordinate.isInServiceArea { message = settings.text("目前在服務範圍外，可手動選擇台北出發地") }
        else if Date().timeIntervalSince(value.timestamp) > 60 { message = settings.text("上次位置，正在更新") }
        else if value.accuracy > 120 { message = AppText.text("位置約 ±%@ 公尺", Int(value.accuracy.rounded())) }
        else { message = nil }
        revision += 1
#if DEBUG
        if firstUsableMilliseconds == nil, value.canPlan(at: Date()), let started = requestStartedAt {
            firstUsableMilliseconds = Date().timeIntervalSince(started) * 1_000
        }
#endif
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let failure = error as? CLError, failure.code == .locationUnknown { return }
        requesting = false
        if usableCoordinate == nil { message = settings.text("目前無法定位，可手動選擇出發地或站牌") }
    }
}
