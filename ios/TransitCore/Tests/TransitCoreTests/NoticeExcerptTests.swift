import XCTest
@testable import TransitCore

final class NoticeExcerptTests: XCTestCase {
    func testOnlyOriginalParagraphsCanBeReturnedInSourceOrder() throws {
        let excerpt = NoticeExcerpt(body: "10/23 09:00 至 12:00 改道。\n307 往板橋不停靠甲站。\n不影響回程；恢復時間依現場公告。")
        XCTAssertEqual(try excerpt.selecting([2, 0]), ["10/23 09:00 至 12:00 改道。", "不影響回程；恢復時間依現場公告。"])
    }
    func testInvalidDuplicateAndEmptySelectionsCannotCreateASummary() {
        let excerpt = NoticeExcerpt(body: "第一段\n第二段\n第三段\n第四段")
        for indices in [[], [-1], [4], [0, 0], [0, 1, 2, 3]] {
            XCTAssertThrowsError(try excerpt.selecting(indices))
        }
    }
    func testLongSingleOrMissingDocumentsUseTheOriginal() {
        for text in ["", "只有一段", String(repeating: "長", count: 1801) + "\n第二段"] {
            let excerpt = NoticeExcerpt(body: text)
            XCTAssertFalse(excerpt.canSummarize)
            XCTAssertThrowsError(try excerpt.selecting([0]))
        }
    }
}
