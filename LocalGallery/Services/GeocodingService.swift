import Contacts
import CoreLocation
import Foundation
import Observation
import os

/// Reverse-geocode GPS into photo-tools `Places/*` tags and IPTC location
/// fields, the same shape `photo-tools tag --gps` writes.
///
/// The lookup is Nominatim in the Rust core (English names), same source
/// Linux uses. Coordinates leave the device. The *output* is one nested
/// `Places/<Country>[/<Region>[/<City>[/<Neighborhood>]]]` keyword plus
/// `photoshop:City/State/Country`, `Iptc4xmpCore:CountryCode/Location`, and
/// `phototools:CountryCode`.
///
/// Live lookups are serial and paced at `minLookupInterval`. Nominatim
/// 429 / 5xx and transport failures retry with exponential backoff.
/// A miss (`nil`, or `geocodeFoundNoResult`) is not retried.
///
    /// Photos whose **library row** already carries a `Places/*` name are
    /// not the Scan work queue (`needsLibraryPlaces`). The write path still
    /// reads the **sidecar**: a finished
    /// `Places/<Country>/<Region>/<City>` path is skipped, and no sidecar
    /// means a geocode will persist one.
/// A shallower tag (`Places/France`) is eligible to be *extended* when a
/// later lookup yields the city. Lookups are cached within
/// `cacheRadiusKm` (photo-tools' `geocode_cache_radius_km`, 0.5 km) so a
/// burst of photos from one street is one query.
@Observable
@MainActor
final class GeocodingService {
    /// Live progress of a run. `nil` when idle.
    struct Progress: Equatable, Sendable {
        var done: Int
        var total: Int
        var startedAt: Date
        var countText: String {
            ProgressETA.countText(processed: done, total: total, startedAt: startedAt)
        }
    }

    struct Summary: Equatable, Sendable {
        var processed = 0
        var written = 0
        var skipped = 0
        var failed = 0
        var cancelled = false
    }

