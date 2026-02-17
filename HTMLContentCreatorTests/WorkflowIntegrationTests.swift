import Foundation
import XCTest
@testable import HTMLContentCreator

final class WorkflowIntegrationTests: XCTestCase {
    private var tempRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("html-content-creator-workflow-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.removeItem(at: tempRoot)
        }
    }

    func testProjectWorkflowWithHTMLGenerationAndDeletion() async throws {
        let paths = WorkspacePaths(root: tempRoot)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let store = LegacyFileStore(paths: paths, fileManager: fileManager)

        let project = try await store.ensureProject("Client A")
        XCTAssertEqual(project, "client-a")

        _ = try await store.writeProjectMetadata(
            projectName: project,
            metadata: ProjectMetadata(htmlTitle: "Client A Deck")
        )

        let firstCapture = CaptureRecord(
            filename: "001_example.com_20260217_0900.png",
            url: URL(string: "https://example.com/one")!,
            capturedAt: Date(timeIntervalSince1970: 1_739_769_000)
        )
        let secondCapture = CaptureRecord(
            filename: "002_example.com_20260217_0901.png",
            url: URL(string: "https://example.com/two")!,
            capturedAt: Date(timeIntervalSince1970: 1_739_769_060)
        )

        let png = try XCTUnwrap(Self.onePixelPNGData())
        _ = try await store.writeCaptureImage(projectName: project, filename: firstCapture.filename, pngData: png)
        _ = try await store.writeCaptureImage(projectName: project, filename: secondCapture.filename, pngData: png)
        try await store.appendCaptureLog(projectName: project, capture: firstCapture)
        try await store.appendCaptureLog(projectName: project, capture: secondCapture)

        let historyBefore = try await store.readHistory(projectName: project)
        XCTAssertEqual(historyBefore.count, 2)

        try await store.saveEditorState(
            projectName: project,
            order: [secondCapture.filename, firstCapture.filename],
            notesByFilename: [
                secondCapture.filename: "*bold* _italic_ note",
                firstCapture.filename: "- bullet item"
            ]
        )

        let htmlGenerator = HTMLDeckGenerator(paths: paths, store: store, fileManager: fileManager)
        let htmlOutput = try await htmlGenerator.generate(projectName: project, requestedTitle: nil)

        let html = try String(contentsOf: htmlOutput.fileURL, encoding: .utf8)
        XCTAssertTrue(html.contains("<title>Client A Deck</title>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<li>bullet item</li>"))

        let secondIndex = try XCTUnwrap(
            html.range(of: "data-capture=\"\(secondCapture.filename)\"")?.lowerBound
        )
        let firstIndex = try XCTUnwrap(
            html.range(of: "data-capture=\"\(firstCapture.filename)\"")?.lowerBound
        )
        XCTAssertLessThan(secondIndex, firstIndex)

        try await store.deleteCapture(projectName: project, filename: firstCapture.filename)
        let historyAfterDelete = try await store.readHistory(projectName: project)
        XCTAssertEqual(historyAfterDelete.count, 1)
        XCTAssertEqual(historyAfterDelete.first?.filename, secondCapture.filename)

        let capturesAfterDelete = await store.readCaptureLog(projectName: project)
        XCTAssertEqual(capturesAfterDelete.map(\.filename), [secondCapture.filename])
    }

    func testListProjectsIncludesDefaultAndCreatedProject() async throws {
        let paths = WorkspacePaths(root: tempRoot)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        let store = LegacyFileStore(paths: paths, fileManager: fileManager)

        _ = try await store.ensureProject("Client A")
        _ = try await store.ensureProject("Client B")

        let projects = try await store.listProjects()
        XCTAssertEqual(projects.first, WorkspacePaths.defaultProjectName)
        XCTAssertTrue(projects.contains("client-a"))
        XCTAssertTrue(projects.contains("client-b"))
    }

    private static func onePixelPNGData() -> Data? {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNgYGD4DwABBAEAgLvRWwAAAABJRU5ErkJggg==")
    }
}
