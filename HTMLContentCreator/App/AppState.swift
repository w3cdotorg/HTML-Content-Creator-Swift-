import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum StartupState: Equatable {
        case idle
        case starting
        case ready
        case failed(String)
    }

    enum CaptureState: Equatable {
        case idle
        case capturing
        case succeeded(String)
        case failed(String)
    }

    enum BatchCaptureState: Equatable {
        case idle
        case ready(sourceName: String, totalURLs: Int, ignoredLines: Int, duplicateURLs: Int)
        case running(current: Int, total: Int, succeeded: Int, failed: Int, currentURL: String)
        case completed(sourceName: String, total: Int, succeeded: Int, failed: Int)
        case failed(String)
    }

    enum EditorState: Equatable {
        case idle
        case loading
        case ready
        case saving
        case failed(String)
    }

    enum HTMLGenerationState: Equatable {
        case idle
        case generating
        case succeeded(String)
        case failed(String)
    }

    enum PDFExportState: Equatable {
        case idle
        case exporting
        case succeeded(String)
        case failed(String)
    }

    struct InlineFeedback: Identifiable, Equatable {
        enum Kind: Equatable {
            case success
            case error
            case info
        }

        let id = UUID()
        let kind: Kind
        let message: String
    }

    struct PreviewState: Equatable {
        let filename: String
        let fileURL: URL
        let sourceURL: URL?
        let timestamp: Date?
    }

    struct EditorItem: Identifiable, Equatable {
        var id: String { filename }

        let filename: String
        let sourceURL: URL
        let capturedAt: Date?
        var note: String
    }

    @Published private(set) var startupState: StartupState = .idle
    @Published private(set) var projects: [String] = []
    @Published var activeProject: String = WorkspacePaths.defaultProjectName
    @Published var newProjectInput: String = ""
    @Published var projectTitleInput: String = ""
    @Published var captureURLInput: String = "https://example.com"
    @Published private(set) var captureState: CaptureState = .idle
    @Published private(set) var batchCaptureState: BatchCaptureState = .idle
    @Published private(set) var batchCaptureURLs: [String] = []
    @Published private(set) var batchCaptureSourceFileName: String?
    @Published private(set) var historyItems: [CaptureHistoryItem] = []
    @Published private(set) var editorState: EditorState = .idle
    @Published private(set) var editorItems: [EditorItem] = []
    @Published private(set) var htmlGenerationState: HTMLGenerationState = .idle
    @Published private(set) var pdfExportState: PDFExportState = .idle
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewState: PreviewState?
    @Published private(set) var generatedHTMLURL: URL?
    @Published private(set) var generatedPDFURL: URL?
    @Published private(set) var lastHTMLGeneratedAt: Date?
    @Published private(set) var lastPDFGeneratedAt: Date?
    @Published private(set) var feedback: InlineFeedback?
    @Published var captureContentBlockingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(captureContentBlockingEnabled, forKey: Self.captureContentBlockingDefaultsKey)
        }
    }

    let environment: AppEnvironment
    private var hasBootstrapped = false
    private static let captureContentBlockingDefaultsKey = "capture.contentBlockingEnabled"

    init(environment: AppEnvironment = AppEnvironment()) {
        self.environment = environment
        if UserDefaults.standard.object(forKey: Self.captureContentBlockingDefaultsKey) == nil {
            self.captureContentBlockingEnabled = true
        } else {
            self.captureContentBlockingEnabled = UserDefaults.standard.bool(forKey: Self.captureContentBlockingDefaultsKey)
        }
    }

    var workspaceRootPath: String {
        environment.paths.root.path
    }

    var isBatchCaptureRunning: Bool {
        if case .running = batchCaptureState {
            return true
        }
        return false
    }

    var canStartBatchCapture: Bool {
        startupState == .ready &&
            !batchCaptureURLs.isEmpty &&
            !isBatchCaptureRunning &&
            captureState != .capturing
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        startupState = .starting

        do {
            projects = try await environment.bootstrap()
            if let first = projects.first {
                activeProject = first
            }
            await refreshActiveProjectContext()
            startupState = .ready
        } catch {
            let wrappedError = AppError.bootstrapFailed(underlying: error)
            startupState = .failed(wrappedError.localizedDescription)
            AppLogger.app.error("Bootstrap failed: \(wrappedError.localizedDescription, privacy: .public)")
            setFeedback(kind: .error, wrappedError.localizedDescription)
        }
    }

    func selectProject(_ candidate: String) async {
        let sanitized = WorkspacePaths.sanitizeProjectName(candidate)
        if sanitized != activeProject {
            activeProject = sanitized
        }
        await refreshActiveProjectContext()
    }

    func createProjectFromInput() async {
        let candidate = WorkspacePaths.sanitizeProjectName(newProjectInput)

        do {
            let created = try await environment.store.ensureProject(candidate)
            newProjectInput = ""
            if !projects.contains(created) {
                projects.append(created)
                projects = sortProjects(projects)
            }
            activeProject = created
            await refreshActiveProjectContext()
            setFeedback(kind: .success, "Project created: \(created)")
        } catch {
            setFeedback(kind: .error, error.localizedDescription)
        }
    }

    func saveProjectTitle() async {
        let title = projectTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadata = ProjectMetadata(htmlTitle: title.isEmpty ? nil : title)

        do {
            _ = try await environment.store.writeProjectMetadata(
                projectName: activeProject,
                metadata: metadata
            )
            if title.isEmpty {
                setFeedback(kind: .success, "HTML title cleared.")
            } else {
                setFeedback(kind: .success, "HTML title saved.")
            }
        } catch {
            setFeedback(kind: .error, error.localizedDescription)
        }
    }

    func refreshHistory() async {
        do {
            historyItems = try await environment.store.readHistory(projectName: activeProject)
        } catch {
            historyItems = []
            setFeedback(kind: .error, "History error: \(error.localizedDescription)")
        }
    }

    func deleteHistoryItem(_ item: CaptureHistoryItem) async {
        do {
            try await environment.store.deleteCapture(projectName: activeProject, filename: item.filename)
            if previewState?.filename == item.filename {
                previewState = nil
                previewImage = nil
            }
            await refreshHistory()
            await refreshEditorState()
            setFeedback(kind: .success, "Capture deleted: \(item.filename)")
        } catch {
            setFeedback(kind: .error, error.localizedDescription)
        }
    }

    func captureCurrentURL() async {
        guard startupState == .ready else {
            captureState = .failed("App is not ready yet.")
            setFeedback(kind: .error, "App is not ready yet.")
            return
        }

        guard !isBatchCaptureRunning else {
            captureState = .failed("Batch capture is currently running.")
            setFeedback(kind: .error, "Batch capture is currently running.")
            return
        }

        captureState = .capturing

        do {
            let output = try await environment.captureService.capture(
                urlString: captureURLInput,
                projectName: activeProject,
                contentBlockingEnabled: captureContentBlockingEnabled
            )
            captureState = .succeeded(output.filename)

            if !projects.contains(output.projectName) {
                projects.append(output.projectName)
                projects = sortProjects(projects)
            }
            activeProject = output.projectName

            previewState = PreviewState(
                filename: output.filename,
                fileURL: output.fileURL,
                sourceURL: output.sourceURL,
                timestamp: output.capturedAt
            )
            previewImage = NSImage(contentsOf: output.fileURL)

            await refreshHistory()
            await refreshEditorState()
            await refreshGeneratedOutputStatus()
            setFeedback(kind: .success, "Capture saved successfully (\(output.projectName)).")
        } catch {
            captureState = .failed(error.localizedDescription)
            AppLogger.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            setFeedback(kind: .error, error.localizedDescription)
        }
    }

    func importBatchCaptureList(from fileURL: URL) async {
        guard !isBatchCaptureRunning else {
            setFeedback(kind: .info, "Batch capture is already running.")
            return
        }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try BatchCaptureURLListParser.parseFile(at: fileURL)
            }.value

            guard !result.urls.isEmpty else {
                throw AppError.invalidInput("No valid http/https URLs found in \(fileURL.lastPathComponent).")
            }

            batchCaptureURLs = result.urls
            batchCaptureSourceFileName = fileURL.lastPathComponent
            batchCaptureState = .ready(
                sourceName: fileURL.lastPathComponent,
                totalURLs: result.urls.count,
                ignoredLines: result.ignoredLineCount,
                duplicateURLs: result.duplicateCount
            )

            let skipped = result.ignoredLineCount + result.duplicateCount
            if skipped > 0 {
                setFeedback(
                    kind: .info,
                    "Loaded \(result.urls.count) URL(s) from \(fileURL.lastPathComponent). Skipped \(skipped) line(s)."
                )
            } else {
                setFeedback(kind: .success, "Loaded \(result.urls.count) URL(s) from \(fileURL.lastPathComponent).")
            }
        } catch {
            batchCaptureState = .failed(error.localizedDescription)
            setFeedback(kind: .error, error.localizedDescription)
        }
    }

    func clearBatchCaptureList() {
        guard !isBatchCaptureRunning else { return }
        batchCaptureURLs = []
        batchCaptureSourceFileName = nil
        batchCaptureState = .idle
    }

    func startBatchCapture() async {
        guard startupState == .ready else {
            setFeedback(kind: .error, "App is not ready yet.")
            return
        }

        guard !batchCaptureURLs.isEmpty else {
            setFeedback(kind: .error, "Import a .txt or .csv URL list first.")
            return
        }

        guard !isBatchCaptureRunning else { return }

        let urls = batchCaptureURLs
        let sourceName = batchCaptureSourceFileName ?? "URL list"
        let targetProject = activeProject

        var succeeded = 0
        var failed = 0
        var firstError: String?
        var lastOutput: CaptureOutput?

        captureState = .capturing
        batchCaptureState = .running(current: 0, total: urls.count, succeeded: 0, failed: 0, currentURL: "")

        for (index, url) in urls.enumerated() {
            let current = index + 1
            batchCaptureState = .running(
                current: current,
                total: urls.count,
                succeeded: succeeded,
                failed: failed,
                currentURL: url
            )

            do {
                let output = try await environment.captureService.capture(
                    urlString: url,
                    projectName: targetProject,
                    contentBlockingEnabled: captureContentBlockingEnabled
                )
                succeeded += 1
                lastOutput = output

                if !projects.contains(output.projectName) {
                    projects.append(output.projectName)
                    projects = sortProjects(projects)
                }
                activeProject = output.projectName

                previewState = PreviewState(
                    filename: output.filename,
                    fileURL: output.fileURL,
                    sourceURL: output.sourceURL,
                    timestamp: output.capturedAt
                )
                previewImage = NSImage(contentsOf: output.fileURL)
            } catch {
                failed += 1
                if firstError == nil {
                    firstError = error.localizedDescription
                }
                AppLogger.capture.error(
                    "Batch capture failed for URL \(url, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        await refreshHistory()
        await refreshEditorState()
        await refreshGeneratedOutputStatus()

        batchCaptureState = .completed(sourceName: sourceName, total: urls.count, succeeded: succeeded, failed: failed)
        if let lastOutput {
            captureState = .succeeded(lastOutput.filename)
        } else if let firstError {
            captureState = .failed(firstError)
        } else {
            captureState = .idle
        }

        if failed == 0 {
            setFeedback(kind: .success, "Batch capture completed: \(succeeded)/\(urls.count) URL(s) succeeded.")
        } else {
            let firstErrorSuffix = firstError.map { " First error: \($0)" } ?? ""
            setFeedback(
                kind: .info,
                "Batch capture completed: \(succeeded) succeeded, \(failed) failed.\(firstErrorSuffix)"
            )
        }
    }

    func openGeneratedHTML() {
        guard let url = generatedHTMLURL else {
            setFeedback(kind: .info, "No generated HTML file for this project yet.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openGeneratedPDF() {
        guard let url = generatedPDFURL else {
            setFeedback(kind: .info, "No generated PDF file for this project yet. Use Export PDF first.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func generateHTMLForActiveProject() async {
        guard startupState == .ready else {
            let message = "App is not ready yet."
            htmlGenerationState = .failed(message)
            setFeedback(kind: .error, message)
            return
        }

        guard htmlGenerationState != .generating else { return }
        htmlGenerationState = .generating

        let trimmedTitle = projectTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle

        do {
            let output = try await environment.htmlGenerator.generate(
                projectName: activeProject,
                requestedTitle: requestedTitle
            )

            generatedHTMLURL = output.fileURL
            htmlGenerationState = .succeeded(output.fileURL.lastPathComponent)
            await refreshGeneratedOutputStatus()
            setFeedback(kind: .success, "HTML generated: \(output.fileURL.lastPathComponent)")
        } catch {
            htmlGenerationState = .failed(error.localizedDescription)
            setFeedback(kind: .error, "HTML generation error: \(error.localizedDescription)")
        }
    }

    func exportPDFForActiveProject() async {
        guard startupState == .ready else {
            let message = "App is not ready yet."
            pdfExportState = .failed(message)
            setFeedback(kind: .error, message)
            return
        }

        guard pdfExportState != .exporting else { return }
        pdfExportState = .exporting

        let trimmedTitle = projectTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle

        do {
            let output = try await environment.pdfExporter.export(
                projectName: activeProject,
                requestedTitle: requestedTitle
            )

            generatedHTMLURL = output.htmlFileURL
            generatedPDFURL = output.fileURL
            htmlGenerationState = .succeeded(output.htmlFileURL.lastPathComponent)
            pdfExportState = .succeeded(output.fileURL.lastPathComponent)

            await refreshGeneratedOutputStatus()
            NSWorkspace.shared.open(output.fileURL)
            setFeedback(kind: .success, "PDF exported: \(output.fileURL.lastPathComponent)")
        } catch {
            pdfExportState = .failed(error.localizedDescription)
            setFeedback(kind: .error, "PDF export error: \(error.localizedDescription)")
        }
    }

    func notifyInfo(_ message: String) {
        setFeedback(kind: .info, message)
    }

    func clearFeedback() {
        feedback = nil
    }

    func refreshEditorState() async {
        editorState = .loading

        let captures = await environment.store.readCaptureLog(projectName: activeProject)
        let notesByFilename = await environment.store.readNotes(projectName: activeProject)
        let order = await environment.store.readOrder(projectName: activeProject)

        let ordered = applySavedOrder(captures: captures, order: order)
        editorItems = ordered.map { capture in
            EditorItem(
                filename: capture.filename,
                sourceURL: capture.url,
                capturedAt: capture.capturedAt,
                note: notesByFilename[capture.filename] ?? ""
            )
        }

        editorState = .ready
    }

    func updateEditorNote(filename: String, note: String) {
        guard let index = editorItems.firstIndex(where: { $0.filename == filename }) else { return }
        editorItems[index].note = note
    }

    func moveEditorItems(from source: IndexSet, to destination: Int) {
        editorItems.move(fromOffsets: source, toOffset: destination)
    }

    func editorImageURL(filename: String) -> URL {
        environment.paths
            .projectDirectory(projectName: activeProject)
            .appendingPathComponent(filename)
    }

    func saveEditorState() async {
        guard editorState != .saving else { return }
        editorState = .saving

        let order = editorItems.map(\.filename)
        let notes = Dictionary(
            uniqueKeysWithValues: editorItems.compactMap { item -> (String, String)? in
                let trimmed = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (item.filename, trimmed)
            }
        )

        do {
            try await environment.store.saveEditorState(
                projectName: activeProject,
                order: order,
                notesByFilename: notes
            )
            editorState = .ready
            setFeedback(kind: .success, "Editor state saved.")
        } catch {
            editorState = .failed(error.localizedDescription)
            setFeedback(kind: .error, "Editor save error: \(error.localizedDescription)")
        }
    }

    func domainFromFilename(_ filename: String) -> String {
        let withoutSuffix = filename.replacingOccurrences(
            of: #"_\d{8}_\d{4}\.png$"#,
            with: "",
            options: .regularExpression
        )
        return withoutSuffix.replacingOccurrences(
            of: #"^\d+_"#,
            with: "",
            options: .regularExpression
        )
    }

    func captureIDFromFilename(_ filename: String) -> String {
        guard let range = filename.range(of: #"^\d+"#, options: .regularExpression) else {
            return "-"
        }
        return String(filename[range])
    }

    private func refreshActiveProjectContext() async {
        htmlGenerationState = .idle
        pdfExportState = .idle
        await loadProjectMetadata()
        await refreshGeneratedOutputStatus()
        await refreshHistory()
        await refreshEditorState()
    }

    private func loadProjectMetadata() async {
        let metadata = await environment.store.readProjectMetadata(projectName: activeProject)
        projectTitleInput = metadata.htmlTitle ?? ""
    }

    private func refreshGeneratedOutputStatus() async {
        let htmlURL = environment.paths.generatedHTMLFile(projectName: activeProject)
        let pdfURL = environment.paths.generatedPDFFile(projectName: activeProject)
        let fm = FileManager.default

        if fm.fileExists(atPath: htmlURL.path) {
            generatedHTMLURL = htmlURL
            lastHTMLGeneratedAt = modificationDate(for: htmlURL)
        } else {
            generatedHTMLURL = nil
            lastHTMLGeneratedAt = nil
        }

        if fm.fileExists(atPath: pdfURL.path) {
            generatedPDFURL = pdfURL
            lastPDFGeneratedAt = modificationDate(for: pdfURL)
        } else {
            generatedPDFURL = nil
            lastPDFGeneratedAt = nil
        }
    }

    private func sortProjects(_ values: [String]) -> [String] {
        let deduplicated = Set(values)
        let sortedSecondary = deduplicated
            .filter { $0 != WorkspacePaths.defaultProjectName }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return [WorkspacePaths.defaultProjectName] + sortedSecondary
    }

    private func setFeedback(kind: InlineFeedback.Kind, _ message: String) {
        feedback = InlineFeedback(kind: kind, message: message)
    }

    private func applySavedOrder(captures: [CaptureRecord], order: [String]) -> [CaptureRecord] {
        if order.isEmpty { return captures }

        var byFilename: [String: CaptureRecord] = [:]
        byFilename.reserveCapacity(captures.count)
        for capture in captures {
            byFilename[capture.filename] = capture
        }

        var ordered: [CaptureRecord] = []
        ordered.reserveCapacity(captures.count)

        for filename in order {
            if let capture = byFilename[filename] {
                ordered.append(capture)
            }
        }

        let alreadyAdded = Set(ordered.map(\.filename))
        for capture in captures where !alreadyAdded.contains(capture.filename) {
            ordered.append(capture)
        }

        return ordered
    }

    private func modificationDate(for url: URL) -> Date? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        return try? url.resourceValues(forKeys: keys).contentModificationDate
    }
}
