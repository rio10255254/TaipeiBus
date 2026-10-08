import Foundation

/// Static 3D viaducts for elevated metro track, in metres east/north/up of a local origin, so the
/// map layer can draw them with the same lighting as its trains. Built once per network.
public enum MetroStructureMesh {
    public struct Vertex: Equatable, Sendable {
        public var x, y, z: Float
        public var nx, ny, nz: Float
        public var r, g, b: Float
        public var material: Float
    }
    public static let deckWidth = 8.0
    public static let stationDeckWidth = 15.0
    public static let deckDepth = 1.8
    public static let pierSpacing = 34.0

    /// `metersPerWorld` converts Web Mercator units to metres at the origin's latitude.
    public static func viaducts(network: MetroNetwork, origin: Coordinate, metersPerWorld: Double,
                                lineColor: (MetroLine) -> (Float, Float, Float)) -> [Vertex] {
        let base = origin.mercator
        func local(_ c: Coordinate) -> (Double, Double) {
            let m = c.mercator
            return ((m.x - base.x) * metersPerWorld, -(m.y - base.y) * metersPerWorld)
        }
        var vertices: [Vertex] = []
        var built = Set<Int64>()
        func cell(_ p: (Double, Double)) -> Int64 { Int64((p.0 / 12).rounded()) &* 1_000_003 &+ Int64((p.1 / 12).rounded()) }
        func covered(_ p: (Double, Double)) -> Bool {
            let x = Int64((p.0 / 12).rounded()), y = Int64((p.1 / 12).rounded())
            for dx in -1...1 { for dy in -1...1 where built.contains((x + Int64(dx)) &* 1_000_003 &+ (y + Int64(dy))) { return true } }
            return false
        }
        var signatures = Set<String>()
        for pattern in network.patterns where pattern.direction == "0" {
            guard signatures.insert(pattern.stationIDs.joined(separator: "|")).inserted,
                  let profile = network.heightProfile(pattern), let line = network.line(pattern.lineID),
                  let geometry = MetroPatternGeometry(pattern: pattern, profile: profile) else { continue }
            let stripe = lineColor(line)
            let track = geometry.line
            // Distances to sample: every geometry vertex, plus extra points along ramps and station ends.
            var marks = Set(track.cumulative.map { ($0 * 10).rounded() / 10 })
            for along in stride(from: 0.0, through: track.length, by: 15) where abs(profile.height(at: along) - profile.height(at: along + 15)) > 0.05 {
                marks.insert(along)
            }
            for station in geometry.stationAlong { for offset in [-80.0, -70, 70, 80] { marks.insert(station + offset) } }
            let distances = marks.filter { $0 >= 0 && $0 <= track.length }.sorted()
            var pierDebt = 0.0
            for (from, to) in zip(distances, distances.dropFirst()) where to - from > 0.5 {
                let h0 = profile.height(at: from), h1 = profile.height(at: to)
                guard min(h0, h1) > 0.6 else { pierDebt = 0; continue }
                let a = track.sample(fraction: from / track.length).0, b = track.sample(fraction: to / track.length).0
                let pa = local(a), pb = local(b)
                let middle = ((pa.0 + pb.0) / 2, (pa.1 + pb.1) / 2)
                if covered(middle) { continue }
                let length = hypot(pb.0 - pa.0, pb.1 - pa.1)
                guard length > 0.3 else { continue }
                let ux = (pb.0 - pa.0) / length, uy = (pb.1 - pa.1) / length
                let nearStation = geometry.stationAlong.contains { abs($0 - (from + to) / 2) < 75 }
                let half = (nearStation ? stationDeckWidth : deckWidth) / 2
                let lx = -uy * half, ly = ux * half
                deck(&vertices, a: pa, b: pb, h0: h0, h1: h1, side: (lx, ly), stripe: stripe)
                pierDebt += length
                while pierDebt >= pierSpacing {
                    pierDebt -= pierSpacing
                    let t = max(0, min(1, 1 - pierDebt / length))
                    let h = h0 + (h1 - h0) * t - deckDepth
                    if h > 1.5 { pier(&vertices, at: (pa.0 + (pb.0 - pa.0) * t, pa.1 + (pb.1 - pa.1) * t), along: (ux, uy), height: h, wide: nearStation) }
                }
            }
            // Mark what this pattern drew so a short-turn pattern does not draw the same deck again.
            for (from, to) in zip(distances, distances.dropFirst()) where min(profile.height(at: from), profile.height(at: to)) > 0.6 {
                let a = local(track.sample(fraction: from / track.length).0), b = local(track.sample(fraction: to / track.length).0)
                built.insert(cell(((a.0 + b.0) / 2, (a.1 + b.1) / 2)))
            }
        }
        return vertices
    }

