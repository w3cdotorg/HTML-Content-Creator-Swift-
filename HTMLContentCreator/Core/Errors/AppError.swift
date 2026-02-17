import Foundation

enum AppError: LocalizedError {
    case invalidInput(String)
    case captureFailed(String)
    case fileSystemOperationFailed(operation: String, path: URL, underlying: Error)
    case bootstrapFailed(underlying: Error)
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .captureFailed(let message):
            return "Capture failed: \(message)"
        case .fileSystemOperationFailed(let operation, let path, let underlying):
            return "Filesystem error (\(operation)) at \(path.path): \(underlying.localizedDescription)"
        case .bootstrapFailed(let underlying):
            return "Application startup failed: \(underlying.localizedDescription)"
        case .unsupportedOperation(let message):
            return "Unsupported operation: \(message)"
        }
    }
}
