import ActivityKit
import UIKit
import OSLog
import SwiftUI
import WidgetKit
import TransitCore

extension RouteSign {
    init(_ route: BusRoute) {
        let text = route.mode == .bus || route.lineCode.isEmpty ? route.localizedName : route.lineCode
        self.init(text: text, color: RouteTint.hex(for: route.name), darkInk: RouteTint.darkInk(for: route.name))
    }
    static let walking = RouteSign(text: "🚶", color: "#5E6670", darkInk: false)
    static let cycling = RouteSign(text: "🚲", color: "#248A3D", darkInk: false)
}

struct RideIslandNotice: Equatable {
    enum Kind { case step, alighting }
    var kind: Kind
    var key: String
    var title: String
    var body: String
}

/// A step is announced once, when the rider first leaves the app at that step.
/// ETA ticks do not reopen the island. Alighting remains subject to the reminder preference.
struct RideIslandNoticePolicy {
    private(set) var sent = Set<String>()
    private var lastStepAt = Date.distantPast
    func candidate(_ state: RideActivityAttributes.ContentState, language: AppLanguage,
                   alighting: Bool, now: Date) -> RideIslandNotice? {
        let value = RideActivityPresentation(state: state, language: language, now: now)
        guard !value.stale else { return nil }
        if alighting, state.phase == .riding, let target = value.target,
           target.timeIntervalSince(now) <= 110, !sent.contains(state.stepKey + ":alight") {
            return RideIslandNotice(kind: .alighting, key: state.stepKey + ":alight",
                title: AppText.text("準備下車", language: language), body: state.headline)
        }
        guard !sent.contains(state.stepKey), now.timeIntervalSince(lastStepAt) >= 12 else { return nil }
        return RideIslandNotice(kind: .step, key: state.stepKey, title: value.phaseTitle, body: state.headline)
    }
    func hasPending(_ state: RideActivityAttributes.ContentState, alighting: Bool, now: Date) -> Bool {
        let value = RideActivityPresentation(state: state, language: .traditionalChinese, now: now)
        guard !value.stale else { return false }
        return !sent.contains(state.stepKey) || (alighting && state.phase == .riding &&
            value.target.map { $0.timeIntervalSince(now) <= 110 } == true && !sent.contains(state.stepKey + ":alight"))
    }
    mutating func record(_ notice: RideIslandNotice, state: RideActivityAttributes.ContentState, at now: Date) {
        sent.insert(notice.key); sent.insert(state.stepKey)
        if notice.kind == .step { lastStepAt = now }
    }
}

/// The system adapter is also exercised with a delayed store in lifecycle tests.
@MainActor protocol RideActivitySession: AnyObject {
    var id: String { get }
    var attributes: RideActivityAttributes { get }
    var activityState: ActivityState { get }
    func update(_ content: ActivityContent<RideActivityAttributes.ContentState>, notice: RideIslandNotice?) async
    func end() async
    func observe(_ change: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never>
}
@MainActor protocol RideActivityStore {
    var allowed: Bool { get }
    var sessions: [any RideActivitySession] { get }
    func start(_ attributes: RideActivityAttributes, content: ActivityContent<RideActivityAttributes.ContentState>) throws -> any RideActivitySession
}
@MainActor private final class SystemRideSession: RideActivitySession {
    let value: Activity<RideActivityAttributes>
    init(_ value: Activity<RideActivityAttributes>) { self.value = value }
    var id: String { value.id }
    var attributes: RideActivityAttributes { value.attributes }
    var activityState: ActivityState { value.activityState }
    func update(_ content: ActivityContent<RideActivityAttributes.ContentState>, notice: RideIslandNotice?) async {
        let alert = notice.map { item in
            AlertConfiguration(title: LocalizedStringResource("\(item.title)"), body: LocalizedStringResource("\(item.body)"),
                sound: item.kind == .alighting ? .default : .named("NavigationQuiet.wav"))
        }
        await value.update(content, alertConfiguration: alert)
    }
    func end() async {
        guard RideActivityController.needsEnding(value.activityState) else { return }
        await value.end(nil, dismissalPolicy: .immediate)
    }
    func observe(_ change: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never> {
        Task { for await state in value.activityStateUpdates { guard !Task.isCancelled else { return }; change(state) } }
    }
}
@MainActor private struct SystemRideStore: RideActivityStore {
    var allowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var sessions: [any RideActivitySession] { Activity<RideActivityAttributes>.activities.map { SystemRideSession($0) } }
    func start(_ attributes: RideActivityAttributes, content: ActivityContent<RideActivityAttributes.ContentState>) throws -> any RideActivitySession {
        SystemRideSession(try Activity.request(attributes: attributes, content: content, pushType: nil))
    }
}

@MainActor protocol RideActivityBackgroundTask: AnyObject {
    func finish()
}
/// Ending a journey also turns off background location. Keep just the native
/// dismissal alive if the rider immediately returns to the Home Screen.
@MainActor private final class SystemRideBackgroundTask: RideActivityBackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Finish navigation activity") { [weak self] in
            Task { @MainActor in self?.finish() }
        }
    }
    func finish() {
        guard identifier != .invalid else { return }
        let value = identifier; identifier = .invalid
        UIApplication.shared.endBackgroundTask(value)
    }
}

