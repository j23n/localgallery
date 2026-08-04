import Foundation
import XCTest
@testable import LocalGallery

/// Record types + plumbing shared by the Phase-4 conformance harnesses
/// (`SeededRNGConformanceTests`, `MemoryEngineConformanceTests`,
/// `ScheduledMemoriesConformanceTests`, `IndexConformanceTests`).
///
/// The fixtures live in `core/fixtures/memories-conformance/` — one copy in
/// the repo, referenced into this test bundle as a folder resource
/// (project.yml) and read straight off disk by the Rust side
/// (`core/gallery-model/tests/memories_conformance_fixtures.rs`). Same
/// arrangement, same regeneration rules and same "a mismatch never rewrites
/// the fixture" guarantee as the Phase-3 set — see `ConformanceFixtures`.
enum MemoriesConformance {

    static let directory = ConformanceFixtures.memoriesDirectoryName

    // MARK: - Dates

    /// Fixture dates are absolute instants written in UTC. The engine reads
    /// `Calendar.current`, so the *interpretation* of an instant depends on
    /// the scenario's `timeZone`; the instant itself does not.
    static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    static func iso(_ date: Date) -> String { utcFormatter.string(from: date) }
    static func iso(_ date: Date?) -> String? { date.map(iso) }

    /// Build a UTC instant. Mirrors `date(_:_:_:_:_:)` in `Fixtures.swift`
    /// but with seconds, which several fixtures need for dedup-window edges.
    static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)) ?? Date()
    }

    // MARK: - Time-zone override

    /// Run `body` with the process time zone (and therefore
    /// `Calendar.current` / `TimeZone.current`) pinned to `identifier`.
    ///
    /// `MemoryEngine.generate` reads `Calendar.current` rather than taking a
    /// calendar parameter — the only way to exercise a non-UTC scenario is to
    /// move the process. Restored on the way out, including on throw.
    static func withTimeZone<T>(_ identifier: String, _ body: () async throws -> T) async rethrows -> T {
        let previous = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: identifier) ?? previous
        defer { NSTimeZone.default = previous }
        return try await body()
    }

    static func withTimeZoneSync<T>(_ identifier: String, _ body: () throws -> T) rethrows -> T {
        let previous = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: identifier) ?? previous
        defer { NSTimeZone.default = previous }
        return try body()
    }
}

// MARK: - Photos

/// A `PhotoFile` reduced to the fields the memory engine and the two indexes
/// actually read. `id` is redundant (it is `stableID(for: path)`) and recorded
/// anyway so the Rust side can cross-check its own derivation.
struct ConfPhoto: Codable, Equatable {
    let path: String
    let id: String
    let filename: String
    let dateTaken: String?
    let tags: [String]
    let countryCode: String?
    let gpsLatitude: Double?
    let gpsLongitude: Double?
    let isVideo: Bool

    init(_ photo: PhotoFile) {
        path = photo.url.path
        id = photo.id.uuidString
        filename = photo.filename
        dateTaken = MemoriesConformance.iso(photo.dateTaken)
        tags = photo.hierarchicalTags.map(\.fullPath)
        countryCode = photo.countryCode
        gpsLatitude = photo.gpsLatitude
        gpsLongitude = photo.gpsLongitude
        isVideo = photo.isVideo
    }
}

/// Test-side photo builder. Deliberately narrow: the memory engine and the
/// indexes read exactly these fields, so a fixture that carries more would
/// imply the port has to reproduce more.
func confPhoto(
    _ path: String,
    date: Date? = nil,
    tags: [String] = [],
    countryCode: String? = nil,
    gps: (lat: Double, lon: Double)? = nil,
    filename: String? = nil
) -> PhotoFile {
    PhotoFile.fixture(
        url: URL(fileURLWithPath: path),
        filename: filename,
        dateTaken: date,
        tags: tags,
        countryCode: countryCode,
        gps: gps
    )
}

// MARK: - Engine inputs

struct ConfFolder: Codable, Equatable {
    let path: String
    let name: String
    let photoPaths: [String]
}

