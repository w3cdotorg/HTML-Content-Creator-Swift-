import Foundation

struct CaptureOutput: Identifiable, Hashable {
    var id: String { filename }

    let projectName: String
    let filename: String
    let fileURL: URL
    let sourceURL: URL
    let capturedAt: Date
}