/// End can preempt an obsolete update. A replacement still waits until every
/// previous island finishes ending, so late native callbacks cannot create duplicates.
@MainActor final class RideActivityController {
    private let logger = Logger(subsystem: "com.rio10255254.TaipeiBus", category: "RideActivity")
    typealias State = RideActivityAttributes.ContentState
    private struct Desired {
        var state: State
        var attributes: RideActivityAttributes
        var presentImportantUpdates: Bool
        var alightingAlerts: Bool
    }
    private let store: any RideActivityStore
    private let now: () -> Date
    private let beginBackgroundTask: @MainActor () -> any RideActivityBackgroundTask
    private var activity: (any RideActivitySession)?
    private var desired: Desired?
    private var pushed: State?
    private var noticePolicy = RideIslandNoticePolicy()
    var canPresentNotice: ((RideIslandNotice, State) -> Bool)?
    var didPresentNotice: ((RideIslandNotice, State) -> Void)?
    private var revision = 0
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    private var retirements: [String: Task<Void, Never>] = [:]
    private var mayHaveActivities = true
    private var retiredIDs = Set<String>()
    private var stoppedByUser = false
    private var lastAllowed: Bool?
    private var authorizationTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private(set) var debugState = "none"
    var isAllowed: Bool { store.allowed }
    var isRunning: Bool {
        store.allowed && desired != nil && !stoppedByUser && activity.map { $0.activityState == .active || $0.activityState == .stale } == true
    }
    var onAvailabilityChange: (() -> Void)?
    /// Lifecycle events for the shareable diagnostics report; no places or coordinates.
    var onDiagnostic: ((String) -> Void)?
    /// Only `.ended` and `.dismissed` are final. Any other state, including one a newer iOS
    /// adds, can still occupy an island slot and must be ended rather than skipped.
    nonisolated static func needsEnding(_ state: ActivityState) -> Bool { state != .ended && state != .dismissed }
    /// This app's activities iOS still lists, e.g. "native=1[active] ending=0".
    var nativeSummary: String {
        let listed = store.sessions.filter { Self.needsEnding($0.activityState) }
        return "native=\(listed.count)[\(listed.map { "\($0.activityState)" }.joined(separator: ","))] ending=\(retirements.count)"
    }

