import Foundation

actor CaptureService {
    private let paths: WorkspacePaths
    private let store: LegacyFileStore

    init(paths: WorkspacePaths, store: LegacyFileStore) {
        self.paths = paths
        self.store = store
    }

    func capture(
        urlString rawURL: String,
        projectName rawProjectName: String?,
        contentBlockingEnabled: Bool = true
    ) async throws -> CaptureOutput {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidInput("URL is required.")
        }

        guard let url = URL(string: trimmed) else {
            throw AppError.invalidInput("Invalid URL.")
        }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AppError.invalidInput("Only http/https URLs are supported.")
        }

        let projectName = try await store.ensureProject(rawProjectName)
        let captureID = try await store.nextCaptureID(projectName: projectName)
        let now = Date()
        let domain = Self.extractDomain(from: url)
        let filename = "\(captureID)_\(domain)_\(LegacyDateFormatter.yyyymmddString(from: now))_\(LegacyDateFormatter.hhmmString(from: now)).png"

        let pngData = try await WebKitCaptureEngine.capture(
            url: url,
            contentBlockingEnabled: contentBlockingEnabled
        )
        let fileURL = try await store.writeCaptureImage(projectName: projectName, filename: filename, pngData: pngData)

        let record = CaptureRecord(
            filename: filename,
            url: url,
            capturedAt: now
        )
        try await store.appendCaptureLog(projectName: projectName, capture: record)

        AppLogger.capture.info("Capture saved: \(filename, privacy: .public)")

        return CaptureOutput(
            projectName: projectName,
            filename: filename,
            fileURL: fileURL,
            sourceURL: url,
            capturedAt: now
        )
    }

    private static func extractDomain(from url: URL) -> String {
        var host = (url.host ?? "unknown-site").lowercased()
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        let cleaned = host.replacingOccurrences(
            of: "[^a-z0-9.-]",
            with: "",
            options: .regularExpression
        )
        return cleaned.isEmpty ? "unknown-site" : cleaned
    }
}
