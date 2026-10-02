import SwiftUI
import TransitCore

/// Only this small label observes map frame positions. The rest of the UI isn't rebuilt per frame.
@MainActor
final class MapSelectionOverlay: ObservableObject {
    @Published private(set) var windowPoint: CGPoint?
    private var lastUpdate: CFTimeInterval = 0
    func update(_ point: CGPoint?) {
        let time = CACurrentMediaTime()
        guard point == nil || time - lastUpdate > 0.08 else { return }
        if let old = windowPoint, let point, hypot(old.x - point.x, old.y - point.y) < 0.6 { return }
        if windowPoint != point { windowPoint = point }
        lastUpdate = time
    }
}

struct MapContextLabels: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var overlay: MapSelectionOverlay
    let showDetails: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if let point = overlay.windowPoint, model.selectedStationID != nil || model.selectedVehicleID != nil {
                let frame = geometry.frame(in: .global)
                let anchor = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                let width = min(290.0, geometry.size.width - 32)
                let x = min(geometry.size.width - width / 2 - 16, max(width / 2 + 16, anchor.x))
                let y = min(geometry.size.height - 210, max(160, anchor.y - 108))
                Path { path in
                    path.move(to: anchor)
                    path.addLine(to: CGPoint(x: anchor.x, y: anchor.y - 18))
                    path.addLine(to: CGPoint(x: x, y: y + 44))
                }
                .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .allowsHitTesting(false)
                label.frame(width: width).position(x: x, y: y)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: x)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: y)
            }
        }
    }

    @ViewBuilder private var label: some View {
        if let station = model.selectedStation {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Button(action: showDetails) {
                        Text(station.name).font(.headline).foregroundStyle(.primary)
                            .shadow(color: .white, radius: 4)
                    }.buttonStyle(.plain).frame(minHeight: 44)
                    Text(station.bearingLabel).font(.caption).foregroundStyle(.secondary).shadow(color: .white, radius: 3)
                    Spacer(minLength: 0)
                    Button(action: showDetails) { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .background(.regularMaterial, in: Circle()).accessibilityLabel("此站所有路線與到站預估")
                }
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    let arrivals = StationArrival.rows(station: station, metadata: model.metadata, snapshot: model.snapshot, now: timeline.date)
                    HStack(spacing: 8) {
                        ForEach(Array(arrivals.prefix(2))) { arrival in
                            Button {
                                if let route = arrival.route { model.selectRoute(route, direction: arrival.stop.direction) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(arrival.route?.name ?? arrival.stop.routeID).font(.caption.weight(.semibold))
                                    Text(EstimateFeed.label(arrival.estimateSeconds)).font(.body.weight(.bold)).monospacedDigit()
                                }
                                .padding(.horizontal, 13).padding(.vertical, 8).frame(minHeight: 48)
                                .foregroundStyle(arrival.estimateSeconds == nil ? Color.secondary : Color.accentColor)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
                            }.buttonStyle(.plain)
                        }
                        if arrivals.isEmpty { Text("暫無到站資訊").font(.subheadline).shadow(color: .white, radius: 3) }
                    }
                }
                Text("官方路線預估").font(.caption2).foregroundStyle(.secondary).shadow(color: .white, radius: 3)
            }
        } else if let bus = model.selectedVehicle {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(bus.routeName).font(.system(.title, design: .rounded).weight(.bold)).foregroundStyle(Color.accentColor)
                    Text("往 \(bus.destination)").font(.subheadline).lineLimit(2)
                    Spacer(minLength: 0)
                    Button(action: showDetails) { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .background(.regularMaterial, in: Circle()).accessibilityLabel("車輛資訊")
                }
                Text(bus.plate).font(.subheadline.weight(.semibold)).monospaced()
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(bus.isFresh(at: timeline.date) ? "GPS \(Int(bus.speed)) km/h · \(max(0, Int(timeline.date.timeIntervalSince(bus.observedAt)))) 秒前" : "定位已延遲")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .shadow(color: .white.opacity(0.95), radius: 4)
        }
    }
}
