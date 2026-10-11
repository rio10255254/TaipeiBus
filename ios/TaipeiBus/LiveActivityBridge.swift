import ActivityKit
import SwiftUI
import WidgetKit
import TransitCore

extension RouteSign {
    init(_ route: BusRoute) {
        let text = route.mode == .bus || route.lineCode.isEmpty ? route.localizedName : route.lineCode
        self.init(text: text, color: RouteTint.hex(for: route.name), darkInk: RouteTint.darkInk(for: route.name))
    }
    static let walking = RouteSign(text: "🚶", color: "#5E6670", darkInk: false)
}

/// Pro: the current trip on the Lock Screen and in the Dynamic Island. The app pushes a new
/// state while it runs; in between, the system counts down to the stored arrival time itself,
/// so nothing depends on a push server.
@MainActor
final class RideActivityController {
    typealias State = RideActivityAttributes.ContentState
    private var activity: Activity<RideActivityAttributes>?
    private var pushed: State?
    private(set) var debugState = "none"

    func update(_ state: State?, destination: String, language: AppLanguage, enabled: Bool) {
        guard enabled, let state else { endAll(); return }
        if activity == nil { activity = Activity<RideActivityAttributes>.activities.first { $0.activityState == .active } }
        if let current = activity, current.attributes.destination != destination || current.activityState != .active {
            endAll()
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { debugState = "disabled"; return }
        guard let current = activity else {
            do {
                activity = try Activity.request(attributes: RideActivityAttributes(destination: destination, language: language.rawValue),
                                                content: ActivityContent(state: state, staleDate: Self.staleDate(state)), pushType: nil)
                pushed = state; debugState = "started:" + state.phase.rawValue
            } catch { debugState = "unavailable" }
            return
        }
        guard let pushed, !Self.changed(pushed, state), state.updatedAt.timeIntervalSince(pushed.updatedAt) < 60 else {
            self.pushed = state; debugState = "updated:" + state.phase.rawValue
            Task { await current.update(ActivityContent(state: state, staleDate: Self.staleDate(state))) }
            return
        }
    }

    func endAll() {
        let running = Activity<RideActivityAttributes>.activities
        activity = nil; pushed = nil
        guard !running.isEmpty else { return }
        debugState = "ended"
        Task { for item in running { await item.end(nil, dismissalPolicy: .immediate) } }
    }

    private static func staleDate(_ state: State) -> Date {
        max(state.updatedAt.addingTimeInterval(900), (state.target ?? .distantPast).addingTimeInterval(300))
    }
    /// A new push only when something the rider reads changed; the countdown runs by itself.
    private static func changed(_ old: State, _ new: State) -> Bool {
        if old.phase != new.phase || old.sign != new.sign || old.headline != new.headline || old.detail != new.detail ||
            old.status != new.status || old.stopsLeft != new.stopsLeft || (old.target == nil) != (new.target == nil) { return true }
        guard let a = old.target, let b = new.target else { return false }
        return abs(a.timeIntervalSince(b)) >= 20
    }
}

/// Pro: saved trips on the Home Screen. The app records which bus each trip starts with; the
/// widget asks the official feed for that stop's next arrival on its own schedule.
@MainActor
final class CommuteWidgetBridge {
    private let defaults: UserDefaults
    private let key = "widgetCommuteRides.v1"
    private var rides: [String: CommuteWidgetPayload.Ride]
    private var planned: [String: Date] = [:]
    private var written: Data?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rides = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: CommuteWidgetPayload.Ride].self, from: $0) } ?? [:]
    }

    static func ride(_ ride: TransitRide, walkSeconds: Double, headwaySeconds: Double?) -> CommuteWidgetPayload.Ride {
        CommuteWidgetPayload.Ride(metro: ride.route.mode != .bus, sign: RouteSign(ride.route),
            routeKey: ride.route.mode == .bus ? ride.route.parentID : "", stopID: ride.boarding.id,
            stopName: ride.boarding.localizedName,
            toward: AppText.text("往 %@", ride.route.localizedDestination(direction: ride.direction)),
            walkSeconds: max(0, walkSeconds), headwaySeconds: headwaySeconds)
    }
    func record(_ id: UUID, ride: CommuteWidgetPayload.Ride) {
        planned[id.uuidString] = Date()
        guard rides[id.uuidString] != ride else { return }
        rides[id.uuidString] = ride
        if let bytes = try? JSONEncoder().encode(rides) { defaults.set(bytes, forKey: key) }
    }
    /// Saved trips the widget shows that have not been planned in this session for a while.
    func needsPlanning(_ journeys: [SavedJourney], now: Date) -> SavedJourney? {
        journeys.prefix(CommuteWidgetPayload.maximumCommutes).first { journey in
            planned[journey.id.uuidString].map { now.timeIntervalSince($0) > 6 * 3600 } ?? true
        }
    }
    func markPlanned(_ id: UUID) { planned[id.uuidString] = Date() }

    func payload(_ journeys: [SavedJourney], proUntil: Date?, language: AppLanguage, now: Date) -> CommuteWidgetPayload {
        CommuteWidgetPayload(language: language.rawValue, proUntil: proUntil, updatedAt: now,
            commutes: journeys.prefix(CommuteWidgetPayload.maximumCommutes).map { journey in
                CommuteWidgetPayload.Commute(id: journey.id.uuidString, title: journey.title, symbol: journey.symbol,
                    destination: journey.destination.localizedName, ride: rides[journey.id.uuidString])
            })
    }
    func publish(_ payload: CommuteWidgetPayload) {
        var comparable = payload; comparable.updatedAt = .distantPast
        // Pro's end is rounded to the hour so a moving grace window does not rewrite the item.
        comparable.proUntil = payload.proUntil.map { Date(timeIntervalSinceReferenceDate: ($0.timeIntervalSinceReferenceDate / 3600).rounded(.down) * 3600) }
        guard let signature = try? JSONEncoder().encode(comparable), signature != written,
              let bytes = try? JSONEncoder().encode(payload) else { return }
        written = signature
        if SharedStore.write(bytes, account: SharedStore.commutesAccount) { WidgetCenter.shared.reloadAllTimelines() }
    }
}

