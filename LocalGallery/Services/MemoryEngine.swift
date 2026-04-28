import Foundation

/// Once-a-day memory generation. Currently houses the pure helpers shared by
/// trip / birthday / on-this-day detection. The orchestrator entry point
/// (`generate(...)`) lands in a follow-up commit; for now the Store keeps it
/// inline and calls into these helpers.
enum MemoryEngine {
    static func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let R = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func countryName(from code: String) -> String? {
        Locale.current.localizedString(forRegionCode: code)
    }

    static func formatDateRange(_ first: Date, _ last: Date) -> String {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return fmt.string(from: first)
        }
        return "\(fmt.string(from: first)) – \(fmt.string(from: last))"
    }

    /// Standardized memory subtitle: "<first date> – <last date> · N photos".
    /// Falls back to just the photo count when no date range is available
    /// (e.g. birthday memories whose photos all lack dateTaken).
    static func subtitleWithCount(dateRange: ClosedRange<Date>?, count: Int) -> String {
        let countText = "\(count) \(count == 1 ? "photo" : "photos")"
        guard let range = dateRange else { return countText }
        return "\(formatDateRange(range.lowerBound, range.upperBound)) · \(countText)"
    }

    // MARK: - Generate

    /// Run the full memory-generation pipeline on a detached task and return
    /// the selected top-20 memories. Pure over its inputs; the Store handles
    /// the once-per-day gate, observed-state assignment, cache write, and
    /// widget export.
    static func generate(
        from allPhotos: [PhotoFile],
        leafFolders: [PhotoFolder],
        contacts: [ContactInfo],
        personContactLinks: [String: PersonLink],
        contactsByLowerName: [String: ContactInfo],
        birthdaysEnabled: Bool,
        now: Date = Date()
    ) async -> [Memory] {
        await Task.detached(priority: .utility) {
            let calendar = Calendar.current
            let today = now
            let todayComponents = calendar.dateComponents([.month, .day], from: today)
            let currentYear = calendar.component(.year, from: today)
            let currentMonthYear = calendar.dateComponents([.month, .year], from: today)
            var candidates: [Memory] = []

            let photosWithDates = allPhotos.compactMap { photo -> (PhotoFile, Date)? in
                guard let date = photo.dateTaken else { return nil }
                return (photo, date)
            }

            // === 1. On This Day ===
            let onThisDay = photosWithDates.filter { (_, date) in
                let c = calendar.dateComponents([.month, .day, .year], from: date)
                return c.month == todayComponents.month && c.day == todayComponents.day && c.year != currentYear
            }.sorted { $0.1 < $1.1 }

            if onThisDay.count >= 2 {
                let years = Set(onThisDay.map { calendar.component(.year, from: $0.1) })
                let ids = onThisDay.map(\.0.id)
                candidates.append(Memory(
                    id: "onThisDay", type: .onThisDay,
                    title: "On this day",
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 2],
                    dateRange: onThisDay.first!.1...onThisDay.last!.1,
                    score: Double(ids.count) * 2.0 + Double(years.count) * 3.0,
                    yearsAgo: nil, personName: nil
                ))
            }

            // === 2. X Years Ago ===
            for milestone in [1, 2, 3, 5, 10, 15, 20] {
                guard let targetDate = calendar.date(byAdding: .year, value: -milestone, to: today),
                      let windowStart = calendar.date(byAdding: .day, value: -3, to: targetDate),
                      let windowEnd = calendar.date(byAdding: .day, value: 3, to: targetDate) else { continue }

                let window = photosWithDates.filter { $0.1 >= windowStart && $0.1 <= windowEnd }
                    .sorted { $0.1 < $1.1 }
                guard window.count >= 3,
                      let first = window.first?.1, let last = window.last?.1 else { continue }

                let targetYear = calendar.component(.year, from: targetDate)
                let ids = window.map(\.0.id)
                candidates.append(Memory(
                    id: "yearsAgo-\(milestone)", type: .yearsAgo,
                    title: "On this day in \(targetYear)",
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 2],
                    dateRange: first...last,
                    score: Double(ids.count) * 1.5 + (milestone >= 5 ? 10.0 : 5.0),
                    yearsAgo: milestone, personName: nil
                ))
            }

            // === 3. Person Through the Years ===
            let peoplePairs = allPhotos.flatMap { photo in
                photo.hierarchicalTags
                    .filter { $0.namespace?.lowercased() == "people" }
                    .map { (name: $0.displayName, photo: photo) }
            }
            let byPerson = Dictionary(grouping: peoplePairs, by: { $0.name })

            for (name, entries) in byPerson {
                let withDates = entries.compactMap { entry -> (PhotoFile, Date)? in
                    guard let date = entry.photo.dateTaken else { return nil }
                    return (entry.photo, date)
                }
                let years = Set(withDates.map { calendar.component(.year, from: $0.1) })
                guard years.count >= 3, withDates.count >= 5 else { continue }
                let sorted = withDates.sorted { $0.1 < $1.1 }
                let ids = sorted.map(\.0.id)
                guard let first = sorted.first?.1, let last = sorted.last?.1 else { continue }
                candidates.append(Memory(
                    id: "person-\(name)", type: .personOverTime,
                    title: "\(name) over the years",
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids.last!,
                    dateRange: first...last,
                    score: Double(years.count) * 4.0 + Double(ids.count) * 0.5 + 20.0,
                    yearsAgo: nil, personName: name
                ))
            }

            // === 4. Folder-based Event Memories ===
            for folder in leafFolders {
                let withDates = folder.photos.compactMap { photo -> (PhotoFile, Date)? in
                    guard let date = photo.dateTaken else { return nil }
                    return (photo, date)
                }.sorted { $0.1 < $1.1 }
                guard withDates.count >= 8,
                      let first = withDates.first?.1, let last = withDates.last?.1,
                      calendar.dateComponents([.month, .year], from: last) != currentMonthYear
                else { continue }

                let daySpan = calendar.dateComponents([.day], from: first, to: last).day ?? 0
                let spanBonus = min(Double(daySpan), 14.0)
                let ids = withDates.map(\.0.id)

                candidates.append(Memory(
                    id: "folder-\(folder.url.lastPathComponent)", type: .folderEvent,
                    title: folder.name,
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 3],
                    dateRange: first...last,
                    score: Double(ids.count) * 0.4 + spanBonus * 1.0,
                    yearsAgo: nil, personName: nil
                ))
            }

            // === 5. Photo Density Detection ===
            let byDay = Dictionary(grouping: photosWithDates) { (_, date) -> DateComponents in
                calendar.dateComponents([.year, .month, .day], from: date)
            }
            let avgPerDay = photosWithDates.isEmpty ? 0.0 : Double(photosWithDates.count) / Double(max(byDay.count, 1))
            let densityThreshold = max(10, Int(avgPerDay * 3.0))

            for (dayComp, dayEntries) in byDay where dayEntries.count >= densityThreshold {
                guard let dayDate = calendar.date(from: dayComp),
                      !calendar.isDateInToday(dayDate),
                      calendar.dateComponents([.month, .year], from: dayDate) != currentMonthYear
                else { continue }

                let sorted = dayEntries.sorted { $0.1 < $1.1 }
                let ids = sorted.map(\.0.id)
                guard let first = sorted.first?.1, let last = sorted.last?.1 else { continue }
                let dayKey = "\(dayComp.year ?? 0)-\(dayComp.month ?? 0)-\(dayComp.day ?? 0)"

                candidates.append(Memory(
                    id: "density-\(dayKey)", type: .photoDensity,
                    title: "A busy day",
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 2],
                    dateRange: first...last,
                    score: Double(ids.count) * 1.2,
                    yearsAgo: nil, personName: nil
                ))
            }

            // === 6. Trip Detection ===
            generateTripMemories(from: photosWithDates, calendar: calendar, today: today, into: &candidates)

            // === 7. Birthdays ===
            // Surface a memory only when today (month + day) matches a
            // contact's birthday and the person has at least 1 tagged photo.
            // Explicit entries in `personContactLinks` override the auto-match
            // by name (or suppress it entirely when `.disabled`). Skipped
            // entirely when the master toggle is off.
            if birthdaysEnabled {
                generateBirthdayMemories(
                    from: allPhotos,
                    contacts: contacts,
                    links: personContactLinks,
                    lowerNameIndex: contactsByLowerName,
                    calendar: calendar,
                    todayComponents: todayComponents,
                    into: &candidates
                )
            }

            // Cap per-memory photo count to keep slideshow/grid responsive.
            // Sample evenly across the range to preserve temporal spread.
            let maxPhotosPerMemory = 75
            candidates = candidates.map { mem in
                guard mem.photoIDs.count > maxPhotosPerMemory else { return mem }
                let step = Double(mem.photoIDs.count) / Double(maxPhotosPerMemory)
                let sampled = (0..<maxPhotosPerMemory).map { mem.photoIDs[Int(Double($0) * step)] }
                return Memory(
                    id: mem.id, type: mem.type, title: mem.title, subtitle: mem.subtitle,
                    photoIDs: sampled, coverPhotoID: mem.coverPhotoID,
                    dateRange: mem.dateRange, score: mem.score,
                    yearsAgo: mem.yearsAgo, personName: mem.personName
                )
            }

            // Standardize every memory's subtitle to "<first date> – <last date> · N photos".
            // Done after the photo-count sampling above so the count reflects what the
            // user will actually see in the grid/slideshow.
            candidates = candidates.map { mem in
                let unified = subtitleWithCount(dateRange: mem.dateRange, count: mem.photoIDs.count)
                return Memory(
                    id: mem.id, type: mem.type, title: mem.title, subtitle: unified,
                    photoIDs: mem.photoIDs, coverPhotoID: mem.coverPhotoID,
                    dateRange: mem.dateRange, score: mem.score,
                    yearsAgo: mem.yearsAgo, personName: mem.personName
                )
            }

            // Sort by score, then greedily select top 10 with overlap penalty.
            // Sub-trips are intentionally inside their parent trip's photo set,
            // so they bypass the overlap filter — losing them defeats the goal
            // of surfacing finer-grained legs of long journeys.
            candidates.sort { $0.score > $1.score }
            var selected: [Memory] = []
            var usedPhotoIDs = Set<UUID>()
            for candidate in candidates {
                let isSubtrip = candidate.id.hasPrefix("subtrip-")
                let candidateSet = Set(candidate.photoIDs)
                if !isSubtrip {
                    let overlapCount = candidateSet.intersection(usedPhotoIDs).count
                    let overlapRatio = candidateSet.isEmpty ? 0.0 : Double(overlapCount) / Double(candidateSet.count)
                    if overlapRatio > 0.7 { continue }
                }
                selected.append(candidate)
                usedPhotoIDs.formUnion(candidateSet)
                if selected.count >= 10 { break }
            }

            return selected
        }.value
    }

    // MARK: Diagnostics

    /// One-shot diagnostic dump covering the inputs `generate` consumes:
    /// date provenance (embedded vs filesystem fallback), GPS coverage,
    /// People/* tag coverage, and the densest single-day clusters. Helps
    /// identify bulk-import date pollution and missing metadata.
    static func logMemoryInputSummary(allPhotos: [PhotoFile]) {
        let total = allPhotos.count
        guard total > 0 else { return }

        let withDate       = allPhotos.filter { $0.dateTaken != nil }
        let fromMetadata   = allPhotos.filter { $0.dateFromMetadata }.count
        let fallbackDate   = withDate.count - fromMetadata
        let withGPS        = allPhotos.filter { $0.gpsLatitude != nil && $0.gpsLongitude != nil }.count
        let withAnyTag     = allPhotos.filter { !$0.hierarchicalTags.isEmpty }.count

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
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")

        Log.memory.info("""
            Input summary: \(total) photos total
              dates: \(fromMetadata) from metadata, \(fallbackDate) filesystem fallback, \(total - withDate.count) missing
              GPS: \(withGPS) photos
              tags: \(withAnyTag) tagged, \(peoplePhotos.count) with People/*, \(personNameCounts.count) unique names
              top People: \(topPeople.isEmpty ? "(none)" : topPeople)
            """)

        // Top 5 densest single days — smoking gun for bulk-import clustering.
        let cal = Calendar.current
        struct DayStat { var total = 0; var fromMetadata = 0 }
        var byDay: [DateComponents: DayStat] = [:]
        for photo in withDate {
            guard let date = photo.dateTaken else { continue }
            let key = cal.dateComponents([.year, .month, .day], from: date)
            var stat = byDay[key, default: DayStat()]
            stat.total += 1
            if photo.dateFromMetadata { stat.fromMetadata += 1 }
            byDay[key] = stat
        }
        let densest = byDay.sorted { $0.value.total > $1.value.total }.prefix(5)
        let dayLines = densest.map { (k, s) -> String in
            let y = k.year ?? 0, m = k.month ?? 0, d = k.day ?? 0
            return String(format: "%04d-%02d-%02d: %d photos (%d from metadata, %d fallback)",
                          y, m, d, s.total, s.fromMetadata, s.total - s.fromMetadata)
        }
        Log.memory.info("Top 5 densest days:\n  \(dayLines.joined(separator: "\n  "))")
    }

    // MARK: Birthday Detection

    /// Build "Happy birthday, <name>" memories for every person whose linked
    /// (manual or auto-matched) contact has a birthday equal to today's
    /// month/day. Photo set = every photo carrying the People/* tag for that
    /// person, sorted oldest → newest so the slideshow tells a story.
    static func generateBirthdayMemories(
        from allPhotos: [PhotoFile],
        contacts: [ContactInfo],
        links: [String: PersonLink],
        lowerNameIndex: [String: ContactInfo],
        calendar: Calendar,
        todayComponents: DateComponents,
        into candidates: inout [Memory]
    ) {
        guard let todayMonth = todayComponents.month,
              let todayDay = todayComponents.day else { return }

        // Group photos by person tag fullPath, retaining the original casing.
        struct PersonBundle { let fullPath: String; let displayName: String; var photos: [PhotoFile] }
        var byPath: [String: PersonBundle] = [:]
        for photo in allPhotos {
            for tag in photo.hierarchicalTags where tag.namespace?.lowercased() == "people" {
                if var existing = byPath[tag.fullPath] {
                    existing.photos.append(photo)
                    byPath[tag.fullPath] = existing
                } else {
                    byPath[tag.fullPath] = PersonBundle(
                        fullPath: tag.fullPath,
                        displayName: tag.displayName,
                        photos: [photo]
                    )
                }
            }
        }

        let contactByID = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })

        for (path, bundle) in byPath {
            // Resolve effective contact: explicit `.disabled` skips this tag,
            // a `.manual` link wins over name-based auto-match, and absence
            // means "auto-match by displayName".
            let contact: ContactInfo?
            switch links[path] {
            case .disabled:
                continue
            case .manual(let id):
                contact = contactByID[id]
            case nil:
                contact = lowerNameIndex[bundle.displayName.lowercased()]
            }
            guard let contact,
                  let bMonth = contact.birthday?.month,
                  let bDay = contact.birthday?.day,
                  bMonth == todayMonth, bDay == todayDay else { continue }

            // Sort by date when available; undated photos go to the end so the
            // cover (most recent) prefers a real timestamp.
            let sorted = bundle.photos.sorted { a, b in
                (a.dateTaken ?? .distantPast) < (b.dateTaken ?? .distantPast)
            }
            let ids = sorted.map(\.id)
            guard let coverID = ids.last else { continue }

            let dateRange: ClosedRange<Date>?
            if let first = sorted.first?.dateTaken, let last = sorted.last?.dateTaken {
                dateRange = first...last
            } else {
                dateRange = nil
            }

            // Score sits well above on-this-day / years-ago so birthdays float
            // to the front of the rail on the matching day.
            candidates.append(Memory(
                id: "birthday-\(path)",
                type: .birthday,
                title: "Happy birthday, \(bundle.displayName)",
                subtitle: nil,
                photoIDs: ids,
                coverPhotoID: coverID,
                dateRange: dateRange,
                score: 100.0 + Double(min(ids.count, 50)) * 0.5,
                yearsAgo: nil,
                personName: bundle.displayName
            ))
        }
    }

    // MARK: Trip Detection

    static func generateTripMemories(
        from photosWithDates: [(PhotoFile, Date)],
        calendar: Calendar,
        today: Date,
        into candidates: inout [Memory]
    ) {
        let geoPhotos = photosWithDates
            .filter { $0.0.gpsLatitude != nil && $0.0.gpsLongitude != nil }
            .sorted { $0.1 < $1.1 }

        guard geoPhotos.count >= 5 else { return }

        let allLats = geoPhotos.compactMap(\.0.gpsLatitude).sorted()
        let allLons = geoPhotos.compactMap(\.0.gpsLongitude).sorted()
        let homeLat = allLats[allLats.count / 2]
        let homeLon = allLons[allLons.count / 2]

        let distanceThresholdKm = 50.0
        var currentTrip: [(PhotoFile, Date)] = []

        for entry in geoPhotos {
            guard let lat = entry.0.gpsLatitude, let lon = entry.0.gpsLongitude else { continue }
            let dist = haversineKm(lat1: homeLat, lon1: homeLon, lat2: lat, lon2: lon)

            if dist > distanceThresholdKm {
                if let lastDate = currentTrip.last?.1,
                   entry.1.timeIntervalSince(lastDate) > 48 * 3600 {
                    flushTrip(currentTrip, calendar: calendar, today: today, into: &candidates)
                    currentTrip = []
                }
                currentTrip.append(entry)
            } else {
                flushTrip(currentTrip, calendar: calendar, today: today, into: &candidates)
                currentTrip = []
            }
        }
        flushTrip(currentTrip, calendar: calendar, today: today, into: &candidates)
    }

    // MARK: Trip Segmentation

    static func flushTrip(
        _ entries: [(PhotoFile, Date)],
        calendar: Calendar,
        today: Date,
        into candidates: inout [Memory]
    ) {
        guard entries.count >= 5 else { return }
        let sorted = entries.sorted { $0.1 < $1.1 }
        guard let first = sorted.first?.1, let last = sorted.last?.1 else { return }

        let currentMonthYear = calendar.dateComponents([.month, .year], from: today)
        guard calendar.dateComponents([.month, .year], from: last) != currentMonthYear else { return }

        let days = max(1, calendar.dateComponents([.day], from: first, to: last).day ?? 1)
        let ids = sorted.map(\.0.id)
        let tripKey = "\(calendar.component(.year, from: first))-\(calendar.component(.month, from: first))-\(calendar.component(.day, from: first))"

        let locationLabel = tripLabel(for: sorted.map(\.0))
        let title: String
        if let locationLabel {
            title = "A trip to \(locationLabel)"
        } else {
            title = "A trip"
            let sampleTags = sorted.prefix(3).flatMap { $0.0.hierarchicalTags.map(\.fullPath) }
            let sampleCountries = sorted.prefix(3).compactMap { $0.0.countryCode }
            Log.memory.debug("Trip \(tripKey): no location label. sampleTags=\(sampleTags) countryCodes=\(sampleCountries)")
        }

        candidates.append(Memory(
            id: "trip-\(tripKey)", type: .trip,
            title: title,
            subtitle: nil,
            photoIDs: ids,
            coverPhotoID: ids[ids.count / 3],
            dateRange: first...last,
            score: Double(ids.count) * 1.5 + Double(days) * 2.0 + 18.0,
            yearsAgo: nil, personName: nil
        ))

        // Surface meaningful sub-trips inside long parent trips — e.g. the
        // Buenos Aires leg of a 3-month South America journey. We split the
        // sorted photos by country code first, then by city-level Places path
        // when only one country is present. A segment qualifies if it spans at
        // least 2 days, has 5+ photos, and is meaningfully smaller than the
        // parent (so we don't duplicate the parent as a sub-trip).
        guard days >= 5 else { return }
        let parentSet = Set(ids)
        let segments: [(label: String, key: String, entries: [(PhotoFile, Date)])]
        let countriesPresent = Set(sorted.compactMap { $0.0.countryCode?.uppercased() })
        if countriesPresent.count >= 2 {
            segments = consecutiveCountrySegments(in: sorted)
        } else {
            segments = consecutivePlacesSegments(in: sorted)
        }
        for seg in segments {
            guard seg.entries.count >= 5,
                  let segFirst = seg.entries.first?.1,
                  let segLast = seg.entries.last?.1 else { continue }
            let segDays = max(1, calendar.dateComponents([.day], from: segFirst, to: segLast).day ?? 1)
            guard segDays >= 2 else { continue }
            // Sub-trip must be a strict subset of the parent and noticeably
            // smaller — otherwise it's just the trip again.
            let segIDs = seg.entries.map(\.0.id)
            let segSet = Set(segIDs)
            guard segSet != parentSet,
                  Double(segSet.count) <= Double(parentSet.count) * 0.85 else { continue }

            let subTitle = "A trip to \(seg.label)"
            candidates.append(Memory(
                id: "subtrip-\(tripKey)-\(seg.key)", type: .trip,
                title: subTitle,
                subtitle: nil,
                photoIDs: segIDs,
                coverPhotoID: segIDs[segIDs.count / 3],
                dateRange: segFirst...segLast,
                // Slightly under the parent so the parent floats first when
                // both surface, but high enough that ranks above generic items.
                score: Double(segIDs.count) * 1.4 + Double(segDays) * 1.8 + 6.0,
                yearsAgo: nil, personName: nil
            ))
        }
    }

    /// Group a sorted-by-date photo run into consecutive-country segments.
    static func consecutiveCountrySegments(
        in entries: [(PhotoFile, Date)]
    ) -> [(label: String, key: String, entries: [(PhotoFile, Date)])] {
        var out: [(label: String, key: String, entries: [(PhotoFile, Date)])] = []
        var current: [(PhotoFile, Date)] = []
        var currentCode: String? = nil
        func flush() {
            guard let code = currentCode, !current.isEmpty else { return }
            let label = countryName(from: code) ?? code
            out.append((label, code.lowercased(), current))
        }
        for e in entries {
            let code = e.0.countryCode?.uppercased()
            if code != currentCode {
                flush()
                current = []
                currentCode = code
            }
            if currentCode != nil { current.append(e) }
        }
        flush()
        return out
    }

    /// Group a sorted-by-date photo run by deepest Places leaf (city or below).
    /// Used when the trip stays in one country — surfaces city-level legs.
    static func consecutivePlacesSegments(
        in entries: [(PhotoFile, Date)]
    ) -> [(label: String, key: String, entries: [(PhotoFile, Date)])] {
        func cityKey(for photo: PhotoFile) -> (label: String, key: String)? {
            // Pick the longest Places path on the photo and use the city-level
            // segment (depth 3 = country/region/city). Fall back to the deepest
            // available.
            let placesPaths = photo.hierarchicalTags
                .filter { $0.namespace?.lowercased() == "places" }
                .map { $0.fullPath.split(separator: "/").map(String.init) }
            guard let longest = placesPaths.max(by: { $0.count < $1.count }), longest.count > 1 else { return nil }
            // segments without "Places"
            let segs = Array(longest.dropFirst())
            let cityIdx = min(2, segs.count - 1) // 0=country, 1=region, 2=city
            let label = segs[cityIdx]
            let key = segs.prefix(cityIdx + 1).joined(separator: "-").lowercased()
            return (label, key)
        }
        var out: [(label: String, key: String, entries: [(PhotoFile, Date)])] = []
        var current: [(PhotoFile, Date)] = []
        var currentLabel: String? = nil
        var currentKey: String? = nil
        func flush() {
            guard let label = currentLabel, let key = currentKey, !current.isEmpty else { return }
            out.append((label, key, current))
        }
        for e in entries {
            let info = cityKey(for: e.0)
            let label = info?.label
            let key = info?.key
            if key != currentKey {
                flush()
                current = []
                currentLabel = label
                currentKey = key
            }
            if currentKey != nil { current.append(e) }
        }
        flush()
        return out
    }

    // MARK: Trip Labeling

    /// Derives a location-based title for a trip from `Places/*` tags and
    /// `photo-tools:CountryCode`. Returns nil when no tag data is available so
    /// the caller can fall back to the generic "A trip" title.
    static func tripLabel(for photos: [PhotoFile]) -> String? {
        var countryCounts: [String: Int] = [:]
        for photo in photos {
            if let code = photo.countryCode, !code.isEmpty {
                countryCounts[code, default: 0] += 1
            }
        }

        if countryCounts.count >= 2 {
            let sorted = countryCounts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            if sorted.count > 3 {
                return "\(sorted.count) countries"
            }
            let names = sorted.map { countryName(from: $0.key) ?? $0.key }
            if names.count == 2 {
                return "\(names[0]) & \(names[1])"
            }
            return "\(names[0]), \(names[1]) & \(names[2])"
        }

        let prefix = deepestSharedPlacesPrefix(in: photos)
        if let leaf = prefix.last {
            return leaf
        }

        if let (code, _) = countryCounts.first {
            return countryName(from: code) ?? code
        }

        return nil
    }

    /// Longest `Places/*` path segments shared by every photo that carries at
    /// least one `Places/*` tag. Photos without any `Places/*` tag are skipped
    /// (collapse-on-missing-levels, per photo-tools xmp-schema.md §2.2).
    /// Returns `[]` when no photo has a `Places/*` tag.
    static func deepestSharedPlacesPrefix(in photos: [PhotoFile]) -> [String] {
        var perPhotoSegments: [[String]] = []
        for photo in photos {
            let placesPaths = photo.hierarchicalTags
                .filter { $0.namespace?.lowercased() == "places" }
                .map { $0.fullPath.split(separator: "/").dropFirst().map(String.init) }
            guard let longest = placesPaths.max(by: { $0.count < $1.count }), !longest.isEmpty else {
                continue
            }
            perPhotoSegments.append(longest)
        }
        guard let first = perPhotoSegments.first else { return [] }
        var prefix = first
        for segments in perPhotoSegments.dropFirst() {
            let limit = min(prefix.count, segments.count)
            var i = 0
            while i < limit && prefix[i].caseInsensitiveCompare(segments[i]) == .orderedSame {
                i += 1
            }
            prefix = Array(prefix.prefix(i))
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
