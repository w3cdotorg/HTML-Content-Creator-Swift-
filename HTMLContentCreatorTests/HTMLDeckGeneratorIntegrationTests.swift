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

    func testGenerateHTMLFromOldFixturesAppliesOrderAndNotes() async throws {
        let sourceOldRoot = workspaceRoot().appendingPathComponent("old", isDirectory: true)
        try XCTSkipIf(!fileManager.fileExists(atPath: sourceOldRoot.path), "Missing old/ fixtures.")

        try copyFixture(
            from: sourceOldRoot.appendingPathComponent("screenshots/captures.md"),
            to: tempRoot.appendingPathComponent("screenshots/captures.md")
        )
        try copyFixture(
            from: sourceOldRoot.appendingPathComponent("order/default.md"),
            to: tempRoot.appendingPathComponent("order/default.md")
        )
        try copyFixture(
            from: sourceOldRoot.appendingPathComponent("notes/default/notes.md"),
            to: tempRoot.appendingPathComponent("notes/default/notes.md")
        )

        let paths = WorkspacePaths(root: tempRoot)
        let store = LegacyFileStore(paths: paths, fileManager: fileManager)
        let generator = HTMLDeckGenerator(paths: paths, store: store, fileManager: fileManager)

        let output = try await generator.generate(projectName: "default", requestedTitle: "Integration Deck")
        XCTAssertTrue(fileManager.fileExists(atPath: output.fileURL.path))
        XCTAssertEqual(output.title, "Integration Deck")

        let html = try String(contentsOf: output.fileURL, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Integration Deck</title>"))
        XCTAssertTrue(html.contains("id=\"editToggle\""))
        XCTAssertTrue(html.contains("id=\"exportPdf\""))
        XCTAssertTrue(html.contains("window.print()"))
        XCTAssertFalse(html.contains("phase 7"))
        XCTAssertTrue(html.contains("<aside class=\"note\">"))
        XCTAssertTrue(html.contains("socio-technique"))

        let first = "data-capture=\"001_simonwillison.net_20260203_1602.png\""
        let second = "data-capture=\"002_luiscardoso.dev_20260203_1611.png\""
        let firstIndex = try XCTUnwrap(html.range(of: first)?.lowerBound)
        let secondIndex = try XCTUnwrap(html.range(of: second)?.lowerBound)
        XCTAssertLessThan(firstIndex, secondIndex)

        XCTAssertTrue(html.contains("screenshots/001_simonwillison.net_20260203_1602.png"))
    }

    private func workspaceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func copyFixture(from source: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
    }
}
