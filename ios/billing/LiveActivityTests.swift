import XCTest
import ActivityKit
@testable import TransitCore
@testable import TaipeiBus

@MainActor final class LiveActivityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func state(_ scenario: String = "riding") -> RideActivityAttributes.ContentState {
        IslandPreviewGallery.sample(scenario, language: .traditionalChinese, now: now)
    }
    func testStalenessOverridesStopsAndAlightingInEveryPresentation() {
        var state = state("alighting")
        state.freshUntil = now
        let value = RideActivityPresentation(state: state, language: .traditionalChinese, now: now)
        XCTAssertTrue(value.stale)
        XCTAssertFalse(value.alightingSoon)
        XCTAssertNil(value.compactText)
        XCTAssertNil(value.target)
        XCTAssertNil(value.progress)
        XCTAssertEqual(value.symbol, "arrow.clockwise")
        XCTAssertFalse(value.accessibilityLabel.contains("準備下車"))
    }
    func testSystemStaleOverridesFutureExpiry() {
        let value = RideActivityPresentation(state: state(), language: .english, systemStale: true, now: now)
        XCTAssertTrue(value.stale); XCTAssertNil(value.compactText)
        XCTAssertEqual(value.status, "Tap to refresh")
    }
    func testClockChangeAndInvalidCountdownDoNotCreateAnInvertedTimerRange() {
        let shifted = RideActivityPresentation(state: state(), language: .english, now: now.addingTimeInterval(-600))
        XCTAssertTrue(shifted.stale); XCTAssertNil(shifted.target)
        var invalid = state()
        invalid.target = now.addingTimeInterval(-5)
        let value = RideActivityPresentation(state: invalid, language: .english, now: now.addingTimeInterval(-10))
        XCTAssertNil(value.target)
    }
    func testElapsedCountdownDoesNotClaimTheVehicleHasArrived() {
        let value = RideActivityPresentation(state: state("due"), language: .traditionalChinese, now: now)
        XCTAssertTrue(value.due); XCTAssertNil(value.target); XCTAssertNil(value.minutes)
        XCTAssertEqual(value.status, "留意來車")
    }
    func testActivityKitDeadlineEndsTheTimerWithoutAPeriodicView() {
        var value = state("waiting")
        value.target = now.addingTimeInterval(45)
        XCTAssertEqual(value.updateDeadline, now.addingTimeInterval(45))
        let expired = RideActivityPresentation(state: value, language: .traditionalChinese, systemStale: true, now: now.addingTimeInterval(46))
        XCTAssertNil(expired.target)
        XCTAssertEqual(expired.status, "留意來車，點一下更新")
        value.target = now.addingTimeInterval(600)
        XCTAssertEqual(value.updateDeadline, now.addingTimeInterval(120))
    }
    func testOneStopUsesAlightingCueWhileTimeAndStopCountRemainAvailableWhenExpanded() {
        let value = RideActivityPresentation(state: state("alighting"), language: .traditionalChinese, now: now)
        XCTAssertTrue(value.alightingSoon)
        XCTAssertEqual(value.compactText, "下車")
        XCTAssertEqual(value.symbol, "arrow.down")
        XCTAssertNotNil(value.target)
        XCTAssertEqual(value.state.detail, AppText.remainingStops(1, language: .traditionalChinese))
    }
    func testMissingTimeDoesNotMeanArrivalAndProgressIsClamped() {
        var state = state(); state.target = nil; state.status = nil; state.stopsLeft = 15
        let value = RideActivityPresentation(state: state, language: .english, now: now)
        XCTAssertEqual(value.status, "Trip details"); XCTAssertFalse(value.due)
        XCTAssertEqual(value.progress, 0)
    }
    func testOldActivityPayloadStillDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state())) as? [String: Any])
        object.removeValue(forKey: "symbol"); object.removeValue(forKey: "freshUntil")
        for key in ["stepIdentifier", "rideIdentifier", "nextInstruction", "remainingMeters"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(RideActivityAttributes.ContentState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.symbol); XCTAssertNil(old.freshUntil)
        XCTAssertFalse(RideActivityPresentation(state: old, language: .english, now: now).stale)
        XCTAssertTrue(RideActivityPresentation(state: old, language: .english, now: now.addingTimeInterval(121)).stale)
    }
    func testMovementPhasesUseDifferentSymbolsAndTitles() {
        let cases = [("walking", "figure.walk", "步行前往"), ("cycling", "bicycle", "騎車前往"), ("transfer", "figure.walk", "轉乘")]
        for (scenario, symbol, title) in cases {
            let value = RideActivityPresentation(state: state(scenario), language: .traditionalChinese, now: now)
            XCTAssertEqual(value.symbol, symbol); XCTAssertEqual(value.phaseTitle, title)
            XCTAssertEqual(value.minutes, 4)
        }
    }
    func testRepeatedRefreshKeepsOneActivityAndEndRemovesIt() async {
        let store = FakeRideStore()
        let value = RideActivityController(store: store, now: { [now] in now })
        for _ in 0..<20 { value.update(state(), destination: "內湖", language: .traditionalChinese, enabled: true) }
        await value.waitForPendingChanges()
        XCTAssertEqual(store.created.count, 1); XCTAssertTrue(value.isRunning)
        value.endAll()
        XCTAssertFalse(value.isRunning, "Stopping must take effect before the asynchronous system call completes")
        await value.waitForPendingChanges()
        XCTAssertTrue(store.sessions.isEmpty)
    }
    func testDestinationAndLanguageReplaceInsteadOfLeavingTwoIslands() async {
        let store = FakeRideStore()
        let controller = RideActivityController(store: store, now: { [now] in now })
        controller.update(state(), destination: "內湖", language: .traditionalChinese, enabled: true)
        await controller.waitForPendingChanges()
        controller.update(state("walking"), destination: "公館", language: .english, enabled: true)
        await controller.waitForPendingChanges()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.created.last?.attributes.language, AppLanguage.english.rawValue)
        XCTAssertEqual(store.events, ["start:內湖", "end:內湖", "start:公館"])
    }
    func testSlowOldUpdateCannotResurrectAnEndedTripOrOverwriteNextTrip() async {
        let store = FakeRideStore()
        let controller = RideActivityController(store: store, now: { [now] in now })
        controller.update(state(), destination: "A", language: .traditionalChinese, enabled: true)
        await controller.waitForPendingChanges()
        let old = store.created[0]
        old.holdUpdate = true
        controller.update(state("alighting"), destination: "A", language: .traditionalChinese, enabled: true)
        for _ in 0..<30 { if old.updatePending != nil { break }; await Task.yield() }
        XCTAssertNotNil(old.updatePending)
        controller.endAll()
        controller.update(state("walking"), destination: "B", language: .english, enabled: true)
        old.updatePending?.resume(); old.updatePending = nil
        await controller.waitForPendingChanges()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.created.last?.attributes.destination, "B")
        XCTAssertEqual(store.created.last?.content.state.phase, .walking)
        XCTAssertEqual(old.activityState, .ended)
    }
    func testImmediateRestartToSameDestinationFinishesPreviousSession() async {
        let store = FakeRideStore()
        let value = RideActivityController(store: store, now: { [now] in now })
        value.update(state(), destination: "A", language: .english, enabled: true)
        await value.waitForPendingChanges()
        value.endAll()
        value.update(state("waiting"), destination: "A", language: .english, enabled: true)
        await value.waitForPendingChanges()
        XCTAssertEqual(store.created.count, 2)
        XCTAssertEqual(store.created[0].activityState, .ended)
        XCTAssertEqual(store.sessions.count, 1)
    }
    func testLateDismissalFromEndedActivityCannotDismissNewJourney() async {
        let store = FakeRideStore()
        let value = RideActivityController(store: store, now: { [now] in now })
        value.update(state(), destination: "A", language: .english, enabled: true)
        await value.waitForPendingChanges()
        let previous = store.created[0]
        value.endAll()
        value.update(state("walking"), destination: "B", language: .english, enabled: true)
        previous.dismiss()
        await value.waitForPendingChanges()
        XCTAssertTrue(value.isRunning)
        XCTAssertEqual(store.created.last?.attributes.destination, "B")
    }
    func testDismissalIsRespectedUntilUserRestarts() async {
        let store = FakeRideStore()
        let value = RideActivityController(store: store, now: { [now] in now })
        value.update(state(), destination: "A", language: .english, enabled: true)
        await value.waitForPendingChanges()
        store.created[0].dismiss()
        value.update(state("walking"), destination: "A", language: .english, enabled: true)
        await value.waitForPendingChanges()
        XCTAssertFalse(value.isRunning); XCTAssertEqual(store.created.count, 1)
        value.allowRestart()
        value.update(state("walking"), destination: "A", language: .english, enabled: true)
        await value.waitForPendingChanges()
        XCTAssertTrue(value.isRunning); XCTAssertEqual(store.created.count, 2)
    }
    func testRestoringExistingSessionRemovesDuplicateActivities() async throws {
        let store = FakeRideStore()
        let attributes = RideActivityAttributes(destination: "A", language: AppLanguage.english.rawValue)
        for _ in 0..<2 { _ = try store.start(attributes, content: ActivityContent(state: state(), staleDate: now.addingTimeInterval(120))) }
        let value = RideActivityController(store: store, now: { [now] in now })
        value.update(state("walking"), destination: "A", language: .english, enabled: true)
        await value.waitForPendingChanges()
        XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(store.created.count, 2)
        XCTAssertTrue(value.isRunning)
    }
    func testRevokingAndRestoringPermissionDoesNotRequireAChangedRoute() async {
        let store = FakeRideStore(), snapshot = state()
        let controller = RideActivityController(store: store, now: { [now] in now })
        store.allowed = false
        controller.update(snapshot, destination: "A", language: .english, enabled: true)
        await controller.waitForPendingChanges()
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(store.created.isEmpty)
        store.allowed = true
        controller.update(snapshot, destination: "A", language: .english, enabled: true)
        await controller.waitForPendingChanges()
        XCTAssertTrue(controller.isRunning)
        store.allowed = false
        controller.update(snapshot, destination: "A", language: .english, enabled: true)
        XCTAssertFalse(controller.isRunning)
        await controller.waitForPendingChanges()
        XCTAssertTrue(store.sessions.isEmpty)
        store.allowed = true
        controller.update(snapshot, destination: "A", language: .english, enabled: true)
        await controller.waitForPendingChanges()
        XCTAssertTrue(controller.isRunning)
        controller.update(nil, destination: "", language: .english, enabled: false)
        await controller.waitForPendingChanges()
        XCTAssertTrue(store.sessions.isEmpty)
    }
    func testCentralPresentationRetainsBothTimeAndStops() {
        let value = RideActivityPresentation(state: state(), language: .traditionalChinese, now: now)
        XCTAssertNotNil(value.target)
        XCTAssertEqual(value.secondaryMetric, AppText.stops(5, language: .traditionalChinese))
        XCTAssertEqual(value.metricCaption, "距離下車")
    }
    func testStepNoticeWaitsUntilTheAppIsInBackgroundAndOccursOnce() async {
        let store = FakeRideStore()
        let controller = RideActivityController(store: store, now: { [now] in now })
        controller.update(state("walking"), destination: "A", language: .english, enabled: true)
        await controller.waitForPendingChanges()
        XCTAssertTrue(store.created[0].notices.isEmpty)
        controller.update(state("walking"), destination: "A", language: .english, enabled: true, presentImportantUpdates: true)
        await controller.waitForPendingChanges()
        XCTAssertEqual(store.created[0].notices.count, 1)
        for seconds in [1.0, 15, 31, 61] {
            var updated = state("walking"); updated.updatedAt = now.addingTimeInterval(seconds)
            controller.update(updated, destination: "A", language: .english, enabled: true, presentImportantUpdates: true)
            await controller.waitForPendingChanges()
        }
        XCTAssertEqual(store.created[0].notices.count, 1, "Ordinary ETA ticks must not keep reopening the island")
        controller.update(state("walking"), destination: "A", language: .english, enabled: true)
        controller.update(state("walking"), destination: "A", language: .english, enabled: true, presentImportantUpdates: true)
        await controller.waitForPendingChanges()
        XCTAssertEqual(store.created[0].notices.count, 1, "Reopening the app is not a new journey step")
    }
    func testBoardingAndTransferGetDistinctQuietNotices() async {
        let store = FakeRideStore()
        var clock = now
        let value = RideActivityController(store: store, now: { clock })
        for (i, phase) in ["waiting", "riding", "transfer"].enumerated() {
            clock = now.addingTimeInterval(Double(i)*20)
            var current = state(phase); current.updatedAt = clock
            value.update(current, destination: "A", language: .english, enabled: true, presentImportantUpdates: true)
            await value.waitForPendingChanges()
        }
        XCTAssertEqual(store.created[0].notices.count, 3)
        XCTAssertTrue(store.created[0].notices.allSatisfy { $0.kind == .step })
    }
    func testStaleStateNeverOpensAnUrgentIsland() async {
        let store = FakeRideStore()
        let value = RideActivityController(store: store, now: { [now] in now })
        value.update(state("stale"), destination: "A", language: .english, enabled: true, presentImportantUpdates: true, alightingAlerts: true)
        await value.waitForPendingChanges()
        XCTAssertTrue(store.created[0].notices.isEmpty)
    }
    func testOldSourceTimeCannotCertifyItsOwnFreshness() async {
        let store = FakeRideStore()
        let wallClock = now.addingTimeInterval(181)
        let value = RideActivityController(store: store, now: { wallClock })
        value.update(state("waiting"), destination: "A", language: .english, enabled: true, presentImportantUpdates: true)
        await value.waitForPendingChanges()
        XCTAssertTrue(store.created[0].notices.isEmpty)
        XCTAssertEqual(store.created[0].content.relevanceScore, 0)
    }
    func testAlightingNoticeIsOnceAndHonorsTheReminderPreference() {
        var policy = RideIslandNoticePolicy(), current = state("riding")
        current.target = now.addingTimeInterval(100)
        XCTAssertEqual(policy.candidate(current, language: .english, alighting: false, now: now)?.kind, .step)
        let notice = policy.candidate(current, language: .english, alighting: true, now: now)!
        XCTAssertEqual(notice.kind, .alighting)
        policy.record(notice, state: current, at: now)
        XCTAssertNil(policy.candidate(current, language: .english, alighting: true, now: now.addingTimeInterval(5)))
    }
    func testRapidStepsAreCoalescedButAlightingCanInterruptTheQuietCooldown() {
        var policy = RideIslandNoticePolicy()
        let first = state("walking")
        policy.record(policy.candidate(first, language: .english, alighting: true, now: now)!, state: first, at: now)
        var riding = state("riding")
        XCTAssertNil(policy.candidate(riding, language: .english, alighting: true, now: now.addingTimeInterval(5)))
        XCTAssertNotNil(policy.candidate(riding, language: .english, alighting: true, now: now.addingTimeInterval(13)))
        riding.target = now.addingTimeInterval(80)
        XCTAssertEqual(policy.candidate(riding, language: .english, alighting: true, now: now.addingTimeInterval(5))?.kind, .alighting)
    }
    func testAlreadyDeliveredLocalReminderDoesNotCauseADuplicateIslandAlert() async {
        let store = FakeRideStore()
        let value = RideActivityController(store: store, now: { [now] in now })
        value.canPresentNotice = { notice, _ in notice.kind != .alighting }
        var close = state("riding"); close.target = now.addingTimeInterval(80)
        value.update(close, destination: "A", language: .english, enabled: true, presentImportantUpdates: true, alightingAlerts: true)
        await value.waitForPendingChanges()
        XCTAssertTrue(store.created[0].notices.isEmpty)
        close.updatedAt = now.addingTimeInterval(31)
        value.update(close, destination: "A", language: .english, enabled: true, presentImportantUpdates: true, alightingAlerts: true)
        await value.waitForPendingChanges()
        XCTAssertTrue(store.created[0].notices.isEmpty)
    }
    func testEndingAndStartingTheSameDestinationAllowsTheNewTripIntroduction() async {
        let store = FakeRideStore()
        let value = RideActivityController(store: store, now: { [now] in now })
        value.update(state("walking"), destination: "A", language: .english, enabled: true, presentImportantUpdates: true)
        await value.waitForPendingChanges()
        value.endAll()
        value.update(state("walking"), destination: "A", language: .english, enabled: true, presentImportantUpdates: true)
        await value.waitForPendingChanges()
        XCTAssertEqual(store.created.count, 2)
        XCTAssertEqual(store.created[1].notices.count, 1)
    }
    func testQuietStepSoundIsIncludedAndActuallySilent() throws {
        let file = try XCTUnwrap(Bundle.main.url(forResource: "NavigationQuiet", withExtension: "wav"))
        let data = try Data(contentsOf: file)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertTrue(data.dropFirst(44).allSatisfy { $0 == 0 })
    }
    func testLocalReminderOwnershipKeepsSafetyFallbackAndAvoidsDuplicates() {
        let value = AlightReminder(); value.auditPermission(.allowed)
        defer { value.reset() }
        value.update(rideID: "A", stopName: "下車", secondsToAlight: 180, now: now)
        XCTAssertTrue(value.canPresentInActivity(rideID: "A", now: now))
        value.presentedInActivity(rideID: "A")
        XCTAssertFalse(value.canPresentInActivity(rideID: "A", now: now))
        value.update(rideID: "B", stopName: "下車", secondsToAlight: 80, now: now)
        XCTAssertFalse(value.canPresentInActivity(rideID: "B", now: now))
    }

}

