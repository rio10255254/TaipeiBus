import XCTest
@testable import TransitCore

final class AssistantSafetyTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-22T04:00:00Z")!
    func testLiteralParametersAndTaipeiArrivalDate() throws {
        let draft = AssistantIntentDraft(destination: "台大醫院", preference: .lessWalking,
            preferenceEvidence: "不想走太多路", timeEvidence: "明天 9 點前", arrivalDay: "2026-10-23", arrivalHour: 9, arrivalMinute: 0)
        let value = try draft.validated(source: "明天 9 點前到台大醫院，不想走太多路", now: now)
        XCTAssertEqual(value.preference, .lessWalking)
        XCTAssertEqual(value.arriveBy, ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z"))
        XCTAssertEqual(value.destination, "台大醫院")
    }
    func testInventedPlacesPreferencesAndTimesAreRejected() throws {
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "台北車站").validated(source: "去台大醫院", now: now))
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "台大醫院", origin: "西門").validated(source: "去台大醫院", now: now))
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "台大醫院", preference: .faster).validated(source: "去台大醫院", now: now))
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "台大醫院", arrivalDay: "2026-10-23", arrivalHour: 9, arrivalMinute: 0).validated(source: "去台大醫院", now: now))
        XCTAssertNil(try AssistantIntentDraft(destination: "台大醫院").validated(source: "去台大醫院", now: now).arriveBy)
    }
    func testInvalidRolledOverPastAndAmbiguousDatesAreRejected() {
        for (day, hour, minute) in [("2026-02-30", 9, 0), ("2026-10-23", 24, 0), ("2026-10-23", 9, 60), ("2026-10-21", 9, 0), ("2028-10-23", 9, 0)] {
            XCTAssertThrowsError(try AssistantIntentDraft(destination: "醫院", timeEvidence: "早上", arrivalDay: day, arrivalHour: hour, arrivalMinute: minute).validated(source: "早上去醫院", now: now))
        }
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "醫院", needsClarification: true).validated(source: "早點去醫院", now: now))
    }
    func testExplicitTimeCannotBeSilentlyDroppedOrMovedToAnotherDay() {
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "台大醫院").validated(source: "明天 9 點前到台大醫院", now: now))
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "醫院", timeEvidence: "明天 9 點", arrivalDay: "2026-10-24",
            arrivalHour: 9, arrivalMinute: 0).validated(source: "明天 9 點到醫院", now: now))
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "醫院", timeEvidence: "明天", arrivalDay: "2026-10-23",
            arrivalHour: 9, arrivalMinute: 0).validated(source: "明天或後天去醫院", now: now))
    }
    func testPlateMatchesOnlyNearbyFreshCandidatesWithoutGuessing() {
        let candidates = [
            PlateCandidate(id: "near", plate: "ABC-1234", observedAt: now, distance: 25),
            PlateCandidate(id: "far", plate: "ABC-1234", observedAt: now, distance: 301),
            PlateCandidate(id: "stale", plate: "ABC-1234", observedAt: now.addingTimeInterval(-91), distance: 10),
            PlateCandidate(id: "future", plate: "ABC-1234", observedAt: now.addingTimeInterval(16), distance: 10)
        ]
        XCTAssertEqual(PlateRecognition.matches(text: ["車牌 ＡＢＣ－１２３４"], candidates: candidates, at: now).map(\.id), ["near"])
        XCTAssertEqual(PlateRecognition.matches(text: ["ABC 1234"], candidates: candidates, at: now).count, 1)
        XCTAssertTrue(PlateRecognition.matches(text: ["XABC-1234Y", "ABC-I234"], candidates: candidates, at: now).isEmpty)
        XCTAssertTrue(PlateRecognition.matches(text: ["ABC-1234"], candidates: [PlateCandidate(id: "unknown", plate: "ABC-1234", observedAt: now, distance: .nan)], at: now).isEmpty)
    }
    func testDuplicatePlateIdentitiesRemainAmbiguous() {
        let candidates = ["one", "two"].map { PlateCandidate(id: $0, plate: "ABC-1234", observedAt: now, distance: 10) }
        XCTAssertEqual(PlateRecognition.matches(text: ["ABC1234"], candidates: candidates, at: now).count, 2)
    }
    func testCommuteNeedsThreeDistinctDaysAndOnlyExistingSavedJourneys() {
        let id = UUID(), deleted = UUID()
        var history = CommutePatterns()
        for offset in [3, 2, 1] { history.record(journeyID: id, at: now.addingTimeInterval(Double(-offset) * 86_400)) }
        XCTAssertEqual(history.suggestions(available: [id], at: now), [id])
        XCTAssertTrue(history.suggestions(available: [deleted], at: now).isEmpty)
        XCTAssertTrue(history.suggestions(available: [id], at: now.addingTimeInterval(7200)).isEmpty)
        XCTAssertTrue(history.suggestions(available: [id], at: now.addingTimeInterval(43 * 86_400)).isEmpty)
        var repeats = CommutePatterns()
        for minute in 0..<3 { repeats.record(journeyID: id, at: now.addingTimeInterval(Double(minute) * 60)) }
        XCTAssertEqual(repeats.events.count, 1)
        XCTAssertTrue(repeats.suggestions(available: [id], at: now.addingTimeInterval(600)).isEmpty)
    }
    func testCommuteHistoryIsBoundedAndRejectsFutureEvents() {
        let id = UUID()
        var history = CommutePatterns(events: (0..<300).map { CommutePatterns.Event(journeyID: id, startedAt: now.addingTimeInterval(Double(-$0) * 3600)) })
        XCTAssertEqual(history.events.count, 240)
        history.prune(at: now, keeping: [])
        XCTAssertTrue(history.events.isEmpty)
        let future = CommutePatterns(events: [CommutePatterns.Event(journeyID: id, startedAt: now.addingTimeInterval(3600))])
        XCTAssertTrue(future.suggestions(available: [id], at: now).isEmpty)
    }
}
