import Foundation

struct TagSuggestion: Identifiable, Hashable, Sendable {
    let id: String              // fullPath lowercased
    let displayName: String     // leaf value
    let fullPath: String        // original hierarchical path
    let namespace: String?      // first segment or nil
    let count: Int              // number of photos with this tag
    let latestPhotoDate: Date?  // most recent photo date; set for people tags, nil otherwise

    init(id: String, displayName: String, fullPath: String, namespace: String?, count: Int,
         latestPhotoDate: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.fullPath = fullPath
        self.namespace = namespace
        self.count = count
        self.latestPhotoDate = latestPhotoDate
    }

    var icon: String {
        if namespace?.lowercased() == "places" {
            // Depth = segments after the "Places" root.
            let depth = fullPath.split(separator: "/").count - 1
            return TagNamespace.placesIcon(depth: depth)
        }
        return TagNamespace.icon(for: namespace)
    }
}
