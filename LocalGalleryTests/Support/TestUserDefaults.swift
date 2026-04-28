import Foundation

/// A `UserDefaults` instance scoped to a fresh suite name per test, so
/// `didSet` writers don't leak between cases. Callers must invoke
/// `cleanup(_:)` from `tearDown()` to drop the persistent domain.
enum TestUserDefaults {
    static func make() -> UserDefaults {
        let suite = "LocalGallery.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    static func cleanup(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}
