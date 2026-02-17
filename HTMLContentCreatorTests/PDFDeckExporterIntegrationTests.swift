import Foundation
import PDFKit
import XCTest
@testable import HTMLContentCreator

final class PDFDeckExporterIntegrationTests: XCTestCase {
    private var tempRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("html-content-creator-pdf-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.removeItem(at: tempRoot)
        }
    }

    func testPDFExportUsesLandscapeA4AndOnePagePerSlidePlusTitle() async throws {
        let fixtureRoot = workspaceRoot().appendingPathComponent("old/screenshots", isDirectory: true)
        try XCTSkipIf(!fileManager.fileExists(atPath: fixtureRoot.path), "Missing old/ screenshot fixtures.")

        let paths = WorkspacePaths(root: tempRoot)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let store = LegacyFileStore(paths: paths, fileManager: fileManager)
        let htmlGenerator = HTMLDeckGenerator(paths: paths, store: store, fileManager: fileManager)
        let exporter = PDFDeckExporter(paths: paths, htmlGenerator: htmlGenerator, fileManager: fileManager)

        let firstCapture = CaptureRecord(
            filename: "001_simonwillison.net_20260203_1602.png",
            url: URL(string: "https://simonwillison.net/2026/Jan/30/a-programming-tool-for-the-arts/")!,
            capturedAt: Date(timeIntervalSince1970: 1_738_593_732)
        )
        let secondCapture = CaptureRecord(
            filename: "002_luiscardoso.dev_20260203_1611.png",
            url: URL(string: "https://www.luiscardoso.dev/blog/sandboxes-for-ai")!,
            capturedAt: Date(timeIntervalSince1970: 1_738_594_288)
        )

        _ = try await store.writeCaptureImage(
            projectName: WorkspacePaths.defaultProjectName,
            filename: firstCapture.filename,
            pngData: fixtureData(root: fixtureRoot, filename: firstCapture.filename)
        )
        _ = try await store.writeCaptureImage(
            projectName: WorkspacePaths.defaultProjectName,
            filename: secondCapture.filename,
            pngData: fixtureData(root: fixtureRoot, filename: secondCapture.filename)
        )

        try await store.appendCaptureLog(projectName: WorkspacePaths.defaultProjectName, capture: firstCapture)
        try await store.appendCaptureLog(projectName: WorkspacePaths.defaultProjectName, capture: secondCapture)
        try await store.saveEditorState(
            projectName: WorkspacePaths.defaultProjectName,
            order: [firstCapture.filename, secondCapture.filename],
            notesByFilename: [secondCapture.filename: "Note slide 2"]
        )

        let output = try await exporter.export(
            projectName: WorkspacePaths.defaultProjectName,
            requestedTitle: "Legacy PDF Rules"
        )
        XCTAssertTrue(fileManager.fileExists(atPath: output.fileURL.path))

        let document = try XCTUnwrap(PDFDocument(url: output.fileURL))
        XCTAssertEqual(document.pageCount, 3)

        for pageIndex in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: pageIndex))
            let mediaBox = page.bounds(for: .mediaBox)
            XCTAssertGreaterThan(mediaBox.width, mediaBox.height)
            XCTAssertEqual(mediaBox.width, 842, accuracy: 4)
            XCTAssertEqual(mediaBox.height, 595, accuracy: 4)
        }

        let firstSlidePage = try XCTUnwrap(document.page(at: 1))
        let secondSlidePage = try XCTUnwrap(document.page(at: 2))
        XCTAssertTrue(hasImageLinkAnnotation(firstSlidePage))
        XCTAssertTrue(hasImageLinkAnnotation(secondSlidePage))

        let titlePage = try XCTUnwrap(document.page(at: 0))
        XCTAssertFalse(hasImageLinkAnnotation(titlePage))
        XCTAssertTrue(hasLinkURL(firstSlidePage, containing: "simonwillison.net"))
        XCTAssertTrue(hasLinkURL(secondSlidePage, containing: "luiscardoso.dev"))
    }

    private func workspaceRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fixtureData(root: URL, filename: String) throws -> Data {
        let path = root.appendingPathComponent(filename)
        return try Data(contentsOf: path)
    }

    private func hasImageLinkAnnotation(_ page: PDFPage) -> Bool {
        page.annotations.contains { annotation in
            if let url = annotation.url {
                return !url.absoluteString.isEmpty
            }
            return false
        }
    }

    private func hasLinkURL(_ page: PDFPage, containing fragment: String) -> Bool {
        page.annotations.contains { annotation in
            guard let absolute = annotation.url?.absoluteString else { return false }
            return absolute.contains(fragment)
        }
    }
}
