import Foundation

struct CaptureHistoryItem: Identifiable, Hashable {
    var id: String { filename }

    let filename: String
    let fileURL: URL
    let modifiedAt: Date
}
