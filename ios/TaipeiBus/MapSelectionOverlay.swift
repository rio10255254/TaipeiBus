import SwiftUI
import TransitCore

/// Only this small label observes map frame positions. The rest of the UI isn't rebuilt per frame.
@MainActor
final class MapSelectionOverlay: ObservableObject {
    @Published private(set) var windowPoint: CGPoint?
    /// The rider's location dot in window space; a label should not hide where the rider is.
    var userPoint: CGPoint?
    private var lastUpdate: CFTimeInterval = 0
    @Published private(set) var compactStation = false
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
    /// Map zoom at the last update, so a label can keep clear of a long vehicle's body.
    private(set) var zoom: Double = 16
    func update(_ point: CGPoint?, zoom: Double? = nil) {
        if let zoom {
            self.zoom = zoom
            if zoom < 13.2, !compactStation { compactStation = true }
            else if zoom > 13.8, compactStation { compactStation = false }
        }
        let time = CACurrentMediaTime()
        guard point == nil || time - lastUpdate > 1.0 / 60 else { return }
        if let old = windowPoint, let point, hypot(old.x - point.x, old.y - point.y) < 0.25 { return }
        if windowPoint != point { windowPoint = point }
        lastUpdate = time
    }
}

#if DEBUG
struct DebugMapCameraText: View {
    @ObservedObject var overlay: MapSelectionOverlay
    var body: some View {
        Text("Map state").font(.system(size: 1)).foregroundStyle(.clear).accessibilityLabel(overlay.cameraState)
            .frame(width: 1, height: 1).accessibilityIdentifier("map-camera-state").allowsHitTesting(false)
    }
}
#endif

struct MapContextLabels: View {
    @ObservedObject var model: TransitAppModel
    @ObservedObject var overlay: MapSelectionOverlay
    var bottomClearance: CGFloat = 210
    /// Space taken by the navigation banner above the map controls.
    var topClearance: CGFloat = 0
    @State private var expandedStationID: String?
    @State private var labelSize = CGSize(width: 280, height: 86)
    let showDetails: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }

    var body: some View {
        GeometryReader { geometry in
            if let point = overlay.windowPoint, model.mapLabelStation != nil || model.selectedVehicleID != nil || model.selectedTrainID != nil {
                let frame = geometry.frame(in: .global)
                let anchor = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                let vehicle = model.selectedVehicleID != nil || model.selectedTrainID != nil
                let expanded = expandedStationID == model.mapLabelStation?.id && expandedStationID != nil
                let width = min(!vehicle && overlay.compactStation && !expanded ? 200.0 : 280.0, geometry.size.width - 32)
                let freeTop: CGFloat = (model.routeBoardingStop != nil && !vehicle ? 170 : vehicle ? 64 : 140) + topClearance
                let available = CGRect(x: 16, y: freeTop, width: geometry.size.width - 32,
                    height: max(1, geometry.size.height - bottomClearance - 12 - freeTop))
                // The right-hand glass control stack and the compass beneath it.
                let obstacles = [CGRect(x: geometry.size.width - 76, y: topClearance, width: 76, height: 224)]
                    + (overlay.userPoint.map { [CGRect(x: $0.x - frame.minX - 28, y: $0.y - frame.minY - 28, width: 56, height: 56)] } ?? [])
                // A three-car train is ~37 m long and may point any way; reserve its whole body,
                // sized from the current zoom, so the card never sits on top of it.
                let metresPerPoint = 70_400 / pow(2, overlay.zoom)
                let half = min(110, max(20, 18.4 / metresPerPoint + 6))
                let trainArea = model.selectedTrainID == nil ? nil :
                    CGRect(x: anchor.x - half, y: anchor.y - half, width: half * 2, height: half * 2)
                let placement = MapLabelPlacement.frame(anchor: anchor, size: CGSize(width: width, height: labelSize.height),
                    inside: available, avoiding: obstacles, anchorArea: trainArea)
                let tip = CGPoint(x: anchor.y < placement.minY || anchor.y > placement.maxY ? placement.midX : min(placement.maxX, max(placement.minX, anchor.x)),
                                  y: min(placement.maxY, max(placement.minY, anchor.y)))
                Path { path in path.move(to: anchor); path.addLine(to: tip) }
                    .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, lineCap: .round)).allowsHitTesting(false)
                MapContextLabelContent(model: model, signature: "\(model.snapshot.revision):\(model.metroRevision):\(model.mapLabelStation?.id ?? ""):\(model.selectedVehicleID ?? ""):\(model.selectedTrainID ?? ""):\(model.language.rawValue):\(expanded):\(overlay.compactStation)",
                    expanded: expanded, compact: overlay.compactStation,
                    toggle: {
#if DEBUG
                        model.recordMapTap(expanded ? "station-collapse" : "station-expand")
#endif
                        expandedStationID = expanded ? nil : model.mapLabelStation?.id
                    }, showDetails: showDetails)
                    .equatable().frame(width: width).fixedSize(horizontal: false, vertical: true)
                    .background { GeometryReader { body in Color.clear.preference(key: MapLabelSizeKey.self, value: body.size) } }
                    .position(x: placement.midX, y: placement.midY)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .onPreferenceChange(MapLabelSizeKey.self) { size in if size.height > 0, abs(size.height - labelSize.height) > 0.5 { labelSize = size } }
        .onChange(of: model.mapLabelStation?.id) { _, _ in expandedStationID = nil }
        .onChange(of: overlay.compactStation) { _, compact in if compact { expandedStationID = nil } }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: overlay.windowPoint != nil)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: expandedStationID)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: overlay.compactStation)
    }

}

