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
    func testPlaceToolShortensLongAddresses() async throws {
        let long = TravelPlace(name: "臺北車站", address: "臺北市中正區北平西路三號一樓至地下三樓（台鐵、高鐵、捷運共構）",
                               coordinate: Coordinate(latitude: 25.047, longitude: 121.517))
        let context = JourneyAssistantContext(journeys: []) { _ in [long] }
        let text = try await context.search("北車")
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: String]])
        XCTAssertEqual(rows.first?["address"], String(long.address.prefix(20)))
        // The full place, not the shortened text, is what the review screen receives.
        XCTAssertEqual(context.place(id: try XCTUnwrap(rows.first?["id"]))?.address, long.address)
    }
    func testSavedJourneyToolPreservesDistinctEndpointsAndPreferences() throws {
        let home = TravelPlace(name: "家", address: "測試地址", coordinate: Coordinate(latitude: 25.03, longitude: 121.53))
        let work = TravelPlace(name: "公司", address: "測試地址", coordinate: Coordinate(latitude: 25.04, longitude: 121.54))
        let saved = SavedJourney(id: UUID(), title: "上班", symbol: "briefcase.fill", origin: home,
                                 destination: work, preference: .faster, updatedAt: Date())
        let context = JourneyAssistantContext(journeys: [saved]) { _ in [] }
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try context.savedJourneys(matching: "上班").utf8)) as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        let from = try XCTUnwrap(row["origin"] as? [String: String])
        let to = try XCTUnwrap(row["destination"] as? [String: String])
        XCTAssertEqual(context.place(id: try XCTUnwrap(from["id"]))?.id, home.id)
        XCTAssertEqual(context.place(id: try XCTUnwrap(to["id"]))?.id, work.id)
        XCTAssertEqual(Set(from.keys), ["id", "name"], "Saved endpoints carry no address")
        XCTAssertEqual(row["preference"] as? String, "faster")
        XCTAssertEqual(context.toolCalls, ["listSavedJourneys: 上班"])
    }
    func testGoingHomeFindsTheHomeJourneyAmongFiftyWithinAFewHundredCharacters() throws {
        func place(_ index: Int) -> TravelPlace {
            TravelPlace(name: "地點\(index)", address: "臺北市信義區市府路\(index)號很長很長的地址說明文字",
                        coordinate: Coordinate(latitude: 25.03 + Double(index) / 10_000, longitude: 121.53))
        }
        var library = (0..<50).map { index in
            SavedJourney(id: UUID(), title: "行程\(index)", symbol: "mappin", origin: place(index),
                         destination: place(index + 100), preference: .balanced, updatedAt: Date())
        }
        let home = TravelPlace(name: "古亭站", address: "臺北市中正區", coordinate: Coordinate(latitude: 25.026, longitude: 121.522))
        library[37] = SavedJourney(id: UUID(), title: "回家", symbol: "house.fill", origin: nil,
                                   destination: home, preference: .lessWalking, updatedAt: Date())
        for query in ["回家", "家", "home"] {
            let context = JourneyAssistantContext(journeys: library) { _ in [] }
            let text = try context.savedJourneys(matching: query)
            XCTAssertLessThan(text.utf8.count, 600, "\(query): \(text)")
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
            XCTAssertLessThanOrEqual(rows.count, 3)
            let first = try XCTUnwrap(rows.first)
            XCTAssertEqual(first["title"] as? String, "回家")
            XCTAssertEqual(first["preference"] as? String, "lessWalking")
            let to = try XCTUnwrap(first["destination"] as? [String: String])
            XCTAssertEqual(context.place(id: try XCTUnwrap(to["id"]))?.id, home.id)
            XCTAssertFalse(text.contains("市府路"), "Addresses never enter the model context")
        }
        let unfiltered = JourneyAssistantContext(journeys: library) { _ in [] }
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try unfiltered.savedJourneys(matching: "").utf8)) as? [Any])
        XCTAssertEqual(all.count, 3)
    }
    func testSavedJourneyToolStopsTheModelFromAskingAgain() throws {
        // On a phone, an empty "[]" reply made the model call listSavedJourneys 30-40 times until the
        // request timed out. A miss now says so plainly, and the tool answers at most twice.
        let context = JourneyAssistantContext(journeys: []) { _ in [] }
        let miss = try context.savedJourneys(matching: "台大")
        XCTAssertTrue(miss.contains("no saved journey") && miss.contains("searchPlaces"), miss)
        _ = try context.savedJourneys(matching: "台灣大學")
        for _ in 0..<5 { XCTAssertEqual(try context.savedJourneys(matching: "臺大"), JourneyAssistantContext.savedExhausted) }
        XCTAssertEqual(context.toolCalls.count, JourneyAssistantContext.savedLimit)
        context.resetSearchBudget()
        XCTAssertNotEqual(try context.savedJourneys(matching: "台大"), JourneyAssistantContext.savedExhausted)
    }
    func testEmptyPlaceSearchSaysSoInsteadOfAnEmptyList() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in [] }
        let reply = try await context.search("不存在的地方")
        XCTAssertTrue(reply.hasPrefix("No Taipei place matches"), reply)
        for _ in 0..<3 { _ = try await context.search("台大") }
        let exhausted = try await context.search("台大")
        XCTAssertEqual(exhausted, JourneyAssistantContext.searchExhausted)
    }
    func testContextOverflowRetriesOnceWithAFreshSessionThenFallsBack() async throws {
        struct Overflow: Error {}
        var attempts: [Bool] = [], restarts = 0
        let value = try await ContextWindowRetry.run(isOverflow: { $0 is Overflow }, fresh: { restarts += 1 }) { retried in
            attempts.append(retried)
            if !retried { throw Overflow() }
            return "ok"
        }
        XCTAssertEqual(value, "ok"); XCTAssertEqual(attempts, [false, true]); XCTAssertEqual(restarts, 1)
        attempts = []
        do {
            _ = try await ContextWindowRetry.run(isOverflow: { $0 is Overflow }, fresh: { restarts += 1 }) { retried -> String in
                attempts.append(retried); throw Overflow()
            }
            XCTFail("A second overflow must reach the manual fallback")
        } catch is Overflow {}
        XCTAssertEqual(attempts, [false, true]); XCTAssertEqual(restarts, 2)
        attempts = []
        do {
            _ = try await ContextWindowRetry.run(isOverflow: { $0 is Overflow }, fresh: { restarts += 1 }) { retried -> String in
                attempts.append(retried); throw URLError(.timedOut)
            }
            XCTFail("Other failures are not retried")
        } catch is URLError {}
        XCTAssertEqual(attempts, [false]); XCTAssertEqual(restarts, 2)
    }
    func testSearchFailureAndBudgetLeaveManualReviewAvailable() async throws {
        var calls = 0
        let context = JourneyAssistantContext(journeys: []) { _ in
            calls += 1
            throw URLError(.notConnectedToInternet)
        }
        for _ in 0..<10 { _ = try await context.search("台北車站") }
        XCTAssertEqual(calls, JourneyAssistantContext.searchLimit)
        XCTAssertEqual(calls, 3)
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
