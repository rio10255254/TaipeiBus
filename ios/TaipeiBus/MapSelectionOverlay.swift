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

#if DEBUG
struct DebugMapCameraText: View {
    @ObservedObject var overlay: MapSelectionOverlay
    var body: some View {
        Text(overlay.cameraState).font(.system(size: 1)).foregroundStyle(.clear)
            .frame(width: 1, height: 1).accessibilityIdentifier("map-camera-state").allowsHitTesting(false)
    }
}
#endif

struct MapContextLabels: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var overlay: MapSelectionOverlay
    let showDetails: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }

    var body: some View {
        GeometryReader { geometry in
            if let point = overlay.windowPoint, model.selectedStationID != nil || model.selectedVehicleID != nil {
                let frame = geometry.frame(in: .global)
                let anchor = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                let width = min(290.0, geometry.size.width - 32)
                let x = min(geometry.size.width - width / 2 - 16, max(width / 2 + 16, anchor.x))
                let compactVehicle = model.selectedVehicleID != nil
                let y = min(geometry.size.height - 210, max(compactVehicle ? 60 : 160, anchor.y - (compactVehicle ? 60 : 108)))
                Path { path in
                    path.move(to: anchor)
                    path.addLine(to: CGPoint(x: anchor.x, y: anchor.y - 18))
                    path.addLine(to: CGPoint(x: x, y: y + (compactVehicle ? 20 : 44)))
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
                        BilingualName(station).font(.headline).foregroundStyle(.primary)
                            .shadow(color: .white, radius: 4)
                    }.buttonStyle(.plain).frame(minHeight: 44)
                        .contextMenu {
                            Button { model.toggleFavorite(station) } label: {
                                Label(model.favorites.contains(station.id) ? AppText.text("移除收藏") : AppText.text("收藏站牌"), systemImage: "star")
                            }
                            ForEach(model.oppositeStations(to: station)) { opposite in
                                Button(AppText.text("改看%@站牌", opposite.localizedBearing)) { model.selectStation(opposite) }
                            }
                        }
                    Text(station.localizedBearing).font(.caption).foregroundStyle(.secondary).shadow(color: .white, radius: 3)
                    Spacer(minLength: 0)
                    Button(action: showDetails) { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .phoneGlass(in: Circle()).accessibilityLabel(AppText.text("此站所有路線與到站預估"))
                }
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    let arrivals = StationArrival.rows(station: station, metadata: model.metadata, snapshot: model.snapshot, now: timeline.date)
                    HStack(spacing: 8) {
                        ForEach(Array(arrivals.prefix(2))) { arrival in
                            Button {
                                if let route = arrival.route { model.selectRoute(route, direction: arrival.stop.direction) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(arrival.route?.localizedName ?? arrival.stop.routeID).font(.caption.weight(.semibold))
                                    Text(EstimateFeed.label(arrival.estimateSeconds)).font(.body.weight(.bold)).monospacedDigit()
                                        .contentTransition(reduceMotion ? .identity : .numericText())
                                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: arrival.estimateSeconds)
                                }
                                .padding(.horizontal, 13).padding(.vertical, 8).frame(minHeight: 48)
                                .foregroundStyle(arrival.estimateSeconds == nil ? Color.secondary : Color.accentColor)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
                            }.buttonStyle(PhonePressStyle())
                        }
                        if arrivals.isEmpty { Text(AppText.text("暫無到站資訊")).font(.subheadline).shadow(color: .white, radius: 3) }
                    }
                }
                Text(AppText.text("官方路線預估")).font(.caption2).foregroundStyle(.secondary).shadow(color: .white, radius: 3)
            }
        } else if let bus = model.selectedVehicle {
            HStack(spacing: 8) {
                Image(systemName: "bus.fill").foregroundStyle(Color.accentColor)
                if model.planner.selected == nil {
                    Text(model.metadata.route(bus.routeID)?.localizedName ?? bus.localizedRouteName)
                        .font(.subheadline.weight(.bold)).foregroundStyle(Color.accentColor).lineLimit(1)
                }
                Text(bus.plate).font(.subheadline.weight(.semibold)).monospaced()
                Button(action: showDetails) { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                    .accessibilityLabel(AppText.text("車輛資訊"))
            }.padding(.horizontal, 12).phoneGlass(in: Capsule()).fixedSize()
        }
    }
}
