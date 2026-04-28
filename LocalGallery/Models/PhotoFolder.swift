import Foundation
import CryptoKit

struct PhotoFolder: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let url: URL
    var name: String
    var subfolders: [PhotoFolder]
    var photos: [PhotoFile]
    var coverPhotoURL: URL?
    var totalPhotoCount: Int
    var dateModified: Date?
    var dateCreated: Date?

    /// Deterministic UUID derived from the folder URL path for stable identity across scans.
    /// SHA-256 truncated to 16 bytes with RFC 4122 variant + version-5 marker — namespace-less; matches localmusic.
    static func stableID(for url: URL) -> UUID {
        let digest = SHA256.hash(data: Data(("folder:" + url.standardized.path).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant RFC 4122
        return UUID(uuid: (bytes[0],  bytes[1],  bytes[2],  bytes[3],
                           bytes[4],  bytes[5],  bytes[6],  bytes[7],
                           bytes[8],  bytes[9],  bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