@MainActor private final class FakeRideStore: RideActivityStore {
    var allowed = true
    var created: [FakeRideSession] = []
    var events: [String] = []
    var sessions: [any RideActivitySession] { created.filter { $0.activityState == .active || $0.activityState == .stale } }
    func start(_ attributes: RideActivityAttributes, content: ActivityContent<RideActivityAttributes.ContentState>) throws -> any RideActivitySession {
        let value = FakeRideSession(attributes: attributes, content: content)
        value.didEnd = { [weak self] in self?.events.append("end:" + attributes.destination) }
        created.append(value); events.append("start:" + attributes.destination)
        return value
    }
}
@MainActor private final class FakeRideSession: RideActivitySession {
    let id = UUID().uuidString
    let attributes: RideActivityAttributes
    var activityState = ActivityState.active
    var content: ActivityContent<RideActivityAttributes.ContentState>
    var notices: [RideIslandNotice] = []
    var holdUpdate = false
    var updatePending: CheckedContinuation<Void, Never>?
    var didEnd: (() -> Void)?
    var observer: (@MainActor (ActivityState) -> Void)?
    init(attributes: RideActivityAttributes, content: ActivityContent<RideActivityAttributes.ContentState>) {
        self.attributes = attributes; self.content = content
    }
    func update(_ content: ActivityContent<RideActivityAttributes.ContentState>, notice: RideIslandNotice?) async {
        if holdUpdate { await withCheckedContinuation { updatePending = $0 } }
        self.content = content
        if let notice { notices.append(notice) }
    }
    func end() async { activityState = .ended; didEnd?(); observer?(.ended) }
    func dismiss() { activityState = .dismissed; observer?(.dismissed) }
    func observe(_ change: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never> {
        observer = change
        return Task {}
    }
}
