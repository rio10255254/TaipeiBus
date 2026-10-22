import XCTest
import TransitCore
@testable import TaipeiBus

@MainActor final class AIIntegrationTests: XCTestCase {
    func testHistoryIsOptInAndDisablingRemovesPersistedData() throws {
        let suite = "ai-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), store = CommuteHabitStore(defaults: defaults)
        XCTAssertFalse(store.enabled)
        store.record(id, available: [id])
        XCTAssertTrue(store.history.events.isEmpty)
        store.enabled = true
        store.record(id, available: [id])
        XCTAssertEqual(CommuteHabitStore(defaults: defaults).history.events.count, 1)
        store.enabled = false
        XCTAssertNil(defaults.data(forKey: "commuteSuggestions.history.v1"))
        XCTAssertTrue(CommuteHabitStore(defaults: defaults).history.events.isEmpty)
    }
    func testDeletedJourneysAndExpiredHistoryArePrunedFromDisk() throws {
        let suite = "ai-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), store = CommuteHabitStore(defaults: defaults)
        store.enabled = true; store.record(id, available: [id])
        store.prune(available: [])
        XCTAssertTrue(CommuteHabitStore(defaults: defaults).history.events.isEmpty)
        store.record(id, available: [id], at: Date().addingTimeInterval(-43 * 86_400))
        XCTAssertTrue(CommuteHabitStore(defaults: defaults).history.events.isEmpty)
    }
    func testAssistantPreferenceMappingPreservesPlannerMeaning() {
        for value in AssistantIntentDraft.Preference.allCases {
            XCTAssertNotNil(RoutePreference(rawValue: value.rawValue))
        }
        let base = LiveSettings.Planning()
        XCTAssertGreaterThan(RoutePreference.lessWalking.applying(to: base).walkingWeight, base.walkingWeight)
        XCTAssertGreaterThan(RoutePreference.fewerTransfers.applying(to: base).effectiveTransferPenaltySeconds, base.effectiveTransferPenaltySeconds)
    }
}

@MainActor final class JourneyAssistantToolTests: XCTestCase {
    func testPlaceToolReturnsOnlyThreeRealNamesAddressesAndOpaqueIDs() async throws {
        let values = (0..<5).map { index in
            TravelPlace(name: "地點\(index)", address: "地址\(index)", coordinate: Coordinate(latitude: 25.03, longitude: 121.53))
        }
        let context = JourneyAssistantContext(journeys: []) { _ in values }
        let data = Data(try await context.search("北車").utf8)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertEqual(Set(row.keys), ["id", "name", "address"])
            let place = try XCTUnwrap(context.place(id: try XCTUnwrap(row["id"])))
            XCTAssertEqual(place.name, row["name"])
            XCTAssertEqual(place.address, row["address"])
        }
        XCTAssertNil(context.place(id: "invented-place"))
    }
    func testSavedJourneyToolPreservesDistinctEndpointsAndPreferences() throws {
        let home = TravelPlace(name: "家", address: "測試地址", coordinate: Coordinate(latitude: 25.03, longitude: 121.53))
        let work = TravelPlace(name: "公司", address: "測試地址", coordinate: Coordinate(latitude: 25.04, longitude: 121.54))
        let saved = SavedJourney(id: UUID(), title: "上班", symbol: "briefcase.fill", origin: home,
                                 destination: work, preference: .faster, updatedAt: Date())
        let context = JourneyAssistantContext(journeys: [saved]) { _ in [] }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try context.savedJourneys().utf8)) as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        let from = try XCTUnwrap(row["origin"] as? [String: String])
        let to = try XCTUnwrap(row["destination"] as? [String: String])
        XCTAssertEqual(context.place(id: try XCTUnwrap(from["id"]))?.id, home.id)
        XCTAssertEqual(context.place(id: try XCTUnwrap(to["id"]))?.id, work.id)
        XCTAssertEqual(row["preference"] as? String, "faster")
        XCTAssertEqual(context.toolCalls, ["listSavedJourneys"])
    }
    func testSearchFailureAndBudgetLeaveManualReviewAvailable() async throws {
        var calls = 0
        let context = JourneyAssistantContext(journeys: []) { _ in
            calls += 1
            throw URLError(.notConnectedToInternet)
        }
        for _ in 0..<10 { _ = try await context.search("台北車站") }
        XCTAssertEqual(calls, 8)
        XCTAssertNil(context.place(id: "place-1"))
    }
    func testCancellationDoesNotRegisterStaleToolEvidence() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in
            try await Task.sleep(for: .seconds(5))
            return []
        }
        let task = Task { try await context.search("北車") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
