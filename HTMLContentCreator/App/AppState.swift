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

    enum HistoryState: Equatable {
        case idle
        case loading
        case loaded
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
    @Published private(set) var historyState: HistoryState = .idle
    @Published private(set) var historyItems: [CaptureHistoryItem] = []
    @Published private(set) var editorState: EditorState = .idle
    @Published private(set) var editorItems: [EditorItem] = []
    @Published private(set) var htmlGenerationState: HTMLGenerationState = .idle
    @Published private(set) var pdfExportState: PDFExportState = .idle
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewState: PreviewState?
    @Published private(set) var generatedHTMLURL: URL?
    @Published private(set) var generatedPDFURL: URL?
    @Published private(set) var feedback: InlineFeedback?

    let environment: AppEnvironment
    private var hasBootstrapped = false

    init(environment: AppEnvironment = AppEnvironment()) {
        self.environment = environment
    }

    var workspaceRootPath: String {
        environment.paths.root.path
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
        historyState = .loading

        do {
            historyItems = try await environment.store.readHistory(projectName: activeProject)
            historyState = .loaded
        } catch {
            historyItems = []
            historyState = .failed(error.localizedDescription)
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

    func previewHistoryItem(_ item: CaptureHistoryItem) {
        let image = NSImage(contentsOf: item.fileURL)
        previewImage = image
        previewState = PreviewState(
            filename: item.filename,
            fileURL: item.fileURL,
            sourceURL: nil,
            timestamp: item.modifiedAt
        )
    }

    func captureCurrentURL() async {
        guard startupState == .ready else {
            captureState = .failed("App is not ready yet.")
            setFeedback(kind: .error, "App is not ready yet.")
            return
        }

        captureState = .capturing

        do {
            let output = try await environment.captureService.capture(
                urlString: captureURLInput,
                projectName: activeProject
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

    func moveEditorItemUp(filename: String) {
        guard let index = editorItems.firstIndex(where: { $0.filename == filename }), index > 0 else {
            return
        }
        editorItems.swapAt(index, index - 1)
    }

    func moveEditorItemDown(filename: String) {
        guard
            let index = editorItems.firstIndex(where: { $0.filename == filename }),
            index < editorItems.count - 1
        else {
            return
        }
        editorItems.swapAt(index, index + 1)
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

        generatedHTMLURL = fm.fileExists(atPath: htmlURL.path) ? htmlURL : nil
        generatedPDFURL = fm.fileExists(atPath: pdfURL.path) ? pdfURL : nil
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
}
