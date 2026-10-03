import SwiftUI
import TransitCore

/// Only this small label observes map frame positions. The rest of the UI isn't rebuilt per frame.
@MainActor
final class MapSelectionOverlay: ObservableObject {
    @Published private(set) var windowPoint: CGPoint?
    private var lastUpdate: CFTimeInterval = 0
#if DEBUG
    @Published private(set) var cameraState = ""
    private var lastCameraUpdate: CFTimeInterval = 0
    func recordCamera(_ state: [String: Any]) {
        let time = CACurrentMediaTime()
        guard time - lastCameraUpdate > 0.5, let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        lastCameraUpdate = time
        if cameraState != text { cameraState = text }
    }
#endif
    func update(_ point: CGPoint?) {
        let time = CACurrentMediaTime()
        guard point == nil || time - lastUpdate > 1.0 / 30 else { return }
        if let old = windowPoint, let point, hypot(old.x - point.x, old.y - point.y) < 0.25 { return }
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
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: x)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: y)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: overlay.windowPoint != nil)
    }

    @ViewBuilder private var label: some View {
        if let station = model.selectedStation {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Button(action: showDetails) {
                        Text(station.name).font(.headline).foregroundStyle(.primary)
                            .shadow(color: .white, radius: 4)
                    }.buttonStyle(.plain).frame(minHeight: 44)
                        .contextMenu {
                            Button { model.toggleFavorite(station) } label: {
                                Label(model.favorites.contains(station.id) ? "移除收藏" : "收藏站牌", systemImage: "star")
                            }
                            ForEach(model.oppositeStations(to: station)) { opposite in
                                Button("改看\(opposite.bearingLabel)站牌") { model.selectStation(opposite) }
                            }
                        }
                    Text(station.bearingLabel).font(.caption).foregroundStyle(.secondary).shadow(color: .white, radius: 3)
                    Spacer(minLength: 0)
                    Button(action: showDetails) { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .phoneGlass(in: Circle()).accessibilityLabel("此站所有路線與到站預估")
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
                                        .contentTransition(reduceMotion ? .identity : .numericText())
                                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: arrival.estimateSeconds)
                                }
                                .padding(.horizontal, 13).padding(.vertical, 8).frame(minHeight: 48)
                                .foregroundStyle(arrival.estimateSeconds == nil ? Color.secondary : Color.accentColor)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
                            }.buttonStyle(PhonePressStyle())
                        }
                        if arrivals.isEmpty { Text("暫無到站資訊").font(.subheadline).shadow(color: .white, radius: 3) }
                    }
                }
                Text("官方路線預估").font(.caption2).foregroundStyle(.secondary).shadow(color: .white, radius: 3)
            }
        } else if let bus = model.selectedVehicle {
            if model.planner.selected != nil {
                HStack(spacing: 8) {
                    Image(systemName: "bus.fill").foregroundStyle(Color.accentColor)
                    Text(bus.plate).font(.subheadline.weight(.semibold)).monospaced()
                    Button(action: showDetails) { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                        .accessibilityLabel("車輛資訊")
                }.padding(.horizontal, 12).phoneGlass(in: Capsule()).fixedSize()
            } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(bus.routeName).font(.system(.title, design: .rounded).weight(.bold)).foregroundStyle(Color.accentColor)
                    Text("往 \(bus.destination)").font(.subheadline).lineLimit(2)
                    Spacer(minLength: 0)
                    Button(action: showDetails) { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .phoneGlass(in: Circle()).accessibilityLabel("車輛資訊")
                }
                Text(bus.plate).font(.subheadline.weight(.semibold)).monospaced()
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bus.hasReliablePosition(at: timeline.date) ? "GPS \(bus.speedLabel) · \(max(0, Int(timeline.date.timeIntervalSince(bus.observedAt)))) 秒前" : "最後回報 · \(max(0, Int(timeline.date.timeIntervalSince(bus.observedAt)))) 秒前")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if let state = bus.trackingLabel(at: timeline.date) {
                            Text(state).font(.caption).foregroundStyle(bus.trackingIssue == nil && bus.isFresh(at: timeline.date) ? Color.secondary : Color.orange)
                        }
                        if let next = model.metadata.journey(routeID: bus.routeID, direction: bus.direction)?.upcoming(vehicle: bus, at: timeline.date).first {
                            Button {
                                if let station = model.metadata.stations[next.stop.stationID] { model.selectStation(station) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "mappin").font(.caption)
                                    Text(next.distance <= 25 ? "\(next.stop.name)附近" : "前方 · \(next.stop.name)").lineLimit(1)
                                    Spacer(minLength: 0)
                                    if next.distance > 25 { Text(next.distance >= 1_000 ? String(format: "%.1f km", next.distance / 1_000) : "\(Int(next.distance.rounded())) m").monospacedDigit() }
                                }.font(.caption.weight(.medium)).frame(minHeight: 44)
                            }.buttonStyle(.plain).accessibilityHint("查看前方站牌的官方到站預估")
                        }
                    }
                }
            }
            .shadow(color: .white.opacity(0.95), radius: 4)
            }
        }
    }
}
