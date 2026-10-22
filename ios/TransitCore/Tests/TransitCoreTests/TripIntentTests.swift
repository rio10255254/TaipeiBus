import XCTest
@testable import TransitCore

final class TripIntentTests: XCTestCase {
    func testFieldsTakenFromTheSentenceAreKept() throws {
        let intent = try XCTUnwrap(TripIntent.validated(sentence: "從台北車站到臺大醫院，不想走太多路", destination: "台大醫院",
            origin: "台北車站", preference: "lessWalking", time: "", savedJourney: "", savedTitles: []))
        XCTAssertEqual(intent, TripIntent(destination: "台大醫院", origin: "台北車站", preference: .lessWalking))
    }

    func testAPlaceTheRiderNeverWroteIsRejected() {
        // A model that "helpfully" completes or swaps the place must not send the rider elsewhere.
        XCTAssertNil(TripIntent.validated(sentence: "我要去醫院", destination: "台大醫院", origin: "", preference: "balanced",
            time: "", savedJourney: "", savedTitles: []))
        let start = TripIntent.validated(sentence: "到西門町，少轉乘", destination: "西門町", origin: "台北車站",
            preference: "fewerTransfers", time: "", savedJourney: "", savedTitles: [])
        XCTAssertEqual(start?.origin, nil)
        XCTAssertEqual(start?.preference, .fewerTransfers)
    }

    func testCurrentLocationWordsAndUnknownPreferencesFallBackToDefaults() {
        let intent = TripIntent.validated(sentence: "從這裡去松山機場最快的方法", destination: "松山機場", origin: "這裡",
            preference: "teleport", time: "", savedJourney: "", savedTitles: [])
        XCTAssertEqual(intent, TripIntent(destination: "松山機場"))
    }

    func testTimeIsReportedNotDropped() {
        let intent = TripIntent.validated(sentence: "明天早上9點前到市政府", destination: "市政府", origin: "",
            preference: "balanced", time: "明天早上9點前", savedJourney: "", savedTitles: [])
        XCTAssertEqual(intent?.timeText, "明天早上9點前")
        XCTAssertEqual(intent?.destination, "市政府")
    }

    func testSavedTripsMustBeNamedAndExist() {
        let titles = ["家", "公司"]
        let home = TripIntent.validated(sentence: "回家", destination: "", origin: "", preference: "balanced",
            time: "", savedJourney: "家", savedTitles: titles)
        XCTAssertEqual(home?.savedJourneyTitle, "家")
        XCTAssertNil(TripIntent.validated(sentence: "回家", destination: "", origin: "", preference: "balanced",
            time: "", savedJourney: "學校", savedTitles: titles), "Only titles the rider actually saved")
        XCTAssertNil(TripIntent.validated(sentence: "去西門町", destination: "", origin: "", preference: "balanced",
            time: "", savedJourney: "公司", savedTitles: titles), "Only titles named in the sentence")
    }

    func testSameStartAndDestinationKeepsOnlyTheDestination() {
        let intent = TripIntent.validated(sentence: "從大安森林公園到大安森林公園", destination: "大安森林公園",
            origin: "大安森林公園", preference: "balanced", time: "", savedJourney: "", savedTitles: [])
        XCTAssertEqual(intent, TripIntent(destination: "大安森林公園"))
    }

    func testOnlyTripSentencesOfferTheModel() {
        for text in ["從公司到台大醫院", "去南港展覽館，不想轉乘", "明天9點前到市政府", "回家", "from Taipei Main Station to Ximen"] {
            XCTAssertTrue(TripIntent.isSentence(text), text)
        }
        for text in ["台大醫院", "我要去台北車站", "忠孝東路四段", "307", "", "到"] {
            XCTAssertFalse(TripIntent.isSentence(text), text)
        }
    }
}
