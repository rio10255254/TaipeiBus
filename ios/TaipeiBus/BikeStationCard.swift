import SwiftUI
import TransitCore

/// The card under the map for a tapped YouBike dock: how many bikes and empty docks the
/// station last reported, how old that report is, and the nearest station with bikes when
/// this one has none. Counts are the operator's, not a prediction by this app.
struct BikeStationCard: View {
    @Environment(\.liveSettings) private var live
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: TransitAppModel
    let station: BikeStation
    let distance: Double?
    let close: () -> Void
    var returning = false
    var embedded = false

    private var dock: BikeDock? { model.bikeDock(station.id) }
    private func tint(_ supply: BikeSupply) -> Color {
        Color(liveHex: NativeBusMap.Coordinator.bikeTint(supply, dark: colorScheme == .dark))
    }
    /// A station with nothing to rent is only useful with somewhere else to walk to.
    private func alternative(at date: Date) -> (station: BikeStation, distance: Double)? {
        guard BikeSupply.level(dock, at: date, returning: returning) == .empty else { return nil }
        return model.bikeNetwork.stations(near: station.coordinate, radius: 500, limit: 8)
            .first { other in
                guard other.id != station.id else { return false }
                let level = BikeSupply.level(model.bikeDock(other.id), at: date, returning: returning)
                return level == .plenty || level == .few
            }
            .map { ($0, $0.coordinate.distance(to: station.coordinate)) }
    }
    private func reportLabel(_ dock: BikeDock?, at date: Date) -> String {
        guard let dock else { return live.text("資料更新中") }
        if !dock.isFresh(at: date) { return live.text("資料延遲") }
        if !dock.active { return live.text("暫停服務") }
        let minutes = Int(max(0, date.timeIntervalSince(dock.observedAt)) / 60)
        return minutes < 1 ? live.text("剛剛更新") : AppText.text("%@ 分前更新", minutes)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let now = timeline.date
            let dock = self.dock
            let bikes = BikeSupply.level(dock, at: now)
            let docks = BikeSupply.level(dock, at: now, returning: true)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: returning ? "parkingsign.circle.fill" : "bicycle").liveFont(.subheadline, weight: .semibold).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Circle().fill(tint(returning ? docks : bikes)))
                        // A new station bounces its mark; the colour follows its supply.
                        .symbolBounce(station.id).smoothChanges(returning ? docks : bikes)
                    VStack(alignment: .leading, spacing: 2) {
                        BilingualName(chinese: station.name, english: station.englishName)
                            .liveFont(.headline, weight: .semibold).lineLimit(2)
                        Text([live.text("YouBike 站點"), station.localizedDistrict,
                              distance.map { distanceLabel($0) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .liveFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button(action: close) {
                        Image(systemName: "xmark").liveFont(.caption, weight: .bold).foregroundStyle(.secondary)
                            .frame(width: 30, height: 30).background(Circle().fill(Color.secondary.opacity(0.14)))
                    }.buttonStyle(.plain).accessibilityLabel(live.text("關閉")).frame(width: 36, height: 44)
                        .accessibilityIdentifier("bike-station-close")
                }
                HStack(spacing: 14) {
                    count(live.text("可借"), value: dock?.rentable, supply: bikes)
                    count(live.text("可還"), value: dock?.returnable, supply: docks)
                    Spacer(minLength: 0)
                    Text(reportLabel(dock, at: now)).liveFont(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("bike-station-report")
                }
                if returning {
                    Text(dock?.availableCount(returning: true, at: now).map { AppText.text("目前可還 %@ 格", $0) } ?? live.text("空位待確認"))
                        .liveFont(.headline, weight: .semibold).foregroundStyle(tint(docks))
                        .accessibilityIdentifier("bike-station-return-status")
                }
                if let nearest = alternative(at: now) {
                    Button { model.selectBikeStation(nearest.station.id, returning: returning) } label: {
                        HStack(spacing: 8) {
                            ContinuousMotion { running in
                                Image(systemName: "figure.walk").liveFont(.caption, weight: .semibold)
                                    .symbolEffect(.pulse, options: .repeating, isActive: running)
                            }
                            Text(AppText.text(returning ? "附近可還 %@ · %@" : "最近可借 %@ · %@", nearest.station.localizedName, distanceLabel(nearest.distance)))
                                .liveFont(.subheadline, weight: .semibold).lineLimit(1)
                        }.padding(.horizontal, 14).frame(minHeight: 40)
                    }
                    .buttonStyle(MapActionStyle())
                    .accessibilityIdentifier("bike-station-alternative")
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 10)
            .modifier(BikeStationSurface(embedded: embedded, shape: live.shape(.panel)))
            .accessibilityElement(children: .contain).accessibilityIdentifier("bike-station-card")
            .accessibilityLabel(AppText.text("YouBike %@，可借 %@，可還 %@", station.localizedName,
                                             dock?.availableCount(returning: false, at: now).map(String.init) ?? live.text("未知"),
                                             dock?.availableCount(returning: true, at: now).map(String.init) ?? live.text("未知")))
        }
    }

    private func count(_ title: String, value: Int?, supply: BikeSupply) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint(supply)).frame(width: 9, height: 9)
            Text(title).liveFont(.caption).foregroundStyle(.secondary)
            let figure = supply == .unknown || supply == .suspended ? "–" : "\(value ?? 0)"
            Text(figure).liveFont(.headline, weight: .semibold).monospacedDigit().liveNumericText(figure)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct BikeStationSurface: ViewModifier {
    let embedded: Bool
    let shape: RoundedRectangle
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content }
        else { content.phoneGlass(in: shape) }
    }
}

