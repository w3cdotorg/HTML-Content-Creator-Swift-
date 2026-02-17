import Foundation
import XCTest
@testable import HTMLContentCreator

final class LegacyMarkdownCodecTests: XCTestCase {
    func testParseCaptureLogParsesBlocksWithOptionalDate() {
        let markdown = """
        # Captures

        <!-- CAPTURE: 001_example.com_20260217_1010.png -->
        - Fichier: `001_example.com_20260217_1010.png`
        - URL: https://example.com/article
        - Date: 2026-02-17 10:10:11
        - Capture: [001_example.com_20260217_1010.png](./001_example.com_20260217_1010.png)

        <!-- CAPTURE: 002_example.com_20260217_1011.png -->
        - Fichier: `002_example.com_20260217_1011.png`
        - URL: https://example.com/next
        - Date: not-a-date
        - Capture: [002_example.com_20260217_1011.png](./002_example.com_20260217_1011.png)

        <!-- CAPTURE: 003_example.com_20260217_1012.png -->
        - Fichier: `003_example.com_20260217_1012.png`
        - URL: not a url
        - Date: 2026-02-17 10:12:11
        - Capture: [003_example.com_20260217_1012.png](./003_example.com_20260217_1012.png)
        """

        let records = LegacyMarkdownCodec.parseCaptureLog(markdown)

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].filename, "001_example.com_20260217_1010.png")
        XCTAssertEqual(records[0].url.absoluteString, "https://example.com/article")
        XCTAssertNotNil(records[0].capturedAt)

        XCTAssertEqual(records[1].filename, "002_example.com_20260217_1011.png")
        XCTAssertEqual(records[1].url.absoluteString, "https://example.com/next")
        XCTAssertNil(records[1].capturedAt)

        XCTAssertEqual(records[2].filename, "003_example.com_20260217_1012.png")
        XCTAssertEqual(records[2].url.absoluteString, "not%20a%20url")
        XCTAssertNotNil(records[2].capturedAt)
    }

    func testSerializeNotesFiltersSortsAndTrimsContent() {
        let notes: [String: String] = [
            "b_capture.png": "  note b  ",
            "invalid/../name.png": "should be filtered",
            "a_capture.png": "note a",
            "c_capture.png": "   "
        ]

        let serialized = LegacyMarkdownCodec.serializeNotes(notes)

        XCTAssertTrue(serialized.hasPrefix("# Notes\n\n"))
        let firstIndex = serialized.range(of: "<!-- NOTE: a_capture.png -->")?.lowerBound
        let secondIndex = serialized.range(of: "<!-- NOTE: b_capture.png -->")?.lowerBound
        XCTAssertNotNil(firstIndex)
        XCTAssertNotNil(secondIndex)
        XCTAssertLessThan(firstIndex!, secondIndex!)
        XCTAssertFalse(serialized.contains("invalid/../name.png"))
        XCTAssertFalse(serialized.contains("c_capture.png"))
    }

    func testParseNotesParsesMarkdownBlocks() {
        let markdown = """
        # Notes

        <!-- NOTE: 001_one.png -->
        first line
        second line
        <!-- END NOTE -->

        <!-- NOTE: 002_two.png -->
        - bullet
        <!-- END NOTE -->
        """

        let notes = LegacyMarkdownCodec.parseNotes(markdown)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes["001_one.png"], "first line\nsecond line")
        XCTAssertEqual(notes["002_two.png"], "- bullet")
    }

    func testParseAndSerializeOrderRoundTrip() {
        let input = """
        # Order
        002_two.png

        invalid/name.png
        001_one.png
        """

        let parsed = LegacyMarkdownCodec.parseOrder(input)
        XCTAssertEqual(parsed, ["002_two.png", "001_one.png"])

        let serialized = LegacyMarkdownCodec.serializeOrder(parsed)
        XCTAssertEqual(serialized, "002_two.png\n001_one.png\n")
    }
}
