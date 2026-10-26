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
}
