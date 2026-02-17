import Foundation
import XCTest
@testable import HTMLContentCreator

final class LegacyFileStoreCounterTests: XCTestCase {
    private var tempRoot: URL!
    private var paths: WorkspacePaths!
    private var store: LegacyFileStore!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("html-content-creator-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testNextCaptureIDUsesCounterWhenPresent() async throws {
        let counterURL = paths.projectCounterFile(projectName: WorkspacePaths.defaultProjectName)
        try "7".write(to: counterURL, atomically: true, encoding: .utf8)

        let next = try await store.nextCaptureID(projectName: WorkspacePaths.defaultProjectName)
        XCTAssertEqual(next, "007")

        let counterValue = try String(contentsOf: counterURL, encoding: .utf8)
        XCTAssertEqual(counterValue.trimmingCharacters(in: .whitespacesAndNewlines), "8")
    }

    func testNextCaptureIDFallsBackToPNGScanWhenCounterInvalid() async throws {
        let projectName = "default"
        let projectDir = paths.projectDirectory(projectName: projectName)

        let files = [
            "001_alpha.com_20260217_1000.png",
            "010_beta.com_20260217_1001.png",
            "not-an-id.png",
            "readme.txt"
        ]
        for file in files {
            let fileURL = projectDir.appendingPathComponent(file)
            try Data().write(to: fileURL)
        }

        let counterURL = paths.projectCounterFile(projectName: projectName)
        try "invalid".write(to: counterURL, atomically: true, encoding: .utf8)

        let next = try await store.nextCaptureID(projectName: projectName)
        XCTAssertEqual(next, "011")

        let counterValue = try String(contentsOf: counterURL, encoding: .utf8)
        XCTAssertEqual(counterValue.trimmingCharacters(in: .whitespacesAndNewlines), "12")
    }

    func testNextCaptureIDUsesProjectSpecificDirectory() async throws {
        let projectName = "client-a"
        let projectDir = paths.projectDirectory(projectName: projectName)
        try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try Data().write(to: projectDir.appendingPathComponent("005_site.com_20260217_1100.png"))

        let next = try await store.nextCaptureID(projectName: projectName)
        XCTAssertEqual(next, "006")
    }
}
