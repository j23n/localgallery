import Foundation
import Observation
import os

/// Owns the memories domain: the generated `[Memory]` list, its disk cache,
/// the once-per-day generation gate, the seen/cool-down bookkeeping, and the
/// hidden-memories set. Extracted from `GalleryStore` so the trickiest state
/// machine in the app lives (and can be tested) in one place; views reach it
/// via `store.memories`.
///
/// The engine itself lives in the Rust core (`CoreMemories.generate`, Phase 4)
/// and is pure; this type supplies its inputs (via the Store-provided
/// `makeInputs` closure), owns the gating rules, and publishes results.
@Observable
@MainActor
final class MemoryCoordinator {
    /// Everything the engine needs from the *Store*, snapshotted on the main
    /// actor at generation time. Built by the Store, which owns the photo
    /// library, contacts, and people state.
    ///
    /// The coordinator's own half of the snapshot — the clock, the seed, the
    /// birthdays toggle and the seen/cool-down maps — is added in `generate`;
    /// together they become `CoreMemories.Inputs`, which is what crosses the
    /// FFI boundary.
    struct GenerationInputs {
        let photos: [PhotoFile]
        let leafFolders: [PhotoFolder]
        let contacts: [ContactInfo]
        let personContactLinks: [String: PersonLink]
        let mePersonPath: String
        let hiddenPeople: Set<String>
    }

    /// The full generated list, cached order. Most UI wants `visible`.
    private(set) var all: [Memory] = []

    /// Memory IDs the user has hidden ("Don't show this memory").
    private(set) var hiddenMemories: Set<String> = [] {
        didSet { defaults.set(Array(hiddenMemories), forKey: "hiddenMemories") }
    }

    /// Memory IDs the user has tapped into (opened the slideshow). Keyed by
    /// memory ID → last-seen date. Memories seen within ~6 months are
    /// deprioritised so the rail stays fresh. Pruned at load to entries
    /// inside the last 12 months — entries older than that have no scoring
    /// effect (the engine only checks `> sixMonthsAgo`) and would otherwise
    /// accumulate forever as the user uses the app across years.
    @ObservationIgnored var seenMemoryIDs: [String: Date] = [:] {
        didSet {
            guard let data = try? JSONEncoder().encode(seenMemoryIDs) else { return }
            defaults.set(data, forKey: "seenMemoryIDs")
        }
    }

    /// Cluster keys (see `CoreMemories.clusterKey(for:)`) → last date the
    /// cluster surfaced on the rail. Clusters are penalised for ~3 days
    /// after surfacing so a trip parent + sub-trips rotate across days.
    /// Pruned at load to entries from the last 7 days; that headroom
    /// covers the 3-day cool-down with slack for time-zone changes.
    @ObservationIgnored var surfacedClusters: [String: Date] = [:] {
        didSet {
            guard let data = try? JSONEncoder().encode(surfacedClusters) else { return }
            defaults.set(data, forKey: "surfacedClusters")
        }
    }

    /// Master toggle for birthday memories. When `false`, generation skips
    /// the birthday category entirely. Default `true` so the feature
    /// surfaces automatically once Contacts access is granted.
    var birthdaysEnabled: Bool = true {
        didSet {
            guard oldValue != birthdaysEnabled else { return }
            defaults.set(birthdaysEnabled, forKey: "birthdayMemoriesEnabled")
            // Force a regenerate so today's rail reflects the toggle change
            // immediately rather than waiting for the daily gate.
            forceRegenerate()
        }
    }

    /// Day the last successful generation ran. Persisted; the once-per-day
    /// gate compares it against today. Only set *after* a generation
    /// completes — a process death or cancelled BG task must not consume
    /// the day.
    @ObservationIgnored private(set) var generatedDay: Date? {
        didSet {
            if let day = generatedDay {
                defaults.set(day, forKey: "memoriesGeneratedDay")
            } else {
                defaults.removeObject(forKey: "memoriesGeneratedDay")
            }
        }
    }

    /// Re-entrancy guard: `generateIfNeeded` spawns an unawaited Task and
    /// the daily gate is only set on completion, so without this two
    /// triggers in quick succession would both generate.
    @ObservationIgnored private var isGenerating = false
    /// Bumped by `forceRegenerate` so an in-flight generation (whose inputs
    /// predate the change that forced the regen) can't set the daily gate
    /// when it lands.
    @ObservationIgnored private var generationEpoch = 0

