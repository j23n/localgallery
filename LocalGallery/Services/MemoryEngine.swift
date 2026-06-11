import Foundation

/// Once-a-day memory generation: the `generate(...)` orchestrator plus the
/// pure per-type generators (trips, birthdays, on-this-day, folder events,
/// density) and scoring/selection. Pure over its inputs — the Store owns the
/// once-per-day gate, observed-state assignment, cache write, and widget
/// export.
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

    // MARK: - Similar-photo dedup

    /// Drops near-duplicate photos from a chronologically-sorted memory feed:
    /// keep the first photo in any rolling `windowSeconds` window. Burst
    /// shots (3–10 frames in a few seconds) collapse to a single
    /// representative, and the slideshow stops dwelling on the same scene.
    static let memoryDedupWindow: TimeInterval = 60

    /// Returns `sorted` with any entry that lands within `windowSeconds` of
    /// the previously kept entry removed. `sorted` is expected to be
    /// ascending by date.
    static func dedupByTimeWindow(
        _ sorted: [(PhotoFile, Date)],
        windowSeconds: TimeInterval = memoryDedupWindow
    ) -> [(PhotoFile, Date)] {
        var out: [(PhotoFile, Date)] = []
        out.reserveCapacity(sorted.count)
        var lastKept: Date?
        for entry in sorted {
            if let last = lastKept, entry.1.timeIntervalSince(last) < windowSeconds {
                continue
            }
            out.append(entry)
            lastKept = entry.1
        }
        return out
    }

    /// Same as `dedupByTimeWindow` but for plain `PhotoFile` arrays where
    /// the date lives on the photo itself. Photos without a `dateTaken`
    /// pass through unchanged (no signal to dedup against).
    static func dedupByTimeWindow(
        _ photos: [PhotoFile],
        windowSeconds: TimeInterval = memoryDedupWindow
    ) -> [PhotoFile] {
        var out: [PhotoFile] = []
        out.reserveCapacity(photos.count)
        var lastKept: Date?
        for photo in photos {
            guard let date = photo.dateTaken else {
                out.append(photo)
                continue
            }
            if let last = lastKept, date.timeIntervalSince(last) < windowSeconds {
                continue
            }
            out.append(photo)
            lastKept = date
        }
        return out
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
        // The heavy pipeline runs on a detached utility task, but the
        // caller's cancellation (the BG-task expiration handler) is forwarded
        // explicitly — `Task.detached` alone would swallow it and the
        // `Task.isCancelled` checks between stages would never trip.
        let work = Task.detached(priority: .utility) { () -> [Memory] in
            let calendar = Calendar.current
            let today = now
            let todayComponents = calendar.dateComponents([.month, .day], from: today)
            let currentMonthYear = calendar.dateComponents([.month, .year], from: today)
            var candidates: [Memory] = []
            let minPhotos = 15
            let minOnThisDayPhotos = 10

            let photosWithDates = allPhotos.compactMap { photo -> (PhotoFile, Date)? in
                guard let date = photo.dateTaken else { return nil }
                return (photo, date)
            }

            Log.memory.info("Pipeline: \(allPhotos.count) photos (\(photosWithDates.count) with dates), \(leafFolders.count) leaf folders, \(contacts.count) contacts, seed='\(seed)', seen=\(seenMemoryIDs.count) IDs, me='\(Log.r.person(mePersonPath))'")

            // === 1. On This Day ===
            if let memory = generateOnThisDay(
                for: today,
                in: photosWithDates,
                calendar: calendar,
                minPhotos: minOnThisDayPhotos
            ) {
                candidates.append(memory)
            }

            // === 2. X Years Ago ===
            let yearsAgo = generateYearsAgo(
                for: today,
                in: photosWithDates,
                calendar: calendar,
                minPhotos: minOnThisDayPhotos
            )
            candidates.append(contentsOf: yearsAgo)
            Log.memory.info("YearsAgo: produced \(yearsAgo.count) memories")

            // === 3. (Person-over-time memories removed — only birthdays surface people now)

            if Task.isCancelled { return [] }

            // === 4. Folder-based Event Memories ===
            var folderEventCount = 0
            for folder in leafFolders {
                let withDatesRaw = folder.photos.compactMap { photo -> (PhotoFile, Date)? in
                    guard let date = photo.dateTaken else { return nil }
                    return (photo, date)
                }.sorted { $0.1 < $1.1 }
                let withDates = dedupByTimeWindow(withDatesRaw)
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

                let sorted = dedupByTimeWindow(dayEntries.sorted { $0.1 < $1.1 })
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

            if Task.isCancelled { return [] }

            // === 6. Trip Detection ===
            let trips = generateTripMemories(
                from: photosWithDates, calendar: calendar, today: today,
                mePersonPath: mePersonPath, hiddenPeople: hiddenPeople
            )
            candidates += trips
            Log.memory.info("Trips: produced \(trips.count) memories")

            // === 7. Birthdays ===
            // Surface a memory only when today (month + day) matches a
            // contact's birthday and the person has at least 1 tagged photo.
            // Explicit entries in `personContactLinks` override the auto-match
            // by name (or suppress it entirely when `.disabled`). Skipped
            // entirely when the master toggle is off.
            if birthdaysEnabled {
                let birthdays = generateBirthdayMemories(
                    from: allPhotos,
                    contacts: contacts,
                    links: personContactLinks,
                    lowerNameIndex: contactsByLowerName,
                    calendar: calendar,
                    todayComponents: todayComponents,
                    hiddenPeople: hiddenPeople
                )
                candidates += birthdays
                Log.memory.info("Birthdays: produced \(birthdays.count) memories")
            } else {
                Log.memory.info("Birthdays: skipped (toggle off)")
            }

            if Task.isCancelled { return [] }

            candidates = finalize(candidates)

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
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Post-processing every surfaced memory goes through, regardless of
    /// which pipeline produced it: cap the photo count (slideshow/grid
    /// responsiveness; sampled evenly so temporal spread survives) and
    /// standardize the subtitle to "<first date> – <last date> · N photos".
    /// `computeScheduledMemories` (the widget's pre-published days) calls
    /// this too so scheduled items match same-day generated ones.
    static func finalize(_ memories: [Memory]) -> [Memory] {
        let maxPhotosPerMemory = 75
        return memories.map { mem in
            var photoIDs = mem.photoIDs
            var coverID = mem.coverPhotoID
            if photoIDs.count > maxPhotosPerMemory {
                let step = Double(photoIDs.count) / Double(maxPhotosPerMemory)
                photoIDs = (0..<maxPhotosPerMemory).map { mem.photoIDs[Int(Double($0) * step)] }
                // Sampling can drop the cover; re-point it at the sampled
                // middle (same neighbourhood the generators pick from) so
                // the card image is always part of the memory's photo set.
                if !photoIDs.contains(coverID) {
                    coverID = photoIDs[photoIDs.count / 2]
                }
            }
            // Subtitle uses the capped count — it should reflect what the
            // user actually sees in the grid/slideshow.
            return Memory(
                id: mem.id, type: mem.type, title: mem.title,
                subtitle: subtitleWithCount(dateRange: mem.dateRange, count: photoIDs.count),
                photoIDs: photoIDs, coverPhotoID: coverID,
                dateRange: mem.dateRange, score: mem.score,
                yearsAgo: mem.yearsAgo, personName: mem.personName
            )
        }
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

}
