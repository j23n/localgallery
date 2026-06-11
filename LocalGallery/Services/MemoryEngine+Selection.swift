import Foundation

/// Cluster identity for the selection stage: memories sharing a cluster key
/// are mutually exclusive in a single rail render and share a cool-down.
extension MemoryEngine {
    // MARK: - Cluster Key

    /// Memories that share a cluster key are mutually exclusive in a single
    /// rail render and share a cool-down: a trip parent (`trip-<key>`) and
    /// its sub-trips (`subtrip-<key>-<seg>`) all collapse to `trip-<key>`,
    /// so only one surfaces per generation and the others stay penalised
    /// for a few days. Every other memory id is its own cluster.
    static func clusterKey(for memoryID: String) -> String {
        if memoryID.hasPrefix("subtrip-") {
            // Sub-trip ids are "subtrip-<year>-<month>-<day>-<segKey>".
            // The trip key is the first three hyphen-joined components after
            // the prefix. Numeric so split-on-"-" is unambiguous.
            let rest = memoryID.dropFirst("subtrip-".count)
            let parts = rest.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count >= 4 {
                let tripKey = parts.prefix(3).joined(separator: "-")
                return "trip-\(tripKey)"
            }
        }
        return memoryID
    }
}