    private static func quad(_ out: inout [Vertex], _ p: [(Double, Double, Double)], normal: (Double, Double, Double),
                             color: (Float, Float, Float), material: Float = 2) {
        for index in [0, 1, 2, 0, 2, 3] {
            let q = p[index]
            out.append(Vertex(x: Float(q.0), y: Float(q.1), z: Float(q.2), nx: Float(normal.0), ny: Float(normal.1), nz: Float(normal.2),
                              r: color.0, g: color.1, b: color.2, material: material))
        }
    }
    static let concrete: (Float, Float, Float) = (0.90, 0.91, 0.92)
    static let concreteSide: (Float, Float, Float) = (0.82, 0.83, 0.85)
    static let underside: (Float, Float, Float) = (0.66, 0.67, 0.70)

    private static func deck(_ out: inout [Vertex], a: (Double, Double), b: (Double, Double), h0: Double, h1: Double,
                             side: (Double, Double), stripe: (Float, Float, Float)) {
        let (lx, ly) = side
        let length = max(0.01, hypot(lx, ly))
        let left = (lx / length, ly / length, 0.0), right = (-lx / length, -ly / length, 0.0)
        // On the lowest part of a ramp the deck rests on the embankment rather than below the street.
        let band0 = max(0, h0 - 0.85), band1 = max(0, h1 - 0.85)
        let floor0 = max(0, h0 - deckDepth), floor1 = max(0, h1 - deckDepth)
        func p(_ point: (Double, Double), _ s: Double, _ z: Double) -> (Double, Double, Double) { (point.0 + lx * s, point.1 + ly * s, z) }
        // Running surface.
        quad(&out, [p(a, 1, h0), p(b, 1, h1), p(b, -1, h1), p(a, -1, h0)], normal: (0, 0, 1), color: concrete)
        // Each side: a line-colour band along the parapet, concrete below it.
        for (s, normal) in [(1.0, left), (-1.0, right)] {
            quad(&out, [p(a, s, h0), p(b, s, h1), p(b, s, band1), p(a, s, band0)], normal: normal, color: stripe)
            quad(&out, [p(a, s, band0), p(b, s, band1), p(b, s, floor1), p(a, s, floor0)], normal: normal, color: concreteSide)
        }
        quad(&out, [p(a, -1, floor0), p(b, -1, floor1), p(b, 1, floor1), p(a, 1, floor0)], normal: (0, 0, -1), color: underside)
    }

    private static func pier(_ out: inout [Vertex], at c: (Double, Double), along u: (Double, Double), height: Double, wide: Bool) {
        let along = 0.9, across = wide ? 3.2 : 1.3
        let ax = u.0 * along, ay = u.1 * along, cx = -u.1 * across, cy = u.0 * across
        let corners = [(c.0 - ax - cx, c.1 - ay - cy), (c.0 + ax - cx, c.1 + ay - cy), (c.0 + ax + cx, c.1 + ay + cy), (c.0 - ax + cx, c.1 - ay + cy)]
        for i in 0..<4 {
            let p0 = corners[i], p1 = corners[(i + 1) % 4]
            let nx = p1.1 - p0.1, ny = -(p1.0 - p0.0), n = max(0.001, hypot(nx, ny))
            quad(&out, [(p0.0, p0.1, 0), (p1.0, p1.1, 0), (p1.0, p1.1, height), (p0.0, p0.1, height)],
                 normal: (nx / n, ny / n, 0), color: concreteSide)
        }
    }
}
