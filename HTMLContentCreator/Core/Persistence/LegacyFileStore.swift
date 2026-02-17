import Foundation

actor LegacyFileStore {
    private let paths: WorkspacePaths
    private let fileManager: FileManager

    init(paths: WorkspacePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    func ensureProject(_ rawName: String?) throws -> String {
        let projectName = WorkspacePaths.sanitizeProjectName(rawName)
        let directory = paths.projectDirectory(projectName: projectName)
        try createDirectory(at: directory)
        return projectName
    }

    func listProjects() throws -> [String] {
        try paths.ensureBaseDirectories(fileManager: fileManager)

        let entries = try fileManager.contentsOfDirectory(
            at: paths.screenshotsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var names: Set<String> = [WorkspacePaths.defaultProjectName]
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let sanitized = WorkspacePaths.sanitizeProjectName(entry.lastPathComponent)
            if sanitized != WorkspacePaths.defaultProjectName {
                names.insert(sanitized)
            }
        }

        let sortedSecondary = names
            .filter { $0 != WorkspacePaths.defaultProjectName }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return [WorkspacePaths.defaultProjectName] + sortedSecondary
    }

    func readProjectMetadata(projectName rawName: String?) -> ProjectMetadata {
        let projectName = WorkspacePaths.sanitizeProjectName(rawName)
        let fileURL = paths.projectMetaFile(projectName: projectName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return ProjectMetadata(htmlTitle: nil)
        }
        guard let decoded = try? JSONDecoder().decode(ProjectMetadata.self, from: data) else {
            return ProjectMetadata(htmlTitle: nil)
        }
        return decoded
    }

    @discardableResult
    func writeProjectMetadata(projectName rawName: String?, metadata: ProjectMetadata) throws -> ProjectMetadata {
        let projectName = try ensureProject(rawName)
        let fileURL = paths.projectMetaFile(projectName: projectName)
        let data = try JSONEncoder().encode(metadata)
        try write(data: data, to: fileURL)
        return metadata
    }

    func readCaptureLog(projectName rawName: String?) -> [CaptureRecord] {
        let projectName = WorkspacePaths.sanitizeProjectName(rawName)
        let fileURL = paths.projectCaptureLogFile(projectName: projectName)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        return LegacyMarkdownCodec.parseCaptureLog(text)
    }

    func writeCaptureImage(projectName rawName: String?, filename: String, pngData: Data) throws -> URL {
        guard isSafeCaptureFilename(filename) else {
            throw AppError.invalidInput("Invalid capture filename: \(filename)")
        }

        let projectName = try ensureProject(rawName)
        let fileURL = paths.projectDirectory(projectName: projectName).appendingPathComponent(filename)
        try write(data: pngData, to: fileURL)
        return fileURL
    }

    func appendCaptureLog(projectName rawName: String?, capture: CaptureRecord) throws {
        let projectName = try ensureProject(rawName)
        let fileURL = paths.projectCaptureLogFile(projectName: projectName)
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "# Captures\n\n"
        let updated = LegacyMarkdownCodec.appendCapture(capture, to: existing)
        try write(text: updated, to: fileURL)
    }

    func removeCaptureFromLog(projectName rawName: String?, filename: String) throws {
        let projectName = WorkspacePaths.sanitizeProjectName(rawName)
        let fileURL = paths.projectCaptureLogFile(projectName: projectName)
        guard let existing = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return
        }
        let updated = LegacyMarkdownCodec.removeCapture(named: filename, from: existing)
        try write(text: updated, to: fileURL)
    }

    func readNotes(projectName rawName: String?) -> [String: String] {
        let projectName = WorkspacePaths.sanitizeProjectName(rawName)
        let fileURL = paths.projectNotesFile(projectName: projectName)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return [:]
        }
        return LegacyMarkdownCodec.parseNotes(text)
    }

    func writeNotes(projectName rawName: String?, notesByFilename: [String: String]) throws {
        let projectName = WorkspacePaths.sanitizeProjectName(rawName)
        let fileURL = paths.projectNotesFile(projectName: projectName)
        let text = LegacyMarkdownCodec.serializeNotes(notesByFilename)
        try write(text: text, to: fileURL)
    }

    func readOrder(projectName rawName: String?) -> [String] {
        let projectName = WorkspacePaths.sanitizeProjectName(rawName)
        let fileURL = paths.projectOrderFile(projectName: projectName)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        return LegacyMarkdownCodec.parseOrder(text)
    }

    func writeOrder(projectName rawName: String?, filenames: [String]) throws {
        let projectName = WorkspacePaths.sanitizeProjectName(rawName)
        let fileURL = paths.projectOrderFile(projectName: projectName)
        let text = LegacyMarkdownCodec.serializeOrder(filenames)
        try write(text: text, to: fileURL)
    }

    func saveEditorState(projectName rawName: String?, order: [String], notesByFilename: [String: String]) throws {
        try writeOrder(projectName: rawName, filenames: order)
        try writeNotes(projectName: rawName, notesByFilename: notesByFilename)
    }

    func readHistory(projectName rawName: String?) throws -> [CaptureHistoryItem] {
        let projectName = try ensureProject(rawName)
        let projectDirectory = paths.projectDirectory(projectName: projectName)
        let fileURLs = try fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var history: [CaptureHistoryItem] = []
        for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "png" {
            let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let modifiedAt = values.contentModificationDate ?? .distantPast
            history.append(
                CaptureHistoryItem(
                    filename: fileURL.lastPathComponent,
                    fileURL: fileURL,
                    modifiedAt: modifiedAt
                )
            )
        }

        history.sort { $0.modifiedAt > $1.modifiedAt }
        return history
    }

    func deleteCapture(projectName rawName: String?, filename: String) throws {
        guard isSafeCaptureFilename(filename) else {
            throw AppError.invalidInput("Invalid capture filename: \(filename)")
        }

        let projectName = WorkspacePaths.sanitizeProjectName(rawName)
        let projectDirectory = paths.projectDirectory(projectName: projectName)
        let fileURL = projectDirectory.appendingPathComponent(filename)

        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw AppError.fileSystemOperationFailed(
                operation: "removeItem",
                path: fileURL,
                underlying: error
            )
        }

        try removeCaptureFromLog(projectName: projectName, filename: filename)
    }

    func nextCaptureID(projectName rawName: String?) throws -> String {
        let projectName = try ensureProject(rawName)
        let counterFile = paths.projectCounterFile(projectName: projectName)

        if let raw = try? String(contentsOf: counterFile, encoding: .utf8),
           let current = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           current >= 1 {
            let next = current + 1
            try write(text: "\(next)", to: counterFile)
            return formatCaptureID(current)
        }

        let next = try computeNextIDFromProjectFiles(projectName: projectName)
        try write(text: "\(next + 1)", to: counterFile)
        return formatCaptureID(next)
    }

    private func computeNextIDFromProjectFiles(projectName: String) throws -> Int {
        let projectDirectory = paths.projectDirectory(projectName: projectName)
        let entries = try fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var maxID = 0
        for entry in entries where entry.pathExtension.lowercased() == "png" {
            let filename = entry.lastPathComponent
            if let extracted = captureID(from: filename), extracted > maxID {
                maxID = extracted
            }
        }
        return maxID + 1
    }

    private func captureID(from filename: String) -> Int? {
        guard let underscoreIndex = filename.firstIndex(of: "_") else {
            return nil
        }
        let prefix = filename[..<underscoreIndex]
        return Int(prefix)
    }

    private func formatCaptureID(_ value: Int) -> String {
        String(format: "%03d", value)
    }

    private func isSafeCaptureFilename(_ value: String) -> Bool {
        guard value == URL(fileURLWithPath: value).lastPathComponent else {
            return false
        }
        guard value.lowercased().hasSuffix(".png") else {
            return false
        }
        return value.range(of: #"^[a-zA-Z0-9._-]+\.png$"#, options: .regularExpression) != nil
    }

    private func createDirectory(at url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw AppError.fileSystemOperationFailed(
                operation: "createDirectory",
                path: url,
                underlying: error
            )
        }
    }

    private func write(text: String, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        guard let data = text.data(using: .utf8) else {
            throw AppError.invalidInput("Unable to encode UTF-8 for \(url.path)")
        }
        try write(data: data, to: url)
    }

    private func write(data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw AppError.fileSystemOperationFailed(
                operation: "write",
                path: url,
                underlying: error
            )
        }
    }
}