    /// One cached reverse-geocode, persisted across launches.
    struct CacheEntry: Codable, Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        var path: String
        var country: String?
        var state: String?
        var city: String?
        var sublocation: String?
        var countryCode: String?
    }

    /// Matches photo-tools' `gps.geocode_cache_radius_km`.
    static let cacheRadiusKm = 0.5

    /// Floor between live Nominatim calls (their polite rate).
    static let minLookupInterval: TimeInterval = 1

    /// Injected endpoint. Empty / unset uses the public OSM instance.
    nonisolated static var nominatimEndpoint: String {
        let env = ProcessInfo.processInfo.environment["LOCALGALLERY_NOMINATIM"] ?? ""
        return env.isEmpty ? "https://nominatim.openstreetmap.org/reverse" : env
    }

    /// Live attempts per unique coordinate, including the first. A photo
    /// that exhausts these is counted failed and left eligible for the
    /// next run — nothing is written, so it is not skipped forever.
    static let maxLookupAttempts = 4

    /// Cap on retry sleep so a throttled library pass cannot stall for
    /// minutes on one coordinate.
    static let maxRetryBackoff: TimeInterval = 16

    /// Nominatim HTTP timeout (core default is 15s). Kept so the Swift
    /// watchdog still abandons a hung transport.
    nonisolated static let lookupTimeout: TimeInterval = 15

    nonisolated enum LookupError: Error, Equatable, Sendable {
        case timedOut
    }

    private(set) var isRunning = false
    private(set) var progress: Progress?
    private(set) var lastSummary: Summary?
    private(set) var lastError: String?

    @ObservationIgnored private let cacheURL: URL
    @ObservationIgnored private var cache: [CacheEntry] = []
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var lastLiveLookupAt: Date?
    @ObservationIgnored var lookup: (@Sendable (Double, Double) async throws -> CacheEntry?)?
    /// Sleep used for pacing and retry backoff. Tests replace this with a
    /// recorder (or a no-op) so they do not wait a real second.
    @ObservationIgnored var wait: (TimeInterval) async -> Void
    /// Clock for the pacing gap. Injected so rate-limit tests do not depend
    /// on wall time.
    @ObservationIgnored var now: () -> Date = Date.init
    /// One photo this run just wrote, skipped, or failed. `LibraryAnalysis`
    /// records it into the live Scan Activity journal.
    @ObservationIgnored var onPlaceRecorded: (@MainActor (URL, String?, ScanActivityEntry.Outcome) -> Void)?

    init(cacheURL: URL) {
        self.cacheURL = cacheURL
        cache = Self.loadCache(from: cacheURL)
        wait = { seconds in
            try? await Task.sleep(for: .seconds(max(0, seconds)))
        }
        lookup = { lat, lon in
            try await Self.liveLookup(latitude: lat, longitude: lon)
        }
    }

    /// Photos this pass should consider: downloaded stills with GPS.
    ///
    /// A finished `Places/<Country>/<Region>/<City>` path (four or more
    /// segments) is left alone — a human or photo-tools placement is not
    /// overwritten. Shallower tags (`Places/France`, `Places/France/Île-de-France`)
    /// stay eligible so a later pass can extend them once the geocoder
    /// actually yields a city. An older lookup often returns country + region
    /// with `locality == nil` for European cities; the first run then
    /// wrote a country-only tag and every later run skipped the photo.
    ///
    /// The sidecar is the write-path source of truth (`placesStillNeeded`).
    /// Scan's work queue uses `needsLibraryPlaces` so a library rescan's
    /// in-memory `Places/*` names skip already-placed photos without
    /// opening every `.xmp` before the first lookup.
    nonisolated static func isEligible(_ photo: PhotoFile, force: Bool = false) -> Bool {
        guard isCandidate(photo) else { return false }
        if force { return true }
        return placesStillNeeded(tags: placeTags(for: photo).map(\.fullPath))
    }

    /// Downloaded still with GPS. No sidecar I/O — safe on the main actor
    /// over the whole library.
    nonisolated static func isCandidate(_ photo: PhotoFile) -> Bool {
        guard !photo.isVideo else { return false }
        if case .remote(downloaded: false) = photo.locality { return false }
        return photo.gpsLatitude != nil && photo.gpsLongitude != nil
    }

    /// GPS still whose library row has no `Places/*` name yet.
    ///
    /// Cheap — reads `PhotoFile.placeTags`, no sidecar I/O. After a places
    /// scan (and after a library rescan that reloads those sidecars) the
    /// name is already on the row; Scan sizes the places queue with this
    /// so already-tagged photos are not "up for places" again.
    nonisolated static func needsLibraryPlaces(_ photo: PhotoFile, force: Bool = false) -> Bool {
        guard isCandidate(photo) else { return false }
        if force { return true }
        return placesNeeded(tags: photo.placeTags.map(\.fullPath), force: force)
    }

    /// Sidecar has no finished `Places/…/City` path. Reads the file.
    nonisolated static func placesStillNeeded(_ photo: PhotoFile) -> Bool {
        placesStillNeeded(tags: placeTags(for: photo).map(\.fullPath))
    }

    /// Places tags from the sidecar. No sidecar ⇒ none, so a write-path
    /// pass will geocode even when the library row already carries a name.
    nonisolated static func placeTags(for photo: PhotoFile) -> [HierarchicalTag] {
        let doc = SidecarDocument.read(imageURL: photo.url)
        guard doc.exists else { return [] }
        return doc.rawTags.map { HierarchicalTag(raw: $0) }
    }

    /// Reverse-geocode `photos` and write sidecars. Serial: Nominatim
    /// is paced at one live request per second.
    func geocode(_ photos: [PhotoFile], force: Bool = false) async -> Summary {
        guard !isRunning else { return lastSummary ?? Summary() }
        isRunning = true
        cancelRequested = false
        lastError = nil
        let startedAt = Date()
        // GPS stills only — no sidecar walk. Scan already dropped rows
        // that carry a `Places/*` name; a finished sidecar city is still
        // skipped per photo below for callers that pass the whole library.
        let candidates = photos.filter(Self.isCandidate)
        Log.ml.info(
            "Places run starting input=\(photos.count) candidates=\(candidates.count) force=\(force) cache=\(cache.count)"
        )
        progress = Progress(done: 0, total: candidates.count, startedAt: startedAt)
        var summary = Summary()

        for photo in candidates {
            if cancelRequested {
                summary.cancelled = true
                break
            }
            summary.processed += 1
            progress = Progress(
                done: summary.processed,
                total: candidates.count,
                startedAt: progress?.startedAt ?? Date()
            )
            guard let lat = photo.gpsLatitude, let lon = photo.gpsLongitude else {
                summary.skipped += 1
                onPlaceRecorded?(photo.url, nil, .skipped)
                continue
            }
            if !force && !Self.placesStillNeeded(photo) {
                summary.skipped += 1
                onPlaceRecorded?(photo.url, nil, .skipped)
                if summary.skipped == 1 || summary.skipped.isMultiple(of: 500) {
                    Log.ml.info(
                        "Places skip already-placed \(summary.skipped) \(Log.r.path(photo.url))"
                    )
                }
                continue
            }
            Log.ml.info(
                "Places photo \(summary.processed)/\(candidates.count) \(Log.r.path(photo.url)) \(Log.r.gps(lat, lon))"
            )
            do {
                let resolveAt = now()
                guard let place = try await resolve(latitude: lat, longitude: lon) else {
                    Log.ml.info(
                        "Places miss \(Log.r.path(photo.url)) in \(Self.ms(since: resolveAt))ms"
                    )
                    summary.skipped += 1
                    onPlaceRecorded?(photo.url, nil, .skipped)
                    continue
                }
                let writeAt = now()
                let written = try await Self.write(
                    photo.url.standardizedFileURL.path,
                    place: place
                )
                Log.ml.info(
                    "Places \(written ? "wrote" : "kept") \(Log.r.place(place.path)) \(Log.r.path(photo.url)) resolve=\(Self.ms(since: resolveAt))ms write=\(Self.ms(since: writeAt))ms"
                )
                if written {
                    summary.written += 1
                    onPlaceRecorded?(photo.url, place.path, .written)
                } else {
                    summary.skipped += 1
                    onPlaceRecorded?(photo.url, place.path, .skipped)
                }
            } catch {
                summary.failed += 1
                lastError = error.localizedDescription
                onPlaceRecorded?(photo.url, nil, .failed(error.localizedDescription))
                if error is PlacesError {
                    Log.ml.error("Places write failed for \(Log.r.path(photo.url)): \(Log.r.error(error))")
                } else {
                    Log.ml.error("Geocode lookup failed for \(Log.r.path(photo.url)): \(Log.r.error(error))")
                }
            }
        }

        persistCache()
        isRunning = false
        cancelRequested = false
        progress = nil
        lastSummary = summary
        Log.ml.info(
            "Places run: \(summary.processed) processed, \(summary.written) written, \(summary.skipped) skipped, \(summary.failed) failed, cancelled=\(summary.cancelled) cache=\(cache.count) elapsed=\(Self.ms(since: startedAt))ms"
        )
        return summary
    }

    func cancel() {
        cancelRequested = true
    }

    /// Cache hit within `cacheRadiusKm`, else a live lookup that is stored.
    func resolve(latitude: Double, longitude: Double) async throws -> CacheEntry? {
        if let hit = nearest(latitude: latitude, longitude: longitude) {
            Log.ml.debug(
                "Places cache hit \(Log.r.place(hit.path)) \(Log.r.gps(latitude, longitude)) cache=\(cache.count)"
            )
            return hit
        }
        guard let lookup else {
            Log.ml.error("Places lookup closure is nil — no provider")
            return nil
        }
        Log.ml.info(
            "Places cache miss \(Log.r.gps(latitude, longitude)) cache=\(cache.count) — live Nominatim"
        )
        guard let entry = try await lookupLive(
            latitude: latitude,
            longitude: longitude,
            using: lookup
        ) else { return nil }
        cache.append(entry)
        persistCache()
        return entry
    }

    /// One coordinate against the geocoder, paced and retried. `nil` is a
    /// real miss (no placemark) and is not retried; thrown errors go through
    /// `isRetryable`.
    private func lookupLive(
        latitude: Double,
        longitude: Double,
        using lookup: @Sendable (Double, Double) async throws -> CacheEntry?
    ) async throws -> CacheEntry? {
        var attempt = 0
        while true {
            if cancelRequested { return nil }
            await waitUntilAllowed()
            if cancelRequested { return nil }
            lastLiveLookupAt = now()
            let attemptAt = now()
            Log.ml.info(
                "Places Nominatim attempt \(attempt + 1)/\(Self.maxLookupAttempts) \(Log.r.gps(latitude, longitude))"
            )
            do {
                let entry = try await lookup(latitude, longitude)
                let path = entry.map { Log.r.place($0.path) } ?? "nil"
                Log.ml.info(
                    "Places Nominatim returned in \(Self.ms(since: attemptAt))ms path=\(path)"
                )
                return entry
            } catch {
                attempt += 1
                let retriesLeft = Self.maxLookupAttempts - attempt
                Log.ml.error(
                    "Places Nominatim error attempt \(attempt) after \(Self.ms(since: attemptAt))ms: \(Log.r.error(error)) retryable=\(Self.isRetryable(error))"
                )
                if Self.isRetryable(error), retriesLeft > 0, !cancelRequested {
                    let backoff = Self.backoff(afterFailures: attempt)
                    Log.ml.info(
                        "Geocode lookup retry \(attempt)/\(Self.maxLookupAttempts - 1) in \(Int(backoff.rounded()))s (\(Log.r.error(error)))"
                    )
                    await pause(backoff)
                    continue
                }
                if Self.isRetryable(error) {
                    Log.ml.error(
                        "Geocode lookup failed after \(attempt) attempts: \(Log.r.error(error))"
                    )
                }
                throw error
            }
        }
    }

    /// Sleep until `minLookupInterval` has passed since the last live call.
    private func waitUntilAllowed() async {
        guard let last = lastLiveLookupAt else { return }
        let remaining = Self.minLookupInterval - now().timeIntervalSince(last)
        if remaining > 0 {
            await pause(remaining)
        }
    }

    /// Cooperative sleep: sliced so Cancel does not wait out a full backoff.
    private func pause(_ seconds: TimeInterval) async {
        var remaining = seconds
        while remaining > 0.000_001, !cancelRequested {
            let slice = min(0.25, remaining)
            await wait(slice)
            remaining -= slice
        }
    }

    /// Transient failures worth another try. Nominatim 429/5xx arrive as
    /// `GeoError.retryable`. Tests still inject `kCLErrorNetwork`.
    static func isRetryable(_ error: Error) -> Bool {
        if case .retryable = error as? GeoError { return true }
        let ns = error as NSError
        if error is LookupError { return true }
        if ns.domain == kCLErrorDomain {
            return ns.code == CLError.Code.network.rawValue
        }
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// 1s, 2s, 4s, … capped at `maxRetryBackoff`.
    static func backoff(afterFailures failures: Int) -> TimeInterval {
        let raw = minLookupInterval * pow(2, Double(max(0, failures - 1)))
        return min(maxRetryBackoff, raw)
    }

    private func nearest(latitude: Double, longitude: Double) -> CacheEntry? {
        var best: (CacheEntry, Double)?
        for entry in cache {
            let d = Self.haversineKm(latitude, longitude, entry.latitude, entry.longitude)
            if d < Self.cacheRadiusKm, best.map({ d < $1 }) ?? true {
                best = (entry, d)
            }
        }
        return best?.0
    }

    private func persistCache() {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let disk = DiskCache(version: Self.diskCacheVersion, entries: cache)
            let data = try JSONEncoder().encode(disk)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Log.ml.error("Geocode cache write failed: \(Log.r.error(error))")
        }
    }

    /// v1 was a bare `[CacheEntry]` array. Those rows often have no city
    /// because we only read `CLPlacemark.locality`. Drop them so the next
    /// scan re-queries with the fuller mapping.
    private static let diskCacheVersion = 2

    private struct DiskCache: Codable {
        var version: Int
        var entries: [CacheEntry]
    }

    private static func loadCache(from url: URL) -> [CacheEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let disk = try? JSONDecoder().decode(DiskCache.self, from: data),
           disk.version == diskCacheVersion
        {
            return disk.entries
        }
        return []
    }

    /// Off the main actor so a hung Apple call cannot pin the UI, and so
    /// Nominatim runs off the main actor so a hung HTTP call cannot pin the UI.
    nonisolated private static func liveLookup(
        latitude: Double,
        longitude: Double
    ) async throws -> CacheEntry? {
        let started = Date()
        let timeout = lookupTimeout
        Log.ml.info(
            "Places Nominatim starting \(Log.r.gps(latitude, longitude)) timeout=\(Int(timeout))s"
        )
        do {
            return try await withThrowingTaskGroup(of: CacheEntry?.self) { group in
                group.addTask {
                    try await Self.reverseGeocode(latitude: latitude, longitude: longitude)
                }
                group.addTask {
                    var waited = 0
                    let step = 5
                    while waited + step < Int(timeout) {
                        try await Task.sleep(for: .seconds(step))
                        waited += step
                        Log.ml.info(
                            "Places Nominatim still waiting \(waited)s \(Log.r.gps(latitude, longitude))"
                        )
                    }
                    try await Task.sleep(for: .seconds(timeout - Double(waited)))
                    Log.ml.error(
                        "Places Nominatim timed out after \(Int(timeout))s \(Log.r.gps(latitude, longitude))"
                    )
                    throw LookupError.timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                Log.ml.info(
                    "Places Nominatim finished in \(Self.ms(since: started))ms \(Log.r.gps(latitude, longitude))"
                )
                return first
            }
        } catch {
            Log.ml.error(
                "Places Nominatim failed in \(Self.ms(since: started))ms: \(Log.r.error(error))"
            )
            throw error
        }
    }

    nonisolated private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    nonisolated private static func reverseGeocode(
        latitude: Double,
        longitude: Double
    ) async throws -> CacheEntry? {
        let built = try nominatimLookup(
            endpoint: nominatimEndpoint,
            latitude: latitude,
            longitude: longitude
        )
        guard let built else { return nil }
        return CacheEntry(
            latitude: latitude,
            longitude: longitude,
            path: built.path,
            country: built.country,
            state: built.state,
            city: built.city,
            sublocation: built.sublocation,
            countryCode: built.countryCode
        )
    }

    /// The CLPlacemark fields Places actually reads. Isolated so tests can
    /// feed a Paris-without-`locality` mark without constructing a placemark.
    nonisolated struct PlacemarkParts: Equatable, Sendable {
        var country: String? = nil
        var state: String? = nil
        var subAdministrativeArea: String? = nil
        var locality: String? = nil
        var postalCity: String? = nil
        var subLocality: String? = nil
        var isoCountryCode: String? = nil
    }

    nonisolated static func place(from mark: CLPlacemark, latitude: Double, longitude: Double) -> CacheEntry? {
        place(
            from: PlacemarkParts(
                country: mark.country,
                state: mark.administrativeArea,
                subAdministrativeArea: mark.subAdministrativeArea,
                locality: mark.locality,
                postalCity: mark.postalAddress?.city,
                subLocality: mark.subLocality,
                isoCountryCode: mark.isoCountryCode
            ),
            latitude: latitude,
            longitude: longitude
        )
    }

    /// Apple often leaves `locality` nil for European cities (Paris is a
    /// common case): the city sits on `postalAddress.city` or
    /// `subAdministrativeArea` instead. Falling back through those — and
    /// dropping duplicates of country/state — is what turns
    /// `Places/France` + a country code into `Places/France/Île-de-France/Paris`.
    nonisolated static func place(from parts: PlacemarkParts, latitude: Double, longitude: Double) -> CacheEntry? {
        // Apple often leaves `locality` nil for European cities; the city
        // sits on `postalAddress.city` or `subAdministrativeArea` instead.
        // The core then collapses duplicate country/state/city levels.
        let city = nonempty(parts.locality)
            ?? nonempty(parts.postalCity)
            ?? nonempty(parts.subAdministrativeArea)
        guard let built = placeFromParts(
            country: parts.country,
            state: parts.state,
            city: city,
            sublocation: parts.subLocality,
            countryCode: parts.isoCountryCode
        ) else { return nil }
        return CacheEntry(
            latitude: latitude,
            longitude: longitude,
            path: built.path,
            country: built.country,
            state: built.state,
            city: built.city,
            sublocation: built.sublocation,
            countryCode: built.countryCode
        )
    }

    nonisolated private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func write(_ path: String, place: CacheEntry) async throws -> Bool {
        let payload = PlaceWrite(
            path: place.path,
            country: place.country,
            state: place.state,
            city: place.city,
            sublocation: place.sublocation,
            countryCode: place.countryCode
        )
        return try await Task.detached(priority: .utility) {
            try writePlaces(imagePath: path, place: payload)
        }.value
    }

    /// Earth-surface distance in kilometres.
    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2)
            + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Test/UI alias for the core's prefix rule.
func isStrictPlacesPrefix(_ existing: String, of newer: String) -> Bool {
    isStrictPlacesPrefix(existing: existing, newer: newer)
}
