import Foundation

struct PDFDeckExporter {
    private let paths: WorkspacePaths
    private let htmlGenerator: HTMLDeckGenerator
    private let fileManager: FileManager

    init(
        paths: WorkspacePaths,
        htmlGenerator: HTMLDeckGenerator,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.htmlGenerator = htmlGenerator
        self.fileManager = fileManager
    }

    func export(projectName rawProjectName: String, requestedTitle: String?) async throws -> PDFExportOutput {
        let htmlOutput = try await htmlGenerator.generate(
            projectName: rawProjectName,
            requestedTitle: requestedTitle
        )

        let outputURL = paths.generatedPDFFile(projectName: htmlOutput.projectName)
        do {
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            throw AppError.fileSystemOperationFailed(
                operation: "createDirectory",
                path: outputURL.deletingLastPathComponent(),
                underlying: error
            )
        }

        try await WebKitPDFExportEngine.export(
            htmlFileURL: htmlOutput.fileURL,
            readAccessURL: paths.root,
            outputPDFURL: outputURL,
            title: htmlOutput.title
        )

        return PDFExportOutput(
            projectName: htmlOutput.projectName,
            htmlFileURL: htmlOutput.fileURL,
            fileURL: outputURL,
            title: htmlOutput.title
        )
    }
}
