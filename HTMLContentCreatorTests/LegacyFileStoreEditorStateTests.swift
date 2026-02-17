import Foundation
import XCTest
@testable import HTMLContentCreator

final class LegacyFileStoreEditorStateTests: XCTestCase {
    private var tempRoot: URL!
    private var paths: WorkspacePaths!
    private var store: LegacyFileStore!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("html-content-creator-editor-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        paths = WorkspacePaths(root: tempRoot)
        try paths.ensureBaseDirectories(fileManager: fileManager)
        store = LegacyFileStore(paths: paths, fileManager: fileManager)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.removeItem(at: tempRoot)
        }
    }

    func testSaveEditorStateRoundTripsOrderAndNotes() async throws {
        let project = "client-a"

        try await store.saveEditorState(
            projectName: project,
            order: [
                "002_two.png",
                "invalid/name.png",
                "001_one.png"
            ],
            notesByFilename: [
                "001_one.png": " first note ",
                "bad/name.png": "ignored",
                "002_two.png": "_italic_ note"
            ]
        )

        let order = await store.readOrder(projectName: project)
        XCTAssertEqual(order, ["002_two.png", "001_one.png"])

        let notes = await store.readNotes(projectName: project)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes["001_one.png"], "first note")
        XCTAssertEqual(notes["002_two.png"], "_italic_ note")
    }

    func testDeleteCaptureAlsoRemovesCaptureFromMarkdown() async throws {
        let project = "client-b"
        let filename = "001_example.com_20260217_1100.png"

        let png = try XCTUnwrap(Self.onePixelPNGData())
        _ = try await store.writeCaptureImage(projectName: project, filename: filename, pngData: png)
        try await store.appendCaptureLog(
            projectName: project,
            capture: CaptureRecord(
                filename: filename,
                url: URL(string: "https://example.com/delete")!,
                capturedAt: Date(timeIntervalSince1970: 1_739_769_600)
            )
        )

        var before = await store.readCaptureLog(projectName: project)
        XCTAssertEqual(before.map(\.filename), [filename])

        try await store.deleteCapture(projectName: project, filename: filename)
        before = await store.readCaptureLog(projectName: project)
        XCTAssertTrue(before.isEmpty)
    }

    private static func onePixelPNGData() -> Data? {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNgYGD4DwABBAEAgLvRWwAAAABJRU5ErkJggg==")
    }
}
