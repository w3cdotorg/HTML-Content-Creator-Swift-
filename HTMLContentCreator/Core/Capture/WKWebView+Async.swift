import AppKit
import WebKit

@MainActor
extension WKWebView {
    func evaluateJavaScriptAsync(_ source: String, timeoutNanoseconds: UInt64 = 2_500_000_000) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var resolved = false
            var timeoutTask: Task<Void, Never>?

            func resolve(_ result: Result<Any?, Error>) {
                guard !resolved else { return }
                resolved = true
                timeoutTask?.cancel()
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                resolve(.failure(AppError.captureFailed("JavaScript evaluation timed out.")))
            }

            evaluateJavaScript(source) { value, error in
                if let error {
                    resolve(.failure(error))
                } else {
                    resolve(.success(value))
                }
            }
        }
    }

    func takeSnapshotAsync(
        configuration: WKSnapshotConfiguration? = nil,
        timeoutNanoseconds: UInt64 = 20_000_000_000
    ) async throws -> NSImage {
        try await withCheckedThrowingContinuation { continuation in
            var resolved = false
            var timeoutTask: Task<Void, Never>?

            func resolve(_ result: Result<NSImage, Error>) {
                guard !resolved else { return }
                resolved = true
                timeoutTask?.cancel()
                switch result {
                case .success(let image):
                    continuation.resume(returning: image)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                resolve(.failure(AppError.captureFailed("Snapshot timed out.")))
            }

            takeSnapshot(with: configuration) { image, error in
                if let error {
                    resolve(.failure(error))
                } else if let image {
                    resolve(.success(image))
                } else {
                    resolve(.failure(AppError.captureFailed("Snapshot returned no image.")))
                }
            }
        }
    }

    func createPDFAsync(configuration: WKPDFConfiguration, timeoutNanoseconds: UInt64 = 30_000_000_000) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            var resolved = false
            var timeoutTask: Task<Void, Never>?

            func resolve(_ result: Result<Data, Error>) {
                guard !resolved else { return }
                resolved = true
                timeoutTask?.cancel()
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                resolve(.failure(AppError.captureFailed("PDF generation timed out.")))
            }

            createPDF(configuration: configuration) { result in
                switch result {
                case .success(let data):
                    resolve(.success(data))
                case .failure(let error):
                    resolve(.failure(error))
                }
            }
        }
    }
}
