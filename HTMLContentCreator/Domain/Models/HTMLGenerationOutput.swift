import Foundation

struct HTMLGenerationOutput: Identifiable, Equatable {
    var id: String { fileURL.path }

    let projectName: String
    let fileURL: URL
    let title: String
}
