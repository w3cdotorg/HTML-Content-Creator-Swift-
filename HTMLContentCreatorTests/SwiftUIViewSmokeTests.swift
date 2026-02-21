import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import HTMLContentCreator

@MainActor
final class SwiftUIViewSmokeTests: XCTestCase {
    private var tempRoot: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("html-content-creator-swiftui-smoke-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, fileManager.fileExists(atPath: tempRoot.path) {
            try fileManager.removeItem(at: tempRoot)
        }
    }

    func testProjectsViewRenders() async throws {
        let state = try await makeBootstrappedState()
        let image = render(ProjectsView().environmentObject(state))
        XCTAssertNotNil(image)
        XCTAssertEqual(Int(image?.size.width ?? 0), 1280)
        XCTAssertEqual(Int(image?.size.height ?? 0), 900)
    }

    func testCaptureViewRenders() async throws {
        let state = try await makeBootstrappedState()
        let image = render(CaptureView().environmentObject(state))
        XCTAssertNotNil(image)
    }

    func testExploreAndEditViewRendersWithSeededCapture() async throws {
        let state = try await makeBootstrappedState(seedCapture: true)
        let image = render(ExploreAndEditView().environmentObject(state))
        XCTAssertNotNil(image)
    }

    func testShareViewRendersWithPreflightData() async throws {
        let state = try await makeBootstrappedState(seedCapture: true)
        let image = render(ShareView().environmentObject(state))
        XCTAssertNotNil(image)
    }

    func testContentViewRenders() async throws {
        let state = try await makeBootstrappedState(seedCapture: true)
        let image = render(ContentView().environmentObject(state))
        XCTAssertNotNil(image)
    }

    private func makeBootstrappedState(seedCapture: Bool = false) async throws -> AppState {
        let paths = WorkspacePaths(root: tempRoot)
        let environment = AppEnvironment(paths: paths, fileManager: fileManager)
        let state = AppState(environment: environment)

        await state.bootstrapIfNeeded()
        XCTAssertEqual(state.startupState, .ready)

        guard seedCapture else {
            return state
        }

        let filename = "001_example.com_20260221_1000.png"
        let capture = CaptureRecord(
            filename: filename,
            url: URL(string: "https://example.com")!,
            capturedAt: Date(timeIntervalSince1970: 1_771_670_800)
        )

        let pngData = try XCTUnwrap(samplePNGData(fill: .systemTeal))
        _ = try await environment.store.writeCaptureImage(
            projectName: WorkspacePaths.defaultProjectName,
            filename: filename,
            pngData: pngData
        )
        try await environment.store.appendCaptureLog(projectName: WorkspacePaths.defaultProjectName, capture: capture)

        await state.refreshHistory()
        await state.refreshEditorState()
        return state
    }

    private func render<V: View>(_ view: V, size: CGSize = CGSize(width: 1280, height: 900)) -> NSImage? {
        let content = view
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1
        return renderer.nsImage
    }

    private func samplePNGData(fill: NSColor) -> Data? {
        let width = Int(WebKitCaptureEngine.viewport.width)
        let height = Int(WebKitCaptureEngine.viewport.height)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = context
        fill.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
