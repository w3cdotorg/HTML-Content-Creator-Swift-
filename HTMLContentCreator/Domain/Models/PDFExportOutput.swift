import Foundation

struct PDFExportOutput: Identifiable, Equatable {
    var id: String { fileURL.path }

    let projectName: String
    let htmlFileURL: URL
    let fileURL: URL
    let title: String
}