private struct MapContextLabelContent: View, Equatable {
    @ObservedObject var model: TransitAppModel
    let signature: String
    let expanded: Bool
    let compact: Bool
    let toggle: () -> Void
    let showDetails: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.signature == rhs.signature }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { InterfaceMotion.reduced(systemReduceMotion) }

    @ViewBuilder var body: some View {
        if let station = model.mapLabelStation {
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                let all = StationArrival.rows(station: station, metadata: model.metadata, snapshot: model.snapshot, now: timeline.date)
                let arrivals = model.routeBoardingStop.map { stop in all.filter { $0.stop.id == stop.id } } ?? all
                let first = arrivals.first
                VStack(spacing: 4) {
                    Button(action: toggle) {
                        HStack(spacing: 6) {
                            if compact && !expanded {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                Text(station.localizedName).font(.caption.weight(.semibold)).lineLimit(1)
                                if let first, first.estimateSeconds != nil || station.mode == .bus { Text(EstimateFeed.label(first.estimateSeconds)).font(.caption).monospacedDigit() }
                            } else {
                                Image(systemName: station.mode == .bus ? "mappin.circle.fill" : "tram.circle.fill").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    BilingualName(station).font(.headline).lineLimit(2)
                                    Text(station.mode == .bus ? station.localizedBearing : model.metadata.metro.station(station.id)?.code ?? "").font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
                                }
                            }
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                        }.frame(minHeight: 44).contentShape(Rectangle()).mapLabelSurface()
                    }.buttonStyle(.plain).accessibilityIdentifier("map-station-expand")
                        .accessibilityValue(expanded ? AppText.text("已展開") : AppText.text("已收合"))
                    if !compact || expanded, let first {
                        Button {
                            if let route = first.route { model.selectRoute(route, direction: first.stop.direction, boardingStopID: first.stop.id) }
                        } label: {
                            HStack(spacing: 5) {
                                RouteBadge(name: first.route.map { $0.mode == .bus ? $0.localizedName : $0.lineCode } ?? first.stop.routeID, tintName: first.route?.name ?? first.stop.routeID, compact: true)
                                Text(first.estimateSeconds != nil || station.mode == .bus ? EstimateFeed.label(first.estimateSeconds) : AppText.text("看方向")).fontWeight(.semibold).monospacedDigit()
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            }.font(.caption).padding(.leading, 4).padding(.trailing, 10).frame(minHeight: 32)
                                .background(.regularMaterial, in: Capsule())
                                .overlay { Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.5) }
                        }.buttonStyle(PhonePressStyle()).accessibilityHint(AppText.text("官方下一班時間"))
                    }
                    if expanded {
                        if let row = first, let route = row.route {
                            let fleet = model.metadata.vehicles(routeID: route.id, direction: row.stop.direction, allVariants: true, in: model.snapshot.vehicles)
                            let group = RouteBoardingVehicles(stop: row.stop, vehicles: fleet, metadata: model.metadata, at: timeline.date)
                            ForEach(Array(group.approaching.prefix(2))) { approach in
                                Button {
                                    model.selectRoute(route, direction: row.stop.direction, boardingStopID: row.stop.id)
                                    model.selectVehicle(approach.vehicle)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(approach.vehicle.plate).monospaced().fontWeight(.semibold)
                                        Spacer(minLength: 4)
                                        let estimate = model.arrivalDisplay(approach.vehicle, stopID: row.stop.id, at: timeline.date)
                                        Text(estimate.prediction != nil ? estimate.label : AppText.text("時間待確認")).monospacedDigit()
                                        Image(systemName: "scope").foregroundStyle(Color.accentColor)
                                    }.font(.caption).frame(minHeight: 30).padding(.horizontal, 10).mapLabelSurface()
                                }.buttonStyle(PhonePressStyle()).accessibilityIdentifier("map-station-bus-" + approach.vehicle.plate)
                            }
                        }
                        HStack(spacing: 12) {
                            Button(action: showDetails) {
                                Label(AppText.text("到站車輛"), systemImage: "bus").font(.caption.weight(.medium)).padding(.horizontal, 9).frame(minHeight: 36)
                            }.buttonStyle(PhonePressStyle()).phoneGlass(in: Capsule()).accessibilityIdentifier("map-station-details")
                            Button { model.startStationWalk(station) } label: {
                                Label(AppText.text("步行"), systemImage: "figure.walk").font(.caption.weight(.medium)).padding(.horizontal, 9).frame(minHeight: 36)
                            }.buttonStyle(PhonePressStyle()).phoneGlass(in: Capsule()).accessibilityIdentifier("map-station-walk")
                        }
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("map-station-inline-label")
            }
        } else if let bus = model.selectedVehicle {
            HStack(spacing: 8) {
                let route = model.metadata.route(bus.routeID)
                RouteBadge(name: route?.localizedName ?? bus.localizedRouteName, tintName: route?.name ?? bus.routeName, compact: true)
                Text(bus.plate).font(.subheadline.weight(.semibold)).monospaced()
                Button(action: showDetails) { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                    .accessibilityLabel(AppText.text("車輛資訊"))
            }.padding(.horizontal, 12).readableMapSurface().fixedSize()
        } else if let id = model.selectedTrainID, let report = model.metroRealtime?.trains.first(where: { $0.id == id }) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                if (-15...60).contains(timeline.date.timeIntervalSince(report.observedAt)),
                   let pattern = model.metadata.metro.pattern(report.patternID, direction: report.direction),
                   let line = model.metadata.metro.line(pattern.lineID), let station = model.metadata.metro.station(report.nextStationID) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            RouteBadge(name: line.code, tintName: line.name, compact: true)
                            Text(report.id).font(.caption.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 2)
                            Button { model.metroRevisionForSelection() } label: { Image(systemName:"scope").frame(width:32,height:32) }
                                .accessibilityLabel(AppText.text("跟隨列車"))
                        }
                        HStack {
                            Text(AppText.text("下一站 · ") + (AppLanguage.current == .english ? station.englishName : station.name)).font(.subheadline.weight(.semibold))
                            Spacer(minLength:4)
                            Text(MetroCountdown.label(max(0,Int(report.remainingSeconds - max(0,timeline.date.timeIntervalSince(report.observedAt)))))).font(.subheadline).monospacedDigit()
                        }
                        if AppLanguage.current == .english { Text(station.name).font(.caption).foregroundStyle(.secondary) }
                        Text(AppText.text("官方列車訊號 · 位置為估計")).font(.caption2).foregroundStyle(.secondary)
                    }.mapLabelSurface().accessibilityElement(children:.contain).accessibilityIdentifier("map-metro-train-label")
                }
            }
        }
    }
}

private struct MapLabelSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        content.foregroundStyle(Color(uiColor: .label)).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground).opacity(0.92), in: shape)
            .phoneGlass(in: shape)
            .overlay { shape.stroke(Color.primary.opacity(scheme == .dark ? 0.22 : 0.12), lineWidth: 0.75) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.18), radius: 8, y: 3)
    }
}
private extension View {
    func mapLabelSurface() -> some View { modifier(MapLabelSurface()) }
}

private struct MapLabelSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
