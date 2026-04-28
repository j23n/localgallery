import XCTest
@testable import LocalGallery

@MainActor
final class SortFoldersTests: XCTestCase {

    private func folder(_ name: String, modified: Date? = nil, created: Date? = nil) -> PhotoFolder {
        PhotoFolder.fixture(
            url: URL(fileURLWithPath: "/library/\(name)"),
            name: name,
            dateModified: modified,
            dateCreated: created
        )
    }

    // MARK: - Name ordering

    func testNameAscendingUsesLocalizedStandardCompare() {
        let harness = TestGalleryStore.make()
        defer { harness.teardown() }

        harness.store.folderSortOrder = .nameAscending
        let folders = [folder("Bravo"), folder("alpha"), folder("Charlie")]
        let sorted = harness.store.sortFolders(folders)
        XCTAssertEqual(sorted.map(\.name), ["alpha", "Bravo", "Charlie"])
    }

    func testNameDescendingReversesAlphabetical() {
        let harness = TestGalleryStore.make()
        defer { harness.teardown() }

        harness.store.folderSortOrder = .nameDescending
        let folders = [folder("alpha"), folder("Bravo"), folder("Charlie")]
        let sorted = harness.store.sortFolders(folders)
        XCTAssertEqual(sorted.map(\.name), ["Charlie", "Bravo", "alpha"])
    }

    // MARK: - Date modified

    func testDateModifiedNewestFirst() {
        let harness = TestGalleryStore.make()
        defer { harness.teardown() }

        harness.store.folderSortOrder = .dateModifiedNewest
        let folders = [
            folder("a", modified: date(2023, 1, 1)),
            folder("b", modified: date(2025, 6, 1)),
            folder("c", modified: date(2024, 1, 1)),
        ]
        let sorted = harness.store.sortFolders(folders)
        XCTAssertEqual(sorted.map(\.name), ["b", "c", "a"])
    }

    func testDateModifiedOldestFirst() {
        let harness = TestGalleryStore.make()
        defer { harness.teardown() }

        harness.store.folderSortOrder = .dateModifiedOldest
        let folders = [
            folder("a", modified: date(2025, 6, 1)),
            folder("b", modified: date(2023, 1, 1)),
            folder("c", modified: date(2024, 1, 1)),
        ]
        let sorted = harness.store.sortFolders(folders)
        XCTAssertEqual(sorted.map(\.name), ["b", "c", "a"])
    }

    // MARK: - Date created

    func testDateCreatedNewestFirst() {
        let harness = TestGalleryStore.make()
        defer { harness.teardown() }

        harness.store.folderSortOrder = .dateCreatedNewest
        let folders = [
            folder("a", created: date(2023, 1, 1)),
            folder("b", created: date(2025, 6, 1)),
            folder("c", created: date(2024, 1, 1)),
        ]
        let sorted = harness.store.sortFolders(folders)
        XCTAssertEqual(sorted.map(\.name), ["b", "c", "a"])
    }

    func testDateCreatedOldestFirst() {
        let harness = TestGalleryStore.make()
        defer { harness.teardown() }

        harness.store.folderSortOrder = .dateCreatedOldest
        let folders = [
            folder("a", created: date(2025, 6, 1)),
            folder("b", created: date(2023, 1, 1)),
            folder("c", created: date(2024, 1, 1)),
        ]
        let sorted = harness.store.sortFolders(folders)
        XCTAssertEqual(sorted.map(\.name), ["b", "c", "a"])
    }

    // MARK: - Missing dates

    func testFoldersWithoutDateSortToTheEndOfNewestFirst() {
        let harness = TestGalleryStore.make()
        defer { harness.teardown() }

        harness.store.folderSortOrder = .dateModifiedNewest
        let folders = [
            folder("dated", modified: date(2024, 1, 1)),
            folder("undated", modified: nil),
        ]
        let sorted = harness.store.sortFolders(folders)
        XCTAssertEqual(sorted.map(\.name), ["dated", "undated"])
    }

    // MARK: - Label

    func testEachOrderHasAUniqueLabel() {
        let labels = FolderSortOrder.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, FolderSortOrder.allCases.count)
    }

    func testRawValuesAreStable() {
        // UserDefaults round-trips on the rawValue, so renaming a case would
        // silently invalidate every user's saved preference.
        XCTAssertEqual(FolderSortOrder.nameAscending.rawValue, "nameAscending")
        XCTAssertEqual(FolderSortOrder.nameDescending.rawValue, "nameDescending")
        XCTAssertEqual(FolderSortOrder.dateModifiedNewest.rawValue, "dateModifiedNewest")
        XCTAssertEqual(FolderSortOrder.dateModifiedOldest.rawValue, "dateModifiedOldest")
        XCTAssertEqual(FolderSortOrder.dateCreatedNewest.rawValue, "dateCreatedNewest")
        XCTAssertEqual(FolderSortOrder.dateCreatedOldest.rawValue, "dateCreatedOldest")
    }
}
