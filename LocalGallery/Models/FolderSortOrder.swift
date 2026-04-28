import Foundation

enum FolderSortOrder: String, CaseIterable, Sendable {
    case nameAscending
    case nameDescending
    case dateModifiedNewest
    case dateModifiedOldest
    case dateCreatedNewest
    case dateCreatedOldest

    var label: String {
        switch self {
        case .nameAscending: return "Name ↑"
        case .nameDescending: return "Name ↓"
        case .dateModifiedNewest: return "Modified ↓"
        case .dateModifiedOldest: return "Modified ↑"
        case .dateCreatedNewest: return "Created ↓"
        case .dateCreatedOldest: return "Created ↑"
        }
    }
}