    init(store: (any RideActivityStore)? = nil, now: @escaping () -> Date = Date.init,
         beginBackgroundTask: (@MainActor () -> any RideActivityBackgroundTask)? = nil) {
        self.store = store ?? SystemRideStore()
        self.now = now
        self.beginBackgroundTask = beginBackgroundTask ?? { SystemRideBackgroundTask() }
        if store == nil {
            authorizationTask = Task { [weak self] in
                for await _ in ActivityAuthorizationInfo().activityEnablementUpdates {
                    guard !Task.isCancelled else { return }
                    self?.onAvailabilityChange?()
                }
            }
        }
    }
    deinit { authorizationTask?.cancel(); stateTask?.cancel(); worker?.cancel() }
    func allowRestart() {
        guard !isRunning else { return }
        stoppedByUser = false; pushed = nil; noticePolicy = RideIslandNoticePolicy(); debugState = "none"
        revision += 1; schedule()
    }
    func update(_ state: State?, destination: String, language: AppLanguage, enabled: Bool,
                presentImportantUpdates: Bool = false, alightingAlerts: Bool = false) {
        guard enabled, let state else { endAll(recheckSystem: false); return }
        guard !stoppedByUser else { return }
        let permissionChanged = lastAllowed != store.allowed
        lastAllowed = store.allowed
        let attributes = RideActivityAttributes(destination: destination, language: language.rawValue)
        if let old = desired, old.attributes.destination != destination { noticePolicy = RideIslandNoticePolicy() }
        let pendingNotice = presentImportantUpdates && noticePolicy.hasPending(state, alighting: alightingAlerts, now: now())
        if !pendingNotice, !permissionChanged, let old = desired, old.presentImportantUpdates == presentImportantUpdates,
           old.alightingAlerts == alightingAlerts, Self.same(old.attributes, attributes), !Self.changed(old.state, state),
           state.updatedAt.timeIntervalSince(old.state.updatedAt) < 30, isRunning || worker != nil { return }
        desired = Desired(state: state, attributes: attributes, presentImportantUpdates: presentImportantUpdates, alightingAlerts: alightingAlerts)
        revision += 1; mayHaveActivities = true; schedule()
    }
    func endAll(recheckSystem: Bool = true) {
        // Nil GPS/feed updates can arrive every second while browsing. Reserve
        // native re-enumeration for a real End or foreground/background transition.
        guard recheckSystem || desired != nil || activity != nil || mayHaveActivities else { stoppedByUser = false; return }
        var sessions = store.sessions
        if let activity, !sessions.contains(where: { $0.id == activity.id }) { sessions.append(activity) }
        let active = sessions.filter { Self.needsEnding($0.activityState) }
        retiredIDs.formUnion(active.map(\.id))
        // A terminal callback already queued by the old activity must not dismiss
        // a journey that the user starts immediately after this one.
        stateTask?.cancel(); stateTask = nil; activity = nil
        desired = nil; stoppedByUser = false; pushed = nil; noticePolicy = RideIslandNoticePolicy(); debugState = "ended"
        revision += 1
        // ActivityKit updates may remain suspended. Cancel their ownership, not
        // the native retirement, and submit End independently of those awaits.
        worker?.cancel(); worker = nil; workerID = nil
        for session in active { retire(session) }
        schedule()
    }
    private func schedule() {
        guard worker == nil else { return }
        let id = UUID(); workerID = id
        worker = Task { [weak self] in
            guard let self else { return }
            let wasRunning = isRunning, oldDebug = debugState
            await reconcile()
            guard workerID == id else { return }
            worker = nil; workerID = nil
            if wasRunning != isRunning || oldDebug != debugState { onAvailabilityChange?() }
        }
    }
    private func retire(_ session: any RideActivitySession) {
        guard retirements[session.id] == nil else { return }
        guard Self.needsEnding(session.activityState) else {
            retiredIDs.remove(session.id); return
        }
        retiredIDs.insert(session.id)
        // Acquire the finite background allowance synchronously, before End can
        // disable navigation location or the scene can leave the foreground.
        let backgroundTask = beginBackgroundTask()
        retirements[session.id] = Task { [weak self] in
            await session.end()
            self?.onDiagnostic?("island ended \(session.activityState)")
            backgroundTask.finish()
            self?.retirements.removeValue(forKey: session.id)
            self?.retiredIDs.remove(session.id)
        }
    }
    private func waitForRetirements() async {
        for task in Array(retirements.values) { await task.value }
    }
    private func reconcile() async {
        while !Task.isCancelled {
            await waitForRetirements()
            guard !Task.isCancelled else { return }
            let version = revision
            let next = store.allowed && !stoppedByUser ? desired : nil
            var sessions = store.sessions
            if let activity, !sessions.contains(where: { $0.id == activity.id }) { sessions.append(activity) }
            let matching = next.flatMap { wanted in
                sessions.first { !retiredIDs.contains($0.id) && Self.same($0.attributes, wanted.attributes) && ($0.activityState == .active || $0.activityState == .stale) }
            }
            // Detach the observer before intentional end events; those are not a user dismissal.
            if activity?.id != matching?.id { stateTask?.cancel(); stateTask = nil; activity = nil; pushed = nil }
            for session in sessions where session.id != matching?.id {
                retire(session)
            }
            await waitForRetirements()
            guard !Task.isCancelled else { return }
            guard version == revision else { continue }
            guard let next else {
                activity = nil; pushed = nil; mayHaveActivities = false
                if !store.allowed { debugState = "disabled" }
                return
            }
            if activity == nil, let matching { activity = matching; observe(matching) }
            if activity == nil {
                do {
                    let created = try store.start(next.attributes, content: content(next.state))
                    // Request already includes this payload. Publishing it again
                    // cancels the first system render without providing new data.
                    activity = created; pushed = next.state; observe(created)
                    debugState = "started:" + next.state.phase.rawValue
                    onDiagnostic?("island started \(next.state.phase.rawValue) \(nativeSummary)")
                } catch {
                    let failure = error as NSError
                    logger.error("Activity request failed: domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
                    debugState = "unavailable"
                    onDiagnostic?("island request_failed domain=\(failure.domain) code=\(failure.code)")
                }
            }
            if let current = activity {
                // An old source timestamp cannot certify its own freshness, especially
                // after an earlier native update kept this worker suspended.
                let presentedAt = now()
                let language = AppLanguage(rawValue: next.attributes.language) ?? .traditionalChinese
                var notice = next.presentImportantUpdates ? noticePolicy.candidate(next.state, language: language,
                    alighting: next.alightingAlerts, now: presentedAt) : nil
                if let candidate = notice, canPresentNotice?(candidate, next.state) == false {
                    noticePolicy.record(candidate, state: next.state, at: presentedAt); notice = nil
                }
                if notice != nil || (pushed.map { Self.changed($0, next.state) || next.state.updatedAt.timeIntervalSince($0.updatedAt) >= 30 } ?? true) {
                    await current.update(content(next.state), notice: notice)
                    guard !Task.isCancelled else { return }
                    if let notice, activity?.id == current.id,
                       current.activityState == .active || current.activityState == .stale,
                       desired?.state.stepKey == next.state.stepKey {
                        noticePolicy.record(notice, state: next.state, at: presentedAt)
                        didPresentNotice?(notice, next.state)
                    }
                    guard version == revision else { continue }
                    guard current.activityState == .active || current.activityState == .stale else {
                        stoppedByUser = true; debugState = "dismissed"; return
                    }
                    pushed = next.state; debugState = "updated:" + next.state.phase.rawValue
                }
            }
            if version == revision { return }
        }
    }
    private func observe(_ session: any RideActivitySession) {
        stateTask?.cancel()
        stateTask = session.observe { [weak self] state in
            guard let self, activity?.id == session.id else { return }
            if state == .dismissed || state == .ended {
                stoppedByUser = true; debugState = "dismissed"; onDiagnostic?("island dismissed_by_system_or_user \(state)")
                onAvailabilityChange?()
            }
        }
    }
    private static func same(_ a: RideActivityAttributes, _ b: RideActivityAttributes) -> Bool {
        a.destination == b.destination && a.language == b.language
    }
    private func content(_ state: State) -> ActivityContent<State> {
        let presentedAt = now()
        let sourceExpiry = state.freshUntil ?? state.updatedAt.addingTimeInterval(120)
        let deadline = [state.updateDeadline, sourceExpiry].filter { $0 > presentedAt }.min()
        // An already-expired native deadline can skip the initial system view.
        // Source freshness remains in the payload and the shared presentation
        // still shows its stale/due guidance immediately. Only ask ActivityKit
        // to schedule a future transition when there is one left to perform.
        return ActivityContent(state: state, staleDate: deadline,
            relevanceScore: RideActivityPresentation(state: state, language: .traditionalChinese, now: presentedAt).relevance)
    }
    private static func changed(_ old: State, _ new: State) -> Bool {
        if let before = old.freshUntil, let after = new.freshUntil,
           (before <= new.updatedAt) != (after <= new.updatedAt) { return true }
        if old.phase != new.phase || old.sign != new.sign || old.headline != new.headline || old.detail != new.detail ||
            old.status != new.status || old.stopsLeft != new.stopsLeft || old.totalStops != new.totalStops || old.symbol != new.symbol || old.stepIdentifier != new.stepIdentifier ||
            old.nextInstruction != new.nextInstruction || (old.remainingMeters == nil) != (new.remainingMeters == nil) ||
            (old.target == nil) != (new.target == nil) { return true }
        if let a = old.remainingMeters, let b = new.remainingMeters, abs(a-b) >= 20 { return true }
        guard let a = old.target, let b = new.target else { return false }
        return abs(a.timeIntervalSince(b)) >= 20
    }
#if DEBUG || ISLAND_RENDER_AUDIT
    func waitForPendingChanges() async { while let task = worker { await task.value } }
#endif
}

/// Pro: saved trips on the Home Screen. The app records which bus each trip starts with; the
/// widget asks the official feed for that stop's next arrival on its own schedule.
@MainActor
final class CommuteWidgetBridge {
    /// What the widget watches for one saved trip, and where that plan started.
    private struct Plan: Codable {
        var ride: CommuteWidgetPayload.Ride?
        var walkOnly: Bool
        var from: Coordinate?
    }
    private let defaults: UserDefaults
    private let key = "widgetCommutePlans.v2"
    private var plans: [String: Plan]
    private var planned: [String: Date] = [:]
    private var written: Data?
    private var reloadedAt = Date.distantPast

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        plans = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Plan].self, from: $0) } ?? [:]
    }

    static func ride(_ ride: TransitRide, walkSeconds: Double, headwaySeconds: Double?) -> CommuteWidgetPayload.Ride {
        CommuteWidgetPayload.Ride(metro: ride.route.mode != .bus, sign: RouteSign(ride.route),
            routeKey: ride.route.mode == .bus ? ride.route.parentID : "", stopID: ride.boarding.id,
            stopName: ride.boarding.localizedName,
            toward: AppText.text("往 %@", ride.route.localizedDestination(direction: ride.direction)),
            walkSeconds: max(0, walkSeconds), headwaySeconds: headwaySeconds)
    }
    /// A planned trip: its first ride, or nil when walking is the whole trip.
    func record(_ id: UUID, ride: CommuteWidgetPayload.Ride?, from: Coordinate?) {
        planned[id.uuidString] = Date()
        let plan = Plan(ride: ride, walkOnly: ride == nil, from: from)
        if let old = plans[id.uuidString], old.ride == plan.ride, old.walkOnly == plan.walkOnly {
            switch (old.from, from) {
            case (nil, nil): return
            case let (a?, b?) where a.distance(to: b) < 50: return
            default: break
            }
        }
        plans[id.uuidString] = plan
        if let bytes = try? JSONEncoder().encode(plans) { defaults.set(bytes, forKey: key) }
    }
    /// The next saved trip the widget shows whose plan is missing, old, or — for a trip from the
    /// current location — was made somewhere else: "回家" from work starts at a different stop.
    func needsPlanning(_ journeys: [SavedJourney], location: Coordinate?, now: Date) -> SavedJourney? {
        journeys.prefix(CommuteWidgetPayload.maximumCommutes).first { journey in
            let id = journey.id.uuidString
            guard let last = planned[id] else { return true }
            if now.timeIntervalSince(last) > 6 * 3600 { return true }
            guard journey.origin == nil, now.timeIntervalSince(last) > 120, let location else { return false }
            return plans[id]?.from.map { $0.distance(to: location) > 400 } ?? true
        }
    }
    func markPlanned(_ id: UUID) { planned[id.uuidString] = Date() }

    func payload(_ journeys: [SavedJourney], proUntil: Date?, language: AppLanguage, now: Date) -> CommuteWidgetPayload {
        CommuteWidgetPayload(language: language.rawValue, proUntil: proUntil, updatedAt: now,
            commutes: journeys.prefix(CommuteWidgetPayload.maximumCommutes).map { journey in
                let plan = plans[journey.id.uuidString]
                return CommuteWidgetPayload.Commute(id: journey.id.uuidString, title: journey.title, symbol: journey.symbol,
                    destination: journey.destination.localizedName, ride: plan?.ride, walkOnly: plan?.walkOnly)
            })
    }
    func publish(_ payload: CommuteWidgetPayload) {
        var comparable = payload; comparable.updatedAt = .distantPast
        // Pro's end is rounded to the hour so a moving grace window does not rewrite the item.
        comparable.proUntil = payload.proUntil.map { Date(timeIntervalSinceReferenceDate: ($0.timeIntervalSinceReferenceDate / 3600).rounded(.down) * 3600) }
        guard let signature = try? JSONEncoder().encode(comparable) else { return }
        if signature != written, let bytes = try? JSONEncoder().encode(payload) {
            // Keychain calls are synchronous; keep them off the main thread, and try each new
            // payload once rather than on every refresh if the shared group is unavailable.
            written = signature
            Task.detached(priority: .utility) {
                guard SharedStore.write(bytes, account: SharedStore.commutesAccount) else { return }
                await MainActor.run { [weak self] in self?.reload() }
            }
            return
        }
        // While the app is open its reloads do not use the widget's daily refresh budget, so keep
        // the Home Screen times fresh every few minutes.
        if Date().timeIntervalSince(reloadedAt) > 300, payload.proUntil != nil { reload() }
    }
    private func reload() {
        reloadedAt = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: "CommuteWidget")
    }
}