struct ConfContact: Codable, Equatable {
    let id: String
    let givenName: String
    let familyName: String
    let birthdayMonth: Int?
    let birthdayDay: Int?

    init(_ c: ContactInfo) {
        id = c.id
        givenName = c.givenName
        familyName = c.familyName
        birthdayMonth = c.birthday?.month
        birthdayDay = c.birthday?.day
    }
}

/// `[String: PersonLink]` as an array so the fixture keeps a stable, readable
/// order (and so `.disabled` versus `.manual` is legible without knowing how
/// Swift synthesises an enum's `Codable`).
struct ConfLink: Codable, Equatable {
    let personPath: String
    let kind: String            // "manual" | "disabled"
    let contactID: String?
}

/// A `[String: Date]` entry (seen memories, surfaced clusters).
struct ConfDateEntry: Codable, Equatable {
    let key: String
    let date: String
}

struct ConfEngineInputs: Codable, Equatable {
    /// The instant handed to `generate(now:)`, in UTC.
    let now: String
    /// Process time zone the scenario ran under — `MemoryEngine.generate`
    /// reads `Calendar.current`, so this is an input, not a note.
    let timeZone: String
    let seed: String
    let birthdaysEnabled: Bool
    let mePersonPath: String
    let hiddenPeople: [String]
    let photos: [ConfPhoto]
    let leafFolders: [ConfFolder]
    let contacts: [ConfContact]
    /// Derived from `contacts` exactly as `ContactLinker.index` derives it:
    /// `fullName.lowercased()` → contact, first write wins.
    let contactsByLowerNameIsDerivedFromContacts: Bool
    let personContactLinks: [ConfLink]
    let seenMemoryIDs: [ConfDateEntry]
    let surfacedClusters: [ConfDateEntry]
}

struct ConfMemory: Codable, Equatable {
    let id: String
    let type: String
    let title: String
    let subtitle: String?
    /// Ordered. The order is the slideshow order and is part of the contract.
    let photoIDs: [String]
    let photoCount: Int
    let coverPhotoID: String
    /// `Memory.score` is the score *before* the daily jitter — the jitter is
    /// never stored on a `Memory` and is therefore not directly observable.
    /// What the jitter does observably is decide the order of this list.
    let score: Double
    let yearsAgo: Int?
    let personName: String?
    let dateRangeStart: String?
    let dateRangeEnd: String?

    init(_ m: Memory) {
        id = m.id
        type = m.type.rawValue
        title = m.title
        subtitle = m.subtitle
        photoIDs = m.photoIDs.map(\.uuidString)
        photoCount = m.photoIDs.count
        coverPhotoID = m.coverPhotoID.uuidString
        score = m.score
        yearsAgo = m.yearsAgo
        personName = m.personName
        dateRangeStart = MemoriesConformance.iso(m.dateRange?.lowerBound)
        dateRangeEnd = MemoriesConformance.iso(m.dateRange?.upperBound)
    }
}

struct ConfEngineScenario: Codable, Equatable {
    let name: String
    let notes: [String]
    let inputs: ConfEngineInputs
    /// The selected top-10, in rail order.
    let expected: [ConfMemory]
}

/// Locale/calendar the fixture was produced under. `MemoryEngine` formats
/// subtitles with `DateFormatter.setLocalizedDateFormatFromTemplate` and
/// resolves country names with `Locale.current.localizedString(forRegionCode:)`
/// — both are ICU, both are locale-sensitive, and both land in strings the
/// fixture pins. A harness that runs under a different locale must not silently
/// "fail" against these files.
struct ConfEnvironment: Codable, Equatable {
    let localeIdentifier: String
    let calendarIdentifier: String
    let notes: [String]

    static func current(notes: [String]) -> ConfEnvironment {
        ConfEnvironment(
            localeIdentifier: Locale.current.identifier,
            calendarIdentifier: "\(Calendar.current.identifier)",
            notes: notes
        )
    }
}

struct ConfEngineDump: Codable, Equatable {
    let schema: Int
    let environment: ConfEnvironment
    let notes: [String]
    let scenarios: [ConfEngineScenario]
}
