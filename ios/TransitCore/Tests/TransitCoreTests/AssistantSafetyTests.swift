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
    func testNormalizedPlacesAndColloquialPreferenceReachReview() throws {
        let certain = AssistantFieldReview(destination: .certain, origin: .certain, preference: .certain, time: .certain)
        let value = try AssistantIntentDraft(destination: "臺北車站", origin: "公司已存地點", preference: .faster,
            review: certain).validated(source: "從公司到北車，快一點", now: now)
        XCTAssertEqual(value.destination, "臺北車站")
        XCTAssertEqual(value.origin, "公司已存地點")
        XCTAssertEqual(value.preference, .faster)
        XCTAssertEqual(value.review, certain)
    }
    func testAmbiguityPreservesEveryUsableFieldInsteadOfRejectingSentence() throws {
        let review = AssistantFieldReview(destination: .needsConfirmation, origin: .certain, preference: .certain, time: .certain)
        let value = try AssistantIntentDraft(destination: "台大", origin: "西門站", preference: .lessWalking,
            needsClarification: true, review: review).validated(source: "從西門到台大，少走路", now: now)
        XCTAssertEqual(value.destination, "台大")
        XCTAssertEqual(value.origin, "西門站")
        XCTAssertEqual(value.preference, .lessWalking)
        XCTAssertEqual(value.review, review)
    }
    func testInvalidDatesRemainEditableAndCannotEnterPlannerAsDates() throws {
        for (day, hour, minute) in [("2026-02-30", 9, 0), ("2026-10-23", 24, 0), ("2026-10-23", 9, 60),
                                  ("2026-10-21", 9, 0), ("2028-10-23", 9, 0), ("not-a-date", 9, 0), ("2026-x-10-23", 9, 0)] {
            let value = try AssistantIntentDraft(destination: "醫院", timeEvidence: "早上", arrivalDay: day,
                arrivalHour: hour, arrivalMinute: minute,
                review: .init(time: .certain)).validated(source: "早上去醫院", now: now)
            XCTAssertNil(value.arriveBy)
            XCTAssertEqual(value.review.time, .needsConfirmation)
            XCTAssertEqual(value.timeDescription, "早上")
            XCTAssertEqual(value.destination, "醫院")
        }
    }
    func testMissingTimeAndDestinationAreReviewedWithoutKeywordRejection() throws {
        let value = try AssistantIntentDraft(destination: "", timeEvidence: "明天 9 點前", needsClarification: true)
            .validated(source: "明天 9 點前要到那邊", now: now)
        XCTAssertEqual(value.review.destination, .needsConfirmation)
        XCTAssertEqual(value.review.time, .needsConfirmation)
        XCTAssertNil(value.arriveBy)
        // A time-like substring is not a parser or a reason to reject a place.
        XCTAssertNoThrow(try AssistantIntentDraft(destination: "今天書屋").validated(source: "去今天書屋", now: now))
    }
    func testInputLimitsAndFinalDeadlineGuard() {
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "").validated(source: "  ", now: now))
        XCTAssertThrowsError(try AssistantIntentDraft(destination: "").validated(source: String(repeating: "字", count: 601), now: now))
        XCTAssertFalse(AssistantJourneyRequest.canPlan(arriveBy: now, now: now))
        XCTAssertTrue(AssistantJourneyRequest.canPlan(arriveBy: now.addingTimeInterval(90 * 86_400), now: now))
        XCTAssertFalse(AssistantJourneyRequest.canPlan(arriveBy: now.addingTimeInterval(90 * 86_400 + 1), now: now))
    }
    func testChoiceQuestionHasTwoOrThreeDistinctOptions() {
        XCTAssertNil(AssistantClarification(question: "", options: ["甲", "乙"]))
        XCTAssertNil(AssistantClarification(question: "去哪裡？", options: ["甲", " 甲 ", ""]))
        let question = AssistantClarification(question: "去哪裡？", options: ["甲", "乙", "丙", "丁"])
        XCTAssertEqual(question?.options, ["甲", "乙", "丙"])
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
