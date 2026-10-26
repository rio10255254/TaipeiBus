import XCTest
@testable import TransitCore

final class OfficialNoticeMentionTests: XCTestCase {
    private func notice(_ title: String, _ body: String = "", daysAgo: Double = 1) -> OfficialNotice {
        OfficialNotice(title: title, body: body, source: URL(string: "https://pto.gov.taipei/n/\(title.hashValue)")!,
                       publishedAt: Date(timeIntervalSince1970: 1_800_000_000 - daysAgo * 86_400))
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testARouteNumberIsFoundOnlyOnItsOwn() {
        let marathon = notice("臺北馬拉松交通管制", "307、262 等路線改道。")
        XCTAssertEqual(OfficialNotices.mentioning(route: "307", in: [marathon], now: now), marathon)
        XCTAssertEqual(OfficialNotices.mentioning(route: "262", in: [marathon], now: now), marathon)
        XCTAssertNil(OfficialNotices.mentioning(route: "30", in: [marathon], now: now))
        XCTAssertNil(OfficialNotices.mentioning(route: "3070", in: [marathon], now: now))
        let red = notice("紅32 調整班次")
        XCTAssertNil(OfficialNotices.mentioning(route: "32", in: [red], now: now))
        XCTAssertEqual(OfficialNotices.mentioning(route: "紅32", in: [red], now: now), red)
    }

    func testOnlyTheLastTwoWeeksCountAndTheNewestComesFirst() {
        let old = notice("307 改道", daysAgo: 20), newer = notice("307 恢復行駛", daysAgo: 1), older = notice("307 延駛", daysAgo: 5)
        XCTAssertEqual(OfficialNotices.mentioning(route: "307", in: [old, older, newer], now: now), newer)
        XCTAssertNil(OfficialNotices.mentioning(route: "307", in: [old], now: now))
    }
}
