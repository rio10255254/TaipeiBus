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
    /// `overscan` pre-places a thinner ring of labels just outside the screen so a short
    /// pan reveals places that are already laid out instead of an empty edge. The ring has
    /// its own half-size budget and never takes slots from the visible area.
    public static func select(_ points: [PlaceLabelCandidate], zoom: Double, width: Double, height: Double,
                              previous: Set<String> = [], overscan: Double = 0) -> [String] {
        let budget = limit(zoom: zoom, width: width, height: height)
        guard budget > 0 else { return [] }
        let margin = 48.0, ring = max(margin, overscan.isFinite ? overscan : 0)
        let ringBudget = ring > margin ? budget / 2 : 0
        func inside(_ p: PlaceLabelCandidate, _ m: Double) -> Bool {
            p.x >= -m && p.x <= width + m && p.y >= -m && p.y <= height + m
        }
        let filtered = points.filter {
            !$0.id.isEmpty && $0.x.isFinite && $0.y.isFinite && $0.rank.isFinite && $0.rank >= 0 && inside($0, ring)
        }
        let ordered = filtered.map { ($0, inside($0, margin)) }.sorted { lhs, rhs in
            let (a, av) = lhs, (b, bv) = rhs
            if av != bv { return av }
            if a.landmark != b.landmark { return a.landmark }
            let ar = a.rank - (previous.contains(a.id) ? 8 : 0)
            let br = b.rank - (previous.contains(b.id) ? 8 : 0)
            if ar != br { return ar < br }
            let ad = hypot(a.x - width / 2, a.y - height / 2)
            let bd = hypot(b.x - width / 2, b.y - height / 2)
            return ad == bd ? a.id < b.id : ad < bd
        }
        var usedIDs = Set<String>(), cells: [String: PlaceLabelCandidate] = [:], result: [String] = []
        var visible = 0, outer = 0
        let spacing = zoom < 16.5 ? 72.0 : 52.0
        for (point, onScreen) in ordered {
            if onScreen ? visible >= budget : outer >= ringBudget { if onScreen { continue } else { break } }
            guard !usedIDs.contains(point.id) else { continue }
            let cx = Int(floor(point.x / spacing)), cy = Int(floor(point.y / spacing))
            let cell = "\(cx):\(cy)"
            guard cells[cell] == nil else { continue }
            let crowded = (-1...1).contains { dx in
                (-1...1).contains { dy in
                    guard let neighbor = cells["\(cx + dx):\(cy + dy)"] else { return false }
                    return hypot(point.x - neighbor.x, point.y - neighbor.y) < spacing * 0.75
                }
            }
            guard !crowded else { continue }
            cells[cell] = point
            usedIDs.insert(point.id); result.append(point.id)
            if onScreen { visible += 1 } else { outer += 1 }
            if visible == budget && outer == ringBudget { break }
        }
        return result
    }
}
