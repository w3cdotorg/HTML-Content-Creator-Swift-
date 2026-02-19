import Foundation
import XCTest
@testable import HTMLContentCreator

final class HTMLDeckGeneratorIntegrationTests: XCTestCase {
    private var tempRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("html-content-creator-integration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.removeItem(at: tempRoot)
        }
    }

    func testGenerateHTMLAppliesOrderAndNotes() async throws {
        let paths = WorkspacePaths(root: tempRoot)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let store = LegacyFileStore(paths: paths, fileManager: fileManager)
        let generator = HTMLDeckGenerator(paths: paths, store: store, fileManager: fileManager)

        let first = CaptureRecord(
            filename: "001_example.com_20260203_1602.png",
            url: URL(string: "https://example.com/first")!,
            capturedAt: Date(timeIntervalSince1970: 1_738_593_732)
        )
        let second = CaptureRecord(
            filename: "002_example.com_20260203_1611.png",
            url: URL(string: "https://example.com/second")!,
            capturedAt: Date(timeIntervalSince1970: 1_738_594_288)
        )

        // Append in reverse order; saved editor order should override this.
        try await store.appendCaptureLog(projectName: WorkspacePaths.defaultProjectName, capture: second)
        try await store.appendCaptureLog(projectName: WorkspacePaths.defaultProjectName, capture: first)
        try await store.saveEditorState(
            projectName: WorkspacePaths.defaultProjectName,
            order: [first.filename, second.filename],
            notesByFilename: [
                first.filename: "*socio-technique* note"
            ]
        )

        let output = try await generator.generate(projectName: "default", requestedTitle: "Integration Deck")
        XCTAssertTrue(fileManager.fileExists(atPath: output.fileURL.path))
        XCTAssertEqual(output.title, "Integration Deck")

        let html = try String(contentsOf: output.fileURL, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Integration Deck</title>"))
        XCTAssertTrue(html.contains("id=\"editToggle\""))
        XCTAssertTrue(html.contains("id=\"exportPdf\""))
        XCTAssertTrue(html.contains("window.print()"))
        XCTAssertTrue(html.contains("<aside class=\"note\">"))
        XCTAssertTrue(html.contains("socio-technique"))

        let firstMarker = "data-capture=\"001_example.com_20260203_1602.png\""
        let secondMarker = "data-capture=\"002_example.com_20260203_1611.png\""
        let firstIndex = try XCTUnwrap(html.range(of: firstMarker)?.lowerBound)
        let secondIndex = try XCTUnwrap(html.range(of: secondMarker)?.lowerBound)
        XCTAssertLessThan(firstIndex, secondIndex)

        XCTAssertTrue(html.contains("screenshots/001_example.com_20260203_1602.png"))
    }
}
