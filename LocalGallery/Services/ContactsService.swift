import Foundation
import Contacts
import os

/// Injectable surface that `GalleryStore` talks to for address-book access.
/// `LiveContactsService` is the production wrapper around the static
/// `ContactsService` helpers; tests can substitute a stub returning fixture
/// contacts. View-layer helpers (`isAuthorized(_:)`, `authorizationStatus()`)
/// keep calling the static `ContactsService` enum directly — they don't need
/// the test seam.
protocol ContactsServicing: Sendable {
    func authorizationStatus() -> CNAuthorizationStatus
    func requestAccess() async -> Bool
    func loadContacts() async -> [ContactInfo]
}

struct LiveContactsService: ContactsServicing {
    func authorizationStatus() -> CNAuthorizationStatus { ContactsService.authorizationStatus() }
    func requestAccess() async -> Bool { await ContactsService.requestAccess() }
    func loadContacts() async -> [ContactInfo] { await ContactsService.loadContacts() }
}

#if DEBUG
/// Synchronous, deterministic stub — tests pre-load `contacts` and assert
/// against memory generation downstream.
struct StubContactsService: ContactsServicing {
    var contacts: [ContactInfo] = []
    var status: CNAuthorizationStatus = .authorized
    func authorizationStatus() -> CNAuthorizationStatus { status }
    func requestAccess() async -> Bool {
        ContactsService.isAuthorized(status)
    }
    func loadContacts() async -> [ContactInfo] { contacts }
}
#endif

/// Static wrapper around `CNContactStore`. Keeps Contacts.framework concerns
/// out of `GalleryStore` and gives memory generation a Sendable snapshot to
/// work with.
enum ContactsService {
    static func authorizationStatus() -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// Whether the current status grants enough access to enumerate contacts.
    static func isAuthorized(_ status: CNAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    /// Prompt the user for Contacts access if not already determined. Returns
    /// `true` when the app has full or limited authorization afterwards.
    static func requestAccess() async -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if isAuthorized(status) { return true }
        switch status {
        case .denied, .restricted:
            return false
        case .notDetermined:
            let store = CNContactStore()
            do {
                return try await store.requestAccess(for: .contacts)
            } catch {
                Log.contacts.error("Contacts access request failed: \(error.localizedDescription)")
                return false
            }
        default:
            return false
        }
    }

    /// Load all contacts. Returns `[]` (without throwing) when access is denied
    /// or restricted so callers can no-op silently.
    static func loadContacts() async -> [ContactInfo] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard isAuthorized(status) else { return [] }

        return await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactBirthdayKey as CNKeyDescriptor,
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)
            request.unifyResults = true
            var collected: [ContactInfo] = []
            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    collected.append(ContactInfo(
                        id: contact.identifier,
                        givenName: contact.givenName,
                        familyName: contact.familyName,
                        birthday: contact.birthday
                    ))
                }
            } catch {
                Log.contacts.error("Failed to enumerate contacts: \(error.localizedDescription)")
            }
            let withBirthday = collected.filter { $0.hasUsableBirthday }.count
            Log.contacts.info("Loaded \(collected.count) contacts (\(withBirthday) with birthdays)")
            return collected
        }.value
    }
}
