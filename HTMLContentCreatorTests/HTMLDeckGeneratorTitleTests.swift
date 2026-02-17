import Foundation
import XCTest
@testable import HTMLContentCreator

final class HTMLDeckGeneratorTitleTests: XCTestCase {
    private var tempRoot: URL!
    private var paths: WorkspacePaths!
    private var store: LegacyFileStore!
    private var generator: HTMLDeckGenerator!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("html-content-creator-title-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        paths = WorkspacePaths(root: tempRoot)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        store = LegacyFileStore(paths: paths, fileManager: fileManager)
        generator = HTMLDeckGenerator(paths: paths, store: store, fileManager: fileManager)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.removeItem(at: tempRoot)
        }
    }

    func testGenerateUsesRequestedTitleAndPersistsMetadata() async throws {
        let project = "client-a"
        try await seedCapture(projectName: project, filename: "001_example.com_20260217_1000.png")

        let output = try await generator.generate(projectName: project, requestedTitle: "Deck Requested")
        XCTAssertEqual(output.title, "Deck Requested")

        let meta = await store.readProjectMetadata(projectName: project)
        XCTAssertEqual(meta.htmlTitle, "Deck Requested")
    }

    func testGenerateFallsBackToStoredMetadataTitle() async throws {
        let project = "client-b"
        try await seedCapture(projectName: project, filename: "001_example.com_20260217_1010.png")
        _ = try await store.writeProjectMetadata(
            projectName: project,
            metadata: ProjectMetadata(htmlTitle: "Stored Deck")
        )

        let output = try await generator.generate(projectName: project, requestedTitle: nil)
        XCTAssertEqual(output.title, "Stored Deck")
    }

    func testGenerateFallsBackToDefaultTitleWhenNoMetadata() async throws {
        let project = "client-c"
        try await seedCapture(projectName: project, filename: "001_example.com_20260217_1020.png")

        let output = try await generator.generate(projectName: project, requestedTitle: nil)
        XCTAssertEqual(output.title, "Captures - client-c")
    }

    private func seedCapture(projectName: String, filename: String) async throws {
        let capture = CaptureRecord(
            filename: filename,
            url: URL(string: "https://example.com")!,
            capturedAt: Date(timeIntervalSince1970: 1_739_769_000)
        )
        try await store.appendCaptureLog(projectName: projectName, capture: capture)
    }
}
