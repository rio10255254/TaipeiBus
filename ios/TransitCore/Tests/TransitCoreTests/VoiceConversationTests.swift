import XCTest
@testable import TransitCore

final class VoiceConversationTests: XCTestCase {
    private func action(_ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["type": type, "stop": "", "route": "", "destination": "", "origin": "", "time": "", "mode": "any",
         "preference": "balanced", "option": 0].merging(extra) { $1 }
    }
    private func reply(_ json: String) -> VoiceReply? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]).flatMap(VoiceReply.init(json:))
    }

    // MARK: Reply

    func testAServerReplyDecodesFromJSON() {
        let decoded = reply("""
        {"say":"307 {r1}，在新埔站下車。","actions":[{"type":"show_route","stop":"","route":"307","destination":"","origin":"","time":"","mode":"any","preference":"balanced","option":0}],
         "confirm":{"type":"none","stop":"","route":"","destination":"","origin":"","time":"","mode":"any","preference":"balanced","option":0},
         "choices":[],"followUp":false}
        """)
        XCTAssertEqual(decoded, VoiceReply(say: "307 {r1}，在新埔站下車。", actions: [.showRoute("307")]))
    }

    func testChangingTheTripIsOnlyEverAsked() {
        let decoded = VoiceReply(json: ["say": "要開始導航嗎？", "actions": [action("start_navigation"), action("show_stop", ["stop": "台北車站"])],
                                        "confirm": action("none"), "choices": [], "followUp": false])
        XCTAssertEqual(decoded?.actions, [.showStop("台北車站")])
        XCTAssertEqual(decoded?.confirm, .startNavigation)
        XCTAssertEqual(decoded?.followUp, true, "A question always waits for the answer")
        XCTAssertNil(VoiceReply(json: ["say": "好", "confirm": action("show_stop", ["stop": "A"])])?.confirm,
                     "Only trip changes are confirmed; anything else in confirm is dropped")
    }

    func testUnknownIncompleteAndExtraActionsAreDropped() {
        let decoded = VoiceReply(json: ["say": "好的", "actions": [
            action("delete_everything"), action("show_stop"), action("plan_trip"), action("choose_option", ["option": 7]),
            action("show_route", ["route": "1"]), action("show_route", ["route": "2"]), action("show_route", ["route": "3"]),
            action("show_route", ["route": "4"]),
        ]])
        XCTAssertEqual(decoded?.actions, [.showRoute("1"), .showRoute("2"), .showRoute("3")])
    }

    func testPlanTripKeepsTheRidersWords() {
        let decoded = VoiceReply(json: ["say": "幫你找去台大的路線。", "actions": [action("plan_trip", ["destination": "台大機械館", "time": "明天早上九點前"])]])
        XCTAssertEqual(decoded?.actions, [.planTrip(destination: "台大機械館", origin: "", time: "明天早上九點前", mode: "any", preference: "balanced", then: "")])
    }

    func testPlanTripKeepsTheLaterStops() {
        let decoded = VoiceReply(json: ["say": "好。", "actions": [action("plan_trip", ["destination": "西門町", "time": "明天下午", "then": "淡水"])]])
        XCTAssertEqual(decoded?.actions, [.planTrip(destination: "西門町", origin: "", time: "明天下午", mode: "any", preference: "balanced", then: "淡水")])
    }

    func testChoicesAreTrimmedUniqueAndAtMostThree() {
        let decoded = VoiceReply(json: ["say": "哪一站？", "choices": [" 台北車站 ", "台北車站", "西門", "公館", "古亭", 5]])
        XCTAssertEqual(decoded?.choices, ["台北車站", "西門", "公館"])
    }

    func testNothingOrTooMuchToSayIsUnusable() {
        XCTAssertNil(VoiceReply(json: ["say": "  "]))
        XCTAssertNil(VoiceReply(json: ["say": String(repeating: "很", count: 161)]))
    }

    // MARK: Spoken answer

    private let values = ["r1": "約 4 分鐘到", "r2": "還有 3 站"]
    private let known = ["307", "忠孝復興站", "新埔站", "紅25"]

    func testSlotsAreFilledWithTheAppsValues() {
        XCTAssertEqual(SpokenAnswer.render("307 {r1}，{r2}在新埔站下車。", values: values, known: known),
                       .success("307 約 4 分鐘到，還有 3 站在新埔站下車。"))
    }

    func testANumberTheModelWroteItselfIsRefused() {
        XCTAssertEqual(SpokenAnswer.render("307 大約 4 分鐘到。", values: values, known: known), .failure(.unsupportedNumber("4")))
        XCTAssertEqual(SpokenAnswer.render("再三站就到了。", values: values, known: known), .failure(.unsupportedNumber("三站")))
        XCTAssertEqual(SpokenAnswer.render("下兩站就到了。", values: values, known: known), .failure(.unsupportedNumber("兩站")))
        XCTAssertEqual(SpokenAnswer.render("十一點有車。", values: values, known: known), .failure(.unsupportedNumber("十一點")))
        XCTAssertEqual(SpokenAnswer.render("搭 299 比較快。", values: values, known: known), .failure(.unsupportedNumber("299")),
                       "A route the rider never saw may be made up")
    }

    func testNumbersTheRiderAlreadySawOrSaidMayBeSpoken() {
        XCTAssertEqual(SpokenAnswer.render("紅25 {r1}。", values: values, known: known), .success("紅25 約 4 分鐘到。"))
        XCTAssertEqual(SpokenAnswer.render("３０７ {r1}。", values: values, known: known), .success("３０７ 約 4 分鐘到。"),
                       "Full-width digits are the same route")
        XCTAssertEqual(SpokenAnswer.render("要跟哪一班？下一站下車也可以。", values: values, known: known), .success("要跟哪一班？下一站下車也可以。"),
                       "哪一班 and 下一站 name one, not a count")
        XCTAssertEqual(SpokenAnswer.render("想早一點到的話可以改搭捷運。", values: values, known: known),
                       .success("想早一點到的話可以改搭捷運。"), "早一點 is not one o'clock")
    }

    func testAUnitAroundASlotIsSaidOnce() {
        let values = ["r1": "5 分鐘", "r2": "全程約 25 分", "r3": "約 4 分鐘到", "r4": "尚未發車", "r5": "19:55"]
        func say(_ text: String) -> String? { try? SpokenAnswer.render(text, values: values, known: known).get() }
        XCTAssertEqual(say("307 往板橋 {r1} 分鐘後到忠孝復興站。"), "307 往板橋 5 分鐘後到忠孝復興站。")
        XCTAssertEqual(say("307 約 {r1} 分鐘到。"), "307 約 5 分鐘到。", "A plain minute count keeps the rider-friendly 約")
        XCTAssertEqual(say("第一個方案全程 {r2}，{r5} 抵達。"), "第一個方案全程約 25 分，19:55 抵達。")
        XCTAssertEqual(say("全程約 {r2} 分鐘。"), "全程約 25 分。")
        XCTAssertEqual(say("307 約 {r3}。"), "307 約 4 分鐘到。")
        XCTAssertEqual(say("307 {r3}到忠孝復興站。"), "307 約 4 分鐘到忠孝復興站。")
        XCTAssertEqual(say("307 {r4} 分鐘後到。"), "307 尚未發車。")
    }

    func testRouteNumbersAreSpokenDigitByDigit() {
        XCTAssertEqual(SpokenAnswer.speakable("307 約 12 分鐘到，或搭 紅25。", routes: ["307", "紅25"]), "3 0 7 約 12 分鐘到，或搭 紅25。")
        XCTAssertEqual(SpokenAnswer.speakable("1200 公尺", routes: ["307"]), "1200 公尺", "Only route numbers")
    }

    func testAnUnknownSlotIsRefused() {
        XCTAssertEqual(SpokenAnswer.render("{r9}", values: values, known: known), .failure(.unknownSlot("r9")))
        XCTAssertEqual(SpokenAnswer.render(" ", values: values, known: known), .failure(.empty))
    }

    // MARK: Context

    func testTheStateListsMeaningsButNeverValues() {
        let now = ISO8601DateFormatter().date(from: "2026-10-25T11:40:00Z")!
        let context = VoiceContext(now: now, screen: "導航中：搭 307 往板橋", facts: ["上車站：忠孝復興站"],
                                   references: VoiceContext.numbered([("307 往板橋 到 忠孝復興站 的到站預估", "約 4 分鐘到")]),
                                   pending: .boarded, names: ["307"])
        let prompt = context.prompt()
        XCTAssertTrue(prompt.contains("2026-10-25 19:40"))
        XCTAssertTrue(prompt.contains("[r1] 307 往板橋 到 忠孝復興站 的到站預估"))
        XCTAssertTrue(prompt.contains("待確認：已上車"))
        XCTAssertFalse(prompt.contains("約 4 分鐘到"), "The model never sees the value it would read out")
        XCTAssertEqual(context.values, ["r1": "約 4 分鐘到"])
    }

    // MARK: Confirmation and history

    func testAShortYesOrNoIsReadOnThePhone() {
        for text in ["好", "好啊", "可以", "對", "嗯嗯", "開始吧", "OK", "好！"] { XCTAssertEqual(VoiceConfirmation.read(text), .yes, text) }
        for text in ["不要", "不用了", "取消", "算了", "先不要", "不好"] { XCTAssertEqual(VoiceConfirmation.read(text), .no, text) }
        for text in ["好啊那回程呢要搭哪一班", "不知道", "307 還要多久", ""] { XCTAssertEqual(VoiceConfirmation.read(text), .unclear, text) }
    }

    func testHistoryKeepsTheLastEightTurns() {
        var history = VoiceHistory()
        for turn in 1...10 { history.append(user: "u\(turn)", said: "s\(turn)") }
        XCTAssertEqual(history.json.count, 8)
        XCTAssertEqual(history.json.first, ["user": "u3", "say": "s3"])
        XCTAssertEqual(history.json.last, ["user": "u10", "say": "s10"])
    }

    func testTimesAreSaidWithTheirDay() {
        let now = ISO8601DateFormatter().date(from: "2026-10-25T15:39:00Z")!  // 23:39 in Taipei
        XCTAssertEqual(VoiceClock.label(now.addingTimeInterval(15 * 60), now: now), "23:54")
        XCTAssertEqual(VoiceClock.label(now.addingTimeInterval(27 * 60), now: now), "明天 00:06")
        XCTAssertEqual(VoiceClock.label(now.addingTimeInterval(26 * 3600), now: now), "後天 01:39")
        XCTAssertEqual(VoiceClock.label(now.addingTimeInterval(72 * 3600), now: now), "10/28 23:39")
    }

    func testStreamedAnswerIsSpokenSentenceBySentence() {
        var sentences = SpokenSentences()
        XCTAssertEqual(sentences.push("307 往"), [])
        XCTAssertEqual(sentences.push("板橋，{r"), [])
        XCTAssertEqual(sentences.push("1}。671 "), ["307 往板橋，{r1}。"])
        XCTAssertEqual(sentences.push("{r2}。要跟車嗎？"), ["671 {r2}。", "要跟車嗎？"])
        XCTAssertEqual(sentences.finish(), "")
    }

    func testTheLastSentenceWithoutAStopComesOutAtTheEnd() {
        var sentences = SpokenSentences()
        XCTAssertEqual(sentences.push("好，幫你規劃到台北101"), [])
        XCTAssertEqual(sentences.finish(), "好，幫你規劃到台北101")
    }

    func testAClosingQuoteStaysWithItsSentence() {
        var sentences = SpokenSentences()
        XCTAssertEqual(sentences.push("你可以說「我上車了。」之後"), ["你可以說「我上車了。」"])
        XCTAssertEqual(sentences.push("我會提醒你。"), ["之後我會提醒你。"])
        // A quote that arrives after its sentence went out is not spoken alone.
        XCTAssertEqual(sentences.push("說「好。"), ["說「好。"])
        XCTAssertEqual(sentences.push("」"), [])
        XCTAssertEqual(sentences.finish(), "")
    }

    private var station: VoiceContext {
        VoiceContext(screen: "站牌：忠孝復興站", references: VoiceContext.numbered([("307 的到站", "約 4 分鐘到"), ("671 的到站", "尚未發車")]),
                     names: ["307", "671", "忠孝復興站"])
    }

    func testAStreamedTurnSpeaksEachCheckedSentenceAsItArrives() {
        var turn = SpokenTurn(context: station, heard: "307 跟 671 呢")
        XCTAssertEqual(turn.receive("307 {r1}"), [])
        XCTAssertEqual(turn.receive("。671 {r2}。要"), ["307 約 4 分鐘到。", "671 尚未發車。"])
        XCTAssertEqual(turn.receive("跟哪一班"), [])
        XCTAssertEqual(turn.finishWords(), ["要跟哪一班"])
        XCTAssertEqual(turn.finish(choices: []), [])
        XCTAssertEqual(turn.spoken.joined(), "307 約 4 分鐘到。671 尚未發車。要跟哪一班")
        XCTAssertNil(turn.refused)
    }

    func testASentenceThatCannotPassYetWaitsForTheChoicesAndHoldsWhatFollows() {
        var turn = SpokenTurn(context: station, heard: "附近有什麼車")
        XCTAssertEqual(turn.receive("有別的車。要 299 還是 952？好"), ["有別的車。"])
        XCTAssertEqual(turn.receive("嗎？"), [], "Nothing is spoken after a sentence that is held back")
        XCTAssertEqual(turn.finish(choices: ["299", "952"]), ["要 299 還是 952？好嗎？"])
        XCTAssertNil(turn.refused)
    }

    func testWhatStillFailsAtTheEndIsRefused() {
        var turn = SpokenTurn(context: station, heard: "307 呢")
        XCTAssertEqual(turn.receive("307 {r1}。大約 8 分鐘就到。"), ["307 約 4 分鐘到。"])
        XCTAssertEqual(turn.finish(choices: []), [])
        XCTAssertEqual(turn.refused, .unsupportedNumber("8"))
        XCTAssertEqual(turn.spoken, ["307 約 4 分鐘到。"])
    }
}
