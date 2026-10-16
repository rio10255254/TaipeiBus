import Foundation
import MapKit

@MainActor func probe() async {
    let gated = CommandLine.arguments.contains("--gated"), gate = DirectionsRequestGate()
    var providerRequests = 0, deferred = 0, primaryConfirmed = 0, failures = 0
    let destination = CLLocationCoordinate2D(latitude:25.026154,longitude:121.543636)
    let normal = [
        CLLocationCoordinate2D(latitude:25.0192,longitude:121.5390),
        CLLocationCoordinate2D(latitude:25.01945,longitude:121.53955),
        CLLocationCoordinate2D(latitude:25.01965,longitude:121.53965),
        CLLocationCoordinate2D(latitude:25.01985,longitude:121.53965),
        CLLocationCoordinate2D(latitude:25.01925,longitude:121.53975),
        CLLocationCoordinate2D(latitude:25.01905,longitude:121.53975),
        CLLocationCoordinate2D(latitude:25.01885,longitude:121.53975),
        CLLocationCoordinate2D(latitude:25.01865,longitude:121.53975)
        ,CLLocationCoordinate2D(latitude:25.0202,longitude:121.5397)
        ,CLLocationCoordinate2D(latitude:25.0185,longitude:121.5385)
        ,CLLocationCoordinate2D(latitude:25.0180,longitude:121.5385)
        ,CLLocationCoordinate2D(latitude:25.0174,longitude:121.5360)
        ,CLLocationCoordinate2D(latitude:25.0157,longitude:121.5380)
        ,CLLocationCoordinate2D(latitude:25.0175,longitude:121.5405)
        ,CLLocationCoordinate2D(latitude:25.0185,longitude:121.5415)
        ,CLLocationCoordinate2D(latitude:25.0203,longitude:121.5413)
    ]
    // Two ordinary searches used to issue this many optional street requests in
    // a burst. Stop at the first provider limit, and never retry this probe.
    let points = CommandLine.arguments.contains("--repeat") ? (0..<54).map {
        CLLocationCoordinate2D(latitude:25.01945 + Double($0)*0.000004,longitude:121.53955)
    } : normal
    for (index,start) in points.enumerated() {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark:MKPlacemark(coordinate:start))
        request.destination = MKMapItem(placemark:MKPlacemark(coordinate:destination))
        request.transportType = .walking; request.requestsAlternateRoutes = true
        let clock = Date()
        do {
            let operation = MKDirections(request:request)
            let primary = [0,1,24,25].contains(index)
            let result: MKDirections.Response
            if gated {
                result = try await gate.execute(primary ? .firstChoice : .alternatives, cancel: { operation.cancel() }) {
                    providerRequests += 1; return try await operation.calculate()
                }
            } else { providerRequests += 1; result = try await operation.calculate() }
            if primary, !result.routes.isEmpty { primaryConfirmed += 1 }
            for route in result.routes where route.polyline.pointCount > 0 {
                let first = route.polyline.points()[0].coordinate
                let last = route.polyline.points()[route.polyline.pointCount-1].coordinate
                let from = CLLocation(latitude:start.latitude,longitude:start.longitude)
                let to = CLLocation(latitude:destination.latitude,longitude:destination.longitude)
                print("PROBE from=\(start.latitude),\(start.longitude) elapsed=\(Date().timeIntervalSince(clock)) meters=\(route.distance) startGap=\(from.distance(from:CLLocation(latitude:first.latitude,longitude:first.longitude))) endGap=\(to.distance(from:CLLocation(latitude:last.latitude,longitude:last.longitude)))")
            }
        } catch is DirectionsRequestGate.Deferred { deferred += 1
        } catch {
            failures += 1
            let value = error as NSError
            print("PROBE_ERROR count=\(index+1) from=\(start.latitude),\(start.longitude) domain=\(value.domain) code=\(value.code) error=\(error)")
            if value.domain == MKErrorDomain { break }
        }
    }
    print("PROBE_SUMMARY gated=\(gated) attempted=\(points.count) providerRequests=\(providerRequests) deferred=\(deferred) primaryConfirmed=\(primaryConfirmed) failures=\(failures)")
    if gated, primaryConfirmed != 4 || failures > 0 { exit(1) }
}
await probe()
