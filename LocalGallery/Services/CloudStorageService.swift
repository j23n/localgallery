import Foundation
import FileProvider

/// File-provider storage mechanics behind the Settings "Cloud Storage"
/// section: probing download status across the library and evicting
/// materialised items. Stateless — the Store passes photo snapshots in and
/// applies the resulting model mutations itself.
enum CloudStorageService {
    struct Stats: Sendable, Equatable {
        let materializedCount: Int
        let materializedBytes: Int64
        let placeholderCount: Int
        let totalRemote: Int
    }

    /// Bucket `remotePhotos` by download status. One `resourceValues` probe
    /// per photo — nonisolated async so the walk runs off the main actor (a
    /// multi-thousand-photo cloud library would otherwise hitch the Settings
    /// sheet open animation). No downloads are triggered.
    static func probeStats(of remotePhotos: [PhotoFile]) async -> Stats {
        var materializedCount = 0
        var materializedBytes: Int64 = 0
        var placeholderCount = 0
        for photo in remotePhotos {
            let probe = FileProviderDetector.probe(photo.url)
            if probe.status == .local {
                materializedCount += 1
                materializedBytes += probe.version.size ?? photo.fileSize
            } else {
                placeholderCount += 1
            }
        }
        return Stats(
            materializedCount: materializedCount,
            materializedBytes: materializedBytes,
            placeholderCount: placeholderCount,
            totalRemote: remotePhotos.count
        )
    }

    /// Ask the file-provider stack to evict every photo in `downloaded`.
    /// Eviction is per-domain via `NSFileProviderManager.evictItem`;
    /// providers that don't support eviction silently no-op. Returns the
    /// evicted count.
    static func evictAll(_ downloaded: [PhotoFile]) async -> Int {
        var evicted = 0
        for photo in downloaded {
            do {
                let pair: (NSFileProviderItemIdentifier, NSFileProviderDomainIdentifier)? =
                    try await withCheckedThrowingContinuation { cont in
                        NSFileProviderManager.getIdentifierForUserVisibleFile(at: photo.url) { id, domainID, err in
                            if let err { cont.resume(throwing: err) }
                            else if let id, let domainID { cont.resume(returning: (id, domainID)) }
                            else { cont.resume(returning: nil) }
                        }
                    }
                guard let (itemID, domainID) = pair else { continue }
                // Resolve the domain inside the completion block so the
                // non-Sendable `NSFileProviderDomain` value never crosses
                // an actor hop. We either return a `Bool` (evict success)
                // or rethrow the underlying error.
                let didEvict: Bool = try await withCheckedThrowingContinuation { cont in
                    NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
                        guard let domain = domains.first(where: { $0.identifier == domainID }),
                              let manager = NSFileProviderManager(for: domain) else {
                            cont.resume(returning: false)
                            return
                        }
                        manager.evictItem(identifier: itemID) { error in
                            if let error { cont.resume(throwing: error) }
                            else { cont.resume(returning: true) }
                        }
                    }
                }
                if didEvict { evicted += 1 }
            } catch {
                Log.scan.warning("evictItem failed for \(Log.r.filename(photo.url.lastPathComponent)): \(Log.r.error(error))")
            }
        }
        return evicted
    }
}
