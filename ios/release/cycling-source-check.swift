import Foundation
import MapKit
import UIKit
import CryptoKit
@main final class Probe: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config=UISceneConfiguration(name:"Probe",sessionRole:session.role);config.delegateClass=ProbeScene.self;return config
    }
}
final class ProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene=scene as? UIWindowScene else { return }
        window = UIWindow(windowScene:scene); window?.rootViewController = UIViewController(); window?.makeKeyAndVisible()
        Task { @MainActor in
            print("OS=\(UIDevice.current.systemVersion)");fflush(stdout)
            let taipeiA=CLLocationCoordinate2D(latitude:25.04459,longitude:121.55252)
            let taipeiB=CLLocationCoordinate2D(latitude:25.05189,longitude:121.53517)
            let cases: [(String,MKDirectionsTransportType,CLLocationCoordinate2D,CLLocationCoordinate2D)] = [
                ("Taipei cycling",.cycling,taipeiA,taipeiB),
                ("Taipei driving",.automobile,taipeiA,taipeiB),
                ("Taipei walking",.walking,taipeiA,taipeiB),
                ("Apple sample cycling",.cycling,CLLocationCoordinate2D(latitude:40.77396,longitude:-73.97097),CLLocationCoordinate2D(latitude:40.7528,longitude:-73.97715))]
            for (name,transport,from,to) in cases {
                let request=MKDirections.Request()
                request.source=MKMapItem(placemark:MKPlacemark(coordinate:from))
                request.destination=MKMapItem(placemark:MKPlacemark(coordinate:to))
                request.transportType=transport
                do {
                    let response=try await MKDirections(request:request).calculate()
                    for route in response.routes {
                        let geometry=(0..<route.polyline.pointCount).map { i in let c=route.polyline.points()[i].coordinate; return String(format:"%.6f,%.6f",c.latitude,c.longitude) }.joined(separator:";")
                        let hash=SHA256.hash(data:Data(geometry.utf8)).map { String(format:"%02x",$0) }.joined()
                        print("SOURCE=\(name) REQUESTED=\(transport.rawValue) RETURNED=\(route.transportType.rawValue) meters=\(route.distance) seconds=\(route.expectedTravelTime) hash=\(hash) stepTypes=\(Set(route.steps.map { $0.transportType.rawValue })) notices=\(route.advisoryNotices) instructions=\(route.steps.prefix(8).map(\.instructions))")
                        fflush(stdout)
                    }
                } catch { print("SOURCE=\(name) ERROR=\(error)");fflush(stdout) }
            }
            exit(0)
        }
    }
}
