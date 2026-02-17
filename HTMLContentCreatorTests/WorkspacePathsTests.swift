import Foundation
import XCTest
@testable import HTMLContentCreator

final class WorkspacePathsTests: XCTestCase {
    func testSanitizeProjectNameRules() {
        XCTAssertEqual(WorkspacePaths.sanitizeProjectName(nil), WorkspacePaths.defaultProjectName)
        XCTAssertEqual(WorkspacePaths.sanitizeProjectName(""), WorkspacePaths.defaultProjectName)
        XCTAssertEqual(WorkspacePaths.sanitizeProjectName("   "), WorkspacePaths.defaultProjectName)
        XCTAssertEqual(WorkspacePaths.sanitizeProjectName("Client Project A"), "client-project-a")
        XCTAssertEqual(WorkspacePaths.sanitizeProjectName("My_Project.01"), "my_project.01")
        XCTAssertEqual(WorkspacePaths.sanitizeProjectName("../Bad@Name"), "..badname")
    }

    func testProjectDirectoryUsesDefaultAndCustomLocations() {
        let root = URL(fileURLWithPath: "/tmp/html-content-creator-tests", isDirectory: true)
        let paths = WorkspacePaths(root: root)

        XCTAssertEqual(paths.projectDirectory(projectName: nil), root.appendingPathComponent("screenshots", isDirectory: true))
        XCTAssertEqual(
            paths.projectDirectory(projectName: "Client A"),
            root.appendingPathComponent("screenshots/client-a", isDirectory: true)
        )
    }
}
