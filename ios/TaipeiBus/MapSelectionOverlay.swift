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
    var bottomClearance: CGFloat = 210
    let showDetails: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }

    var body: some View {
        GeometryReader { geometry in
            if let point = overlay.windowPoint, model.mapLabelStation != nil || model.selectedVehicleID != nil {
                let frame = geometry.frame(in: .global)
                let anchor = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                let width = min(290.0, geometry.size.width - 32)
                let x = min(geometry.size.width - width / 2 - 16, max(width / 2 + 16, anchor.x))
                let compactVehicle = model.selectedVehicleID != nil
                let y = min(geometry.size.height - bottomClearance - 64, max(compactVehicle ? 60 : model.routeBoardingStop != nil ? 208 : 150, anchor.y - (compactVehicle ? 60 : 76)))
                Path { path in
                    path.move(to: anchor)
                    path.addLine(to: CGPoint(x: anchor.x, y: anchor.y - 18))
                    path.addLine(to: CGPoint(x: x, y: y + (compactVehicle ? 20 : 44)))
                }
                .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .allowsHitTesting(false)
                MapContextLabelContent(model: model, signature: "\(model.snapshot.revision):\(model.mapLabelStation?.id ?? ""):\(model.selectedVehicleID ?? ""):\(model.language.rawValue)", showDetails: showDetails)
                    .equatable().frame(width: width).position(x: x, y: y)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: overlay.windowPoint != nil)
    }

}

private struct MapContextLabelContent: View, Equatable {
    @ObservedObject var model: TransitAppModel
    let signature: String
    let showDetails: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.signature == rhs.signature }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }

    @ViewBuilder var body: some View {
        if let station = model.mapLabelStation {
            VStack(alignment: .center, spacing: 2) {
                HStack(spacing: 4) {
                    Button(action: showDetails) {
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                BilingualName(station).font(.headline).lineLimit(2)
                                Text(station.localizedBearing).font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }.frame(minHeight: 44).mapLabelInk()
                    }.buttonStyle(.plain).accessibilityIdentifier("map-station-details")
                        .contextMenu {
                            Button { model.toggleFavorite(station) } label: {
                                Label(model.favorites.contains(station.id) ? AppText.text("移除收藏") : AppText.text("收藏站牌"), systemImage: "star")
                            }
                            ForEach(model.oppositeStations(to: station)) { opposite in
                                Button(AppText.text("改看%@站牌", opposite.localizedBearing)) { model.selectStation(opposite) }
                            }
                        }
                    Button { model.startStationWalk(station) } label: {
                        Image(systemName: "figure.walk").font(.body.weight(.semibold)).frame(width: 44, height: 44).mapLabelInk()
                    }.buttonStyle(.plain).accessibilityLabel(AppText.text("步行到這個站牌"))
                        .accessibilityIdentifier("map-station-walk")
                }
                TimelineView(.periodic(from: .now, by: 15)) { timeline in
                    let all = StationArrival.rows(station: station, metadata: model.metadata, snapshot: model.snapshot, now: timeline.date)
                    let arrivals = model.routeBoardingStop.map { stop in all.filter { $0.stop.id == stop.id } } ?? all
                    HStack(spacing: 10) {
                        ForEach(Array(arrivals.prefix(2))) { arrival in
                            Button {
                                if let route = arrival.route { model.selectRoute(route, direction: arrival.stop.direction, boardingStopID: arrival.stop.id) }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(arrival.route?.localizedName ?? arrival.stop.routeID).fontWeight(.semibold)
                                    Text(EstimateFeed.label(arrival.estimateSeconds)).monospacedDigit()
                                        .contentTransition(reduceMotion ? .identity : .numericText())
                                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                                }.font(.caption).lineLimit(1).minimumScaleFactor(0.85)
                                    .padding(.horizontal, 10).frame(minHeight: 36)
                                    .foregroundStyle(Color.accentColor)
                                    .background(.regularMaterial, in: Capsule())
                                    .overlay { Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5) }
                            }.buttonStyle(PhonePressStyle()).accessibilityHint(AppText.text("官方下一班時間"))
                        }
                    }
                }
            }.accessibilityElement(children: .contain).accessibilityIdentifier("map-station-inline-label")
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
            }.padding(.horizontal, 12).readableMapSurface().fixedSize()
        }
    }
}

private struct MapLabelInk: ViewModifier {
    func body(content: Content) -> some View {
        content.foregroundStyle(Color(uiColor: .label))
            .shadow(color: Color(uiColor: .systemBackground), radius: 0.7, x: -1, y: -1)
            .shadow(color: Color(uiColor: .systemBackground), radius: 0.7, x: 1, y: -1)
            .shadow(color: Color(uiColor: .systemBackground), radius: 0.7, x: -1, y: 1)
            .shadow(color: Color(uiColor: .systemBackground), radius: 0.7, x: 1, y: 1)
    }
}
private extension View {
    func mapLabelInk() -> some View { modifier(MapLabelInk()) }
}