/// Presented by the currently visible sheet (or the map during navigation), so
/// inspecting a dock never replaces the trip or changes its navigation phase.
private struct BikeStationDetailsPresentation: ViewModifier {
    @ObservedObject var model: TransitAppModel
    let active: Bool
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { active && model.selectedBikeStation != nil },
            set: { if !$0 && active { model.selectedBikeStationID = nil } })) {
            if let station = model.selectedBikeStation {
                BikeStationCard(model: model, station: station, distance: nil,
                    close: { model.selectedBikeStationID = nil }, returning: model.selectedBikeStationReturning, embedded: true)
                    .padding(18)
                    .presentationDetents([.height(260), .medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
        }
    }
}

extension View {
    func bikeStationDetails(model: TransitAppModel, active: Bool = true) -> some View {
        modifier(BikeStationDetailsPresentation(model: model, active: active))
    }
}

struct JourneyBikeStations: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: TransitAppModel
    let bike: BikeLeg
    let index: Int
    var compact = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            if compact, !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 8) {
                    station(bike.pickup, returning: false, at: timeline.date)
                    station(bike.dropoff, returning: true, at: timeline.date)
                }
            } else {
                VStack(spacing: 6) {
                    station(bike.pickup, returning: false, at: timeline.date)
                    station(bike.dropoff, returning: true, at: timeline.date)
                }
            }
        }
    }
    private func station(_ station: BikeStation, returning: Bool, at date: Date) -> some View {
        let dock = model.bikeDock(station.id)
        let count = dock?.availableCount(returning: returning, at: date)
        let tint = Color(liveHex: NativeBusMap.Coordinator.bikeTint(BikeSupply.level(dock, at: date, returning: returning), dark: colorScheme == .dark))
        let status = count.map { AppText.text(returning ? "可還 %@ 格" : "可借 %@ 輛", $0) }
            ?? AppText.text(dock?.active == false ? "暫停服務" : returning ? "空位待確認" : "車輛待確認")
        return Button { model.selectBikeStation(station.id, returning: returning) } label: {
            HStack(spacing: 8) {
                Image(systemName: returning ? "parkingsign.circle" : "bicycle")
                    .liveFont(.subheadline).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(AppText.text(returning ? "還車" : "借車")).liveFont(.caption).foregroundStyle(.secondary)
                        if compact { Text(status).liveFont(.caption, weight: .semibold).monospacedDigit().foregroundStyle(tint) }
                    }
                    Text(station.localizedName).liveFont(compact ? .caption : .subheadline, weight: .medium)
                        .lineLimit(compact ? 1 : 2).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !compact { Text(status).liveFont(.caption, weight: .semibold).monospacedDigit().foregroundStyle(tint).fixedSize() }
                Image(systemName: "chevron.right").liveFont(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, minHeight: 48)
        }.buttonStyle(MapActionStyle())
            .accessibilityIdentifier("journey-bike-\(returning ? "dropoff" : "pickup")-\(index)")
            .accessibilityLabel(AppText.text(returning ? "還車站 %@，%@" : "借車站 %@，%@", station.localizedName, status))
    }
}
