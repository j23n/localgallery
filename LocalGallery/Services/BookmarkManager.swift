import Foundation
import os

/// Owns the security-scoped bookmark for the user-picked photo folder and the
/// matching balanced `startAccessingSecurityScopedResource` / `stop…` calls.
///
/// Single source of truth for "which URL are we currently scoped into?" — every
/// scan, foreground refresh, and rescan reads it from here. The Store retains
/// the manager and forwards picker / settings calls into it.
@MainActor
final class BookmarkManager {
    private let defaults: UserDefaults
    private let bookmarkKey: String
    /// `nonisolated(unsafe)` so the implicit-nonisolated deinit can read it
    /// to balance the final `stopAccessingSecurityScopedResource`. Mutations
    /// happen only from `@MainActor` methods on this instance, so reads from
    /// deinit observe a stable last-written value.
    private(set) nonisolated(unsafe) var activeURL: URL?

    init(defaults: UserDefaults = .standard, bookmarkKey: String = "rootFolderBookmark") {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
    }

    deinit {
        // Under Swift 6, deinit on a `@MainActor` type is implicitly
        // nonisolated — it runs on whichever thread releases the last
        // reference. That's why `activeURL` above is `nonisolated(unsafe)`.
        // `stopAccessingSecurityScopedResource()` is documented thread-safe
        // (it's reference-counted), so calling it from any thread is fine.
        activeURL?.stopAccessingSecurityScopedResource()
    }

    func save(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmarkData, forKey: bookmarkKey)
        } catch {
            Log.cache.error("Failed to save bookmark: \(error.localizedDescription)")
        }
    }

    func resolve() -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                save(for: url)
            }
            return url
        } catch {
            Log.cache.error("Failed to resolve bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Balanced start: stops any currently-active scope before starting the new
    /// one, so a single instance never holds two scopes at once.
    func startAccessing(_ url: URL) {
        stopAccessing()
        _ = url.startAccessingSecurityScopedResource()
        activeURL = url
    }

    func stopAccessing() {
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = nil
    }
}
