import Foundation

/// Calendar-tied generators: deterministic per-day memories ("On this day",
/// "On this day in <year>"). Shared by the daily `generate(...)` pipeline
/// (for today) and `GalleryStore.computeScheduledMemories` (which
/// pre-publishes the next few days into the widget snapshot).
extension MemoryEngine {
    // MARK: - Calendar-tied generators (per-day, deterministic)

    /// `OnThisDay` for an arbitrary `day`. Same logic the main pipeline runs
    /// for today — extracted so the widget exporter can pre-compute upcoming
    /// days and surface them without waiting for the app to be relaunched on
    /// the matching date. Returns `nil` when the photo set is too thin to
    /// meet `minPhotos`.
    static func generateOnThisDay(
        for day: Date,
        in photosWithDates: [(PhotoFile, Date)],
        calendar: Calendar,
        minPhotos: Int = 10
    ) -> Memory? {
        let dayComps = calendar.dateComponents([.month, .day], from: day)
        let currentYear = calendar.component(.year, from: day)
        let raw = photosWithDates.filter { (_, date) in
            let c = calendar.dateComponents([.month, .day, .year], from: date)
            return c.month == dayComps.month && c.day == dayComps.day && c.year != currentYear
        }.sorted { $0.1 < $1.1 }
        let deduped = dedupByTimeWindow(raw)
        guard deduped.count >= minPhotos else {
            if !raw.isEmpty {
                Log.memory.debug("OnThisDay (\(Log.r.other(Self.iso8601Day.string(from: day)))): only \(deduped.count) after dedup; need \(minPhotos) (raw=\(raw.count))")
            }
            return nil
        }
        let years = Set(deduped.map { calendar.component(.year, from: $0.1) })
        let ids = deduped.map(\.0.id)
        Log.memory.info("OnThisDay (\(Log.r.other(Self.iso8601Day.string(from: day)))): \(ids.count) photos across \(years.count) years (deduped from \(raw.count))")
        // The id is date-qualified: a constant "onThisDay" id would let one
        // viewing apply the 6-month seen-penalty to *every* future day's
        // on-this-day memory even though the content differs daily. The
        // widget's pre-published scheduled memories regenerate the same id
        // when their day arrives, so deep links still resolve.
        return Memory(
            id: "onThisDay-\(Self.iso8601Day.string(from: day))", type: .onThisDay,
            title: "On this day",
            subtitle: nil,
            photoIDs: ids,
            coverPhotoID: ids[ids.count / 2],
            dateRange: deduped.first!.1...deduped.last!.1,
            score: 50.0 + Double(years.count) * 5.0,
            yearsAgo: nil, personName: nil
        )
    }

    /// `YearsAgo` memories for an arbitrary `day`, one per milestone year
    /// that has enough photos. Same logic the main pipeline runs for today —
    /// extracted so the widget exporter can pre-compute upcoming days.
    static func generateYearsAgo(
        for day: Date,
        in photosWithDates: [(PhotoFile, Date)],
        calendar: Calendar,
        minPhotos: Int = 10
    ) -> [Memory] {
        let dayComps = calendar.dateComponents([.month, .day], from: day)
        var out: [Memory] = []
        for milestone in [1, 2, 3, 5, 10, 15, 20] {
            guard let targetDate = calendar.date(byAdding: .year, value: -milestone, to: day) else { continue }
            let targetYear = calendar.component(.year, from: targetDate)
            let raw = photosWithDates.filter { (_, date) in
                let c = calendar.dateComponents([.month, .day, .year], from: date)
                return c.month == dayComps.month && c.day == dayComps.day && c.year == targetYear
            }.sorted { $0.1 < $1.1 }
            let deduped = dedupByTimeWindow(raw)
            guard deduped.count >= minPhotos,
                  let first = deduped.first?.1, let last = deduped.last?.1 else { continue }
            let ids = deduped.map(\.0.id)
            // Date-qualified for the same reason as the onThisDay id above.
            out.append(Memory(
                id: "yearsAgo-\(milestone)-\(Self.iso8601Day.string(from: day))", type: .yearsAgo,
                title: "On this day in \(targetYear)",
                subtitle: nil,
                photoIDs: ids,
                coverPhotoID: ids[ids.count / 2],
                dateRange: first...last,
                score: milestone >= 10 ? 45.0 : milestone >= 5 ? 40.0 : 35.0,
                yearsAgo: milestone, personName: nil
            ))
        }
        return out
    }

    /// Day-only ISO formatter used by the calendar-generator log lines.
    /// `nonisolated(unsafe)` because `ISO8601DateFormatter` is documented
    /// thread-safe and we want one shared instance.
    private nonisolated(unsafe) static let iso8601Day: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}
