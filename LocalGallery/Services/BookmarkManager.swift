import Foundation
import os

/// Owns the security-scoped bookmark for the user-picked photo folder and the
/// matching balanced `startAccessingSecurityScopedResource` / `stop…` calls.
///
/// Single source of truth for "which URL are we currently scoped into?" — every
/// scan, foreground refresh, and rescan reads it from here. The Store retains
/// this service and forwards picker / settings calls into it.
@MainActor
final class BookmarkManager {
    private let defaults: UserDefaults
    private let bookmarkKey: String
    /// `nonisolated(unsafe)` so the implicit-nonisolated deinit can read it
    /// to balance the final `stopAccessingSecurityScopedResource`. Mutations
    /// happen only from `@MainActor` methods on this instance, so reads from
    /// deinit observe a stable last-written value.
    private(set) nonisolated(unsafe) var activeURL: URL?

    /// No default for `bookmarkKey` — it comes from `GalleryPaths` (via the
    /// Store) so the key string lives in exactly one place.
    init(defaults: UserDefaults = .standard, bookmarkKey: String) {
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
            Log.cache.error("Failed to save bookmark: \(Log.r.error(error))")
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
            Log.cache.error("Failed to resolve bookmark: \(Log.r.error(error))")
            return nil
        }
    }

    /// Balanced start: stops any currently-active scope before starting the new
    /// one, so a single instance never holds two scopes at once. `activeURL` is
    /// only recorded when the start call succeeds — recording it on failure
    /// would make the next `stopAccessing()` unbalanced (a documented kernel
    /// resource leak) and hide the access failure from diagnostics.
    func startAccessing(_ url: URL) {
        stopAccessing()
        guard url.startAccessingSecurityScopedResource() else {
            Log.cache.error("Security-scoped access denied for \(Log.r.path(url))")
            return
        }
        activeURL = url
    }

    func stopAccessing() {
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = nil
    }
}
