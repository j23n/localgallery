import Foundation
import os

/// The app's side of the Rust core's memory engine (Phase 4).
///
/// Replaces `MemoryEngine` and its four extension files. The score ladder,
/// trip detection, birthdays, `finalize`, the seeded jitter and the greedy
/// cluster-unique selection all live in `gallery-memories` now; what is here is
/// the marshalling and the two things a Swift caller still owns:
///
/// * **Running off the main actor.** Both entry points are `nonisolated` and
///   hop to a detached task, so the FFI never runs on the main thread —
///   `_plans/06-performance-baseline.md` Finding 3, which measured the
///   scheduled-memories pass at ~9 s of main-thread stall.
/// * **Forwarding cancellation.** `Task.detached` swallows the caller's
///   cancellation, so `generate` wires it explicitly through
///   `withTaskCancellationHandler` into the core's `MemoryGenerator` — the same
///   arrangement `MemoryEngine.generate` had, just with the flag on the other
///   side of the boundary.
///
/// Nothing here decides anything. The once-per-day gate, the seen/cool-down
/// bookkeeping, the hidden set and the cloud-placeholder input filter stay in
/// `MemoryCoordinator`; the widget's use of the horizon stays in `GalleryStore`.
enum CoreMemories {

    /// Everything the engine reads, snapshotted on the main actor by the
    /// caller. A plain `Sendable` value so the whole call can cross to a
    /// detached task without touching the Store.
    struct Inputs: Sendable {
        var photos: [PhotoFile]
        /// The cloud placeholders `MemoryCoordinator` filtered out of `photos`.
        ///
        /// The engine shows them to the **folder-event ladder only**, because
        /// the deleted Swift read `folder.photos` — the folder's own array,
        /// which the placeholder filter never touched — while every other
        /// generator drew from the filtered `allPhotos`. Leaving them out makes
        /// placeholder-heavy folders fall below the 15-photo floor and vanish,
        /// and silently re-cuts the ones that survive.
        var folderPlaceholderPhotos: [PhotoFile]
        var leafFolders: [PhotoFolder]
        var contacts: [ContactInfo]
        var personContactLinks: [String: PersonLink]
        var birthdaysEnabled: Bool
        var mePersonPath: String
        var hiddenPeople: Set<String>
        var now: Date
        var seed: String
        var seenMemoryIDs: [String: Date]
        var surfacedClusters: [String: Date]

        init(
            photos: [PhotoFile],
            folderPlaceholderPhotos: [PhotoFile] = [],
            leafFolders: [PhotoFolder] = [],
            contacts: [ContactInfo] = [],
            personContactLinks: [String: PersonLink] = [:],
            birthdaysEnabled: Bool = true,
            mePersonPath: String = "",
            hiddenPeople: Set<String> = [],
            now: Date,
            seed: String = "",
            seenMemoryIDs: [String: Date] = [:],
            surfacedClusters: [String: Date] = [:]
        ) {
            self.photos = photos
            self.folderPlaceholderPhotos = folderPlaceholderPhotos
            self.leafFolders = leafFolders
            self.contacts = contacts
            self.personContactLinks = personContactLinks
            self.birthdaysEnabled = birthdaysEnabled
            self.mePersonPath = mePersonPath
            self.hiddenPeople = hiddenPeople
            self.now = now
            self.seed = seed
            self.seenMemoryIDs = seenMemoryIDs
            self.surfacedClusters = surfacedClusters
        }
    }

    /// A memory pre-published for a future day, with its validity window.
    struct Scheduled: Sendable {
        let memory: Memory
        let validFrom: Date
        let validTo: Date
    }

    /// How far ahead calendar-tied memories are pre-published. Read from the
    /// core so the two cannot drift.
    static let horizonDays = Int(scheduledMemoryHorizonDays())

    // MARK: - Generation

