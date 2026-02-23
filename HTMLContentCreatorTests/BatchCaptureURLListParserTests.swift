import XCTest
@testable import HTMLContentCreator

final class BatchCaptureURLListParserTests: XCTestCase {
    func testParseTextListSupportsCommentsAndDeduplicates() {
        let input = """
        # URLs
        https://example.com/one
        https://example.com/two

        // comment
        https://example.com/one
        www.example.org/path
        not-a-url
        """

        let result = BatchCaptureURLListParser.parse(text: input)

        XCTAssertEqual(
            result.urls,
            [
                "https://example.com/one",
                "https://example.com/two",
                "https://www.example.org/path"
            ]
        )
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertGreaterThanOrEqual(result.ignoredLineCount, 3)
    }

    func testParseCSVLikeContentFindsURLsInsideColumns() {
        let input = """
        url,title
        https://news.ycombinator.com,item 1
        "https://swift.org",Swift
        foo,bar
        """

        let result = BatchCaptureURLListParser.parse(text: input)

        XCTAssertEqual(
            result.urls,
            [
                "https://news.ycombinator.com",
                "https://swift.org"
            ]
        )
        XCTAssertEqual(result.duplicateCount, 0)
        XCTAssertGreaterThanOrEqual(result.ignoredLineCount, 2)
    }

    func testParseTextListRepairsSchemeTyposAndMissingScheme() {
        let input = """
        htps://example.com/one
        https://example.com/one
        https:/example.com/two
        https:example.com/three
        emsh.cat/one-human-one-agent-one-browser/
        invalid-url
        """

        let result = BatchCaptureURLListParser.parse(text: input)

        XCTAssertEqual(
            result.urls,
            [
                "https://example.com/one",
                "https://example.com/two",
                "https://example.com/three",
                "https://emsh.cat/one-human-one-agent-one-browser/"
            ]
        )
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertGreaterThanOrEqual(result.ignoredLineCount, 1)
    }
}
