import Contacts
import CoreLocation
import Foundation
import Observation
import os

/// Reverse-geocode GPS into photo-tools `Places/*` tags and IPTC location
/// fields, the same shape `photo-tools tag --gps` writes.
///
/// Apple's `CLGeocoder` stands in for Nominatim: it needs no API key and
/// works offline for many regions. The *output* matches photo-tools
/// (schema §1.3 / §2.2): one nested
/// `Places/<Country>[/<Region>[/<City>[/<Neighborhood>]]]` keyword plus
/// `photoshop:City/State/Country`, `Iptc4xmpCore:CountryCode/Location`, and
/// `phototools:CountryCode`.
///
/// Live lookups are serial (CLGeocoder forbids overlap) and paced at
/// `minLookupInterval`. Apple rate-limits per app and reports that as
/// `kCLErrorNetwork`; those errors — and a handful of transport failures —
/// retry with exponential backoff rather than burning the rest of the run.
/// A miss (`nil`, or `geocodeFoundNoResult`) is not retried.
///
/// Photos that already carry a finished `Places/<Country>/<Region>/<City>`
/// path are skipped — a human or photo-tools placement is not overwritten.
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

    /// Floor between live `CLGeocoder` calls. Apple documents no hard
    /// per-second cap, but exceeding the per-app budget fails with
    /// `kCLErrorNetwork`; one lookup a second stays under it in practice
    /// and matches Nominatim's polite rate.
    static let minLookupInterval: TimeInterval = 1

    /// Live attempts per unique coordinate, including the first. A photo
    /// that exhausts these is counted failed and left eligible for the
    /// next run — nothing is written, so it is not skipped forever.
    static let maxLookupAttempts = 4

    /// Cap on retry sleep so a throttled library pass cannot stall for
    /// minutes on one coordinate.
    static let maxRetryBackoff: TimeInterval = 16

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
    /// actually yields a city. CLGeocoder often returns country + region
    /// with `locality == nil` for European cities; the first run then
    /// wrote a country-only tag and every later run skipped the photo.
    nonisolated static func isEligible(_ photo: PhotoFile, force: Bool = false) -> Bool {
        guard !photo.isVideo else { return false }
        if case .remote(downloaded: false) = photo.locality { return false }
        guard photo.gpsLatitude != nil, photo.gpsLongitude != nil else { return false }
        if force { return true }
        let depths = photo.hierarchicalTags.compactMap { tag -> Int? in
            guard tag.namespace?.caseInsensitiveCompare("Places") == .orderedSame else { return nil }
            return tag.fullPath.split(separator: "/").count
        }
        guard let deepest = depths.max() else { return true }
        return deepest < 4
    }

    /// Reverse-geocode `photos` and write sidecars. Serial: `CLGeocoder`
    /// forbids overlapping reverse-geocode requests.
    func geocode(_ photos: [PhotoFile], force: Bool = false) async -> Summary {
        guard !isRunning else { return lastSummary ?? Summary() }
        let eligible = photos.filter { Self.isEligible($0, force: force) }
        isRunning = true
        cancelRequested = false
        progress = Progress(done: 0, total: eligible.count, startedAt: Date())
        lastError = nil
        var summary = Summary()

        for photo in eligible {
            if cancelRequested {
                summary.cancelled = true
                break
            }
            summary.processed += 1
            progress = Progress(
                done: summary.processed,
                total: eligible.count,
                startedAt: progress?.startedAt ?? Date()
            )
            guard let lat = photo.gpsLatitude, let lon = photo.gpsLongitude else {
                summary.skipped += 1
                onPlaceRecorded?(photo.url, nil, .skipped)
                continue
            }
            do {
                guard let place = try await resolve(latitude: lat, longitude: lon) else {
                    summary.skipped += 1
                    onPlaceRecorded?(photo.url, nil, .skipped)
                    continue
                }
                let written = try await Self.write(
                    photo.url.standardizedFileURL.path,
                    place: place
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
                if error is PlacesWriteError {
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
            "Places run: \(summary.processed) processed, \(summary.written) written, \(summary.skipped) skipped, \(summary.failed) failed, cancelled=\(summary.cancelled)"
        )
        return summary
    }

    func cancel() {
        cancelRequested = true
    }

    /// Cache hit within `cacheRadiusKm`, else a live lookup that is stored.
    func resolve(latitude: Double, longitude: Double) async throws -> CacheEntry? {
        if let hit = nearest(latitude: latitude, longitude: longitude) {
            return hit
        }
        guard let lookup else { return nil }
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
            do {
                return try await lookup(latitude, longitude)
            } catch {
                attempt += 1
                let retriesLeft = Self.maxLookupAttempts - attempt
                if Self.isRetryable(error), retriesLeft > 0, !cancelRequested {
                    let backoff = Self.backoff(afterFailures: attempt)
                    Log.ml.info(
                        "Geocode lookup retry \(attempt)/\(Self.maxLookupAttempts - 1) in \(Int(backoff.rounded()))s (\(error.localizedDescription))"
                    )
                    await pause(backoff)
                    continue
                }
                if Self.isRetryable(error) {
                    Log.ml.error(
                        "Geocode lookup failed after \(attempt) attempts: \(error.localizedDescription)"
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

    /// Transient failures worth another try. Apple surfaces geocoder
    /// throttling as `kCLErrorNetwork`; transport errors use `NSURLError`.
    /// A "no result" is a miss, not a throttle.
    static func isRetryable(_ error: Error) -> Bool {
        let ns = error as NSError
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

    private static func liveLookup(latitude: Double, longitude: Double) async throws -> CacheEntry? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        // English names match photo-tools' Nominatim output (`Places/France`
        // not `Places/Frankreich`) so a library tagged by both tools shares
        // one tree.
        let marks = try await CLGeocoder().reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "en_US")
        )
        guard let mark = marks.first else { return nil }
        return place(from: mark, latitude: latitude, longitude: longitude)
    }

    /// photo-tools §2.2: missing levels collapse; no placeholders.
    static func placesPath(
        country: String?,
        state: String?,
        city: String?,
        sublocation: String?
    ) -> String? {
        var segments: [String] = []
        if let country = nonempty(country) { segments.append(country) }
        if let state = nonempty(state) { segments.append(state) }
        if let city = nonempty(city) { segments.append(city) }
        if let sublocation = nonempty(sublocation) { segments.append(sublocation) }
        guard !segments.isEmpty else { return nil }
        return "Places/" + segments.joined(separator: "/")
    }

    /// The CLPlacemark fields Places actually reads. Isolated so tests can
    /// feed a Paris-without-`locality` mark without constructing a placemark.
    struct PlacemarkParts: Equatable, Sendable {
        var country: String? = nil
        var state: String? = nil
        var subAdministrativeArea: String? = nil
        var locality: String? = nil
        var postalCity: String? = nil
        var subLocality: String? = nil
        var isoCountryCode: String? = nil
    }

    static func place(from mark: CLPlacemark, latitude: Double, longitude: Double) -> CacheEntry? {
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
    static func place(from parts: PlacemarkParts, latitude: Double, longitude: Double) -> CacheEntry? {
        let country = nonempty(parts.country)
        let state = distinct(nonempty(parts.state), from: country)
        let city = distinct(
            nonempty(parts.locality)
                ?? nonempty(parts.postalCity)
                ?? nonempty(parts.subAdministrativeArea),
            from: country, state
        )
        let sublocation = distinct(nonempty(parts.subLocality), from: country, state, city)
        guard let path = placesPath(
            country: country,
            state: state,
            city: city,
            sublocation: sublocation
        ) else { return nil }
        let code = parts.isoCountryCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return CacheEntry(
            latitude: latitude,
            longitude: longitude,
            path: path,
            country: country,
            state: state,
            city: city,
            sublocation: sublocation,
            countryCode: (code?.count == 2) ? code : nil
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func distinct(_ value: String?, from others: String?...) -> String? {
        guard let value else { return nil }
        for other in others {
            if let other, value.localizedCaseInsensitiveCompare(other) == .orderedSame {
                return nil
            }
        }
        return value
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
