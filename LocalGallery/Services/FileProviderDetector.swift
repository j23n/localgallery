import Foundation

/// Stateless namespace for detecting whether a URL is backed by a file
/// provider (iCloud Drive, OneDrive, Proton Drive, Google Drive, Dropbox, …)
/// and reporting per-file download status + content version. All calls are
/// metadata-only; nothing here triggers a download.
enum FileProviderDetector {
    /// Raw values are part of the persisted `LibrarySnapshot` (see
    /// `SidecarCandidate`). Without them Swift synthesises `{"local": {}}`
    /// for a case-with-no-payload, and the Rust core — which writes and reads
    /// the same file — emits the bare string.
    enum DownloadStatus: String, Codable, Equatable, Sendable {
        case local
        case placeholder
        case downloading
        case stale
    }

    /// Identity used to detect when the underlying file changed without
    /// downloading it. Prefer `contentIdentifier` (provider-vended via
    /// `URLResourceKey.fileContentIdentifierKey`); fall back to
    /// `(modificationDate, size)` when the provider doesn't populate it.
    ///
    /// `contentIdentifier` is a **String** even though `fileContentIdentifierKey`
    /// vends an `Int64`: SAF and every non-Apple provider hand back opaque
    /// tokens, so the core models it as a string and this side stringifies at
    /// the one place the value is read. Decoding accepts a bare JSON number
    /// too, so sidecar caches written before the change still load.
    struct ContentVersion: Hashable, Codable, Sendable {
        var contentIdentifier: String?
        var modificationDate: Date?
        var size: Int64?

        var isEmpty: Bool {
            contentIdentifier == nil && modificationDate == nil && size == nil
        }

        init(contentIdentifier: String? = nil, modificationDate: Date? = nil, size: Int64? = nil) {
            self.contentIdentifier = contentIdentifier
            self.modificationDate = modificationDate
            self.size = size
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Tolerant on the way in only: entries written while this field
            // was an Int64 are still in every installed sidecar cache, and
            // evicting them would re-download every `.xmp` in the library to
            // save nothing.
            if let raw = try? c.decodeIfPresent(String.self, forKey: .contentIdentifier) {
                contentIdentifier = raw
            } else if let legacy = try? c.decodeIfPresent(Int64.self, forKey: .contentIdentifier) {
                contentIdentifier = String(legacy)
            } else {
                contentIdentifier = nil
            }
            modificationDate = try c.decodeIfPresent(Date.self, forKey: .modificationDate)
            size = try c.decodeIfPresent(Int64.self, forKey: .size)
        }

        /// `lhs` and `rhs` represent the same content if either:
        ///   - both have a `contentIdentifier` and they match, OR
        ///   - neither has one, and `(modificationDate, size)` match.
        /// Mixed presence is treated as different (one side has stronger
        /// identity than the other).
        static func sameContent(_ lhs: ContentVersion, _ rhs: ContentVersion) -> Bool {
            switch (lhs.contentIdentifier, rhs.contentIdentifier) {
            case let (l?, r?): return l == r
            case (nil, nil):
                return lhs.modificationDate == rhs.modificationDate && lhs.size == rhs.size
            default:
                return false
            }
        }
    }

    /// The three keys that actually cost something.
    ///
    /// Measured on the 20k fixture library: a `resourceValues` asking for
    /// these takes ~11 ms and does not parallelise, whatever the thread count
    /// (see `CoreProviderProbe`). A `resourceValues` asking only for
    /// [`sizeKeys`] is a stat.
    static let ubiquitousKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
    ]

    /// The cheap half: plain stat data every filesystem can answer without
    /// asking a daemon.
    static let sizeKeys: Set<URLResourceKey> = [
        .fileContentIdentifierKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .totalFileSizeKey,
    ]

    private static let resourceKeys: Set<URLResourceKey> = ubiquitousKeys.union(sizeKeys)

    /// Read once per file: download status + content version + whether the
    /// URL belongs to a file provider at all. Batches the resource-values
    /// read so the scanner only pays one syscall per file.
    ///
    /// - Parameter includeUbiquitousKeys: when false, only [`sizeKeys`] are
    ///   read. `isFileProvider` and the placeholder decision then rest on
    ///   `totalFileSize > fileSize`, which is the branch third-party providers
    ///   (Proton, OneDrive, Drive, Dropbox) have always taken — iCloud's
    ///   dedicated status keys are the only thing lost, and with them the
    ///   `.downloading` / `.stale` distinctions that nothing in the app reads.
    ///   The scanner passes false for trees whose root is not ubiquitous,
    ///   because on those the expensive keys have never once said anything the
    ///   cheap ones did not.
    static func probe(
        _ url: URL,
        includeUbiquitousKeys: Bool = true
    ) -> (status: DownloadStatus, version: ContentVersion, isFileProvider: Bool) {
        let keys = includeUbiquitousKeys ? resourceKeys : sizeKeys
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return (.local, ContentVersion(), false)
        }

        let isUbiquitous = values.isUbiquitousItem ?? false
        let onDisk = values.fileSize.map(Int64.init)
        let intended = values.totalFileSize.map(Int64.init)
        // A `totalFileSize` larger than `fileSize` is the canonical signal a
        // third-party provider (Proton, OneDrive, Drive, Dropbox) gives for a
        // placeholder. iCloud also populates it but we trust its dedicated
        // status key first.
        let providerLike = (intended ?? 0) > (onDisk ?? 0)
        let isProvider = isUbiquitous || providerLike

        let status: DownloadStatus
        if values.ubiquitousItemIsDownloading == true {
            status = .downloading
        } else if let s = values.ubiquitousItemDownloadingStatus {
            switch s {
            case .current, .downloaded: status = .local
            case .notDownloaded: status = .placeholder
            default: status = .stale
            }
        } else if providerLike {
            status = .placeholder
        } else {
            status = .local
        }

        let version = ContentVersion(
            contentIdentifier: values.fileContentIdentifier.map(String.init),
            modificationDate: values.contentModificationDate,
            size: intended ?? onDisk
        )
        return (status, version, isProvider)
    }

    static func downloadStatus(of url: URL) -> DownloadStatus {
        probe(url).status
    }

    static func contentVersion(of url: URL) -> ContentVersion {
        probe(url).version
    }

    static func isFileProviderURL(_ url: URL) -> Bool {
        probe(url).isFileProvider
    }
}
