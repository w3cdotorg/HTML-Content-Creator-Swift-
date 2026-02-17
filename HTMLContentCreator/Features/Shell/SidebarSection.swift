import Foundation

enum SidebarSection: String, CaseIterable, Hashable, Identifiable {
    case projects
    case capture
    case exploreAndEdit
    case share

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects:
            return "Projects"
        case .capture:
            return "Capture"
        case .exploreAndEdit:
            return "Explore and Edit"
        case .share:
            return "Share"
        }
    }

    var systemImage: String {
        switch self {
        case .projects:
            return "folder"
        case .capture:
            return "camera"
        case .exploreAndEdit:
            return "square.stack.3d.up"
        case .share:
            return "square.and.arrow.up"
        }
    }
}
