import XCTest
@testable import TransitCore

final class VoiceVocabularyTests: XCTestCase {
    func testHintsKeepTheirOrderOnceEachUpToTheLimit() {
        let hints = VoiceVocabulary.hints([["忠孝復興站", " 307 "], ["307", "回家", ""], ["台北101"]], limit: 3)
        XCTAssertEqual(hints, ["忠孝復興站", "307", "回家"])
    }

    func testEveryLandmarkHasBothLanguages() {
        for landmark in VoiceVocabulary.landmarks {
            XCTAssertFalse(landmark.chinese.isEmpty)
            XCTAssertTrue(landmark.english.allSatisfy(\.isASCII), landmark.english)
        }
        XCTAssertEqual(Set(VoiceVocabulary.landmarks.map(\.chinese)).count, VoiceVocabulary.landmarks.count)
    }

    func testAMisheardLandmarkIsPutRight() {
        let names = NameCorrection(nearby: [], others: VoiceVocabulary.landmarks.map(\.chinese))
        XCTAssertEqual(names.correct("我要去淡水老姐"), "我要去淡水老街")
        XCTAssertEqual(names.correct("我要去台北101"), "我要去台北101")
    }

    func testALanguageCanBeSetForOnePieceOfWork() {
        let english = AppLanguage.$override.withValue(.english) { AppLanguage.current }
        XCTAssertEqual(english, .english)
        XCTAssertEqual(AppText.text("結束對話", language: AppLanguage.$override.withValue(.english) { AppLanguage.current }), "End conversation")
        XCTAssertNil(AppLanguage.override)
    }

    func testTheNewActionsAreRead() {
        XCTAssertEqual(VoiceAction(json: ["type": "notices"]), .notices)
        XCTAssertEqual(VoiceAction(json: ["type": "save_stop", "stop": "忠孝復興站"]), .saveStop("忠孝復興站"))
        XCTAssertNil(VoiceAction(json: ["type": "save_stop", "stop": " "]))
        XCTAssertEqual(VoiceAction(json: ["type": "remind_alight"]), .remindAlight)
        XCTAssertFalse(VoiceAction.remindAlight.needsConfirmation)
    }

    func testAChoiceIsPickedByNameOrByCount() {
        let places = ["淡水", "淡水老街", "淡水漁人碼頭"]
        XCTAssertEqual(VoiceChoice.pick("淡水", among: places), 0)
        XCTAssertEqual(VoiceChoice.pick("去淡水老街", among: places), 1)
        XCTAssertEqual(VoiceChoice.pick("漁人碼頭", among: places), 2)
        XCTAssertEqual(VoiceChoice.pick("第二個", among: places), 1)
        XCTAssertEqual(VoiceChoice.pick("The second one", among: places), 1)
        XCTAssertNil(VoiceChoice.pick("307 還要多久", among: places))
        XCTAssertNil(VoiceChoice.pick("第二個方案要走多久", among: places))
        XCTAssertNil(VoiceChoice.pick("", among: places))
    }

    func testTheAssistantsOwnVoiceIsNotARiderCuttingIn() {
        let spoken = "307 往板橋，約 4 分鐘到。要跟車嗎？"
        // Its own sentence heard back, even with a homophone or two.
        XCTAssertFalse(VoiceEcho.interrupts(heard: "307 往板橋約4分鐘到", spoken: spoken))
        XCTAssertFalse(VoiceEcho.interrupts(heard: "307網板橋約四分鐘到要跟車", spoken: spoken))
        XCTAssertFalse(VoiceEcho.interrupts(heard: "", spoken: spoken))
        // The rider saying something else.
        XCTAssertTrue(VoiceEcho.interrupts(heard: "等一下那671呢", spoken: spoken))
        XCTAssertTrue(VoiceEcho.interrupts(heard: "Wait, what about the 671", spoken: "The 307 is 4 minutes away."))
        // On the loudspeaker a short new phrase is not enough.
        XCTAssertFalse(VoiceEcho.interrupts(heard: "307 往板橋那", spoken: spoken, strict: true))
        XCTAssertTrue(VoiceEcho.interrupts(heard: "不用了我要改去台北車站", spoken: spoken, strict: true))
    }

    func testARiderCorrectingThemselvesIsWaitedForLonger() {
        XCTAssertTrue(VoicePatience.corrects("我是說圓山的酒吧"))
        XCTAssertTrue(VoicePatience.corrects("我們要一起我是說圓山的酒吧。"))
        XCTAssertTrue(VoicePatience.corrects("不是，是淡水"))
        XCTAssertTrue(VoicePatience.corrects("I mean the 671"))
        XCTAssertFalse(VoicePatience.corrects("307 還要多久"))
        XCTAssertFalse(VoicePatience.corrects("不是很遠吧"))
        XCTAssertEqual(VoicePatience.next(1.3, after: "我是說圓山"), 1.6, accuracy: 0.001)
        XCTAssertEqual(VoicePatience.next(2.2, after: "我是說圓山"), VoicePatience.longest())
        XCTAssertEqual(VoicePatience.next(1.8, after: "307 還要多久", usual: 1.8), 1.8)
        XCTAssertEqual(VoicePatience.next(2.7, after: "我是說圓山", usual: 1.8), 2.8, accuracy: 0.001)
        XCTAssertEqual(VoicePatience.next(1.6, after: "307 還要多久"), 1.55, accuracy: 0.001)
        XCTAssertEqual(VoicePatience.next(1.3, after: "307 還要多久"), VoicePatience.usual)
    }

    func testTheAnswersOwnWordsAreLeftOutOfWhatTheRiderSaid() {
        // Exactly as heard before the rider spoke.
        XCTAssertEqual(VoiceEcho.removing(echo: "307往板橋", from: "307往板橋我是說圓山的酒吧"), "我是說圓山的酒吧")
        // Rewritten a little once the rider's words followed.
        XCTAssertEqual(VoiceEcho.removing(echo: "307往板橋約4分鐘到", from: "307網板橋約四分鐘到，我是說圓山的酒吧"), "我是說圓山的酒吧")
        XCTAssertEqual(VoiceEcho.removing(echo: "The 307 is 4 minutes", from: "the 307 is four minutes wait what about 671"),
                       "wait what about 671")
        // Nothing heard of the answer, or not what it starts with: all of it stays.
        XCTAssertEqual(VoiceEcho.removing(echo: "", from: "我想去圓山"), "我想去圓山")
        XCTAssertEqual(VoiceEcho.removing(echo: "307往板橋", from: "我想去圓山的酒吧"), "我想去圓山的酒吧")
    }
}
