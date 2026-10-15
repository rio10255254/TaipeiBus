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

    private var dock: BikeDock? { model.bikeDock(station.id) }
    private func tint(_ supply: BikeSupply) -> Color {
        Color(liveHex: NativeBusMap.Coordinator.bikeTint(supply, dark: colorScheme == .dark))
    }
    /// A station with nothing to rent is only useful with somewhere else to walk to.
    private func alternative(at date: Date) -> (station: BikeStation, distance: Double)? {
        guard BikeSupply.level(dock, at: date) == .empty else { return nil }
        return model.bikeNetwork.stations(near: station.coordinate, radius: 500, limit: 8)
            .first { other in
                guard other.id != station.id else { return false }
                let level = BikeSupply.level(model.bikeDock(other.id), at: date)
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
                    Image(systemName: "bicycle").liveFont(.subheadline, weight: .semibold).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(Circle().fill(tint(bikes)))
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
                }
                HStack(spacing: 14) {
                    count(live.text("可借"), value: dock?.rentable, supply: bikes)
                    count(live.text("可還"), value: dock?.returnable, supply: docks)
                    Spacer(minLength: 0)
                    Text(reportLabel(dock, at: now)).liveFont(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("bike-station-report")
                }
                if let nearest = alternative(at: now) {
                    Button { model.selectBikeStation(nearest.station.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "figure.walk").liveFont(.caption, weight: .semibold)
                            Text(AppText.text("最近可借 %@ · %@", nearest.station.localizedName, distanceLabel(nearest.distance)))
                                .liveFont(.subheadline, weight: .semibold).lineLimit(1)
                        }.padding(.horizontal, 14).frame(minHeight: 40)
                    }
                    .buttonStyle(MapActionStyle())
                    .accessibilityIdentifier("bike-station-alternative")
                }
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 10)
            .phoneGlass(in: RoundedRectangle(cornerRadius: 22 * CGFloat(live.appearance.cornerScale), style: .continuous))
            .accessibilityElement(children: .contain).accessibilityIdentifier("bike-station-card")
            .accessibilityLabel(AppText.text("YouBike %@，可借 %@，可還 %@", station.localizedName,
                                             dock.map { String($0.rentable) } ?? live.text("未知"),
                                             dock.map { String($0.returnable) } ?? live.text("未知")))
        }
    }

    private func count(_ title: String, value: Int?, supply: BikeSupply) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint(supply)).frame(width: 9, height: 9)
            Text(title).liveFont(.caption).foregroundStyle(.secondary)
            Text(supply == .unknown ? "–" : "\(value ?? 0)").liveFont(.headline, weight: .semibold).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
