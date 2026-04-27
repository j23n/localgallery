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
    private(set) var activeURL: URL?

    init(defaults: UserDefaults = .standard, bookmarkKey: String = "rootFolderBookmark") {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
    }

    deinit {
        // BookmarkManager is @MainActor; the Store releases its reference on
        // main, so this deinit also runs on main. Stop the security scope so
        // a torn-down instance doesn't leak access.
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
