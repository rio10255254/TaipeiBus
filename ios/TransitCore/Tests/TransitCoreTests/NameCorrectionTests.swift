import XCTest
@testable import TransitCore

final class NameCorrectionTests: XCTestCase {
    private let names = NameCorrection(nearby: ["忠孝敦化", "西門町", "淡水", "市政府", "國立故宮博物院", "公館"])

    func testAHomophoneIsWrittenAsTheStation() {
        XCTAssertEqual(names.correct("我要去忠孝敦華"), "我要去忠孝敦化")
        XCTAssertEqual(names.correct("從西門汀到淡水"), "從西門町到淡水")
    }

    func testAnAccentThatMergesSoundsStillFindsTheName() {
        // zh said as z, and the shi of 市 as si.
        XCTAssertEqual(names.correct("去宗孝敦化"), "去忠孝敦化")
        XCTAssertEqual(names.correct("到四政府"), "到市政府")
    }

    func testShortNamesMustSoundExactlyTheSame() {
        XCTAssertEqual(names.correct("我想去談水"), "我想去談水", "t and d are different sounds")
        XCTAssertEqual(names.correct("公關公司"), "公關公司", "公關 is gōng guān, not gōng guǎn: a word, not the station")
        XCTAssertEqual(names.correct("功館"), "公館")
    }

    func testTextThatIsRightOrNotChineseStaysAsItIs() {
        XCTAssertEqual(names.correct("307 到忠孝敦化還要多久"), "307 到忠孝敦化還要多久")
        XCTAssertEqual(names.correct("How long to Ximending?"), "How long to Ximending?")
        XCTAssertEqual(names.correct(""), "")
    }

    func testTheLongerNameWins() {
        let names = NameCorrection(nearby: ["故宮", "國立故宮博物院"])
        XCTAssertEqual(names.correct("國立顧宮博物院幾點開"), "國立故宮博物院幾點開")
    }

    func testOtherStopsNeedFourCharactersBeforeAccentsCount() {
        let names = NameCorrection(nearby: [], others: ["市政府", "忠孝敦化"])
        XCTAssertEqual(names.correct("到四政府"), "到四政府", "Three characters from afar must sound exactly the same")
        XCTAssertEqual(names.correct("到市正府"), "到市政府", "…which 市正府 does, tones included")
        XCTAssertEqual(names.correct("去宗孝敦化"), "去忠孝敦化")
    }

    func testAShortNameAfterAPlaceWordMayDifferInTone() {
        let names = NameCorrection(nearby: [], others: ["圓山", "公館"])
        XCTAssertEqual(names.correct("我想去遠山的酒吧有什麼推薦的嗎"), "我想去圓山的酒吧有什麼推薦的嗎")
        // Without a place word before it, a different tone stays a different word.
        XCTAssertEqual(names.correct("遠山很美"), "遠山很美")
        XCTAssertEqual(names.correct("公關部門"), "公關部門")
    }

    func testNamesNearbyGoInFrontOfASharedIndex() {
        let city = NameCorrection(nearby: [], others: ["市政府", "忠孝敦化"])
        let names = NameCorrection(nearby: ["市政府"], adding: city)
        XCTAssertEqual(names.correct("到四政府"), "到市政府", "Nearby, three characters are compared loosely")
        XCTAssertEqual(names.correct("去宗孝敦化"), "去忠孝敦化", "The shared names still count")
        XCTAssertEqual(city.correct("到四政府"), "到四政府", "The shared index itself is unchanged")
    }

    func testOfficialPlaceNamesReadFromTheirFile() {
        let data = Data(#"{"places":[["國立故宮博物院",25.1024,121.5485,"spot"],["鼎泰豐",25.0336,121.5299,"food"],["",1,2],["太長的名字太長的名字太長的名字",25,121]]}"#.utf8)
        let places = VoicePlaces(data: data)
        XCTAssertEqual(places.places.map(\.name), ["國立故宮博物院", "鼎泰豐"])
        XCTAssertEqual(places.spots, ["國立故宮博物院"])
        XCTAssertEqual(places.near(Coordinate(latitude: 25.033, longitude: 121.53), within: 2000), ["鼎泰豐"])
        XCTAssertEqual(places.near(nil), [])
    }
}
