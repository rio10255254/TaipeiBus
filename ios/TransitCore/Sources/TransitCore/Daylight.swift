import Foundation

/// Whether the sun is up at a place, from the NOAA solar position approximation (within
/// about a minute of the published sunrise and sunset in Taipei).
public enum Daylight {
    /// Sun elevation above the horizon in degrees.
    public static func solarElevation(at date: Date, coordinate: Coordinate) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
        let g = 2 * Double.pi / 365 * (day - 1 + (hour - 12) / 24)
        let equation = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g) - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let declination = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g) - 0.006758 * cos(2 * g)
            + 0.000907 * sin(2 * g) - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        let solarMinutes = hour * 60 + equation + 4 * coordinate.longitude
        let hourAngle = (solarMinutes / 4 - 180) * .pi / 180
        let latitude = coordinate.latitude * .pi / 180
        let cosZenith = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)
        return 90 - acos(min(1, max(-1, cosZenith))) * 180 / .pi
    }

    /// After sunset and before sunrise, counting the sun's disc and atmospheric refraction.
    public static func isNight(at date: Date, coordinate: Coordinate = .taipei) -> Bool {
        solarElevation(at: date, coordinate: coordinate) < -0.833
    }
}
