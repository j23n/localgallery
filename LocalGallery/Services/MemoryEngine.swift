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

    // MARK: - Cluster Key

    /// Memories that share a cluster key are mutually exclusive in a single
    /// rail render and share a cool-down: a trip parent (`trip-<key>`) and
    /// its sub-trips (`subtrip-<key>-<seg>`) all collapse to `trip-<key>`,
    /// so only one surfaces per generation and the others stay penalised
    /// for a few days. Every other memory id is its own cluster.
    static func clusterKey(for memoryID: String) -> String {
        if memoryID.hasPrefix("subtrip-") {
            // Sub-trip ids are "subtrip-<year>-<month>-<day>-<segKey>".
            // The trip key is the first three hyphen-joined components after
            // the prefix. Numeric so split-on-"-" is unambiguous.
            let rest = memoryID.dropFirst("subtrip-".count)
            let parts = rest.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count >= 4 {
                let tripKey = parts.prefix(3).joined(separator: "-")
                return "trip-\(tripKey)"
            }
        }
        return memoryID
    }

    // MARK: - Generate

    /// Run the full memory-generation pipeline on a detached task and return
    /// the selected top-10 memories. Pure over its inputs; the Store handles
    /// the once-per-day gate, observed-state assignment, cache write, and
    /// widget export.
    ///
    /// - `seed`: drives the daily jitter so the selection rotates. The Store
    ///   passes a day-ordinal for normal runs and a time-based value for
    ///   force-regenerate so each tap gives a fresh set.
    /// - `seenMemoryIDs`: memory IDs the user has already seen (tapped into
    ///   the slideshow). Seen memories are deprioritised for ~6 months so the
    ///   rail stays fresh.
    /// - `surfacedClusters`: cluster keys (see `clusterKey(for:)`) → date the
    ///   cluster last appeared on the rail. Members of recently-surfaced
    ///   clusters get a score penalty so trip parent + sub-trips rotate over
    ///   days instead of all stacking on the same render.
    static func generate(
        from allPhotos: [PhotoFile],
        leafFolders: [PhotoFolder],
        contacts: [ContactInfo],
        personContactLinks: [String: PersonLink],
        contactsByLowerName: [String: ContactInfo],
        birthdaysEnabled: Bool,
        mePersonPath: String = "",
        hiddenPeople: Set<String> = [],
        now: Date = Date(),
        seed: String = "",
        seenMemoryIDs: [String: Date] = [:],
        surfacedClusters: [String: Date] = [:]
    ) async -> [Memory] {
        await Task.detached(priority: .utility) {
            let calendar = Calendar.current
            let today = now
            let todayComponents = calendar.dateComponents([.month, .day], from: today)
            let currentYear = calendar.component(.year, from: today)
            let currentMonthYear = calendar.dateComponents([.month, .year], from: today)
            var candidates: [Memory] = []
            let minPhotos = 15

            let photosWithDates = allPhotos.compactMap { photo -> (PhotoFile, Date)? in
                guard let date = photo.dateTaken else { return nil }
                return (photo, date)
            }

            Log.memory.info("Pipeline: \(allPhotos.count) photos (\(photosWithDates.count) with dates), \(leafFolders.count) leaf folders, \(contacts.count) contacts, seed='\(seed)', seen=\(seenMemoryIDs.count) IDs, me='\(Log.r.person(mePersonPath))'")

            // === 1. On This Day ===
            let onThisDay = photosWithDates.filter { (_, date) in
                let c = calendar.dateComponents([.month, .day, .year], from: date)
                return c.month == todayComponents.month && c.day == todayComponents.day && c.year != currentYear
            }.sorted { $0.1 < $1.1 }

            if onThisDay.count >= minPhotos {
                let years = Set(onThisDay.map { calendar.component(.year, from: $0.1) })
                let ids = onThisDay.map(\.0.id)
                candidates.append(Memory(
                    id: "onThisDay", type: .onThisDay,
                    title: "On this day",
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 2],
                    dateRange: onThisDay.first!.1...onThisDay.last!.1,
                    score: 50.0 + Double(years.count) * 5.0,
                    yearsAgo: nil, personName: nil
                ))
                Log.memory.info("OnThisDay: \(ids.count) photos across \(years.count) years")
            } else if !onThisDay.isEmpty {
                Log.memory.debug("OnThisDay: only \(onThisDay.count) photos (need \(minPhotos))")
            }

            // === 2. X Years Ago ===
            var yearsAgoCount = 0
            for milestone in [1, 2, 3, 5, 10, 15, 20] {
                guard let targetDate = calendar.date(byAdding: .year, value: -milestone, to: today),
                      let windowStart = calendar.date(byAdding: .day, value: -3, to: targetDate),
                      let windowEnd = calendar.date(byAdding: .day, value: 3, to: targetDate) else { continue }

                let window = photosWithDates.filter { $0.1 >= windowStart && $0.1 <= windowEnd }
                    .sorted { $0.1 < $1.1 }
                guard window.count >= minPhotos,
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
                    score: milestone >= 10 ? 45.0 : milestone >= 5 ? 40.0 : 35.0,
                    yearsAgo: milestone, personName: nil
                ))
                yearsAgoCount += 1
            }
            Log.memory.info("YearsAgo: produced \(yearsAgoCount) memories")

            // === 3. (Person-over-time memories removed — only birthdays surface people now)

            // === 4. Folder-based Event Memories ===
            var folderEventCount = 0
            for folder in leafFolders {
                let withDates = folder.photos.compactMap { photo -> (PhotoFile, Date)? in
                    guard let date = photo.dateTaken else { return nil }
                    return (photo, date)
                }.sorted { $0.1 < $1.1 }
                guard withDates.count >= minPhotos,
                      let first = withDates.first?.1, let last = withDates.last?.1,
                      calendar.dateComponents([.month, .year], from: last) != currentMonthYear
                else { continue }

                let daySpan = calendar.dateComponents([.day], from: first, to: last).day ?? 0
                let ids = withDates.map(\.0.id)

                candidates.append(Memory(
                    id: "folder-\(folder.id.uuidString)", type: .folderEvent,
                    title: folder.name,
                    subtitle: nil,
                    photoIDs: ids,
                    coverPhotoID: ids[ids.count / 3],
                    dateRange: first...last,
                    score: 10.0 + min(Double(daySpan), 14.0),
                    yearsAgo: nil, personName: nil
                ))
                folderEventCount += 1
            }
            Log.memory.info("FolderEvents: produced \(folderEventCount) memories from \(leafFolders.count) leaf folders")

            // === 5. Photo Density Detection ===
            let byDay = Dictionary(grouping: photosWithDates) { (_, date) -> DateComponents in
                calendar.dateComponents([.year, .month, .day], from: date)
            }
            let avgPerDay = photosWithDates.isEmpty ? 0.0 : Double(photosWithDates.count) / Double(max(byDay.count, 1))
            let densityThreshold = max(minPhotos, Int(avgPerDay * 3.0))
            var densityCount = 0

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
                    score: 8.0,
                    yearsAgo: nil, personName: nil
                ))
                densityCount += 1
            }
            Log.memory.info("Density: produced \(densityCount) memories (threshold=\(densityThreshold) photos/day)")

            // === 6. Trip Detection ===
            let tripCountBefore = candidates.count
            generateTripMemories(from: photosWithDates, calendar: calendar, today: today, mePersonPath: mePersonPath, hiddenPeople: hiddenPeople, into: &candidates)
            Log.memory.info("Trips: produced \(candidates.count - tripCountBefore) memories")

            // === 7. Birthdays ===
            // Surface a memory only when today (month + day) matches a
            // contact's birthday and the person has at least 1 tagged photo.
            // Explicit entries in `personContactLinks` override the auto-match
            // by name (or suppress it entirely when `.disabled`). Skipped
            // entirely when the master toggle is off.
            if birthdaysEnabled {
                let bdayBefore = candidates.count
                generateBirthdayMemories(
                    from: allPhotos,
                    contacts: contacts,
                    links: personContactLinks,
                    lowerNameIndex: contactsByLowerName,
                    calendar: calendar,
                    todayComponents: todayComponents,
                    hiddenPeople: hiddenPeople,
                    into: &candidates
                )
                Log.memory.info("Birthdays: produced \(candidates.count - bdayBefore) memories")
            } else {
                Log.memory.info("Birthdays: skipped (toggle off)")
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

            // Sort by score, then greedily select top 10 with cluster
            // uniqueness — at most one member of each cluster surfaces on a
            // single render. A cluster groups a trip parent with its
            // sub-trips (see `clusterKey(for:)`); other memory types are
            // singleton clusters keyed by their own id.
            // Deduplicate folder memories that share a name (e.g. five
            // leaf folders all called "Unsorted"). Keep the one with the
            // most photos so the best representative wins.
            var folderNameBest: [String: Int] = [:]
            for (idx, c) in candidates.enumerated() where c.type == .folderEvent {
                let key = c.title.lowercased()
                if let prev = folderNameBest[key] {
                    if c.photoIDs.count > candidates[prev].photoIDs.count {
                        folderNameBest[key] = idx
                    }
                } else {
                    folderNameBest[key] = idx
                }
            }
            let folderKeep = Set(folderNameBest.values)
            candidates = candidates.enumerated().filter { idx, c in
                c.type != .folderEvent || folderKeep.contains(idx)
            }.map(\.element)

            // Day-seeded jitter (0–12 pts) so the selection rotates daily
            // while high-priority types (birthdays, on-this-day) stay on top.
            // Memories seen in the last ~6 months get a penalty so they sink
            // below unseen candidates of similar quality. Clusters surfaced
            // in the last 3 days also get a penalty so a trip parent and its
            // sub-trips rotate across days instead of repeating.
            var rng = SeededRNG(seed: seed)
            let sixMonthsAgo = calendar.date(byAdding: .month, value: -6, to: today) ?? today
            let coolDownThreshold = calendar.date(byAdding: .day, value: -3, to: today) ?? today
            let jitteredScores: [Double] = candidates.map { mem in
                var s = mem.score + Double.random(in: 0..<12, using: &rng)
                if let lastSeen = seenMemoryIDs[mem.id], lastSeen > sixMonthsAgo {
                    s -= 30.0
                }
                let cluster = clusterKey(for: mem.id)
                if let lastSurfaced = surfacedClusters[cluster], lastSurfaced > coolDownThreshold {
                    s -= 25.0
                }
                return s
            }
            let sortedIndices = jitteredScores.indices.sorted { jitteredScores[$0] > jitteredScores[$1] }
            candidates = sortedIndices.map { candidates[$0] }

            var selected: [Memory] = []
            var usedClusters = Set<String>()
            for (idx, candidate) in candidates.enumerated() {
                let cluster = clusterKey(for: candidate.id)
                if usedClusters.contains(cluster) {
                    Log.memory.debug("Skip '\(Log.r.memory(candidate.id))' (cluster '\(Log.r.other(cluster))' already taken; jitteredScore=\(String(format: "%.1f", jitteredScores[sortedIndices[idx]])))")
                    continue
                }
                let seenSuffix = seenMemoryIDs[candidate.id] != nil ? " [seen]" : ""
                let cooledSuffix = (surfacedClusters[cluster].map { $0 > coolDownThreshold } ?? false) ? " [cooled]" : ""
                Log.memory.info("Pick '\(Log.r.memory(candidate.id))' score=\(String(format: "%.1f", candidate.score)) jitter=\(String(format: "%.1f", jitteredScores[sortedIndices[idx]]))\(seenSuffix)\(cooledSuffix) photos=\(candidate.photoIDs.count) title='\(Log.r.title(candidate.title))'")
                selected.append(candidate)
                usedClusters.insert(cluster)
                if selected.count >= 10 { break }
            }

            Log.memory.info("Selected \(selected.count) memories from \(candidates.count) candidates")
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
            .map { "\(Log.r.person($0.key))=\($0.value)" }
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
        hiddenPeople: Set<String> = [],
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
            if hiddenPeople.contains(path) { continue }
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
                score: 100.0,
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
        mePersonPath: String,
        hiddenPeople: Set<String> = [],
        into candidates: inout [Memory]
    ) {
        let geoPhotos = photosWithDates
            .filter { $0.0.gpsLatitude != nil && $0.0.gpsLongitude != nil }
            .sorted { $0.1 < $1.1 }

        guard geoPhotos.count >= 5 else { return }

        let homeRegions = detectHomeRegions(in: geoPhotos, calendar: calendar)

        let isAtHome: (PhotoFile) -> Bool
        if homeRegions.isEmpty {
            // Fallback for libraries too sparse to surface a stable home
            // cluster (a brand-new library, or one with very few GPS-tagged
            // photos). Reverts to the legacy global-median heuristic so trip
            // detection still produces something useful, even if loose.
            let allLats = geoPhotos.compactMap(\.0.gpsLatitude).sorted()
            let allLons = geoPhotos.compactMap(\.0.gpsLongitude).sorted()
            let homeLat = allLats[allLats.count / 2]
            let homeLon = allLons[allLons.count / 2]
            let distanceThresholdKm = 50.0
            Log.memory.info("Trips: no home cluster detected — fallback to global median \(Log.r.other(String(format: "(%.3f, %.3f)", homeLat, homeLon)))")
            isAtHome = { photo in
                guard let lat = photo.gpsLatitude, let lon = photo.gpsLongitude else { return false }
                return haversineKm(lat1: homeLat, lon1: homeLon, lat2: lat, lon2: lon) <= distanceThresholdKm
            }
        } else {
            Log.memory.info("Trips: home detected — \(homeRegions.primaryCount) primary cell(s), \(homeRegions.cells.count) total with neighbours")
            isAtHome = { photo in
                guard let lat = photo.gpsLatitude, let lon = photo.gpsLongitude else { return false }
                return homeRegions.contains(lat: lat, lon: lon)
            }
        }

        var currentTrip: [(PhotoFile, Date)] = []

        for entry in geoPhotos {
            if isAtHome(entry.0) {
                flushTrip(currentTrip, calendar: calendar, today: today, mePersonPath: mePersonPath, hiddenPeople: hiddenPeople, into: &candidates)
                currentTrip = []
            } else {
                if let lastDate = currentTrip.last?.1,
                   entry.1.timeIntervalSince(lastDate) > 48 * 3600 {
                    flushTrip(currentTrip, calendar: calendar, today: today, mePersonPath: mePersonPath, hiddenPeople: hiddenPeople, into: &candidates)
                    currentTrip = []
                }
                currentTrip.append(entry)
            }
        }
        flushTrip(currentTrip, calendar: calendar, today: today, mePersonPath: mePersonPath, hiddenPeople: hiddenPeople, into: &candidates)
    }

    // MARK: Home Detection

    /// Quantised GPS cell. ~11 km × 11 km at the equator, narrowing toward the
    /// poles. Used to cluster photos by location for home detection.
    struct GridCell: Hashable {
        let latBin: Int
        let lonBin: Int

        static let binSizeDegrees: Double = 0.1

        init(lat: Double, lon: Double) {
            self.latBin = Int(floor(lat / Self.binSizeDegrees))
            self.lonBin = Int(floor(lon / Self.binSizeDegrees))
        }

        init(latBin: Int, lonBin: Int) {
            self.latBin = latBin
            self.lonBin = lonBin
        }
    }

    /// Cells the user has lived in (or otherwise spent significant time
    /// across). Each primary cell is expanded by its 8 grid neighbours so
    /// "home" effectively becomes a ~33 km region — daily life around a metro
    /// area still counts as home even when the residence sits on a cell
    /// boundary or a few neighbouring cells get used regularly.
    struct HomeRegions {
        let primaryCount: Int
        let cells: Set<GridCell>

        var isEmpty: Bool { cells.isEmpty }

        func contains(lat: Double, lon: Double) -> Bool {
            cells.contains(GridCell(lat: lat, lon: lon))
        }
    }

    /// Detect home cells from the GPS photo set. A cell qualifies as home
    /// when it has photos spanning ≥180 days *and* covers ≥30 distinct days.
    /// Both criteria together separate "lived here" from "stayed here a
    /// while" — a 3-month trip has wide span but few distinct days; a single
    /// busy week at home has many distinct days but tiny span. The criteria
    /// adapt downward when the library itself is younger than ~360 days, so
    /// new users still get usable trip detection.
    static func detectHomeRegions(
        in geoPhotos: [(PhotoFile, Date)],
        calendar: Calendar
    ) -> HomeRegions {
        struct CellStat {
            var first: Date
            var last: Date
            var days: Set<DateComponents>
        }
        var stats: [GridCell: CellStat] = [:]

        for (photo, date) in geoPhotos {
            guard let lat = photo.gpsLatitude, let lon = photo.gpsLongitude else { continue }
            let cell = GridCell(lat: lat, lon: lon)
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            if var existing = stats[cell] {
                if date < existing.first { existing.first = date }
                if date > existing.last { existing.last = date }
                existing.days.insert(day)
                stats[cell] = existing
            } else {
                stats[cell] = CellStat(first: date, last: date, days: [day])
            }
        }

        guard let firstDate = geoPhotos.first?.1, let lastDate = geoPhotos.last?.1 else {
            return HomeRegions(primaryCount: 0, cells: [])
        }
        let totalSpanDays = calendar.dateComponents([.day], from: firstDate, to: lastDate).day ?? 0
        // Adapt thresholds when the library itself is young: require half its
        // total span and a quarter of its distinct-day budget. Caps lock the
        // strict criteria in once the library is mature.
        let totalDistinctDays = Set(geoPhotos.map { calendar.dateComponents([.year, .month, .day], from: $0.1) }).count
        let minSpanDays = min(180, max(30, totalSpanDays / 2))
        let minDistinctDays = min(30, max(10, totalDistinctDays / 4))

        var primaryCount = 0
        var cells = Set<GridCell>()
        for (cell, stat) in stats {
            let span = calendar.dateComponents([.day], from: stat.first, to: stat.last).day ?? 0
            guard span >= minSpanDays, stat.days.count >= minDistinctDays else { continue }
            primaryCount += 1
            for dlat in -1...1 {
                for dlon in -1...1 {
                    cells.insert(GridCell(latBin: cell.latBin + dlat, lonBin: cell.lonBin + dlon))
                }
            }
        }

        return HomeRegions(primaryCount: primaryCount, cells: cells)
    }

    // MARK: Trip Segmentation

    static func flushTrip(
        _ entries: [(PhotoFile, Date)],
        calendar: Calendar,
        today: Date,
        mePersonPath: String,
        hiddenPeople: Set<String> = [],
        into candidates: inout [Memory]
    ) {
        guard entries.count >= 15 else { return }
        let sorted = entries.sorted { $0.1 < $1.1 }
        guard let first = sorted.first?.1, let last = sorted.last?.1 else { return }

        let currentMonthYear = calendar.dateComponents([.month, .year], from: today)
        guard calendar.dateComponents([.month, .year], from: last) != currentMonthYear else { return }

        let days = max(1, calendar.dateComponents([.day], from: first, to: last).day ?? 1)
        let ids = sorted.map(\.0.id)
        let tripKey = "\(calendar.component(.year, from: first))-\(calendar.component(.month, from: first))-\(calendar.component(.day, from: first))"

        let tripPhotos = sorted.map(\.0)
        let locationLabel = tripLabel(for: tripPhotos)
        let peopleSuffix = tripPeopleSuffix(for: tripPhotos, mePersonPath: mePersonPath, excludedPaths: hiddenPeople)
        let title = composeTripTitle(location: locationLabel, peopleSuffix: peopleSuffix)
        if locationLabel == nil {
            let sampleTags = sorted.prefix(3).flatMap { $0.0.hierarchicalTags.map(\.fullPath) }
            let sampleCountries = sorted.prefix(3).compactMap { $0.0.countryCode }
            let redactedTags = sampleTags.map { Log.r.tag($0) }
            let redactedCountries = sampleCountries.map { Log.r.other($0) }
            Log.memory.debug("Trip \(Log.r.trip(tripKey)): no location label. sampleTags=\(redactedTags) countryCodes=\(redactedCountries)")
        }
        Log.memory.debug("Trip \(Log.r.trip(tripKey)): days=\(days) photos=\(ids.count) → '\(Log.r.title(title))'")

        candidates.append(Memory(
            id: "trip-\(tripKey)", type: .trip,
            title: title,
            subtitle: nil,
            photoIDs: ids,
            coverPhotoID: ids[ids.count / 3],
            dateRange: first...last,
            score: 20.0 + Double(days) * 1.5,
            yearsAgo: nil, personName: nil
        ))

        // Surface meaningful sub-trips inside long parent trips — e.g. the
        // Buenos Aires leg of a 3-month South America journey. We pick the
        // coarsest Places-hierarchy depth (country → region → city) that
        // actually has variation across the trip, so e.g. a Bamberg + Berlin
        // trip splits at the region level (Bavaria + Berlin) rather than
        // collapsing at country level. A segment qualifies if it spans at
        // least 2 days, has 15+ photos, and is meaningfully smaller than the
        // parent (so we don't duplicate the parent as a sub-trip).
        guard days >= 5 else { return }
        let parentSet = Set(ids)
        let segments = splitTripIntoSegments(in: sorted)
        for seg in segments {
            guard seg.entries.count >= 15,
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

            let segPhotos = seg.entries.map(\.0)
            let segPeopleSuffix = tripPeopleSuffix(for: segPhotos, mePersonPath: mePersonPath, excludedPaths: hiddenPeople)
            let subTitle = composeTripTitle(location: seg.label, peopleSuffix: segPeopleSuffix)
            candidates.append(Memory(
                id: "subtrip-\(tripKey)-\(seg.key)", type: .trip,
                title: subTitle,
                subtitle: nil,
                photoIDs: segIDs,
                coverPhotoID: segIDs[segIDs.count / 3],
                dateRange: segFirst...segLast,
                // Slightly under the parent so the parent floats first when
                // both surface, but high enough that ranks above generic items.
                score: 15.0 + Double(segDays) * 1.2,
                yearsAgo: nil, personName: nil
            ))
        }
    }

    /// Group a sorted-by-date trip into consecutive segments at the coarsest
    /// Places hierarchy depth that still has variation. Country-level splits
    /// (depth 0) win when ≥2 countries are present; otherwise regions
    /// (depth 1); otherwise cities (depth 2). Country segmentation prefers
    /// the canonical `countryCode` — its label goes through `countryName`
    /// for proper localization — while region/city use the longest
    /// `Places/*` path on each photo. Returns `[]` when there's no
    /// variation at any depth (e.g. the whole trip is one city).
    static func splitTripIntoSegments(
        in entries: [(PhotoFile, Date)]
    ) -> [(label: String, key: String, entries: [(PhotoFile, Date)])] {
        let countriesPresent = Set(entries.compactMap { $0.0.countryCode?.uppercased() })
        if countriesPresent.count >= 2 {
            return consecutiveCountrySegments(in: entries)
        }
        return consecutivePlacesSegments(in: entries, preferredDepth: 1)
    }

    /// Group a sorted-by-date photo run into consecutive-country segments
    /// using `countryCode` directly.
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

    /// Group a sorted-by-date photo run by `Places/*` path segments at the
    /// coarsest depth ≥ `preferredDepth` that has ≥2 distinct values across
    /// the trip. `preferredDepth` is 1=region, 2=city. Returns `[]` when no
    /// depth in `preferredDepth...2` shows variation.
    ///
    /// Per-photo path = the longest `Places/*` tag carried by that photo,
    /// with the leading `Places` token dropped (so depth 0 = country name,
    /// 1 = region, 2 = city).
    static func consecutivePlacesSegments(
        in entries: [(PhotoFile, Date)],
        preferredDepth: Int
    ) -> [(label: String, key: String, entries: [(PhotoFile, Date)])] {
        let perPhotoSegments: [[String]] = entries.map { e -> [String] in
            let placesPaths = e.0.hierarchicalTags
                .filter { $0.namespace?.lowercased() == "places" }
                .map { $0.fullPath.split(separator: "/").dropFirst().map(String.init) }
            return placesPaths.max(by: { $0.count < $1.count }) ?? []
        }
        func distinctAt(_ depth: Int) -> Int {
            var seen = Set<String>()
            for segs in perPhotoSegments where segs.count > depth {
                seen.insert(segs[depth].lowercased())
            }
            return seen.count
        }
        var chosenDepth: Int? = nil
        for d in max(0, preferredDepth)...2 {
            if distinctAt(d) >= 2 { chosenDepth = d; break }
        }
        guard let depth = chosenDepth else { return [] }

        var out: [(label: String, key: String, entries: [(PhotoFile, Date)])] = []
        var current: [(PhotoFile, Date)] = []
        var currentLabel: String? = nil
        var currentKey: String? = nil
        func flush() {
            guard let label = currentLabel, let key = currentKey, !current.isEmpty else { return }
            out.append((label, key, current))
        }
        for (i, e) in entries.enumerated() {
            let segs = perPhotoSegments[i]
            let label: String?
            let key: String?
            if segs.count > depth {
                label = segs[depth]
                key = segs.prefix(depth + 1).joined(separator: "-").lowercased()
            } else {
                label = nil
                key = nil
            }
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
    ///
    /// 90% rule: when one country dominates (≥90% of geo-tagged photos), the
    /// label collapses to that country alone — minor outliers (a layover, a
    /// quick border crossing) are ignored in the title without altering the
    /// trip's photo set.
    static func tripLabel(for photos: [PhotoFile]) -> String? {
        var countryCounts: [String: Int] = [:]
        for photo in photos {
            if let code = photo.countryCode, !code.isEmpty {
                countryCounts[code, default: 0] += 1
            }
        }

        let total = countryCounts.values.reduce(0, +)
        if total > 0,
           let dominant = countryCounts.max(by: { $0.value < $1.value }),
           Double(dominant.value) / Double(total) >= 0.90 {
            // Prefer the most specific shared Places location (e.g. "Hawaii"
            // rather than "United States") when the hierarchy goes deeper than
            // the country level.
            let prefix = deepestSharedPlacesPrefix(in: photos)
            if prefix.count >= 2, let leaf = prefix.last {
                return leaf
            }
            return countryName(from: dominant.key) ?? dominant.key
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

    // MARK: - Trip Title Composition

    /// Compose `"<Location> with X, Y & Z"` / `"A trip to <Location>"` /
    /// `"A trip with X, Y & Z"` / `"A trip"` depending on which inputs are
    /// available. Centralised so parent + sub-trip titles stay in sync.
    static func composeTripTitle(location: String?, peopleSuffix: String?) -> String {
        switch (location, peopleSuffix) {
        case let (loc?, names?):
            return "\(loc) with \(names)"
        case let (loc?, nil):
            return "A trip to \(loc)"
        case let (nil, names?):
            return "A trip with \(names)"
        case (nil, nil):
            return "A trip"
        }
    }

    /// Build a `"with"` suffix listing the top contributors to a trip's
    /// `People/*` tags. Excludes the user's own tag (`mePersonPath`), drops
    /// to first-name-only, and disambiguates with a last-initial when two
    /// people in the suffix share a first name.
    ///
    /// Returns `nil` when no people remain after exclusion.
    static func tripPeopleSuffix(
        for photos: [PhotoFile],
        mePersonPath: String,
        excludedPaths: Set<String> = [],
        maxNames: Int = 3
    ) -> String? {
        var counts: [String: (path: String, name: String, count: Int)] = [:]
        for photo in photos {
            for tag in photo.hierarchicalTags where tag.namespace?.lowercased() == "people" {
                if !mePersonPath.isEmpty, tag.fullPath == mePersonPath { continue }
                if excludedPaths.contains(tag.fullPath) { continue }
                if var existing = counts[tag.fullPath] {
                    existing.count += 1
                    counts[tag.fullPath] = existing
                } else {
                    counts[tag.fullPath] = (tag.fullPath, tag.displayName, 1)
                }
            }
        }
        guard !counts.isEmpty else { return nil }

        let sorted = counts.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .prefix(maxNames)

        let display = disambiguateFirstNames(sorted.map(\.name))
        guard !display.isEmpty else { return nil }
        return joinNames(display)
    }

    /// Reduce full "First Last" tag names to the shortest unambiguous form.
    /// Single-word tags pass through unchanged; collisions on first name where
    /// the last initials differ get a `"First L."` suffix; collisions where
    /// last initials are missing or identical fall back to the bare first name.
    static func disambiguateFirstNames(_ names: [String]) -> [String] {
        struct Parts { let first: String; let lastInitial: Character? }
        let parsed: [Parts] = names.map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let tokens = trimmed.split(separator: " ").map(String.init)
            let first = tokens.first ?? trimmed
            let lastInitial = tokens.count >= 2 ? tokens.last?.first : nil
            return Parts(first: first, lastInitial: lastInitial)
        }
        let groups = Dictionary(grouping: parsed.indices, by: { parsed[$0].first.lowercased() })
        var out = Array(repeating: "", count: parsed.count)
        for (_, indices) in groups {
            if indices.count == 1 {
                let i = indices[0]
                out[i] = parsed[i].first
                continue
            }
            let initials = indices.compactMap { parsed[$0].lastInitial.map { Character(String($0).uppercased()) } }
            let initialsAreDistinct = Set(initials).count == indices.count
            for i in indices {
                let p = parsed[i]
                if initialsAreDistinct, let li = p.lastInitial {
                    out[i] = "\(p.first) \(String(li).uppercased())."
                } else {
                    out[i] = p.first
                }
            }
        }
        return out
    }

    /// Format a name list as "Anna" / "Anna & Bob" / "Anna, Bob & Charlie".
    static func joinNames(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head) & \(names.last!)"
        }
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
