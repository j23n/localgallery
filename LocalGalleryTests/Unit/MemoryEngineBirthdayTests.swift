import XCTest
@testable import LocalGallery

/// `generateBirthdayMemories` resolves a person tag to a contact three ways
/// (auto-match by name, explicit `.manual` link, explicit `.disabled`) and
/// only fires when the target day matches the contact's birthday month/day.
final class MemoryEngineBirthdayTests: XCTestCase {

    private var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    private let june11 = DateComponents(month: 6, day: 11)

    /// Photos tagged with `person`, spaced beyond the 60s dedup window.
    private func photos(of person: String, dates: [Date?]) -> [PhotoFile] {
        dates.enumerated().map { i, d in
            PhotoFile.fixture(
                url: URL(fileURLWithPath: "/lib/\(person.replacingOccurrences(of: "/", with: "-"))-\(i).jpg"),
                dateTaken: d,
                tags: [person]
            )
        }
    }

    func testAutoMatchByDisplayNameCaseInsensitive() {
        let alice = ContactInfo.fixture(id: "c1", givenName: "Alice", familyName: "Anderson",
                                        birthday: DateComponents(month: 6, day: 11))
        let library = photos(of: "People/Alice Anderson", dates: [date(2022, 3, 1), date(2023, 4, 2)])

        let memories = MemoryEngine.generateBirthdayMemories(
            from: library,
            contacts: [alice],
            links: [:],
            lowerNameIndex: ["alice anderson": alice],
            calendar: utc,
            todayComponents: june11
        )
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.id, "birthday-People/Alice Anderson")
        XCTAssertEqual(memories.first?.type, .birthday)
        XCTAssertEqual(memories.first?.personName, "Alice Anderson")
        XCTAssertEqual(memories.first?.score, 100.0)
    }

    func testNoMemoryWhenBirthdayIsAnotherDay() {
        let alice = ContactInfo.fixture(id: "c1", birthday: DateComponents(month: 12, day: 24))
        let library = photos(of: "People/Alice Anderson", dates: [date(2022, 3, 1)])
        let memories = MemoryEngine.generateBirthdayMemories(
            from: library, contacts: [alice], links: [:],
            lowerNameIndex: ["alice anderson": alice],
            calendar: utc, todayComponents: june11
        )
        XCTAssertTrue(memories.isEmpty)
    }

    func testManualLinkWinsOverNameMismatch() {
        // The tag display name matches no contact, but the user linked it
        // explicitly — the manual link must resolve.
        let bob = ContactInfo.fixture(id: "c2", givenName: "Robert", familyName: "Brown",
                                      birthday: DateComponents(month: 6, day: 11))
        let library = photos(of: "People/Bobby", dates: [date(2021, 1, 1)])
        let memories = MemoryEngine.generateBirthdayMemories(
            from: library, contacts: [bob],
            links: ["People/Bobby": .manual(contactID: "c2")],
            lowerNameIndex: [:],
            calendar: utc, todayComponents: june11
        )
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.personName, "Bobby")
    }

    func testDisabledLinkSuppressesAutoMatch() {
        let alice = ContactInfo.fixture(id: "c1", birthday: DateComponents(month: 6, day: 11))
        let library = photos(of: "People/Alice Anderson", dates: [date(2022, 3, 1)])
        let memories = MemoryEngine.generateBirthdayMemories(
            from: library, contacts: [alice],
            links: ["People/Alice Anderson": .disabled],
            lowerNameIndex: ["alice anderson": alice],
            calendar: utc, todayComponents: june11
        )
        XCTAssertTrue(memories.isEmpty)
    }

    func testHiddenPeopleAreSuppressed() {
        let alice = ContactInfo.fixture(id: "c1", birthday: DateComponents(month: 6, day: 11))
        let library = photos(of: "People/Alice Anderson", dates: [date(2022, 3, 1)])
        let memories = MemoryEngine.generateBirthdayMemories(
            from: library, contacts: [alice], links: [:],
            lowerNameIndex: ["alice anderson": alice],
            calendar: utc, todayComponents: june11,
            hiddenPeople: ["People/Alice Anderson"]
        )
        XCTAssertTrue(memories.isEmpty)
    }

    func testDateRangeIgnoresUndatedPhotosAndCoverIsMostRecentDated() {
        let alice = ContactInfo.fixture(id: "c1", birthday: DateComponents(month: 6, day: 11))
        let first = date(2020, 5, 1)
        let last = date(2023, 8, 9)
        // One undated photo must not collapse the range (and the subtitle
        // with it) to nil; the cover should be the most recent *dated* photo.
        let library = photos(of: "People/Alice Anderson", dates: [nil, first, last])

        let memories = MemoryEngine.generateBirthdayMemories(
            from: library, contacts: [alice], links: [:],
            lowerNameIndex: ["alice anderson": alice],
            calendar: utc, todayComponents: june11
        )
        guard let memory = memories.first else { return XCTFail("expected a birthday memory") }
        XCTAssertEqual(memory.dateRange?.lowerBound, first)
        XCTAssertEqual(memory.dateRange?.upperBound, last)

        let mostRecentDated = library.first { $0.dateTaken == last }
        XCTAssertEqual(memory.coverPhotoID, mostRecentDated?.id)
    }
}