    // MARK: Wiring

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private let cache: JSONDiskCache<[Memory]>
    /// O(1) photo lookup for stale-ID filtering in `visible`.
    @ObservationIgnored private let index: CoreLibraryIndex
    /// Hidden-people set, for suppressing stale birthday memories.
    @ObservationIgnored private let people: PeopleStore
    /// Set by the Store: snapshots engine inputs, or nil when the library
    /// is empty (nothing to generate from).
    @ObservationIgnored var makeInputs: (() -> GenerationInputs?)?
    /// Set by the Store: fired after a generation publishes, so the widget
    /// snapshot can refresh.
    @ObservationIgnored var onMemoriesPublished: (() -> Void)?

    init(
        defaults: UserDefaults,
        clock: any Clock,
        cache: JSONDiskCache<[Memory]>,
        index: CoreLibraryIndex,
        people: PeopleStore
    ) {
        self.defaults = defaults
        self.clock = clock
        self.cache = cache
        self.index = index
        self.people = people

        if let hiddenMem = defaults.array(forKey: "hiddenMemories") as? [String] {
            hiddenMemories = Set(hiddenMem)
        }
        if let raw = defaults.object(forKey: "memoriesGeneratedDay") as? Date {
            generatedDay = raw
        }
        if let data = defaults.data(forKey: "seenMemoryIDs"),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            // Drop entries older than the engine's scoring window so the dict
            // can't grow unbounded across years of use.
            let cutoff = Calendar.current.date(byAdding: .month, value: -12, to: clock.now()) ?? .distantPast
            seenMemoryIDs = dict.filter { $0.value > cutoff }
        }
        if let data = defaults.data(forKey: "surfacedClusters"),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            // Drop entries outside the cool-down window so the map can't
            // grow unbounded across years of use.
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: clock.now()) ?? .distantPast
            surfacedClusters = dict.filter { $0.value > cutoff }
        }
        if defaults.object(forKey: "birthdayMemoriesEnabled") != nil {
            birthdaysEnabled = defaults.bool(forKey: "birthdayMemoriesEnabled")
        }
        if let cached = cache.load() {
            all = cached
            Log.cache.info("Loaded \(cached.count) memories from cache")
        }
    }

    // MARK: Reads

    /// Rail-facing list: hidden memories removed, stale birthday memories
    /// for since-hidden people removed, and memories whose photo IDs are
    /// entirely unresolvable (folder moves change SHA-256 IDs) removed.
    var visible: [Memory] {
        all.filter { memory in
            guard !hiddenMemories.contains(memory.id) else { return false }
            // Suppress birthday memories for people who have since been hidden
            // (catches stale cached memories generated before the person was hidden).
            if memory.id.hasPrefix("birthday-") {
                let personPath = String(memory.id.dropFirst("birthday-".count))
                if people.hiddenPeople.contains(personPath) { return false }
            }
            // Mirror the same resolution order as MemoryCardView's coverURL.
            if index.photo(byID: memory.coverPhotoID) != nil { return true }
            return memory.photoIDs.contains { index.photo(byID: $0) != nil }
        }
    }

    /// True once today's generation has completed. `AppRouter` uses this to
    /// decide whether a widget deep link targeting a not-yet-existing
    /// scheduled memory should stay queued (today's generation still
    /// pending) or be dropped (the memory is genuinely gone).
    var hasGeneratedToday: Bool {
        guard let day = generatedDay else { return false }
        return Calendar.current.isDate(day, inSameDayAs: clock.now())
    }

    // MARK: Mutations

    func hide(_ id: String) {
        hiddenMemories.insert(id)
        onMemoriesPublished?()
    }

    func unhide(_ id: String) {
        hiddenMemories.remove(id)
        onMemoriesPublished?()
    }

    func markSeen(_ id: String) {
        seenMemoryIDs[id] = clock.now()
    }

    /// Wipe the disk cache without touching in-memory state. The Store calls
    /// this when the *library* cache is evicted — memories reference photo
    /// IDs from that schema, so the persisted copy goes too, while the
    /// in-memory list keeps rendering (filtered by `visible`) until the
    /// rescan regenerates.
    func clearDiskCache() {
        cache.clear()
    }

    // MARK: Generation

    /// Trigger generation once per day (or when the list is empty). Called
    /// after scan/enrichment so memories reflect the freshest EXIF/tag/GPS
    /// data. Fire-and-forget; the daily gate is set on completion.
    func generateIfNeeded(seed: String? = nil) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: clock.now())
        let stale = generatedDay.map { !cal.isDate($0, inSameDayAs: today) } ?? true
        guard stale || all.isEmpty else { return }
        guard let inputs = makeInputs?(), !inputs.photos.isEmpty else { return }
        guard !isGenerating else { return }
        isGenerating = true
        let epoch = generationEpoch
        let daySeed = seed ?? WidgetDayKey.string(for: today)
        Task {
            defer { isGenerating = false }
            await generate(inputs: inputs, seed: daySeed)
            // Gate only on completion — a process death or cancellation
            // mid-generation must not consume the daily gate; an epoch bump
            // means a force-regen superseded this run's inputs.
            if !Task.isCancelled && epoch == generationEpoch {
                generatedDay = today
            }
        }
    }

    /// Clear the once-per-day gate + cached memories and immediately re-run
    /// detection. Wired to settings toggles and a long-press on the
    /// "Memories" section header. Uses a time-based seed so each tap gives
    /// a fresh selection.
    ///
    /// No-op when no photos are loaded yet (`makeInputs` returns nil/empty)
    /// — there's nothing to regenerate before the library cache loads, and
    /// the first scan's own `generateIfNeeded` populates from scratch.
    func forceRegenerate() {
        guard makeInputs?()?.photos.isEmpty == false else { return }
        generationEpoch += 1
        generatedDay = nil
        all = []
        cache.clear()
        Log.memory.info("Force-regenerating memories")
        generateIfNeeded(seed: "\(clock.now().timeIntervalSinceReferenceDate)")
    }

    /// Background-task entry point: same once-per-day gate as the foreground
    /// path, but awaited so the BG handler knows when to call
    /// `setTaskCompleted`. The Store refreshes contacts before calling this.
    func runScheduledRefresh() async {
        guard let inputs = makeInputs?(), !inputs.photos.isEmpty else {
            Log.bg.info("No photos in memory; skipping background memory generation")
            return
        }
        let today = Calendar.current.startOfDay(for: clock.now())
        let alreadyToday = generatedDay.map { Calendar.current.isDate($0, inSameDayAs: today) } ?? false
        if alreadyToday {
            Log.bg.info("Memories already generated today; skipping BG regeneration")
            return
        }
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        let epoch = generationEpoch
        await generate(inputs: inputs, seed: WidgetDayKey.string(for: today))
        // Gate only on completion: if the BG task expired and cancelled us
        // mid-generation, the day must stay unconsumed so the next foreground
        // entry retries instead of keeping yesterday's memories all day.
        if !Task.isCancelled && epoch == generationEpoch {
            generatedDay = today
        }
    }

    private func generate(inputs: GenerationInputs, seed: String) async {
        let t = CFAbsoluteTimeGetCurrent()

        // Drop file-provider placeholders that don't have a cached sidecar
        // yet — their tags/GPS/date are unknown, so they'd inflate the pool
        // with garbage candidates. Local photos and remote-with-cached-
        // sidecar photos pass through.
        let filtered = inputs.photos.filter { photo in
            switch photo.locality {
            case .local: return true
            case .remote(let downloaded):
                if downloaded { return true }
                if case .cached = photo.sidecarStatus { return true }
                return false
            }
        }
        if filtered.count != inputs.photos.count {
            Log.memory.info("Memory pool: \(filtered.count) of \(inputs.photos.count) photos (excluded \(inputs.photos.count - filtered.count) cloud placeholders without sidecars)")
        }

        CoreMemories.logInputSummary(allPhotos: filtered)

        // The whole snapshot crosses to a detached task inside `generate`, so
        // nothing below this line reads the Store or the coordinator until the
        // await returns. `contactsByLowerName` is not passed: the core derives
        // it from `contacts` exactly as `ContactLinker.index` does (lowercased
        // full name, first write wins), and shipping both would let the two
        // disagree across the boundary.
        let results = await CoreMemories.generate(CoreMemories.Inputs(
            photos: filtered,
            leafFolders: inputs.leafFolders,
            contacts: inputs.contacts,
            personContactLinks: inputs.personContactLinks,
            birthdaysEnabled: birthdaysEnabled,
            mePersonPath: inputs.mePersonPath,
            hiddenPeople: inputs.hiddenPeople,
            now: clock.now(),
            seed: seed,
            seenMemoryIDs: seenMemoryIDs,
            surfacedClusters: surfacedClusters
        ))

        // An expired BG task cancels mid-generation — don't publish a
        // potentially partial result set over a good cached one.
        guard !Task.isCancelled else {
            Log.memory.info("Memory generation cancelled; discarding results")
            return
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - t) * 1000
        all = results
        // Record the clusters we just surfaced so the next generation
        // applies the cool-down penalty to their members.
        let now = clock.now()
        var updated = surfacedClusters
        for memory in results {
            updated[CoreMemories.clusterKey(for: memory.id)] = now
        }
        surfacedClusters = updated
        cache.save(all)
        Log.memory.info("Generated \(results.count) memories in \(String(format: "%.0f", elapsed))ms")

        // Memories changed → refresh the widget snapshot so the Memories
        // widget picks up new "On this day" / "Years ago" content the same
        // day they become valid.
        onMemoriesPublished?()
    }
}
