import Foundation

/// Lightweight photo descriptor written to disk for widget consumption.
/// Excludes EXIF/dimensions/etc. — widgets only need the thumbnail and
/// enough identity to deep-link back into the app.
struct WidgetPhotoRef: Codable, Hashable, Sendable {
    let id: String                  // PhotoFile.id.uuidString
    let folderId: String            // PhotoFolder.id.uuidString of the containing leaf folder
    let date: Date?
    let tagPaths: [String]          // canonical hierarchical paths (incl. parent prefixes for Places/*)
    let thumbnailFilename: String   // basename inside SharedContainer.thumbsDir
}

/// Bag of recent / representative photos the widgets pick from for the
/// Folder and Tags surfaces. Capped — see `WidgetSnapshotExporter.maxIndexPhotos`.
struct WidgetIndex: Codable, Sendable {
    let generatedAt: Date
    let photos: [WidgetPhotoRef]
}

/// One entry in the folder picker presented by `FolderWidget`'s configuration intent.
struct FolderCatalogEntry: Codable, Hashable, Sendable {
    let id: String              // PhotoFolder.id.uuidString
    let displayName: String     // leaf name, e.g. "Italy 2024"
    let pathDescription: String // human-readable parent chain, "Trips › Italy 2024"
}

struct FolderCatalog: Codable, Sendable {
    let generatedAt: Date
    let folders: [FolderCatalogEntry]
}

/// Flat list of tag full-paths for the Tags widget configuration intent.
struct TagCatalog: Codable, Sendable {
    let generatedAt: Date
    let tagPaths: [String]
}

enum MemorySnapshotKind: String, Codable, Sendable {
    case onThisDay
    case yearsAgo
    case birthday
    case other
}

/// One memory ready to render. The widget renders the highest-priority item
/// whose validity window covers `Date()` at timeline-build time.
struct MemorySnapshotItem: Codable, Hashable, Sendable {
    let id: String                  // matches Memory.id (or "birthday-<name>" for synthesized)
    let kind: MemorySnapshotKind
    let title: String
    let subtitle: String?
    let photoRefs: [WidgetPhotoRef] // candidate set (cover first, then chronological)
    let validFrom: Date
    let validTo: Date               // exclusive
    let priority: Int               // higher wins
}

struct MemorySnapshot: Codable, Sendable {
    let generatedAt: Date
    let items: [MemorySnapshotItem]
}
