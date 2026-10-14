import Foundation

/// Fit a route in the available phone viewport, nearly filling it. A tilted camera
/// foreshortens the far half of the view, so the zoom backs off by exactly that amount.
public struct RouteOverview: Sendable {
    public let center: Coordinate
    public let zoom: Double

    public init?(coordinates: [Coordinate], viewportWidth: Double, viewportHeight: Double, pitch: Double = 35, padding: Double = 16) {
        let points = coordinates.filter { $0.latitude.isFinite && $0.longitude.isFinite &&
            (21...26).contains($0.latitude) && (119...123).contains($0.longitude) }
        guard !points.isEmpty, viewportWidth.isFinite, viewportHeight.isFinite,
              viewportWidth > 0, viewportHeight > 0 else { return nil }
        let projected = points.map(\.mercator)
        let west = projected.map { $0.x }.min()!, east = projected.map { $0.x }.max()!
        let north = projected.map { $0.y }.min()!, south = projected.map { $0.y }.max()!
        let x = (west + east) / 2, y = (north + south) / 2
        center = Coordinate(latitude: atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi,
                            longitude: x * 360 - 180)
        let edge = padding.isFinite ? max(0,padding) * 2 : 32
        let horizontal = log2(max(80, viewportWidth - edge) / (512 * max(east - west, 0.000001)))
        let vertical = log2(max(80, viewportHeight - edge) / (512 * max(south - north, 0.000001)))
        let tilt = min(60, max(0, pitch.isFinite ? pitch : 0)) * .pi / 180
        let margin = log2(1 / cos(tilt)) + 0.05
        zoom = min(17.2, max(9, min(horizontal, vertical) - margin))
    }
}
