import Foundation

struct WorkspacePaths {
    static let defaultProjectName = "default"
    static let applicationSupportFolderName = "HTML Content Creator"

    let root: URL

    var screenshotsDirectory: URL { root.appendingPathComponent("screenshots", isDirectory: true) }
    var orderDirectory: URL { root.appendingPathComponent("order", isDirectory: true) }
    var notesDirectory: URL { root.appendingPathComponent("notes", isDirectory: true) }
    var generatedHTMLDirectory: URL { root }
    var generatedPDFDirectory: URL { root }
    var oldReferenceDirectory: URL { root.appendingPathComponent("old", isDirectory: true) }

    init(root: URL = WorkspacePaths.defaultRootURL()) {
        self.root = root
    }

    static func defaultRootURL() -> URL {
        let fileManager = FileManager.default

        if let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent(applicationSupportFolderName, isDirectory: true)
        }

        let homeFallback = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return homeFallback
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }

    static func sanitizeProjectName(_ raw: String?) -> String {
        guard let raw else { return defaultProjectName }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return defaultProjectName }

        let hyphenated = trimmed.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        let sanitized = hyphenated.replacingOccurrences(
            of: "[^a-z0-9._-]",
            with: "",
            options: .regularExpression
        )
        return sanitized.isEmpty ? defaultProjectName : sanitized
    }

    func projectDirectory(projectName rawName: String?) -> URL {
        let name = Self.sanitizeProjectName(rawName)
        if name == Self.defaultProjectName {
            return screenshotsDirectory
        }
        return screenshotsDirectory.appendingPathComponent(name, isDirectory: true)
    }

    func projectCounterFile(projectName: String?) -> URL {
        projectDirectory(projectName: projectName).appendingPathComponent(".counter")
    }

    func projectMetaFile(projectName: String?) -> URL {
        projectDirectory(projectName: projectName).appendingPathComponent(".project.json")
    }

    func projectCaptureLogFile(projectName: String?) -> URL {
        projectDirectory(projectName: projectName).appendingPathComponent("captures.md")
    }

    func projectOrderFile(projectName rawName: String?) -> URL {
        let name = Self.sanitizeProjectName(rawName)
        return orderDirectory.appendingPathComponent("\(name).md")
    }

    func projectNotesFile(projectName rawName: String?) -> URL {
        let name = Self.sanitizeProjectName(rawName)
        return notesDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("notes.md")
    }

    func generatedHTMLFile(projectName rawName: String?) -> URL {
        let name = Self.sanitizeProjectName(rawName)
        return generatedHTMLDirectory.appendingPathComponent("captures_\(name).html")
    }

    func generatedPDFFile(projectName rawName: String?) -> URL {
        let name = Self.sanitizeProjectName(rawName)
        return generatedPDFDirectory.appendingPathComponent("captures_\(name).pdf")
    }

    func ensureBaseDirectories(fileManager: FileManager = .default) throws {
        let targets = [
            screenshotsDirectory,
            orderDirectory,
            notesDirectory,
            projectDirectory(projectName: Self.defaultProjectName)
        ]

        for target in targets {
            do {
                try fileManager.createDirectory(
                    at: target,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                throw AppError.fileSystemOperationFailed(
                    operation: "createDirectory",
                    path: target,
                    underlying: error
                )
            }
        }
    }
}
