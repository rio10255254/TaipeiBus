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
}
