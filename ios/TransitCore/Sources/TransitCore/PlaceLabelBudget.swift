import Foundation

public struct PlaceLabelCandidate: Sendable {
    public let id: String
    public let x: Double
    public let y: Double
    public let rank: Double
    public let landmark: Bool
    public init(id: String, x: Double, y: Double, rank: Double, landmark: Bool) {
        self.id = id; self.x = x; self.y = y; self.rank = rank; self.landmark = landmark
    }
}

/// A real viewport budget, independent of the tile's relative POI ranks.
public enum PlaceLabelBudget {
    public static let maximum = 96
    public static func limit(zoom: Double, width: Double, height: Double) -> Int {
        guard zoom.isFinite, zoom >= 14, width.isFinite, height.isFinite, width > 0, height > 0 else { return 0 }
        let base = zoom < 15.5 ? 24 : zoom < 16.5 ? 48 : zoom < 17.5 ? 72 : 96
        let area = max(0.5, min(1, width * height / (400 * 650)))
        return min(maximum, max(12, Int(Double(base) * area)))
    }
    public static func select(_ points: [PlaceLabelCandidate], zoom: Double, width: Double, height: Double,
                              previous: Set<String> = []) -> [String] {
        let budget = limit(zoom: zoom, width: width, height: height)
        guard budget > 0 else { return [] }
        let margin = 48.0
        let filtered = points.filter {
            !$0.id.isEmpty && $0.x.isFinite && $0.y.isFinite && $0.rank.isFinite && $0.rank >= 0 &&
                $0.x >= -margin && $0.x <= width + margin && $0.y >= -margin && $0.y <= height + margin
        }
        let ordered = filtered.sorted { a, b in
            if a.landmark != b.landmark { return a.landmark }
            let ar = a.rank - (previous.contains(a.id) ? 8 : 0)
            let br = b.rank - (previous.contains(b.id) ? 8 : 0)
            if ar != br { return ar < br }
            let ad = hypot(a.x - width / 2, a.y - height / 2)
            let bd = hypot(b.x - width / 2, b.y - height / 2)
            return ad == bd ? a.id < b.id : ad < bd
        }
        var usedIDs = Set<String>(), cells = Set<String>(), result: [String] = []
        let spacing = zoom < 16.5 ? 72.0 : 52.0
        for point in ordered {
            guard !usedIDs.contains(point.id) else { continue }
            let cell = "\(Int(floor(point.x / spacing))):\(Int(floor(point.y / spacing)))"
            guard cells.insert(cell).inserted else { continue }
            usedIDs.insert(point.id); result.append(point.id)
            if result.count == budget { break }
        }
        return result
    }
}
