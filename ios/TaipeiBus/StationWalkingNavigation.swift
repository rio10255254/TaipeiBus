import SwiftUI
import MapKit
import TransitCore

/// One verified pedestrian route format shared by journey and station walking.
enum PedestrianPath {
    static func leg(_ route: MKRoute, from: Coordinate, to: Coordinate) -> WalkingLeg? {
        guard route.polyline.pointCount >= 2 else { return nil }
        var points = Array(repeating: CLLocationCoordinate2D(), count: route.polyline.pointCount)
        route.polyline.getCoordinates(&points, range: NSRange(location: 0, length: points.count))
        let coordinates = points.map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }
        guard coordinates.first!.distance(to: from) <= 50, coordinates.last!.distance(to: to) <= 50 else { return nil }
        var leg = WalkingLeg(from: from, to: to)
        leg.coordinates = coordinates; leg.distance = route.distance; leg.duration = route.expectedTravelTime
        leg.instructions = route.steps.map(\.instructions).filter { !$0.isEmpty }
        leg.road = RouteLine(coordinates: coordinates)
        return leg
    }
}

@MainActor
final class StationWalkingNavigation: ObservableObject {
    @Published private(set) var target: Station?
    @Published private(set) var leg: WalkingLeg?
    @Published private(set) var progress: WalkingProgress?
    @Published private(set) var calculating = false
    @Published private(set) var issue: String?
    @Published private(set) var revision = 0
    @Published private(set) var routeRevision = 0
    private struct Instruction { let text: String; let along: Double }
    private var instructions: [Instruction] = []
    private var task: Task<Void, Never>?
    private var request: MKDirections?
    private var generation = UUID()
    private var requestedAt = Date.distantPast
    var isActive: Bool { target != nil }
    var coordinates: [Coordinate] { progress?.remainingCoordinates ?? leg?.coordinates ?? [] }
    var remainingDistance: Double? { progress?.remainingDistance ?? leg?.distance }
    var remainingSeconds: Double? { progress?.remainingSeconds ?? leg?.duration }
    var currentInstruction: String {
        let along = progress?.match?.along ?? 0
        return instructions.last(where: { $0.along <= along + 8 })?.text ?? instructions.first?.text ?? AppText.text("沿橘色路線步行")
    }
    var nextInstruction: String? {
        guard let progress, progress.locationConfirmed, let along = progress.match?.along,
              let next = instructions.first(where: { $0.along > along + 8 }) else { return nil }
        return AppText.text("再 %@ · %@", distanceLabel(next.along - along), next.text)
    }
    var locationConfirmed: Bool {
        progress?.locationConfirmed == true && progress?.lastFix.map { Date().timeIntervalSince($0) <= 20 } == true
    }
    func begin(_ station: Station, location: LocationService) {
        cancel(); target = station
        update(location: location)
    }
    func update(location: LocationService) {
        guard let target else { return }
        guard let coordinate = location.usableCoordinate else {
            issue = location.message ?? AppText.text("正在取得目前位置"); return
        }
        if leg == nil { if !calculating, Date().timeIntervalSince(requestedAt) >= 20 { calculate(from: coordinate, to: target) }; return }
        guard let accuracy = location.accuracy, let timestamp = location.updatedAt, var value = progress else { return }
        let now = Date()
        _ = value.update(coordinate: coordinate, accuracy: accuracy, timestamp: timestamp, now: now)
        progress = value; revision += 1
        if value.needsReroute, !calculating, now.timeIntervalSince(requestedAt) >= 20 {
            calculate(from: coordinate, to: target)
        }
    }
    func retry(location: LocationService) {
        guard let target else { return }
        location.request()
        if let coordinate = location.usableCoordinate { calculate(from: coordinate, to: target) }
    }
    private func calculate(from: Coordinate, to station: Station) {
        task?.cancel(); request?.cancel()
        let token = UUID(); generation = token; calculating = true; issue = nil; requestedAt = Date()
        let directions = MKDirections.Request()
        directions.source = TravelPlace(name: AppText.text("目前位置"), address: "", coordinate: from).mapItem
        directions.destination = TravelPlace(name: station.localizedName, address: station.address, coordinate: station.coordinate).mapItem
        directions.transportType = .walking; directions.requestsAlternateRoutes = true
        let operation = MKDirections(request: directions); request = operation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await operation.calculate()
                guard !Task.isCancelled, generation == token, target?.id == station.id else { return }
                let usable = response.routes.compactMap { route -> (MKRoute, WalkingLeg)? in
                    PedestrianPath.leg(route, from: from, to: station.coordinate).map { (route, $0) }
                }.min { $0.0.expectedTravelTime < $1.0.expectedTravelTime }
                calculating = false; request = nil
                guard let (route, path) = usable else { issue = AppText.text("暫時找不到步行路線"); return }
                leg = path
                progress = WalkingProgress(coordinates: path.coordinates, distance: path.distance ?? 0, seconds: path.duration ?? 0)
                let line = RouteLine(coordinates: path.coordinates)
                var previous = 0.0
                instructions = route.steps.compactMap { step in
                    guard !step.instructions.isEmpty, step.polyline.pointCount > 0 else { return nil }
                    let point = step.polyline.points()[0].coordinate
                    let coordinate = Coordinate(latitude: point.latitude, longitude: point.longitude)
                    let along = line.candidates(coordinate, maximumDistance: 40)
                        .filter { $0.along >= previous - 10 }.min { $0.distance + abs($0.along - previous) * 0.001 < $1.distance + abs($1.along - previous) * 0.001 }?.along ?? previous
                    previous = max(previous, along)
                    return Instruction(text: step.instructions, along: previous)
                }
                routeRevision += 1; revision += 1
            } catch {
                if generation == token, !Task.isCancelled { calculating = false; request = nil; issue = AppText.text("步行路線暫時無法更新") }
            }
        }
    }
    func cancel() {
        task?.cancel(); task = nil; request?.cancel(); request = nil; generation = UUID()
        target = nil; leg = nil; progress = nil; instructions = []; calculating = false; issue = nil; revision += 1
    }
}

