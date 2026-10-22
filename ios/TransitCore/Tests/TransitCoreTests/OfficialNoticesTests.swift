import XCTest
@testable import TransitCore

final class OfficialNoticesTests: XCTestCase {
    private func rss(link: String = "https://pto.gov.taipei/News_Content.aspx?n=D065CCB1467288C8&amp;s=ABC") -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8"?><rss version="2.0"><channel><item>
        <title><![CDATA[公車改道措施]]></title><link>\(link)</link>
        <description><![CDATA[<p>10/23 09:00 &amp; 12:00</p><p>307 往板橋不停靠甲站。<br>不影響回程。</p><script>bad()</script><a href="https://example.invalid">附件</a>]]></description>
        <pubDate>Thu, 22 Oct 2026 08:00:00 GMT</pubDate></item></channel></rss>
        """.utf8)
    }
    func testRSSPreservesOfficialFactsAndDecodesPlainText() throws {
        let notices = try OfficialNotices.parse(rss())
        XCTAssertEqual(notices.count, 1)
        let notice = try XCTUnwrap(notices.first)
        XCTAssertEqual(notice.title, "公車改道措施")
        XCTAssertEqual(notice.body, "10/23 09:00 & 12:00\n307 往板橋不停靠甲站。\n不影響回程。\n附件")
        XCTAssertEqual(notice.publishedAt, ISO8601DateFormatter().date(from: "2026-10-22T08:00:00Z"))
        XCTAssertFalse(notice.body.contains("bad()"))
    }
    func testUntrustedLinksEmptyAndMalformedFeedsFailClosed() {
        for link in ["https://pto.gov.taipei.evil.example/News_Content.aspx", "http://pto.gov.taipei/News_Content.aspx",
                     "https://user@pto.gov.taipei/News_Content.aspx", "https://pto.gov.taipei/wrong"] {
            XCTAssertThrowsError(try OfficialNotices.parse(rss(link: link)))
        }
        for data in [Data(), Data("<rss>".utf8), Data(repeating: 65, count: OfficialNotices.maximumBytes + 1),
                     Data("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss/>".utf8)] {
            XCTAssertThrowsError(try OfficialNotices.parse(data))
        }
    }
    func testNumericEntitiesAndParagraphBoundariesSurvive() {
        XCTAssertEqual(OfficialNotices.plainText("<p>&#65;&#x42;&nbsp;&lt;C&gt;</p><li>第二段</li>"), "AB <C>\n第二段")
    }
}
