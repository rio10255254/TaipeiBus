import Foundation
import MapKit
import UIKit
@main final class Probe: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds); window?.rootViewController = UIViewController(); window?.makeKeyAndVisible()
        Task { @MainActor in
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude:25.04459,longitude:121.55252)))
    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude:25.05189,longitude:121.53517)))
    request.transportType = .cycling
    do {
        let response = try await MKDirections(request:request).calculate()
        print("REQUESTED=\(request.transportType.rawValue) routes=\(response.routes.map { "type=\($0.transportType.rawValue),meters=\($0.distance),seconds=\($0.expectedTravelTime)" })")
        guard let route = response.routes.first(where: { $0.transportType == .cycling && $0.distance > 0 && $0.expectedTravelTime > 0 }) else { print("No cycling route returned");exit(1) }
        print("TAIPEI_CYCLING meters=\(route.distance) seconds=\(route.expectedTravelTime) points=\(route.polyline.pointCount) steps=\(route.steps.count)")
        exit(0)
    } catch { print("Cycling source check:",error); exit(1) }
}
        return true
    }
}
