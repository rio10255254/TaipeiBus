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
        XCTAssertEqual(decoded?.actions, [.planTrip(destination: "台大機械館", origin: "", time: "明天早上九點前", mode: "any", preference: "balanced")])
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
        XCTAssertEqual(SpokenAnswer.render("搭 299 比較快。", values: values, known: known), .failure(.unsupportedNumber("299")),
                       "A route the rider never saw may be made up")
    }

    func testNumbersTheRiderAlreadySawOrSaidMayBeSpoken() {
        XCTAssertEqual(SpokenAnswer.render("紅25 {r1}。", values: values, known: known), .success("紅25 約 4 分鐘到。"))
        XCTAssertEqual(SpokenAnswer.render("３０７ {r1}。", values: values, known: known), .success("３０７ 約 4 分鐘到。"),
                       "Full-width digits are the same route")
        XCTAssertEqual(SpokenAnswer.render("想早一點到的話可以改搭捷運。", values: values, known: known),
                       .success("想早一點到的話可以改搭捷運。"), "早一點 is not one o'clock")
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

    func testHistoryKeepsTheLastTwoTurns() {
        var history = VoiceHistory()
        history.append(user: "a", said: "1"); history.append(user: "b", said: "2"); history.append(user: "c", said: "3")
        XCTAssertEqual(history.json, [["user": "b", "say": "2"], ["user": "c", "say": "3"]])
    }
}
