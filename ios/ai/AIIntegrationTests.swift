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
    private let now = ISO8601DateFormatter().date(from: "2026-10-22T04:00:00Z")!  // 12:00 Taipei
    private func place(_ name: String, _ latitude: Double = 25.04) -> TravelPlace {
        TravelPlace(name: name, address: "臺北市中正區", coordinate: Coordinate(latitude: latitude, longitude: 121.52))
    }
    private func saved(_ title: String, _ symbol: String, _ destination: TravelPlace, _ preference: RoutePreference = .balanced) -> SavedJourney {
        SavedJourney(id: UUID(), title: title, symbol: symbol, origin: nil, destination: destination, preference: preference, updatedAt: Date())
    }
    private func reading(_ destination: String, _ kind: JourneyReading.Kind = .place, origin: String = "",
                         originKind: JourneyReading.Kind = .none) -> JourneyReading {
        JourneyReading(destination: destination, destinationKind: kind, origin: origin, originKind: originKind)
    }

    func testOrdinaryPlaceUsesCurrentLocationAndAsksNothing() async throws {
        // 現在去台北車站: on a phone the old design asked whether to start from 公司 or 家.
        var searched: [String] = []
        let context = JourneyAssistantContext(journeys: []) { query in
            searched.append(query); return [self.place("臺北車站"), self.place("台北車站 M8 出口", 25.05)]
        }
        let turn = try await context.resolve(reading("台北車站"), source: "現在去台北車站", now: now)
        XCTAssertNil(turn.clarification)
        XCTAssertEqual(searched, ["台北車站"])
        XCTAssertEqual(turn.request.destination, "臺北車站", "The best search result is used right away")
        XCTAssertEqual(turn.request.review, AssistantFieldReview(destination: .certain, origin: .certain, preference: .certain, time: .certain))
        XCTAssertEqual(turn.request.origin, "")
        XCTAssertEqual(turn.destinationCandidates.first?.name, "臺北車站", "The exact match is offered first")
        XCTAssertNil(turn.request.arriveBy)
        XCTAssertEqual(turn.request.timeDescription, "")
    }
    func testWorkWithoutASavedJourneyIsNeverSearchedOnTheMap() async throws {
        // Choosing 公司 once searched the map for 公司 and picked an unrelated company in 三重.
        var searched: [String] = []
        let context = JourneyAssistantContext(journeys: []) { query in searched.append(query); return [self.place("堅詠股份有限公司")] }
        for kind in [JourneyReading.Kind.work, .place, .saved] {
            let turn = try await context.resolve(reading("台北車站", origin: "公司", originKind: kind), source: "從公司到台北車站", now: now)
            XCTAssertEqual(turn.request.origin, "公司")
            XCTAssertEqual(turn.request.review.origin, .needsConfirmation)
            XCTAssertTrue(turn.originCandidates.isEmpty)
        }
        XCTAssertFalse(searched.contains("公司"))
    }
    func testMislabelledKindsStillPlan() async throws {
        // On a phone every request ended with no place search: the model labelled ordinary places
        // and an unstated start as home/work/saved.
        var searched: [String] = []
        let context = JourneyAssistantContext(journeys: []) { query in searched.append(query); return [self.place("國立臺灣大學")] }
        for kind in [JourneyReading.Kind.home, .work, .school, .saved] {
            let turn = try await context.resolve(reading("國立臺灣大學", kind, origin: "", originKind: kind),
                                                 source: "騎單車去台大", now: now)
            XCTAssertEqual(turn.destinationCandidates.first?.name, "國立臺灣大學", kind.rawValue)
            XCTAssertEqual(turn.request.origin, "", "An unstated start is the current location")
            XCTAssertEqual(turn.request.review.origin, .certain)
        }
        XCTAssertEqual(searched.count, 4)
    }
    func testHomeUsesTheSavedJourneyAndItsPreferenceUnlessTheUserAsksForAnother() async throws {
        let home = place("古亭站")
        let context = JourneyAssistantContext(journeys: [saved("家", "house.fill", home, .lessWalking)]) { _ in
            XCTFail("A saved journey is not searched"); return []
        }
        let turn = try await context.resolve(reading("家", .home), source: "回家", now: now)
        XCTAssertEqual(turn.request.destination, "古亭站")
        XCTAssertEqual(turn.request.preference, .lessWalking)
        XCTAssertEqual(turn.destinationCandidates.map(\.id), [home.id])
        XCTAssertEqual(turn.request.review.destination, .certain)
        var faster = reading("家", .home); faster.preference = .faster
        let asked = try await context.resolve(faster, source: "回家，快一點", now: now)
        XCTAssertEqual(asked.request.preference, .faster)
        XCTAssertTrue(context.toolCalls.allSatisfy { $0.hasPrefix("listSavedJourneys") })
    }
    func testGoingHomeFindsTheHomeJourneyAmongFifty() async throws {
        var library = (0..<50).map { saved("行程\($0)", "mappin", place("地點\($0)")) }
        let home = place("古亭站")
        library[37] = saved("回家", "house.fill", home, .lessWalking)
        let context = JourneyAssistantContext(journeys: library) { _ in [] }
        for text in ["回家", "家", "家裡"] {
            let turn = try await context.resolve(reading(text, .home), source: text, now: now)
            XCTAssertEqual(turn.destinationCandidates.map(\.id), [home.id], text)
            XCTAssertNil(turn.clarification)
        }
    }
    func testTwoHomesAskWhichOneAndTheAnswerNeedsNoModel() async throws {
        let first = place("測試住家（古亭）"), second = place("測試住家（板橋）", 25.01)
        let context = JourneyAssistantContext(journeys: [saved("家", "house.fill", first), saved("另一個家", "house.fill", second)]) { _ in [] }
        let turn = try await context.resolve(reading("家", .home), source: "回家", now: now)
        let question = try XCTUnwrap(turn.clarification)
        XCTAssertTrue(question.options[0].contains("古亭"))
        XCTAssertEqual(question.options.count, 2)
        XCTAssertEqual(turn.request.review.destination, .needsConfirmation)
        let next = try await context.answer(option: 1)
        XCTAssertNil(next.clarification)
        XCTAssertEqual(next.request.destination, "測試住家（板橋）")
        XCTAssertEqual(next.request.review.destination, .certain)
    }
    func testSeveralResultsPlanWithTheBestOneWithoutAsking() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("中山站"), self.place("中山國中", 25.06)] }
        let turn = try await context.resolve(reading("中山"), source: "到中山", now: now)
        XCTAssertNil(turn.clarification)
        XCTAssertEqual(turn.request.destination, "中山站")
        XCTAssertEqual(turn.destinationCandidates.map(\.name), ["中山站", "中山國中"])
    }
    func testUnstatedOrUnplannableTimesMeanLeavingNow() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("國立臺灣大學")] }
        // 騎單車去台大 once showed "2026-10-23 -1:-1" as a deadline needing confirmation.
        var dayOnly = reading("國立臺灣大學"); dayOnly.arrivalDay = "2026-10-23"
        var departure = reading("國立臺灣大學"); departure.departureTime = true; departure.timeEvidence = "明天九點"
        departure.arrivalDay = "2026-10-23"; departure.arrivalHour = 9
        for value in [dayOnly, departure] {
            let turn = try await context.resolve(value, source: "騎單車去台大", now: now)
            XCTAssertNil(turn.request.arriveBy)
            XCTAssertEqual(turn.request.timeDescription, "")
            XCTAssertEqual(turn.request.review.time, .certain)
            XCTAssertNil(turn.clarification)
        }
    }
    func testDeadlineAlreadyPassedTodayMeansTomorrow() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("臺北車站")] }
        var value = reading("台北車站"); value.timeEvidence = "九點以前"; value.arrivalHour = 9
        let turn = try await context.resolve(value, source: "到北車，九點以前", now: now)
        XCTAssertNil(turn.clarification)
        XCTAssertEqual(turn.request.arriveBy, ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z"))
    }
    func testOnlyWhatTheSentenceSaysIsKept() async throws {
        // 「回家」 alone came back from the model as cycling with an arrival deadline.
        let home = place("古亭站")
        let context = JourneyAssistantContext(journeys: [saved("家", "house.fill", home)]) { _ in [] }
        var invented = reading("家", .home); invented.travelMode = .cycling
        invented.timeEvidence = "九點前"; invented.arrivalHour = 9
        let turn = try await context.resolve(invented, source: "回家", now: now)
        XCTAssertEqual(turn.mode, .any)
        XCTAssertNil(turn.request.arriveBy)
        XCTAssertEqual(turn.request.timeDescription, "")
        var said = reading("家", .home); said.travelMode = .cycling; said.timeEvidence = "九點前"; said.arrivalHour = 9
        let kept = try await context.resolve(said, source: "九點前騎單車回家", now: now)
        XCTAssertEqual(kept.mode, .cycling)
        XCTAssertNotNil(kept.request.arriveBy)
        var walk = reading("家", .home); walk.travelMode = .walking
        let walking = try await context.resolve(walk, source: "走路回家", now: now)
        XCTAssertEqual(walking.mode, .walking)
    }
    func testCyclingRequestReachesThePlanner() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("國立臺灣大學")] }
        var value = reading("國立臺灣大學"); value.travelMode = .cycling
        let turn = try await context.resolve(value, source: "騎單車去台大", now: now)
        XCTAssertEqual(turn.mode, .cycling)
        XCTAssertEqual(turn.request.preference, .balanced, "A way of travelling is not a route preference")
    }
    func testArrivalDeadlineAndConflictingPreference() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("臺大醫院")] }
        var value = reading("台大醫院"); value.timeEvidence = "明天九點前"; value.arrivalDay = "2026-10-23"; value.arrivalHour = 9
        value.preference = nil
        let turn = try await context.resolve(value, source: "明天九點前到臺大醫院，快一點但完全不要走路", now: now)
        XCTAssertEqual(turn.request.arriveBy, ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z"))
        XCTAssertEqual(turn.request.review.time, .certain)
        XCTAssertEqual(turn.request.review.preference, .needsConfirmation)
        XCTAssertEqual(turn.request.review.destination, .certain)
    }
    func testSearchFailureLeavesTheKeywordEditable() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in throw URLError(.notConnectedToInternet) }
        let turn = try await context.resolve(reading("台大"), source: "去台大", now: now)
        XCTAssertEqual(turn.request.destination, "台大")
        XCTAssertEqual(turn.request.review.destination, .needsConfirmation)
        XCTAssertTrue(turn.destinationCandidates.isEmpty)
        do { _ = try await context.answer(option: 0); XCTFail("Nothing was asked") } catch {}
    }
    func testCancellationStopsResolution() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in
            try await Task.sleep(for: .seconds(5))
            return []
        }
        let task = Task { try await context.resolve(self.reading("北車"), source: "去北車", now: self.now) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
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
}
