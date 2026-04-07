import Foundation

struct ProjectMetadata: Hashable, Codable {
    var htmlTitle: String?
    var displayName: String?

    init(htmlTitle: String?, displayName: String? = nil) {
        self.htmlTitle = htmlTitle
        self.displayName = displayName
    }
}
