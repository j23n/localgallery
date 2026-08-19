import Foundation
import XCTest
@testable import LocalGallery

/// Pure helpers for the library-folder watcher. Vnode sources and
/// NSFilePresenter are Darwin-only and are not exercised here.
final class LibraryRootMonitorTests: XCTestCase {

    /// No published tree (root gone / unlistable) still yields the bookmark
    /// URL — that is what a remount has to fire against.
    func testWatchURLsIsJustTheRootWhenTheTreeIsMissing() {
        let root = URL(fileURLWithPath: "/library")
        XCTAssertEqual(
            LibraryRootMonitor.watchURLs(root: root, tree: nil).map(\.path),
            ["/library"]
        )
    }

    /// Directories only: photo files in the fixture must not become watch
    /// targets. The root is de-duplicated against `tree.url`.
    func testWatchURLsWalksFoldersAndSkipsPhotos() {
        let root = URL(fileURLWithPath: "/library")
        let italy = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/2024/Italy"),
            photos: [.fixture(url: URL(fileURLWithPath: "/library/2024/Italy/a.jpg"))]
        )
        let year = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/2024"),
            subfolders: [italy]
        )
        let tree = PhotoFolder.fixture(url: root, subfolders: [year])

        XCTAssertEqual(
            Set(LibraryRootMonitor.watchURLs(root: root, tree: tree).map(\.path)),
            ["/library", "/library/2024", "/library/2024/Italy"]
        )
    }

    /// A tree rooted somewhere other than the bookmark still keeps the
    /// bookmark URL first — that is the path `open` failed on, and the
    /// presenter is registered there.
    func testWatchURLsKeepsTheBookmarkWhenTheTreeRootDiffers() {
        let bookmark = URL(fileURLWithPath: "/Volumes/Photos")
        let tree = PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/Volumes/Photos/Library"),
            subfolders: [PhotoFolder.fixture(url: URL(fileURLWithPath: "/Volumes/Photos/Library/2024"))]
        )
        XCTAssertEqual(
            LibraryRootMonitor.watchURLs(root: bookmark, tree: tree).map(\.path),
            ["/Volumes/Photos", "/Volumes/Photos/Library", "/Volumes/Photos/Library/2024"]
        )
    }

    /// The tagging/faces coalescer is a 30 s budget for interrupting the
    /// user. This one has to be shorter or Collections stays stale.
    @MainActor
    func testWatcherCoalescerIsNotTheTaggingWindow() {
        let monitor = LibraryRootMonitor()
        XCTAssertEqual(monitor.coalescer.interval, LibraryRootMonitor.refreshInterval)
        XCTAssertNotEqual(
            monitor.coalescer.interval,
            TaggingService.refreshInterval,
            "deletions must not wait out the tagging/faces window"
        )
    }
}
