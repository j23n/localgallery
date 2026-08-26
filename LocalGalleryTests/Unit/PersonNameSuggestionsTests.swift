import XCTest
@testable import LocalGallery

final class PersonNameSuggestionsTests: XCTestCase {
    private func contact(
        _ given: String, _ family: String, nickname: String = ""
    ) -> ContactInfo {
        ContactInfo.fixture(givenName: given, familyName: family, nickname: nickname)
    }

    func testAnEmptyFieldOffersLibraryNamesNotTheAddressBook() {
        let items = PersonNameSuggestions.matching(
            typed: "",
            libraryNames: ["Zoe", "Anna"],
            contacts: [contact("Alice", "Anderson")]
        )
        XCTAssertEqual(items.map(\.name), ["Anna", "Zoe"])
        XCTAssertTrue(items.allSatisfy { !$0.fromContacts })
    }

    func testTypingAGivenNameSuggestsTheContactFullName() {
        let items = PersonNameSuggestions.matching(
            typed: "Ali",
            libraryNames: ["Anna"],
            contacts: [contact("Alice", "Anderson")]
        )
        XCTAssertEqual(items.map(\.name), ["Alice Anderson"])
        XCTAssertEqual(items.first?.fromContacts, true)
    }

    func testAFamilyNamePrefixSuggestsTheContact() {
        let items = PersonNameSuggestions.matching(
            typed: "Sch",
            libraryNames: [],
            contacts: [contact("Anna", "Schmidt")]
        )
        XCTAssertEqual(items.map(\.name), ["Anna Schmidt"])
    }

    func testANicknameMatchStillInsertsTheFullName() {
        let items = PersonNameSuggestions.matching(
            typed: "Bob",
            libraryNames: [],
            contacts: [contact("Robert", "Smith", nickname: "Bob")]
        )
        XCTAssertEqual(items.map(\.name), ["Robert Smith"])
    }

    func testAPrefixOutranksAContainsMatch() {
        let items = PersonNameSuggestions.matching(
            typed: "Ann",
            libraryNames: ["Joanna", "Anna"],
            contacts: []
        )
        XCTAssertEqual(items.map(\.name), ["Anna", "Joanna"])
    }

    func testLibraryNamesWinATieWithContacts() {
        let items = PersonNameSuggestions.matching(
            typed: "Ann",
            libraryNames: ["Anna"],
            contacts: [contact("Anna", "Schmidt")]
        )
        XCTAssertEqual(items.first?.name, "Anna")
        XCTAssertEqual(items.first?.fromContacts, false)
        XCTAssertEqual(items.map(\.name), ["Anna", "Anna Schmidt"])
    }

    func testALinkedContactIsNotOfferedAlongsideItsLibraryName() {
        let linked = ContactInfo.fixture(id: "c-anna", givenName: "Anna", familyName: "Schmidt")
        let other = ContactInfo.fixture(id: "c-annika", givenName: "Annika", familyName: "Berg")
        let items = PersonNameSuggestions.matching(
            typed: "Ann",
            libraryNames: ["Anna"],
            contacts: [linked, other],
            linkedContactIDs: [linked.id]
        )
        XCTAssertEqual(items.map(\.name), ["Anna", "Annika Berg"])
        XCTAssertFalse(items.contains { $0.name == "Anna Schmidt" })
    }

    func testTheAlreadyTypedNameIsNotSuggested() {
        let items = PersonNameSuggestions.matching(
            typed: "Anna",
            libraryNames: ["Anna"],
            contacts: [contact("Anna", "")]
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testNamelessContactsAreSkipped() {
        let items = PersonNameSuggestions.matching(
            typed: "a",
            libraryNames: ["(No name)"],
            contacts: [ContactInfo.fixture(givenName: "", familyName: "")]
        )
        XCTAssertTrue(items.isEmpty)
    }

    func testTheCapKeepsTheBestPrefixMatches() {
        let library = (1...20).map { String(format: "Alex %02d", $0) }
        let items = PersonNameSuggestions.matching(
            typed: "Alex",
            libraryNames: library,
            contacts: [],
            limit: 8
        )
        XCTAssertEqual(items.count, 8)
        XCTAssertEqual(items.map(\.name), (1...8).map { String(format: "Alex %02d", $0) })
    }
}
