import Foundation

/// Stateless namespace for detecting whether a URL is backed by a file
/// provider (iCloud Drive, OneDrive, Proton Drive, Google Drive, Dropbox, …)
/// and reporting per-file download status + content version. All calls are
/// metadata-only; nothing here triggers a download.
enum FileProviderDetector {
    enum DownloadStatus: Equatable, Sendable {
        case local
        case placeholder
        case downloading
        case stale
    }

    /// Identity used to detect when the underlying file changed without
    /// downloading it. Prefer `contentIdentifier` (provider-vended via
    /// `URLResourceKey.fileContentIdentifierKey`); fall back to
    /// `(modificationDate, size)` when the provider doesn't populate it.
    struct ContentVersion: Hashable, Codable, Sendable {
        var contentIdentifier: Int64?
        var modificationDate: Date?
        var size: Int64?

        var isEmpty: Bool {
            contentIdentifier == nil && modificationDate == nil && size == nil
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

    private static let resourceKeys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
        .fileContentIdentifierKey,
        .contentModificationDateKey,
        .fileSizeKey,
        .totalFileSizeKey,
    ]

    /// Read once per file: download status + content version + whether the
    /// URL belongs to a file provider at all. Batches the resource-values
    /// read so the scanner only pays one syscall per file.
    static func probe(_ url: URL) -> (status: DownloadStatus, version: ContentVersion, isFileProvider: Bool) {
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
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
            contentIdentifier: values.fileContentIdentifier,
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
