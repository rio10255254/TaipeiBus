import Foundation
import MapKit
Task { @MainActor in
    let request = MKDirections.Request()
    request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude:25.04459,longitude:121.55252)))
    request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude:25.05189,longitude:121.53517)))
    request.transportType = .cycling
    do {
        let response = try await MKDirections(request:request).calculate()
        guard let route = response.routes.first(where: { $0.transportType == .cycling && $0.distance > 0 && $0.expectedTravelTime > 0 }) else { fatalError("No cycling route returned") }
        print("TAIPEI_CYCLING meters=\(route.distance) seconds=\(route.expectedTravelTime) points=\(route.polyline.pointCount) steps=\(route.steps.count)")
        exit(0)
    } catch { print("Cycling source check:",error); exit(1) }
}
RunLoop.main.run()
