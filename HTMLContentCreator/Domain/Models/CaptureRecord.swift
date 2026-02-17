import Foundation

struct CaptureRecord: Identifiable, Hashable, Codable {
    var id: String { filename }

    let filename: String
    let url: URL
    let capturedAt: Date?
}
