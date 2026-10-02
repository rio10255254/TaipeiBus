import CoreLocation
import Combine
import TransitCore

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: Coordinate?
    @Published private(set) var message: String?
    @Published private(set) var requesting = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
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
            message = "定位未開啟，可直接搜尋站牌"
        @unknown default:
            message = "目前無法定位，可直接搜尋站牌"
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
            message = "尚未取得位置，可直接搜尋站牌"; return
        }
        coordinate = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        if coordinate?.isInServiceArea == false { message = "目前在服務範圍外，可搜尋台北站牌" }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        requesting = false
        message = "目前無法定位，可直接搜尋站牌"
    }
}
