import Foundation

/// Which model pack the app should use, given what is in the app bundle and
/// what the user has imported.
///
/// **Newest wins, wherever it lives.** Not "imported always wins": a pack
/// imported once would then shadow the bundled pack forever, so an app update
/// that ships a better encoder would quietly do nothing and the user would have
/// no way to see why. An imported `…-v2` beats a bundled `…-v1`; a bundled
/// `…-v2` beats a stale imported `…-v1`. Equal versions go to the imported
/// copy, because installing it was deliberate.
///
/// Resolution is a pure function of two candidate lists so it is testable
/// without a 157 MB pack — which is the whole reason this is a type rather
/// than three lines inside `TaggingService`.
enum PackResolver {
    /// Where a pack directory came from.
    enum Source: Sendable, Equatable {
        /// `LocalGallery.app/pack/`, staged by `scripts/prepare_pack.sh`. Read
        /// in place: the core only ever reads and hashes a pack, so the
        /// read-only app bundle is a valid location and there is no reason to
        /// copy it into Application Support on first launch.
        case bundled
        /// `Application Support/ModelPacks/<version>/`, copied there by
        /// `TaggingService.importModelPack`.
        case imported

        /// As Settings shows it.
        var label: String {
            switch self {
            case .bundled: return "Bundled"
            case .imported: return "Imported"
            }
        }
    }

    struct Resolution: Sendable, Equatable {
        var directory: URL
        var source: Source
    }

    /// Every subdirectory of `root` that looks like a pack.
    ///
    /// The per-root half of resolution: enumeration is all it does, so the
    /// ordering rule lives in exactly one place (`resolve`) and applies across
    /// both roots rather than once per root.
    nonisolated static func candidates(in root: URL?) -> [URL] {
        guard let root else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && hasManifest(url)
        }
    }

    /// The pack to use, or `nil` when neither list holds one.
    ///
    /// Name order rather than mtime: pack directories are named for their
    /// version, and a copy's mtime says when it was installed, not which
    /// version it is. The comparison is `.numeric` because plain lexicographic
    /// ordering ranks `…-v1.9` above `…-v1.10`.
    nonisolated static func resolve(bundled: [URL], imported: [URL]) -> Resolution? {
        let all = imported.filter(hasManifest).map { Resolution(directory: $0, source: .imported) }
            + bundled.filter(hasManifest).map { Resolution(directory: $0, source: .bundled) }
        return all.max { a, b in
            switch a.directory.lastPathComponent.compare(
                b.directory.lastPathComponent, options: [.numeric]
            ) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.source == .bundled && b.source == .imported
            }
        }
    }

    /// A directory with no `manifest.json` is not a pack — an empty
    /// `build/pack` resource, or a folder the user picked by mistake.
    private nonisolated static func hasManifest(_ dir: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("manifest.json").path
        )
    }
}
