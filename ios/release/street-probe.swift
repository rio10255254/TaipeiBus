import Foundation
import MapKit

@MainActor func probe() async {
    let destination = CLLocationCoordinate2D(latitude:25.026154,longitude:121.543636)
    for start in [
        CLLocationCoordinate2D(latitude:25.0192,longitude:121.5390),
        CLLocationCoordinate2D(latitude:25.01945,longitude:121.53955),
        CLLocationCoordinate2D(latitude:25.01965,longitude:121.53965),
        CLLocationCoordinate2D(latitude:25.01985,longitude:121.53965),
        CLLocationCoordinate2D(latitude:25.01925,longitude:121.53975),
        CLLocationCoordinate2D(latitude:25.01905,longitude:121.53975),
        CLLocationCoordinate2D(latitude:25.01885,longitude:121.53975),
        CLLocationCoordinate2D(latitude:25.01865,longitude:121.53975)
    ] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark:MKPlacemark(coordinate:start))
        request.destination = MKMapItem(placemark:MKPlacemark(coordinate:destination))
        request.transportType = .walking; request.requestsAlternateRoutes = true
        let clock = Date()
        do {
            let result = try await MKDirections(request:request).calculate()
            for route in result.routes where route.polyline.pointCount > 0 {
                let first = route.polyline.points()[0].coordinate
                let last = route.polyline.points()[route.polyline.pointCount-1].coordinate
                let from = CLLocation(latitude:start.latitude,longitude:start.longitude)
                let to = CLLocation(latitude:destination.latitude,longitude:destination.longitude)
                print("PROBE from=\(start.latitude),\(start.longitude) elapsed=\(Date().timeIntervalSince(clock)) meters=\(route.distance) startGap=\(from.distance(from:CLLocation(latitude:first.latitude,longitude:first.longitude))) endGap=\(to.distance(from:CLLocation(latitude:last.latitude,longitude:last.longitude)))")
            }
        } catch { print("PROBE_ERROR from=\(start.latitude),\(start.longitude) error=\(error)") }
    }
}
await probe()
