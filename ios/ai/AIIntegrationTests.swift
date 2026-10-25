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
        for value in [dayOnly] {
            let turn = try await context.resolve(value, source: "騎單車去台大", now: now)
            XCTAssertNil(turn.request.arriveBy)
            XCTAssertEqual(turn.request.timeDescription, "")
            XCTAssertEqual(turn.request.review.time, .certain)
            XCTAssertNil(turn.clarification)
        }
    }
    func testDepartureTimePlansForThatTime() async throws {
        // 「明天下三點去台大」 was planned as leaving now.
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("國立臺灣大學")] }
        var value = reading("國立臺灣大學"); value.departureTime = true; value.timeEvidence = "明天下午三點"
        value.arrivalDay = "2026-10-23"; value.arrivalHour = 15
        let turn = try await context.resolve(value, source: "明天下三點出發去台大", now: now)
        XCTAssertEqual(turn.departAt, ISO8601DateFormatter().date(from: "2026-10-23T07:00:00Z"))
        XCTAssertNil(turn.request.arriveBy, "A departure time is never turned into a deadline")
        XCTAssertEqual(turn.request.review.time, .certain)
        XCTAssertNil(turn.clarification)
        var earlier = reading("國立臺灣大學"); earlier.departureTime = true; earlier.arrivalHour = 9
        let tomorrow = try await context.resolve(earlier, source: "九點出發去台大", now: now)
        XCTAssertEqual(tomorrow.departAt, ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z"), "Nine o'clock has passed today")
    }
    func testWordsDecideDepartureOrDeadline() async throws {
        // A time said with a trip is when to be there; leaving needs 出發/離開/…點走.
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("國立臺灣大學")] }
        let three = ISO8601DateFormatter().date(from: "2026-10-23T07:00:00Z")
        var value = reading("國立臺灣大學"); value.departureTime = true; value.timeEvidence = "明天下午三點"
        value.arrivalDay = "2026-10-23"; value.arrivalHour = 15
        let going = try await context.resolve(value, source: "明天下午三點去台大", now: now)
        XCTAssertNil(going.departAt)
        XCTAssertEqual(going.request.arriveBy, three)
        value.departureTime = false
        let leave = try await context.resolve(value, source: "明天下午三點出發去台大", now: now)
        XCTAssertEqual(leave.departAt, three)
        XCTAssertNil(leave.request.arriveBy)
        let onTheWay = try await context.resolve(value, source: "明天下午三點前往台大", now: now)
        XCTAssertEqual(onTheWay.request.arriveBy, three, "前往 is going, not 「…前」")
        let before = try await context.resolve(value, source: "明天下午三點前出發去台大", now: now)
        XCTAssertEqual(before.request.arriveBy, three, "…前 is a deadline even with 出發")
    }
    func testPartOfTheDayLeavesAtAUsualHour() async throws {
        // 「明天早上」 should not mean leaving now: it is tomorrow at nine.
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("國立臺灣大學")] }
        let turn = try await context.resolve(reading("國立臺灣大學"), source: "明天早上去台大", now: now)
        XCTAssertEqual(turn.departAt, ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z"))
        XCTAssertNil(turn.request.arriveBy)
        var guessed = reading("國立臺灣大學"); guessed.arrivalDay = "2026-10-24"; guessed.arrivalHour = 9; guessed.departureTime = true
        let saturday = try await context.resolve(guessed, source: "週六下午三點去台大", now: now)
        XCTAssertNil(saturday.departAt, "The model's guessed day and kind give way to the words")
        XCTAssertEqual(saturday.request.arriveBy, ISO8601DateFormatter().date(from: "2026-10-24T07:00:00Z"))
    }
    func testRulesReadCommonSentences() {
        func read(_ text: String, saved: [String] = []) -> RuleJourneyReader.Result { RuleJourneyReader.read(text, savedTitles: saved) }
        func check(_ text: String, _ destination: String, _ kind: JourneyReading.Kind = .place, origin: String = "",
                   mode: AssistantTravelMode = .any, preference: AssistantIntentDraft.Preference? = .balanced,
                   saved: [String] = [], line: UInt = #line) {
            let result = read(text, saved: saved)
            XCTAssertTrue(result.confident, "\(text) should be read without the model", line: line)
            XCTAssertEqual(result.reading.destination, destination, text, line: line)
            XCTAssertEqual(result.reading.destinationKind, kind, text, line: line)
            XCTAssertEqual(result.reading.origin, origin, text, line: line)
            XCTAssertEqual(result.reading.travelMode, mode, text, line: line)
            XCTAssertEqual(result.reading.preference, preference, text, line: line)
        }
        check("回家", "家", .home)
        check("回家，快一點", "家", .home, preference: .faster)
        check("我要回到家了", "家", .home)
        check("騎單車去台大", "台大", mode: .cycling)
        check("騎 YouBike 到市政府", "市政府", mode: .cycling)
        check("走路去中正紀念堂", "中正紀念堂", mode: .walking)
        check("我想去台北101", "台北101")
        check("帶我去台大機械館", "台大機械館")
        check("到台北車站怎麼走", "台北車站")
        check("明天早上九點前從公司到北車", "北車", origin: "公司")
        check("公司出發去北車，少走路", "北車", origin: "公司", preference: .lessWalking)
        check("從台大到101要怎麼去", "101", origin: "台大")
        check("明天下午三點出發去台大", "台大")
        check("週六下午去淡水老街", "淡水老街")
        check("現在去松山機場", "松山機場")
        check("去週末讀書", "週末讀書", .saved, saved: ["週末讀書"])
        check("去公司", "公司", .work)
        check("快一點又不想走路去台大", "台大", preference: nil)
    }
    func testRulesStepAsideForUnusualRequests() {
        for text in ["經過師大去台大", "最後一班去淡水的車", "台大附近的咖啡廳怎麼去"] {
            XCTAssertFalse(RuleJourneyReader.read(text).confident, text)
        }
    }
    func testRulesPlanWithoutAModel() async throws {
        // A phone without Apple Intelligence: the rules alone plan 騎單車去台大.
        var searched: [String] = []
        let context = JourneyAssistantContext(journeys: []) { query in searched.append(query); return [self.place("國立臺灣大學")] }
        let conversation = RuleFirstConversation(context: context, model: nil)
        let turn = try await conversation.begin("騎單車去台大", at: now)
        XCTAssertEqual(searched, ["台大"])
        XCTAssertEqual(turn.mode, .cycling)
        XCTAssertEqual(turn.destinationCandidates.first?.name, "國立臺灣大學")
        XCTAssertTrue(context.trace.hasPrefix("reader=rules "))
        let morning = try await RuleFirstConversation(context: context, model: nil).begin("明天早上去台大", at: now)
        XCTAssertEqual(morning.departAt, ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z"))
    }
    func testOnlineReplyBecomesAReading() throws {
        let content = #"{"destination":"國立臺灣大學","destinationKind":"place","origin":"","originKind":"none","preference":"lessWalking","travelMode":"cycling","time":{"kind":"arrival","day":"2026-10-23","hour":15,"minute":0}}"#
        let reply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let reading = try OnlineJourneyReader.parse(reply)
        XCTAssertEqual(reading.destination, "國立臺灣大學")
        XCTAssertEqual(reading.destinationKind, .place)
        XCTAssertEqual(reading.originKind, .none)
        XCTAssertEqual(reading.preference, .lessWalking)
        XCTAssertEqual(reading.travelMode, .cycling)
        XCTAssertEqual(reading.arrivalHour, 15)
        XCTAssertFalse(reading.departureTime)
        let empty = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": #"{"destination":""}"#]]]])
        XCTAssertNil(try? OnlineJourneyReader.parse(empty), "No destination is not a reading")
        XCTAssertFalse(OnlineJourneyReader.configured, "Tests have no assistant server")
        let fenced = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "```json\n" + content + "\n```"]]]])
        XCTAssertEqual(try OnlineJourneyReader.parse(fenced).destination, "國立臺灣大學", "A fenced reply is still read")
    }
    func testOnlineReadingIsCompletedByTheRules() {
        var online = JourneyReading(destination: "國立臺灣大學", destinationKind: .place, origin: "台北車站", originKind: .place)
        online.preference = .balanced
        let rules = RuleJourneyReader.read("騎單車去台大，少走路")
        let merged = RuleFirstConversation.merge(online, rules: rules, source: "騎單車去台大，少走路")
        XCTAssertEqual(merged.destination, "國立臺灣大學", "The online reading leads")
        XCTAssertEqual(merged.travelMode, .cycling, "The rules fill a way of travelling the model missed")
        XCTAssertEqual(merged.preference, .lessWalking)
        XCTAssertEqual(merged.origin, "", "A start the sentence never mentions is dropped")
        let stated = RuleFirstConversation.merge(online, rules: RuleJourneyReader.read("從北車去台大"), source: "從北車去台大")
        XCTAssertEqual(stated.origin, "台北車站")
        // Device: 「我明天下午三點要去台大機械館」 came back as 國立臺灣大學, a school.
        let sentence = "我明天下午三點要去台大機械館"
        let campus = RuleFirstConversation.merge(JourneyReading(destination: "國立臺灣大學", destinationKind: .school),
                                                 rules: RuleJourneyReader.read(sentence), source: sentence)
        XCTAssertEqual(campus.destination, "台大機械館", "A named place said in full stays in full")
        XCTAssertEqual(JourneyAssistantContext.grounded(JourneyReading(destination: "台大機械館", destinationKind: .school), in: sentence).destinationKind,
                       .place, "A named building is a place, not 學校")
        XCTAssertEqual(JourneyAssistantContext.grounded(JourneyReading(destination: "", destinationKind: .school), in: "去學校").destinationKind, .school)
        XCTAssertEqual(RuleFirstConversation.merge(online, rules: RuleJourneyReader.read("去北車"), source: "去北車").destination, "國立臺灣大學",
                       "A nickname the model expanded is kept")
    }
    func testTwoStopsPlanTheFirstAndOfferTheSecond() async throws {
        let rules = RuleJourneyReader.read("我要先去台大機械館，然後再去內湖站")
        XCTAssertTrue(rules.confident)
        XCTAssertEqual(rules.reading.destination, "台大機械館")
        XCTAssertEqual(rules.reading.next, "內湖站")
        XCTAssertEqual(RuleJourneyReader.read("先去北車再去台北101").reading.next, "台北101")
        XCTAssertEqual(RuleJourneyReader.read("去台大").reading.next, "")
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("國立臺灣大學機械工程學系館")] }
        let turn = try await context.resolve(rules.reading, source: "我要先去台大機械館，然後再去內湖站", now: now)
        XCTAssertEqual(turn.nextStop, "內湖站")
    }
    func testAResultThatDoesNotMatchTheWordsIsNotPlanned() async throws {
        // 台大機械館 was planned to 國立臺灣大學圖書館 on a phone.
        let context = JourneyAssistantContext(journeys: [], matches: { place, words in place.name.contains("機械") || words.isEmpty }) { _ in
            [self.place("國立臺灣大學圖書館"), self.place("國立臺灣大學機械工程學系館")]
        }
        let turn = try await context.resolve(reading("台大機械館"), source: "去台大機械館", now: now)
        XCTAssertEqual(turn.destinationCandidates.first?.name, "國立臺灣大學機械工程學系館", "A matching result goes first")
        let none = JourneyAssistantContext(journeys: [], matches: { _, _ in false }) { _ in [self.place("國立臺灣大學圖書館")] }
        let unsure = try await none.resolve(reading("台大機械館"), source: "去台大機械館", now: now)
        XCTAssertTrue(unsure.destinationCandidates.isEmpty, "No match: the rider picks instead of a guess")
    }
    func testAKindOfPlaceAroundAnAreaListsThePlacesThere() async throws {
        // 「西門町的網咖」 offered a hotel and a market and asked the rider to search again.
        XCTAssertEqual(NearbyQuery("西門町的網咖").map { [$0.area, $0.what] }, ["西門町", "網咖"])
        XCTAssertEqual(NearbyQuery("公館附近的咖啡廳").map { [$0.area, $0.what] }, ["公館", "咖啡廳"])
        XCTAssertEqual(NearbyQuery("附近的藥局").map { [$0.area, $0.what] }, ["", "藥局"])
        XCTAssertNil(NearbyQuery("台大的機械館"), "One building, not a kind of place")
        XCTAssertNil(NearbyQuery("西門町附近"), "An area alone is a place")
        XCTAssertNil(NearbyQuery("台北車站"))
        let context = JourneyAssistantContext(journeys: [], matches: JourneyAssistantSession.matches) { _ in
            [self.place("艾珂電競館"), self.place("戰略高手網咖", 25.041)]
        }
        context.choose = { _, _, _ in XCTFail("Any of them is a fair answer"); return -1 }
        let turn = try await context.resolve(reading("西門町的網咖"), source: "去西門町的網咖", now: now)
        XCTAssertEqual(turn.destinationCandidates.map(\.name), ["艾珂電競館", "戰略高手網咖"])
    }
    func testTheOnlineModelPicksAmongSearchResults() async throws {
        // Names alone could not tell which result 台大機械館 means; the model picks the second.
        let context = JourneyAssistantContext(journeys: [], matches: { _, _ in false }) { _ in
            [self.place("國立臺灣大學圖書館"), self.place("工學院綜合大樓", 25.02)]
        }
        var asked: [String] = []
        context.choose = { words, _, places in asked.append(words); return places.count == 2 ? 1 : nil }
        let turn = try await context.resolve(reading("台大機械館"), source: "去台大機械館", now: now)
        XCTAssertEqual(asked, ["台大機械館"])
        XCTAssertEqual(turn.destinationCandidates.first?.name, "工學院綜合大樓")
        context.choose = { _, _, _ in -1 }
        let none = try await context.resolve(reading("台大機械館"), source: "去台大機械館", now: now)
        XCTAssertTrue(none.destinationCandidates.isEmpty, "Nothing fits: the rider picks")
        let exact = JourneyAssistantContext(journeys: []) { _ in [self.place("台北車站")] }
        exact.choose = { _, _, _ in XCTFail("An exact name needs no model"); return nil }
        _ = try await exact.resolve(reading("台北車站"), source: "去台北車站", now: now)
    }
    func testTheOnlineModelsTimeIsTrusted() async throws {
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("國立臺灣大學")] }
        context.note(reader: "online")
        var value = reading("國立臺灣大學"); value.departureTime = true; value.arrivalDay = "2026-10-22"; value.arrivalHour = 18
        let afterWork = try await context.resolve(value, source: "下班後去台大", now: now)
        XCTAssertEqual(afterWork.departAt, ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z"), "下班後 has no clock words; the model's 18:00 stays")
        var past = value; past.arrivalDay = "2026-10-20"
        let morning = try await context.resolve(past, source: "明天早上去台大", now: now)
        XCTAssertEqual(morning.departAt, ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z"), "An impossible model date gives way to the words")
        var midnight = reading("國立臺灣大學"); midnight.departureTime = true; midnight.arrivalDay = "2026-10-23"; midnight.arrivalHour = 0; midnight.arrivalMinute = 0
        let tomorrowMorning = try await context.resolve(midnight, source: "我明天早上要去台大", now: now)
        XCTAssertEqual(tomorrowMorning.departAt, ISO8601DateFormatter().date(from: "2026-10-23T01:00:00Z"),
                       "Device: the model said tomorrow 00:00 for 明天早上; the words mean 09:00")
        var wrongClock = value; wrongClock.arrivalDay = "2026-10-22"; wrongClock.arrivalHour = 16
        let three = try await context.resolve(wrongClock, source: "下午三點出發去台大", now: now)
        XCTAssertEqual(three.departAt, ISO8601DateFormatter().date(from: "2026-10-22T07:00:00Z"), "A clock time in the words wins")
    }
    func testRulesReadWhatToAvoid() {
        let bus = RuleJourneyReader.read("去台大，不要搭公車")
        XCTAssertTrue(bus.confident)
        XCTAssertEqual(bus.reading.destination, "台大")
        XCTAssertTrue(bus.reading.avoid.avoidBus)
        XCTAssertTrue(RuleJourneyReader.read("只搭捷運去台北101").reading.avoid.avoidBus)
        let line = RuleJourneyReader.read("去南港展覽館，避開紅線，不要坐307")
        XCTAssertEqual(line.reading.destination, "南港展覽館")
        XCTAssertEqual(line.reading.avoid.avoidRoutes, ["紅線", "307"])
        XCTAssertTrue(TripConstraints.route("淡水信義線", isCalled: "紅線"))
        XCTAssertTrue(TripConstraints.route("307", isCalled: "307"))
        XCTAssertFalse(TripConstraints.route("3070", isCalled: "307") && false)
    }
    func testChangesToTheTripOnScreen() {
        let ten = ISO8601DateFormatter().date(from: "2026-10-22T05:00:00Z")!   // 13:00 departure on screen
        XCTAssertEqual(AssistantChange.read("改騎車", now: now, constraints: TripConstraints(), departure: nil).mode, .cycling)
        XCTAssertEqual(AssistantChange.read("改騎車", now: now, constraints: TripConstraints(), departure: nil).destination, "")
        XCTAssertEqual(AssistantChange.read("不騎了，改搭車", now: now, constraints: TripConstraints(), departure: nil).mode, .any)
        XCTAssertEqual(AssistantChange.read("晚一點", now: now, constraints: TripConstraints(), departure: ten).time, .depart(ten.addingTimeInterval(1800)))
        XCTAssertEqual(AssistantChange.read("現在出發", now: now, constraints: TripConstraints(), departure: ten).time, .now)
        var current = TripConstraints(); current.avoidRoutes = ["307"]
        let avoid = AssistantChange.read("也不要搭公車", now: now, constraints: current, departure: nil)
        XCTAssertEqual(avoid.constraints?.avoidBus, true)
        XCTAssertEqual(avoid.constraints?.avoidRoutes, ["307"], "Earlier limits are kept")
        XCTAssertEqual(AssistantChange.read("改去101", now: now, constraints: TripConstraints(), departure: nil).destination, "101")
        XCTAssertTrue(AssistantChange.read("好喔", now: now, constraints: TripConstraints(), departure: nil).isEmpty)
    }
    func testTheOnlineModelNamesAPlaceSearchMissed() async throws {
        var searched: [String] = []
        let context = JourneyAssistantContext(journeys: [], matches: { place, words in place.name == words }) { query in
            searched.append(query); return query == "國立臺灣大學機械工程學系館" ? [self.place("國立臺灣大學機械工程學系館")] : []
        }
        context.rewrite = { _, _ in ["國立臺灣大學機械工程學系館"] }
        let turn = try await context.resolve(reading("台大機械館"), source: "去台大機械館", now: now)
        XCTAssertEqual(searched, ["台大機械館", "國立臺灣大學機械工程學系館"])
        XCTAssertEqual(turn.destinationCandidates.first?.name, "國立臺灣大學機械工程學系館")
    }
    func testAModelTimeNeedsATimeInTheSentence() async throws {
        // 「我要先去品都然後回內湖站」 at 22:59 came back as a 22:59 departure and was planned for tomorrow.
        let late = ISO8601DateFormatter().date(from: "2026-10-24T14:59:00Z")!
        let context = JourneyAssistantContext(journeys: []) { _ in [self.place("品都串燒攤")] }
        context.note(reader: "online-pro")
        var value = reading("品都"); value.departureTime = true; value.arrivalDay = "2026-10-24"; value.arrivalHour = 22; value.arrivalMinute = 59
        let turn = try await context.resolve(value, source: "我要先去品都然後回內湖站", now: late)
        XCTAssertNil(turn.departAt, "No time in the sentence: leave now")
        XCTAssertNil(turn.request.arriveBy)
        let echoed = try await context.resolve(value, source: "等等去品都", now: late)
        XCTAssertNil(echoed.departAt, "The current time echoed back is now, not tomorrow")
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

@MainActor final class AssistantInputTests: XCTestCase {
    func testOnlySentencesLeaveTheOrdinarySearch() {
        for text in ["騎單車去台大", "回家", "明天九點前到北車", "從公司到西門", "帶我去101", "我要去台大醫院"] {
            XCTAssertTrue(AssistantSentence.looksLikeRequest(text), text)
        }
        for text in ["台大", "西門站", "回龍", "市政府", "台北101", "a", ""] {
            XCTAssertFalse(AssistantSentence.looksLikeRequest(text), text)
        }
    }
    func testRecentRequestsStayFewDistinctAndRemovable() throws {
        let suite = "ai-recents-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recents = AssistantRecents(defaults: defaults)
        for index in 0..<8 { recents.remember("去地點\(index)") }
        recents.remember("去地點3")
        XCTAssertEqual(recents.items.first, "去地點3")
        XCTAssertEqual(recents.items.count, 6)
        XCTAssertEqual(Set(recents.items).count, 6)
        recents.remove("去地點3")
        XCTAssertFalse(AssistantRecents(defaults: defaults).items.contains("去地點3"), "Removal persists")
        recents.clear()
        XCTAssertTrue(AssistantRecents(defaults: defaults).items.isEmpty)
    }
}