struct StationWalkingDock: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: TransitAppModel
    @ObservedObject var navigation: StationWalkingNavigation
    var body: some View {
        if let station = navigation.target {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        BilingualName(station).liveFont(.headline, weight: .bold).lineLimit(2)
                        Text(station.localizedBearing).liveFont(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button { model.finishStationWalk() } label: {
                        Image(systemName: "xmark").liveFont(.subheadline, weight: .bold).frame(width: 40, height: 40)
                    }
                    .buttonStyle(MapActionStyle(tint: Color.primary))
                    .accessibilityLabel(AppText.text("返回站牌")).accessibilityIdentifier("station-walk-close")
                }
                if navigation.calculating {
                    HStack { ProgressView(); Text(AppText.text("正在規劃步行路線")) }.liveFont(.subheadline)
                } else if let issue = navigation.issue {
                    Text(issue).liveFont(.subheadline).foregroundStyle(.secondary)
                    if model.location.permissionDenied {
                        Button(AppText.text("開啟定位設定")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.secondaryAction()
                    } else {
                        Button(AppText.text("重試")) { navigation.retry(location: model.location) }.secondaryAction()
                    }
                } else if navigation.leg != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(navigation.remainingSeconds.map { AppText.text("約 %@ 分", max(1, Int(ceil($0 / 60)))) } ?? "—")
                                    .liveFont(.title3, weight: .bold).monospacedDigit().contentTransition(.numericText())
                                Text(navigation.remainingDistance.map(distanceLabel) ?? "—").liveFont(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            }
                            if !navigation.locationConfirmed { Text(AppText.text("定位確認中")).liveFont(.caption).foregroundStyle(.secondary) }
                        }.accessibilityElement(children: .combine).accessibilityIdentifier("station-walk-progress")
                    }
                    HStack(spacing: 12) {
                        Button { model.showStationWalkOverview() } label: {
                            Label(AppText.text("全程"), systemImage: "map").lineLimit(1).frame(maxWidth: .infinity, minHeight: 50)
                        }.buttonStyle(MapActionStyle()).accessibilityIdentifier("station-walk-overview")
                        Button { model.finishStationWalk() } label: {
                            Text(AppText.text("已到站牌")).lineLimit(1).frame(maxWidth: .infinity, minHeight: 50)
                        }.buttonStyle(MapActionStyle(prominent: true)).accessibilityIdentifier("station-walk-arrive")
                    }.liveFont(.body, weight: .semibold)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: MapChrome.cardRadius, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: MapChrome.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(scheme == .dark ? 0.16 : 0.07), lineWidth: 0.6) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.14), radius: 18, y: 6)
                .accessibilityElement(children: .contain).accessibilityIdentifier("station-walk-navigation")
        }
    }
}

/// Turn-by-turn walking guidance in the same dark banner as bus navigation.
struct StationWalkBanner: View {
    @ObservedObject var navigation: StationWalkingNavigation
    var body: some View {
        if navigation.target != nil, navigation.leg != nil, !navigation.calculating, navigation.issue == nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "figure.walk").font(.system(size: 30, weight: .semibold)).frame(width: 40)
                    Text(navigation.currentInstruction).liveFont(.title3, weight: .bold).lineLimit(3).minimumScaleFactor(0.8)
                        .accessibilityIdentifier("station-walk-instruction")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                if let next = navigation.nextInstruction {
                    BannerStrip {
                        Image(systemName: "arrow.turn.down.right").font(.caption.weight(.bold))
                        Text(AppText.text("接著 · ") + next).lineLimit(2)
                    }
                }
            }
            .modifier(InstructionBannerSurface())
            .smoothChanges(navigation.currentInstruction)
        }
    }
}
