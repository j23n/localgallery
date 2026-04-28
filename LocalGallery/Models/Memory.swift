import Foundation

enum MemoryType: String, Codable, Sendable {
    case onThisDay
    case yearsAgo
    case personOverTime
    case folderEvent
    case photoDensity
    case trip
    /// "It's <name>'s birthday" — surfaced only on the matching calendar day.
    /// Source: system address book linked to a People/* tag.
    case birthday
}

extension MemoryType: Hashable {}

struct Memory: Identifiable, Hashable, Codable, Sendable {
    let id: String            // deterministic key, e.g. "onThisDay", "yearsAgo-5"
    let type: MemoryType
    let title: String
    let subtitle: String?
    let photoIDs: [UUID]
    let coverPhotoID: UUID
    let dateRange: ClosedRange<Date>?
    let score: Double
    let yearsAgo: Int?
    let personName: String?

    static func == (lhs: Memory, rhs: Memory) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
