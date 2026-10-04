import Foundation

/// Keep a small map label near its pin without covering controls or the pin itself.
public enum MapLabelPlacement {
    public static func frame(anchor: CGPoint, size: CGSize, inside bounds: CGRect, avoiding obstacles: [CGRect] = []) -> CGRect {
        guard !bounds.isEmpty, anchor.x.isFinite, anchor.y.isFinite, size.width.isFinite, size.height.isFinite else { return .zero }
        let width = min(max(1, size.width), bounds.width), height = min(max(1, size.height), bounds.height)
        let gap: CGFloat = 18
        let origins = [CGPoint(x: anchor.x - width / 2, y: anchor.y - height - gap),
            CGPoint(x: anchor.x - width / 2, y: anchor.y + gap),
            CGPoint(x: anchor.x + gap, y: anchor.y - height / 2),
            CGPoint(x: anchor.x - width - gap, y: anchor.y - height / 2)]
        return origins.enumerated().map { index, origin -> (CGRect, CGFloat) in
            let x = min(bounds.maxX - width, max(bounds.minX, origin.x))
            let y = min(bounds.maxY - height, max(bounds.minY, origin.y))
            let frame = CGRect(x: x, y: y, width: width, height: height)
            let adjusted = hypot(x - origin.x, y - origin.y)
            let overlap = obstacles.reduce(CGFloat.zero) { total, obstacle in
                let intersection = frame.intersection(obstacle)
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
            return (frame, adjusted * 2 + CGFloat(index) * 4 + overlap * 10 + (frame.contains(anchor) ? 10_000 : 0))
        }.min { $0.1 < $1.1 }!.0
    }
}
