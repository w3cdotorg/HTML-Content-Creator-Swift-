import Foundation

struct AppEnvironment {
    let paths: WorkspacePaths
    let store: LegacyFileStore
    let captureService: CaptureService
    let htmlGenerator: HTMLDeckGenerator
    let pdfExporter: PDFDeckExporter

    init(paths: WorkspacePaths = WorkspacePaths(), fileManager: FileManager = .default) {
        self.paths = paths
        let store = LegacyFileStore(paths: paths, fileManager: fileManager)
        let htmlGenerator = HTMLDeckGenerator(paths: paths, store: store, fileManager: fileManager)

        self.store = store
        self.captureService = CaptureService(paths: paths, store: store)
        self.htmlGenerator = htmlGenerator
        self.pdfExporter = PDFDeckExporter(paths: paths, htmlGenerator: htmlGenerator, fileManager: fileManager)
    }

    func bootstrap() async throws -> [String] {
        try paths.ensureBaseDirectories()
        let projects = try await store.listProjects()
        AppLogger.app.info("Workspace ready at \(paths.root.path, privacy: .public), projects=\(projects.count)")
        return projects
    }
}