    /// Run the ladder and return the selected top-10.
    ///
    /// Cancellation is forwarded into the core; a cancelled run answers with an
    /// empty list, exactly as the Swift engine's `Task.isCancelled` checks did.
    /// The caller is expected to check `Task.isCancelled` afterwards rather than
    /// publish that empty list over a good cached one.
    nonisolated static func generate(_ inputs: Inputs) async -> [Memory] {
        // One generator per run: `cancel()` is sticky by design, so a
        // cancellation that lands before the core call starts is still seen.
        let generator = MemoryGenerator()
        let results = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                // Marshalling is inside the detached task, not before it: it
                // walks every photo twice (once into a `ScanPhoto`, once for
                // its UTC offset) and the caller is `MemoryCoordinator`, which
                // is `@MainActor`.
                generator.generate(inputs: record(from: inputs))
            }.value
        } onCancel: {
            generator.cancel()
        }
        return results.compactMap(memory(from:))
    }

    /// Pre-compute the next `horizonDays` days of calendar-tied memories
    /// (onThisDay, yearsAgo, birthdays) for the widget. Day 0 is excluded — it
    /// is already on the rail.
    ///
    /// `hiddenMemoryIDs` is `MemoryCoordinator.hiddenMemories`, passed
    /// separately because it is coordinator state rather than engine input.
    nonisolated static func computeScheduled(
        _ inputs: Inputs,
        hiddenMemoryIDs: Set<String>
    ) async -> [Scheduled] {
        let hidden = Array(hiddenMemoryIDs)
        let horizon = Int64(horizonDays)
        let items = await Task.detached(priority: .utility) {
            computeScheduledMemories(
                inputs: record(from: inputs), horizonDays: horizon, hiddenMemoryIds: hidden
            )
        }.value
        return items.compactMap { item in
            memory(from: item.memory).map {
                Scheduled(
                    memory: $0,
                    validFrom: Date(timeIntervalSinceReferenceDate: item.validFrom),
                    validTo: Date(timeIntervalSinceReferenceDate: item.validTo)
                )
            }
        }
    }

    // MARK: - Pure helpers the app still calls

    /// Memories sharing a cluster key are mutually exclusive in one rail render
    /// and share a cool-down: a trip parent and its sub-trips collapse to
    /// `trip-<key>`; every other id is its own cluster.
    static func clusterKey(for memoryID: String) -> String {
        memoryClusterKey(memoryId: memoryID)
    }

    /// Localized country name for an ISO 3166-1 alpha-2 code.
    ///
    /// **Behaviour change, deliberate and documented:** this was
    /// `Locale.current.localizedString(forRegionCode:)`, so it followed the
    /// device language. The core ships an `en_US` table instead, because a trip
    /// memory's *title* is part of its identity in the fixtures and an ICU
    /// dependency in the core buys one string per country. A non-English device
    /// now sees English country names in trip titles and the photo-info pill.
    static func countryName(from code: String) -> String? {
        memoryCountryName(code: code)
    }

    // MARK: - Marshalling

    /// `Calendar.current.timeZone.secondsFromGMT(for:)` per photo — the offset
    /// that was in force **when the photo was taken**, not when the run
    /// happens.
    ///
    /// The core has no tz database, so this is the only place the real
    /// transition table can be consulted. Without it a single offset resolved
    /// at `now` buckets a summer photo on a different local day depending on
    /// the season the generation runs in, which moves `density-*` and `trip-*`
    /// ids — and therefore cluster keys — twice a year, so the seen (−30) and
    /// cool-down (−25) penalties stop matching the history the user's own taps
    /// wrote.
    ///
    /// An undated photo gets the offset at `now`: it has no instant of its own,
    /// and every ladder that buckets by day ignores it anyway.
    ///
    /// One `secondsFromGMT(for:)` per photo is ~20 ms over 20k. This runs
    /// inside the detached task, never on the main actor.
    private static func offsets(for photos: [PhotoFile], fallback: Date) -> [Int32] {
        let zone = Calendar.current.timeZone
        return photos.map { Int32(zone.secondsFromGMT(for: $0.dateTaken ?? fallback)) }
    }

    private static func record(from inputs: Inputs) -> MemoryGenerationInputs {
        MemoryGenerationInputs(
            photos: inputs.photos.map(CoreScanner.record(of:)),
            photoTimeZoneOffsets: offsets(for: inputs.photos, fallback: inputs.now),
            folderPlaceholderPhotos: inputs.folderPlaceholderPhotos.map(CoreScanner.record(of:)),
            folderPlaceholderTimeZoneOffsets: offsets(
                for: inputs.folderPlaceholderPhotos, fallback: inputs.now
            ),
            leafFolders: inputs.leafFolders.map {
                MemoryLeafFolder(
                    id: $0.id.uuidString,
                    name: $0.name,
                    photoIds: $0.photos.map(\.id.uuidString)
                )
            },
            contacts: inputs.contacts.map {
                MemoryContact(
                    id: $0.id,
                    givenName: $0.givenName,
                    familyName: $0.familyName,
                    birthdayMonth: $0.birthday?.month.map(UInt32.init),
                    birthdayDay: $0.birthday?.day.map(UInt32.init)
                )
            },
            personContactLinks: inputs.personContactLinks.map { path, link in
                switch link {
                case .manual(let contactID):
                    return MemoryPersonLink(personPath: path, contactId: contactID)
                case .disabled:
                    // No contact id *is* `.disabled` on the wire.
                    return MemoryPersonLink(personPath: path, contactId: nil)
                }
            },
            birthdaysEnabled: inputs.birthdaysEnabled,
            mePersonPath: inputs.mePersonPath,
            hiddenPeople: Array(inputs.hiddenPeople),
            now: inputs.now.timeIntervalSinceReferenceDate,
            // The offset at `now`, which is what today, the horizon and the two
            // penalty windows are computed in. Each *photo* carries its own
            // (see `offsets(for:fallback:)`), so this one is never applied to
            // history.
            //
            // Read off `Calendar.current.timeZone`, **not** `TimeZone.current`,
            // and that is load-bearing: `TimeZone.current` is cached and does
            // not track an `NSTimeZone.default` override, so it answers GMT in
            // exactly the situation the non-UTC conformance scenario creates —
            // and would answer a stale zone on a device whose zone changed
            // while the app was running. `Calendar.current.timeZone` resolves
            // through the current calendar every time, which is what the
            // deleted engine read.
            timeZoneOffsetSeconds: Int32(Calendar.current.timeZone.secondsFromGMT(for: inputs.now)),
            seed: inputs.seed,
            seenMemoryIds: inputs.seenMemoryIDs.map {
                MemoryDateEntry(key: $0.key, date: $0.value.timeIntervalSinceReferenceDate)
            },
            surfacedClusters: inputs.surfacedClusters.map {
                MemoryDateEntry(key: $0.key, date: $0.value.timeIntervalSinceReferenceDate)
            }
        )
    }

    /// A core record → the app's `Memory`. `nil` only when the core handed back
    /// ids that are not UUIDs, which it cannot do — the `compactMap` is there so
    /// a future wire change fails as a missing memory rather than a crash.
    private static func memory(from record: MemoryRecord) -> Memory? {
        guard let cover = UUID(uuidString: record.coverPhotoId) else { return nil }
        let range: ClosedRange<Date>? = {
            guard let start = record.dateRangeStart, let end = record.dateRangeEnd else { return nil }
            let lower = Date(timeIntervalSinceReferenceDate: start)
            let upper = Date(timeIntervalSinceReferenceDate: end)
            return lower <= upper ? lower...upper : nil
        }()
        return Memory(
            id: record.id,
            type: type(of: record.kind),
            title: record.title,
            subtitle: record.subtitle,
            photoIDs: record.photoIds.compactMap(UUID.init(uuidString:)),
            coverPhotoID: cover,
            dateRange: range,
            score: record.score,
            yearsAgo: record.yearsAgo.map(Int.init),
            personName: record.personName
        )
    }

    private static func type(of kind: MemoryKind) -> MemoryType {
        switch kind {
        case .onThisDay: return .onThisDay
        case .yearsAgo: return .yearsAgo
        case .personOverTime: return .personOverTime
        case .folderEvent: return .folderEvent
        case .photoDensity: return .photoDensity
        case .trip: return .trip
        case .birthday: return .birthday
        }
    }

    // MARK: - Diagnostics

    /// One-shot diagnostic dump of the inputs a generation consumes: date
    /// provenance, GPS coverage, `People/*` coverage and the densest days.
    /// Stayed in Swift — it reads nothing the engine decides and logging is not
    /// something the core owns.
    static func logInputSummary(allPhotos: [PhotoFile]) {
        let total = allPhotos.count
        guard total > 0 else { return }

        let withDate = allPhotos.filter { $0.dateTaken != nil }
        let fromMetadata = allPhotos.filter { $0.dateFromMetadata }.count
        let withGPS = allPhotos.filter { $0.gpsLatitude != nil && $0.gpsLongitude != nil }.count
        let withAnyTag = allPhotos.filter { !$0.hierarchicalTags.isEmpty }.count

        let peoplePhotos = allPhotos.filter { photo in
            photo.hierarchicalTags.contains { $0.namespace?.lowercased() == "people" }
        }
        let personNameCounts = Dictionary(
            peoplePhotos.flatMap { photo in
                photo.hierarchicalTags
                    .filter { $0.namespace?.lowercased() == "people" }
                    .map { ($0.displayName, 1) }
            },
            uniquingKeysWith: +
        )
        let topPeople = personNameCounts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\(Log.r.person($0.key))=\($0.value)" }
            .joined(separator: ", ")

        Log.memory.info("""
            Input summary: \(total) photos total
              dates: \(fromMetadata) from metadata, \(withDate.count - fromMetadata) filesystem fallback, \(total - withDate.count) missing
              GPS: \(withGPS) photos
              tags: \(withAnyTag) tagged, \(peoplePhotos.count) with People/*, \(personNameCounts.count) unique names
              top People: \(topPeople.isEmpty ? "(none)" : topPeople)
            """)
    }
}
