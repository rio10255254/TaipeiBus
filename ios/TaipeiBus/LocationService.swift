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
    private let manager = CLLocationManager()
    var usableCoordinate: Coordinate? {
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways,
              let updatedAt, abs(updatedAt.timeIntervalSinceNow) < 300 else { return nil }
        return coordinate
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func request() {
        message = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            requesting = true
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requesting = true
            manager.requestLocation()
        case .restricted, .denied:
            requesting = false
            message = "定位未開啟，可手動選擇出發地"
        @unknown default:
            message = "目前無法定位，可手動選擇出發地或站牌"
        }
    }

    func requestIfAuthorized() {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { request() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if requesting { request() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        requesting = false
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 120 else {
            message = "尚未取得位置，可手動選擇出發地或站牌"; return
        }
        coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        accuracy = location.horizontalAccuracy
        updatedAt = location.timestamp
        if coordinate?.isInServiceArea == false { message = "目前在服務範圍外，可手動選擇台北出發地" }
        else if location.horizontalAccuracy > 100 { message = "定位約 ±\(Int(location.horizontalAccuracy.rounded())) m，請確認站牌方向" }
        else { message = nil }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        requesting = false
        message = "目前無法定位，可手動選擇出發地或站牌"
    }
}
