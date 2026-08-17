import Foundation
import XCTest
@testable import LocalGallery

/// The people domain's persisted state across a rename.
///
/// Every key `PeopleStore` writes is a person's **tag path**, and the rescan
/// that follows a rename cannot tell a renamed person from a new one — so a
/// rename that does not migrate them loses the user's "me" person, their pins,
/// their hidden set and their cover photos, silently, with nothing to notice
/// until they go looking. That is what these cases pin.
@MainActor
final class PeopleStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = TestUserDefaults.make()
    }

    override func tearDown() {
        TestUserDefaults.cleanup(defaults)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> PeopleStore {
        PeopleStore(defaults: defaults, clock: SystemClock(), index: CoreLibraryIndex())
    }

    private func person(_ name: String, count: Int = 1) -> TagSuggestion {
        TagSuggestion(
            id: "people/\(name.lowercased())",
            displayName: name,
            fullPath: "People/\(name)",
            namespace: "People",
            count: count
        )
    }

    // MARK: - The four keys

    func testRenameCarriesEveryPersistedDecisionToTheNewPath() {
        let store = makeStore()
        let photo = UUID()
        store.hidePerson("People/Anna")
        store.unhidePerson("People/Anna")
        store.hidePerson("People/Anna")
        store.toggleFeaturePerson("People/Bob")
        store.toggleFeaturePerson("People/Anna")
        store.toggleFeaturePerson("People/Cy")
        store.setFeaturedPhoto(personPath: "People/Anna", photoID: photo)
        store.markAsMe("People/Anna")

        store.renamePerson(from: "People/Anna", to: "People/Anna Schmidt")

        XCTAssertEqual(store.hiddenPeople, ["People/Anna Schmidt"])
        XCTAssertEqual(
            store.featuredPeople,
            ["People/Bob", "People/Anna Schmidt", "People/Cy"],
            "the feature order is the user's, and a rename is not a reordering"
        )
        XCTAssertEqual(store.featuredPhotoByPerson["People/Anna Schmidt"], photo)
        XCTAssertNil(store.featuredPhotoByPerson["People/Anna"])
        XCTAssertEqual(store.mePersonPath, "People/Anna Schmidt")
    }

    /// The migration has to survive the process, not just the object — every
    /// one of these is written through a `didSet` into UserDefaults.
    func testTheMigratedStateIsWhatTheNextLaunchReads() {
        let store = makeStore()
        store.hidePerson("People/Anna")
        store.toggleFeaturePerson("People/Anna")
        store.setFeaturedPhoto(personPath: "People/Anna", photoID: UUID())
        store.markAsMe("People/Anna")

        store.renamePerson(from: "People/Anna", to: "People/Ada")

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.hiddenPeople, ["People/Ada"])
        XCTAssertEqual(relaunched.featuredPeople, ["People/Ada"])
        XCTAssertNotNil(relaunched.featuredPhotoByPerson["People/Ada"])
        XCTAssertEqual(relaunched.mePersonPath, "People/Ada")
    }

    func testRenamingToTheSameNameChangesNothing() {
        let store = makeStore()
        store.toggleFeaturePerson("People/Anna")
        store.markAsMe("People/Anna")

        store.renamePerson(from: "People/Anna", to: "People/Anna")

        XCTAssertEqual(store.featuredPeople, ["People/Anna"])
        XCTAssertEqual(store.mePersonPath, "People/Anna")
    }

    func testAPersonWithNoPersistedStateRenamesWithoutInventingAny() {
        let store = makeStore()
        store.toggleFeaturePerson("People/Bob")

        store.renamePerson(from: "People/Anna", to: "People/Ada")

        XCTAssertTrue(store.hiddenPeople.isEmpty)
        XCTAssertEqual(store.featuredPeople, ["People/Bob"], "an unrelated person was touched")
        XCTAssertTrue(store.featuredPhotoByPerson.isEmpty)
        XCTAssertEqual(store.mePersonPath, "")
    }

    // MARK: - Collisions

    /// Renaming onto an existing person is a merge at the name level, so both
    /// sides can carry the same decision. Featuring twice would render as two
    /// identical rail entries.
    func testRenamingOntoAFeaturedPersonLeavesOnePin() {
        let store = makeStore()
        store.toggleFeaturePerson("People/Bob")
        store.toggleFeaturePerson("People/Anna")
        store.toggleFeaturePerson("People/Anna Schmidt")

        store.renamePerson(from: "People/Anna", to: "People/Anna Schmidt")

        XCTAssertEqual(
            store.featuredPeople,
            ["People/Bob", "People/Anna Schmidt"],
            "the survivor keeps the older position, and nobody is pinned twice"
        )
    }

    /// Both sides hidden collapses to one entry, which is what a set is for —
    /// and the result must still be hidden, not quietly back on the rail.
    func testRenamingOntoAHiddenPersonLeavesThemHidden() {
        let store = makeStore()
        store.hidePerson("People/Anna")
        store.hidePerson("People/Anna Schmidt")

        store.renamePerson(from: "People/Anna", to: "People/Anna Schmidt")

        XCTAssertEqual(store.hiddenPeople, ["People/Anna Schmidt"])
    }

    /// Both sides have a cover photo and only one can survive. The name the
    /// user just chose is the one whose choice is kept.
    func testACoverPhotoCollisionKeepsTheNewNamesChoice() {
        let store = makeStore()
        let oldCover = UUID()
        let newCover = UUID()
        store.setFeaturedPhoto(personPath: "People/Anna", photoID: oldCover)
        store.setFeaturedPhoto(personPath: "People/Anna Schmidt", photoID: newCover)

        store.renamePerson(from: "People/Anna", to: "People/Anna Schmidt")

        XCTAssertEqual(store.featuredPhotoByPerson["People/Anna Schmidt"], newCover)
        XCTAssertNil(store.featuredPhotoByPerson["People/Anna"], "the old entry was left behind")
        XCTAssertEqual(store.featuredPhotoByPerson.count, 1)
    }

    /// The rail is what the user actually sees the result in: one entry, under
    /// the new name, still ahead of the people who were never featured.
    func testTheRailShowsOnePersonAfterACollidingRename() {
        let store = makeStore()
        store.updateTopPeople([person("Anna Schmidt", count: 9), person("Bob", count: 4)])
        store.toggleFeaturePerson("People/Anna")
        store.toggleFeaturePerson("People/Anna Schmidt")

        store.renamePerson(from: "People/Anna", to: "People/Anna Schmidt")

        XCTAssertEqual(
            store.visiblePeople.map(\.fullPath),
            ["People/Anna Schmidt", "People/Bob"]
        )
    }

    // MARK: - Side effects

    /// Trip titles depend on the "me" person and the memory rail on the hidden
    /// set, so a rename that moves either has to say so.
    func testRenamingNotifiesTheStoreThatItsDerivedStateMoved() {
        let store = makeStore()
        store.markAsMe("People/Anna")
        var widgetExports = 0
        store.onWidgetAffectingChange = { widgetExports += 1 }

        store.renamePerson(from: "People/Anna", to: "People/Ada")

        XCTAssertGreaterThan(widgetExports, 0)
    }
}
