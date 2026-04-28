import Foundation
import Contacts
import os

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
