import XCTest
@testable import TransitCore

final class NavigationReadinessTests: XCTestCase {
    func testAnEnabledPreferenceDoesNotReplaceNotificationPermission() {
        var state = NavigationReadiness(hasPro: true, checkingPro: false, notifications: .notDetermined)
        XCTAssertEqual(state.reminder(enabled: true), .needsPermission)
        state.notifications = .denied
        XCTAssertEqual(state.reminder(enabled: true), .needsPermission)
        state.notifications = .allowed
        XCTAssertEqual(state.reminder(enabled: true), .ready)
        XCTAssertEqual(state.reminder(enabled: false), .disabled)
    }
    func testAnUnresolvedInitialPurchaseIsNotShownAsReadyOrAsAConfirmedFreeAccount() {
        var state = NavigationReadiness()
        XCTAssertEqual(state.reminder(enabled: true), .checking)
        state.checkingPro = false
        XCTAssertEqual(state.reminder(enabled: true), .requiresPro)
        state.hasPro = true; state.notifications = .checking
        XCTAssertEqual(state.reminder(enabled: true), .checking)
    }
    func testLocalReminderCanBeReadyWithoutGPSButContinuousBackgroundCannot() {
        let state = NavigationReadiness(hasPro: true, checkingPro: false, notifications: .allowed, location: .denied)
        XCTAssertEqual(state.reminder(enabled: true), .ready)
        XCTAssertFalse(state.canRunInBackground(started: true, arrived: false, reminderEnabled: true,
                                                activityEnabled: false, activityRunning: false))
    }
    func testPreviewArrivalAndEndedTripsCannotUseContinuousBackgroundLocation() {
        let state = NavigationReadiness(hasPro: true, checkingPro: false, notifications: .allowed, location: .allowed)
        XCTAssertFalse(state.canRunInBackground(started: false, arrived: false, reminderEnabled: true, activityEnabled: true, activityRunning: true))
        XCTAssertFalse(state.canRunInBackground(started: true, arrived: true, reminderEnabled: true, activityEnabled: true, activityRunning: true))
        XCTAssertTrue(state.canRunInBackground(started: true, arrived: false, reminderEnabled: true, activityEnabled: false, activityRunning: false))
    }
    func testInactiveOrDeniedLiveActivityCannotKeepTheAppRunningByPreferenceAlone() {
        var state = NavigationReadiness(hasPro: true, checkingPro: false, notifications: .denied, location: .allowed)
        XCTAssertFalse(state.canRunInBackground(started: true, arrived: false, reminderEnabled: true, activityEnabled: true, activityRunning: false))
        XCTAssertTrue(state.canRunInBackground(started: true, arrived: false, reminderEnabled: false, activityEnabled: true, activityRunning: true))
        state.liveActivitiesAllowed = false
        XCTAssertEqual(state.liveActivity(enabled: true), .needsPermission)
        XCTAssertFalse(state.canRunInBackground(started: true, arrived: false, reminderEnabled: false, activityEnabled: true, activityRunning: true))
    }
    func testAUserDisabledFeatureOrRevokedAccessStopsItsBackgroundWork() {
        var state = NavigationReadiness(hasPro: true, checkingPro: true, notifications: .allowed, location: .allowed)
        XCTAssertTrue(state.canRunInBackground(started: true, arrived: false, reminderEnabled: true, activityEnabled: false, activityRunning: false), "A pending refresh retains verified access")
        XCTAssertFalse(state.canRunInBackground(started: true, arrived: false, reminderEnabled: false, activityEnabled: false, activityRunning: false))
        state.hasPro = false; state.checkingPro = false
        XCTAssertFalse(state.canRunInBackground(started: true, arrived: false, reminderEnabled: true, activityEnabled: true, activityRunning: true))
    }
    func testADeviceRefusalDoesNotMasqueradeAsAnActiveLiveActivity() {
        let state = NavigationReadiness(hasPro: true, checkingPro: false)
        XCTAssertEqual(state.liveActivity(enabled: true, failed: true), .unavailable)
        XCTAssertEqual(state.liveActivity(enabled: false, failed: true), .disabled)
        XCTAssertEqual(state.liveActivity(enabled: true, failed: false), .ready)
    }
    func testDelayedGPSDoesNotDiscreditFreshOfficialArrivals() throws {
        let now = Date(), old = now.addingTimeInterval(-180)
        let snapshot = TransitSnapshot(sourceUpdatedAt: old, estimates: EstimateFeed(updatedAt: now))
        let status = try XCTUnwrap(BusDataStatus.evaluate(snapshot, positions: true, arrivals: true, at: now))
        XCTAssertEqual(status.source, .positions); XCTAssertEqual(status.state, .delayed)
        XCTAssertEqual(status.updatedAt, old)
        XCTAssertNil(BusDataStatus.evaluate(snapshot, positions: false, arrivals: true, at: now))
    }
    func testDelayedArrivalsDoNotDiscreditFreshBusPositions() throws {
        let now = Date(), old = now.addingTimeInterval(-240)
        let snapshot = TransitSnapshot(sourceUpdatedAt: now, estimates: EstimateFeed(updatedAt: old))
        let status = try XCTUnwrap(BusDataStatus.evaluate(snapshot, positions: true, arrivals: true, at: now))
        XCTAssertEqual(status.source, .arrivals); XCTAssertEqual(status.updatedAt, old)
        XCTAssertNil(BusDataStatus.evaluate(snapshot, positions: true, arrivals: false, at: now))
    }
    func testUnrelatedBusFailuresAreSilentInAnUnrelatedContext() {
        let snapshot = TransitSnapshot(vehicleError: "network", estimates: EstimateFeed(error: "network"))
        XCTAssertNil(BusDataStatus.evaluate(snapshot, positions: false, arrivals: false, at: Date()))
    }
    func testInitialLoadIsDistinctFromRetainedDelayedData() throws {
        let now = Date()
        let waiting = try XCTUnwrap(BusDataStatus.evaluate(TransitSnapshot(), positions: true, arrivals: true, at: now))
        XCTAssertEqual(waiting.state, .updating); XCTAssertEqual(waiting.source, .both)
        let delayed = try XCTUnwrap(BusDataStatus.evaluate(TransitSnapshot(vehicleError: "offline"), positions: true, arrivals: false, at: now))
        XCTAssertEqual(delayed.state, .delayed)
    }
}