#if DEBUG || ISLAND_RENDER_AUDIT
@MainActor private final class IslandPreviewActivity: ObservableObject {
    let controller = RideActivityController()
    let location = LocationService()
    let usesLocation = ProcessInfo.processInfo.arguments.contains("--island-background-location")
    private var wantsLocation = false
    func startLocation() {
        guard usesLocation else { return }
        wantsLocation = true
        location.onAuthorizationChange = { [weak self] in
            guard let self else { return }
            location.setBackgroundNavigation(wantsLocation, activityVisible: wantsLocation)
            objectWillChange.send()
        }
        location.onNavigationUpdate = { [weak self] in self?.objectWillChange.send() }
        location.setActive(true); location.setWalkingNavigation(true)
        // The gallery starts its system activity together with location, as a trip does.
        location.request(); location.setBackgroundNavigation(true, activityVisible: true)
        objectWillChange.send()
    }
    func stopLocation() {
        guard usesLocation else { return }
        wantsLocation = false
        location.setBackgroundNavigation(false); location.setWalkingNavigation(false); location.setActive(false)
        objectWillChange.send()
    }
    func setSceneActive(_ active: Bool) {
        guard usesLocation else { return }
        location.setActive(active && wantsLocation)
    }
}

/// Deliberately labelled development fixtures, never used as physical-device review evidence.
struct IslandPreviewGallery: View {
    let language: AppLanguage
    @State private var selected: Int = {
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "--island-scenario"), args.indices.contains(flag + 1) {
            if args[flag + 1] == "stale" { return 6 }
            if args[flag + 1] == "due" { return 7 }
        }
        return args.contains("--island-companion") ? 4 : args.contains("--island-walking") ? 3 : 0
    }()
    @State private var reference = Date()
    @StateObject private var activity = IslandPreviewActivity()
    private var controller: RideActivityController { activity.controller }
    @State private var message = ""
    private let names = ["waiting", "riding", "alighting", "walking", "cycling", "transfer", "stale", "due", "long"]
    private var state: RideActivityAttributes.ContentState {
        Self.sample(names[selected], language: language, now: reference)
    }
    static func sample(_ name: String, language: AppLanguage, now: Date) -> RideActivityAttributes.ContentState {
        let english = language == .english
        var value = RideActivityAttributes.ContentState(phase: .waiting,
            sign: RouteSign(text: "630", color: "#1F6FD1", darkInk: false),
            headline: english ? "Neihu Station" : "捷運內湖站",
            detail: english ? "Toward Donghu · Wait at this stop" : "往東湖 · 在本站候車",
            target: now.addingTimeInterval(240), status: AppText.text("官方下一班", language: language),
            stopsLeft: nil, totalStops: nil, updatedAt: now, symbol: "bus.fill", freshUntil: now.addingTimeInterval(120))
        switch name {
        case "riding", "alighting", "stale":
            value.phase = .riding; value.stopsLeft = name == "alighting" ? 1 : 5; value.totalStops = 12
            value.detail = AppText.remainingStops(value.stopsLeft!, language: language)
            value.status = AppText.text("預估時間", language: language)
            if name == "stale" { value.updatedAt = now.addingTimeInterval(-300); value.freshUntil = now.addingTimeInterval(-1) }
        case "walking", "cycling", "transfer":
            value.phase = name == "cycling" ? .cycling : name == "transfer" ? .transferring : .walking
            value.sign = name == "cycling" ? .cycling : .walking
            value.symbol = name == "cycling" ? "bicycle" : "figure.walk"
            value.detail = english ? "Follow the route to the next connection" : "沿路線前往下一段接駁"
            value.status = AppText.text("預估時間", language: language)
        case "due": value.target = now.addingTimeInterval(-5)
        case "long":
            value.sign.text = english ? "Minsheng Metrobus" : "民生幹線（往返區間）"
            value.headline = english ? "Zhongxiao Fuxing Station · Exit 2" : "捷運忠孝復興站・二號出口"
        default: break
        }
        value.stepIdentifier = "preview:" + name
        if value.phase == .riding { value.nextInstruction = english ? "Then walk to your destination" : "下車後步行至目的地" }
        if value.phase == .walking || value.phase == .cycling { value.remainingMeters = 450 }
        return value
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Dynamic Island · Layout verification").font(.headline)
                Picker("Scenario", selection: $selected) {
                    ForEach(names.indices, id: \.self) { index in Text(names[index]).tag(index) }
                }.pickerStyle(.menu).accessibilityIdentifier("island-scenario")
                Button("Next scenario") { selected = (selected + 1) % names.count; reference = Date() }
                    .accessibilityIdentifier("island-next")
                let value = RideActivityPresentation(state: state, language: language)
                HStack {
                    RideIslandLeading(presentation: value)
                    Spacer().frame(minWidth: 70)
                    RideIslandTrailing(presentation: value)
                }.padding(.horizontal, 12).frame(width: 250, height: 37).background(.black, in: Capsule())
                    .accessibilityIdentifier("island-compact")
                HStack(spacing: 8) {
                    Capsule().fill(.black).frame(width: 170, height: 37)
                    RideIslandMinimal(presentation: value).frame(width: 37, height: 37).background(.black, in: Circle())
                }.accessibilityIdentifier("island-minimal")
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        RideActivityBadge(state: state)
                        Text(value.phaseTitle).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        RideCountdown(state: state, language: language, size: 24, showsCaption: true).frame(maxWidth: 130)
                    }
                    RideActivityDetails(presentation: value)
                }.padding(16).frame(maxWidth: .infinity).background(.black, in: RoundedRectangle(cornerRadius: 32))
                    .environment(\.colorScheme, .dark).foregroundStyle(.white).accessibilityIdentifier("island-expanded")
                RideActivityLockView(state: state, attributes: .init(destination: state.headline, language: language.rawValue))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).accessibilityIdentifier("island-lock")
                Button("Start system activity") {
                    reference = Date(); message = "starting"
                    controller.onAvailabilityChange = { message = controller.debugState }
                    controller.update(state, destination: "Island verification", language: language, enabled: true)
                    activity.startLocation()
                }.accessibilityIdentifier("island-system-start")
                Button("Add second test activity") {
                    do {
                        _ = try Activity<RideActivityAttributes>.request(attributes: .init(destination: "Second test activity", language: language.rawValue),
                            content: ActivityContent(state: Self.sample("cycling", language: language, now: Date()), staleDate: Date().addingTimeInterval(120)), pushType: nil)
                        message = "two-activities"
                    } catch { message = "second-failed" }
                }.accessibilityIdentifier("island-system-second")
                Button("End test activities") {
                    controller.endAll(); message = "ending"
                    activity.stopLocation()
                    Task { await controller.waitForPendingChanges(); message = "ended" }
                }.accessibilityIdentifier("island-system-end")
                Text(message).accessibilityIdentifier("island-system-status")
                Text(String(Activity<RideActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }.count))
                    .accessibilityIdentifier("island-system-count")
                if activity.usesLocation {
                    Text(activity.location.backgroundNavigation && activity.location.usableCoordinate != nil ? "background-location-with-fix" : "location-stopped-or-waiting")
                        .accessibilityIdentifier("island-location-status")
                }
            }.padding(16)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            activity.setSceneActive(false)
            guard ProcessInfo.processInfo.arguments.contains("--island-auto-expand"), controller.isRunning else { return }
            var current = state; current.updatedAt = Date(); current.freshUntil = Date().addingTimeInterval(120)
            controller.update(current, destination: "Island verification", language: language, enabled: true,
                presentImportantUpdates: true, alightingAlerts: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            activity.setSceneActive(true)
            guard ProcessInfo.processInfo.arguments.contains("--island-auto-expand"), controller.isRunning else { return }
            controller.update(state, destination: "Island verification", language: language, enabled: true)
        }
    }
}
#endif

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