#if DEBUG
/// Interface verification: the widget and Live Activity layouts rendered at their real sizes
/// inside the app, because the simulator's Home Screen cannot be driven from a UI test.
struct WidgetPreviewGallery: View {
    let language: AppLanguage
    private let now = Date()
    private var signs: (bus: RouteSign, metro: RouteSign) {
        (RouteSign(text: "307", color: RouteTint.hex(for: "307"), darkInk: false),
         RouteSign(text: "R", color: RouteTint.hex(for: "淡水信義線"), darkInk: false))
    }
    private var entry: CommuteEntry {
        let home = CommuteWidgetPayload.Commute(id: "home", title: AppText.text("回家", language: language), symbol: "house.fill", destination: "",
            ride: .init(metro: false, sign: signs.bus, routeKey: "1", stopID: "1", stopName: language == .english ? "Taipei Main Station" : "臺北車站",
                        toward: AppText.text("往 %@", language == .english ? "Banqiao" : "板橋", language: language), walkSeconds: 240))
        let work = CommuteWidgetPayload.Commute(id: "work", title: AppText.text("上班", language: language), symbol: "briefcase.fill", destination: "",
            ride: .init(metro: true, sign: signs.metro, routeKey: "", stopID: "R10", stopName: language == .english ? "Taipei Main Station" : "台北車站",
                        toward: AppText.text("往 %@", language == .english ? "Xiangshan" : "象山", language: language), walkSeconds: 420, headwaySeconds: 300))
        return CommuteEntry(date: now, language: language, locked: false, commutes: [home, work],
                            timings: ["home": CommuteTiming(arrival: now.addingTimeInterval(11 * 60 + 20))])
    }
    private func card<Content: View>(_ width: CGFloat, _ height: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content().padding(16).frame(width: width, height: height)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    private var waiting: RideActivityAttributes.ContentState {
        .init(phase: .waiting, sign: signs.bus, headline: AppText.text("往 %@", language == .english ? "Banqiao" : "板橋", language: language),
              detail: language == .english ? "Taipei Main Station" : "臺北車站", target: now.addingTimeInterval(7 * 60 + 42),
              status: nil, stopsLeft: nil, totalStops: nil, updatedAt: now)
    }
    private var riding: RideActivityAttributes.ContentState {
        .init(phase: .riding, sign: signs.bus, headline: language == .english ? "Banqiao Station" : "板橋車站",
              detail: AppText.remainingStops(5, language: language), target: now.addingTimeInterval(14 * 60 + 5),
              status: nil, stopsLeft: 5, totalStops: 12, updatedAt: now)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    card(170, 170) { CommuteWidgetView(entry: entry, family: .systemSmall) }.accessibilityIdentifier("widget-preview-small")
                    card(170, 170) { CommuteWidgetView(entry: CommuteEntry(date: now, language: language, locked: true, commutes: [], timings: [:]), family: .systemSmall) }
                        .accessibilityIdentifier("widget-preview-locked")
                }
                card(354, 170) { CommuteWidgetView(entry: entry, family: .systemMedium) }.accessibilityIdentifier("widget-preview-medium")
                card(180, 76) { CommuteWidgetView(entry: entry, family: .accessoryRectangular) }.accessibilityIdentifier("widget-preview-lock")
                let attributes = RideActivityAttributes(destination: "", language: language.rawValue)
                RideActivityLockView(state: waiting, attributes: attributes)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous)).frame(width: 354)
                    .accessibilityIdentifier("live-activity-preview-waiting")
                RideActivityLockView(state: riding, attributes: attributes)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous)).frame(width: 354)
                    .accessibilityIdentifier("live-activity-preview-riding")
                HStack(spacing: 0) {
                    RouteSignView(sign: signs.bus, size: 12)
                    Spacer()
                    Text(AppText.stops(5, language: language)).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
                .padding(.horizontal, 12).frame(width: 250, height: 37).background(.black, in: Capsule())
                .accessibilityIdentifier("live-activity-preview-island")
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
#endif
