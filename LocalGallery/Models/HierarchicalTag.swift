import Foundation

// MARK: - Hierarchical Tag

struct HierarchicalTag: Hashable, Codable, Sendable {
    let fullPath: String      // "People/Johannes" or "Places/Italy/Lazio/Rome"
    let namespace: String?    // "People", nil for flat tags
    let displayName: String   // leaf segment, e.g. "Johannes" or "Rome"

    /// Create from a photo-tools `digiKam:TagsList` entry. Paths are `/`-separated
    /// and already Titlecased by the writer (see photo-tools xmp-schema.md §3).
    init(raw: String) {
        self.fullPath = raw
        let parts = raw.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.count > 1 {
            self.namespace = parts.first
            self.displayName = parts.last ?? raw
        } else {
            self.namespace = nil
            self.displayName = raw
        }
    }

    init(fullPath: String, namespace: String?, displayName: String) {
        self.fullPath = fullPath
        self.namespace = namespace
        self.displayName = displayName
    }
}

// MARK: - Tag Namespace Icons

enum TagNamespace {
    /// SF Symbol for one of the six photo-tools taxonomy roots.
    /// See photo-tools xmp-schema.md §2.
    static func icon(for namespace: String?) -> String {
        switch namespace?.lowercased() {
        case "people":    return "person.fill"
        case "places":    return "mappin.and.ellipse"
        case "landmarks": return "building.columns.fill"
        case "objects":   return "cube.fill"
        case "scenes":    return "mountain.2.fill"
        case "text":      return "textformat"
        default:          return "tag.fill"
        }
    }

    /// Depth-aware icon for `Places/*` tags so the suggestion list communicates
    /// what scale the user is filtering at. depth counts the segments under
    /// "Places" — depth 1 = country, 2 = region, 3 = city, 4+ = neighborhood.
    static func placesIcon(depth: Int) -> String {
        switch depth {
        case ...0: return "mappin.and.ellipse"
        case 1:    return "flag.fill"
        case 2:    return "map.fill"
        case 3:    return "building.2.fill"
        default:   return "house.fill"
        }
    }
}
