import XCTest
import StoreKitTest
@testable import TransitCore
@testable import TaipeiBus

@MainActor final class NavigationLifecycleTests: XCTestCase {
    private var session: SKTestSession!
    private var models: [TransitAppModel] = []
    override func setUpWithError() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ProProducts", withExtension: "storekit"))
        session = try SKTestSession(contentsOf: file)
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        session.storefront = "TWN"; session.locale = Locale(identifier: "zh_TW"); session.timeRate = .realTime
    }
    override func tearDownWithError() throws {
        models.forEach { $0.finishJourney() }; models = []
        session.clearTransactions(); session = nil
    }
    private func point(_ meters: Double) -> Coordinate { Coordinate(latitude: 25.04, longitude: 121.55 + meters / 100_750) }
    private func model(mode: TransportMode = .bus, rideActivity: RideActivityController? = nil) -> TransitAppModel {
        var metadata = TransitMetadata()
        var route = BusRoute(id: "route", parentID: "family", name: "284", variantName: "", departure: "起點", destination: "終點")
        route.mode = mode
        metadata.routes[route.id] = route
        let stops = (0...5).map { BusStop(id: "s\($0)", routeID: "family", stationID: "station\($0)", name: "站\($0)", direction: "0", sequence: $0, coordinate: point(Double($0)*400)) }
        metadata.lines["sub:route"] = RouteLine(coordinates: stops.map(\.coordinate))
        for stop in stops { metadata.stops[stop.id] = stop; metadata.paths[route.id, default: []].append(StopReference(stopID: stop.id, sequence: stop.sequence)) }
        metadata.rebuildJourneys()
        let ride = TransitRide(route: route, direction: "0", stops: stops, coordinates: stops.map(\.coordinate))
        let trip = TransitTrip(rides: [ride], accessDistance: 100, egressDistance: 0, transferDistance: 0, score: 0, rideSeconds: [600])
        let option = JourneyOption(id: trip.id, trip: trip, walks: [
            WalkingLeg(from: point(-100), to: point(0), coordinates: [point(-100), point(0)], distance: 100, duration: 90),
            WalkingLeg(from: point(2_000), to: point(2_000), distance: 0, duration: 0)
        ])
        let model = TransitAppModel(rideActivity: rideActivity); models.append(model)
        model.rideActivityOn = false; model.alightReminderOn = true
        let now = Date()
        model.auditNavigation(metadata: metadata, snapshot: TransitSnapshot(sourceUpdatedAt: now,
            estimates: EstimateFeed(seconds: ["family:s0":900], updatedAt: now)), at: now)
        model.planner.auditLoadChoices([option], from: TravelPlace(name: "起點", address: "", coordinate: point(-100)), to: TravelPlace(name: "終點", address: "", coordinate: point(2_000)))
        model.location.auditLocation(LocationSample(coordinate: point(-100), accuracy: 5, timestamp: now))
        model.alightReminder.auditPermission(.allowed); model.synchronizeNavigationState()
        return model
    }
    private func unlock(_ model: TransitAppModel) async {
        await model.purchases.loadProducts(); await model.purchases.purchase(.monthly)
        XCTAssertTrue(model.purchases.hasPro)
    }
    func testPreviewAndItsBackLinkNeverStartBackgroundNavigation() async {
        let value = model(); await unlock(value)
        value.open(URL(string: "taipeibus://journey")!)
        XCTAssertFalse(value.planner.started); XCTAssertFalse(value.location.backgroundNavigation)
        XCTAssertFalse(value.resumeJourneyRequested)
    }
    func testBeginAndFinishSynchronizeWithoutWaitingForAFeed() async {
        let value = model(); await unlock(value)
        value.planner.begin()
        XCTAssertTrue(value.planner.started)
        XCTAssertTrue(value.location.backgroundNavigation, "Background location must be configured before begin returns")
        value.location.setActive(false)
        XCTAssertTrue(value.location.backgroundNavigation, "A foreground departure keeps an already started trip")
        value.finishJourney()
        XCTAssertFalse(value.location.backgroundNavigation, "End is not delayed until the next network refresh")
        XCTAssertFalse(value.planner.started)
    }
    func testPreferenceAndNotificationRevocationStopBackgroundWithoutLosingTheTrip() async {
        let value = model(); await unlock(value); value.planner.begin()
        let selected = value.planner.selectedID
        value.alightReminderOn = false
        XCTAssertFalse(value.location.backgroundNavigation)
        value.alightReminderOn = true
        XCTAssertTrue(value.location.backgroundNavigation)
        value.alightReminder.auditPermission(.denied)
        XCTAssertEqual(value.alightReminderState, .needsPermission)
        XCTAssertFalse(value.alightReminderActive); XCTAssertFalse(value.location.backgroundNavigation)
        XCTAssertTrue(value.planner.started); XCTAssertEqual(value.planner.selectedID, selected)
        value.alightReminder.auditPermission(.allowed)
        XCTAssertTrue(value.location.backgroundNavigation)
    }
    func testEndCannotBeUndoneByAnEntitlementRefreshCompletingLater() async {
        let value = model(); await unlock(value); value.planner.begin()
        let refresh = Task { await value.purchases.refreshAccess() }
        value.finishJourney()
        XCTAssertFalse(value.location.backgroundNavigation)
        await refresh.value
        XCTAssertFalse(value.location.backgroundNavigation); XCTAssertFalse(value.planner.started)
    }
    func testEndingTheRealPlannerAndLeavingDoesNotRestoreItsBlockedActivity() async {
        let store = FakeRideStore()
        // Use the same controller as the app, with only the system adapter delayed.
        let controller = RideActivityController(store: store)
        let value = model(rideActivity: controller)
        await unlock(value)
        value.rideActivityOn = true; value.planner.begin()
        await controller.waitForPendingChanges()
        guard let old = store.created.first else { return XCTFail("The started planner must create its native activity") }
        old.holdUpdate = true
        value.boardCurrentRide()
        for _ in 0..<100 {
            if old.updatePending != nil { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(old.updatePending)
        let refresh = Task { await value.purchases.refreshAccess() }
        value.finishJourney()
        value.synchronizeNavigationState()
        for _ in 0..<100 {
            if old.endCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let endedWithoutOldUpdate = old.endCount
        old.updatePending?.resume(); old.updatePending = nil
        await refresh.value; await controller.waitForPendingChanges()
        value.open(URL(string: "taipeibus://journey")!)
        value.updateLiveSurfaces()
        await controller.waitForPendingChanges()
        XCTAssertEqual(endedWithoutOldUpdate, 1)
        XCTAssertFalse(value.planner.started)
        XCTAssertFalse(value.location.backgroundNavigation)
        XCTAssertFalse(value.liveActivityRunning)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.created.count, 1, "A late permission refresh or old island link must not begin another trip")
    }
    private func startedWithActivity() async throws -> (TransitAppModel, FakeRideStore, RideActivityController) {
        let store = FakeRideStore()
        let controller = RideActivityController(store: store)
        let value = model(rideActivity: controller)
        await unlock(value)
        value.rideActivityOn = true; value.planner.begin()
        await controller.waitForPendingChanges()
        XCTAssertTrue(value.liveActivityRunning)
        return (value, store, controller)
    }
    func testVisibleLiveActivityKeepsBackgroundLocationWithoutTheIndicator() async throws {
        UserDefaults.standard.removeObject(forKey: LocationService.activityBackedFailedKey)
        let (value, store, controller) = try await startedWithActivity()
        let session = try XCTUnwrap(store.created.first)
        XCTAssertTrue(value.location.backgroundNavigation, "Background updates still keep the island current")
        XCTAssertTrue(value.location.activityBacked)
        XCTAssertFalse(value.location.backgroundIndicator,
            "A second island item would move the trip from the central compact island to the detached circle")
        session.dismiss()
        XCTAssertTrue(value.location.backgroundNavigation, "The alighting reminder still needs background location")
        XCTAssertFalse(value.location.activityBacked)
        XCTAssertTrue(value.location.backgroundIndicator, "Without a visible activity, the indicator keeps the app in use")
        value.finishJourney()
        await controller.waitForPendingChanges()
        XCTAssertFalse(value.location.backgroundNavigation); XCTAssertFalse(value.location.backgroundIndicator)
        XCTAssertFalse(value.location.activityBacked)
        XCTAssertTrue(store.sessions.isEmpty)
    }
    func testSilentBackgroundFallsBackToTheIndicatorForThisAndLaterTrips() async throws {
        UserDefaults.standard.removeObject(forKey: LocationService.activityBackedFailedKey)
        defer { UserDefaults.standard.removeObject(forKey: LocationService.activityBackedFailedKey) }
        let (value, _, controller) = try await startedWithActivity()
        XCTAssertTrue(value.location.activityBacked)
        value.location.setActive(false)
        // A short visit away is not evidence: the rider may simply be standing at the stop.
        value.location.checkActivityBackedDelivery(now: Date().addingTimeInterval(60))
        XCTAssertTrue(value.location.activityBacked)
        value.location.setActive(false)
        value.location.checkActivityBackedDelivery(now: Date().addingTimeInterval(200))
        XCTAssertFalse(value.location.activityBacked)
        XCTAssertTrue(value.location.backgroundNavigation); XCTAssertTrue(value.location.backgroundIndicator)
        value.finishJourney(); await controller.waitForPendingChanges()
        let (next, _, _) = try await startedWithActivity()
        XCTAssertFalse(next.location.activityBacked, "A phone that did not deliver updates keeps using the indicator")
        XCTAssertTrue(next.location.backgroundIndicator)
    }
    func testRevokedProStopsPaidBackgroundWorkAndKeepsFreeNavigation() async throws {
        let value = model(); await unlock(value); value.planner.begin()
        let selected = value.planner.selectedID
        let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ProPlan.monthly.productID })
        try session.refundTransaction(identifier: transaction.identifier)
        for _ in 0..<60 {
            await value.purchases.refreshAccess()
            if !value.purchases.hasPro { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(value.purchases.hasPro); XCTAssertFalse(value.location.backgroundNavigation)
        XCTAssertTrue(value.planner.started); XCTAssertEqual(value.planner.selectedID, selected)
    }
    func testLiveActivityLinkResumesTheCurrentStepWithoutChangingTheSelectedRide() async {
        let value = model(); await unlock(value); value.planner.begin(); value.boardCurrentRide()
        let step = value.planner.currentStep, selected = value.planner.selectedID
        value.showingProPlans = true
        value.open(URL(string: "taipeibus://journey")!)
        XCTAssertTrue(value.resumeJourneyRequested); XCTAssertFalse(value.showingProPlans)
        XCTAssertEqual(value.planner.currentStep, step); XCTAssertEqual(value.planner.selectedID, selected)
    }
    func testBusDelayIsNotReportedInMetroOrStandaloneWalkingContexts() {
        let value = model(mode: .metro)
        XCTAssertFalse(value.visibleBusDataNeeds.positions); XCTAssertFalse(value.visibleBusDataNeeds.arrivals)
        value.finishJourney()
        XCTAssertTrue(value.visibleBusDataNeeds.positions)
        XCTAssertFalse(value.visibleBusDataNeeds.arrivals, "Browsing the fleet does not require the arrivals feed")
    }
}
