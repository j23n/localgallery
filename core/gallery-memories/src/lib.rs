//! `MemoryEngine` + `GalleryStore.computeScheduledMemories`, ported (Phase 4
//! step 2).
//!
//! The module layout mirrors the Swift extension files on purpose, so the score
//! ladder documented in `CLAUDE.md` and `_plans/05-phase-4-indexes-memories.md`
//! still maps to code: [`calendar`], [`birthdays`], [`trips`], [`selection`],
//! plus [`scheduled`] for the widget's pre-publish horizon and [`time`] /
//! [`locale`] for the two things Foundation used to supply implicitly.
//!
//! `core/fixtures/memories-conformance/{memory_engine,scheduled_memories}.json`
//! are the spec — 15 generation scenarios and 4 horizon scenarios, generated
//! from the shipping Swift before any of it was ported. Where the Swift is
//! buggy the bug is **pinned**, and this crate reproduces it; each site says so
//! and points at the landmine number in that directory's README.
//!
//! ## What this crate does differently from the Swift, deliberately
//!
//! `_plans/06-performance-baseline.md` Finding 3 measured the scheduled-memory
//! pass at ~9 s on the main thread, and named the architecture — not the
//! language — as the cause. So:
//!
//! 1. **People → photos is grouped once per call**, in [`birthdays::PeopleIndex`],
//!    and shared across all seven horizon days. The Swift regroups the whole
//!    library seven times.
//! 2. **No-birthday days early-exit on the birthday check**, before any photo
//!    work, which is the common case.
//! 3. **Nothing copies a photo.** Every stage carries `u32` indices into the
//!    caller's photo table; the COW-defeating `if var existing = dict[k] { … }`
//!    append that made the Swift quadratic has no analogue here.
//!
//! And two places where Swift's output was *not reproducible* and the fixture
//! pins a contract instead of a coin flip — the birthday walk and the density
//! walk both iterate a `Dictionary`. Here they iterate in **first-seen order**,
//! which is deterministic. That is a tightening; no fixture can say whether a
//! two-birthday day comes out in the "right" order, because Swift had no order.

#![forbid(unsafe_code)]

pub mod birthdays;
pub mod calendar;
pub mod locale;
pub mod scheduled;
pub mod selection;
pub mod time;
pub mod trips;

use std::collections::{HashMap, HashSet};

use gallery_model::{AppleDate, PhotoFile, StableId};

pub use scheduled::{compute_scheduled, ScheduledMemory, SCHEDULED_MEMORY_HORIZON_DAYS};
pub use selection::cluster_key;
pub use time::{LocalCalendar, UtcOffset};

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

/// `MemoryType`. `personOverTime` exists in the Swift enum and is never
/// produced — the generator was removed and the case kept for decoding old
/// caches; it is carried here for the same reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MemoryType {
    OnThisDay,
    YearsAgo,
    PersonOverTime,
    FolderEvent,
    PhotoDensity,
    Trip,
    Birthday,
}

impl MemoryType {
    /// The `rawValue` the Swift enum encodes, which is what the fixtures store.
    pub fn raw_value(self) -> &'static str {
        match self {
            MemoryType::OnThisDay => "onThisDay",
            MemoryType::YearsAgo => "yearsAgo",
            MemoryType::PersonOverTime => "personOverTime",
            MemoryType::FolderEvent => "folderEvent",
            MemoryType::PhotoDensity => "photoDensity",
            MemoryType::Trip => "trip",
            MemoryType::Birthday => "birthday",
        }
    }
}

/// One generated memory.
///
/// `score` is the score **before** the daily jitter — the jitter is never
/// stored, and its only observable effect is the order of the returned list.
/// Swift's `Memory` is `Equatable`/`Hashable` **by id alone**; this type
/// deliberately is not, so that a comparison here is a comparison of content.
#[derive(Debug, Clone, PartialEq)]
pub struct Memory {
    pub id: String,
    pub kind: MemoryType,
    pub title: String,
    pub subtitle: Option<String>,
    /// Ordered; this is the slideshow order and part of the contract.
    pub photo_ids: Vec<StableId>,
    pub cover_photo_id: StableId,
    pub date_range: Option<(AppleDate, AppleDate)>,
    pub score: f64,
    pub years_ago: Option<i32>,
    pub person_name: Option<String>,
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

/// `PersonLink` — an explicit decision about a `People/*` tag that overrides
/// the name-based auto-match.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PersonLink {
    /// Use this contact, whatever the names say.
    Manual(String),
    /// This tag is not a person in the address book. Suppresses the memory.
    Disabled,
}

/// `ContactInfo`, reduced to the fields the engine reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Contact {
    pub id: String,
    pub given_name: String,
    pub family_name: String,
    /// `.year` is routinely missing in address-book data and is never read.
    pub birthday_month: Option<u32>,
    pub birthday_day: Option<u32>,
}

impl Contact {
    /// `"Given Family"` trimmed, falling back to either side for a mononym.
    pub fn full_name(&self) -> String {
        let combined = format!("{} {}", self.given_name, self.family_name);
        let trimmed = combined.trim();
        if trimmed.is_empty() {
            "(No name)".to_string()
        } else {
            trimmed.to_string()
        }
    }

    fn birthday_is(&self, month: u32, day: u32) -> bool {
        self.birthday_month == Some(month) && self.birthday_day == Some(day)
    }
}

/// A leaf `PhotoFolder`, by reference into the photo table rather than by
/// value. The Swift `PhotoFolder` carries `[PhotoFile]`; copying those is one
/// of the costs this port exists to remove.
#[derive(Debug, Clone, PartialEq)]
pub struct LeafFolder {
    /// `PhotoFolder.id` — `StableId::for_folder(path)`. The memory id is
    /// `"folder-<this>"`.
    pub id: StableId,
    pub name: String,
    /// This folder's own photos, in listing order.
    pub photo_ids: Vec<StableId>,
}

/// `MemoryCoordinator.GenerationInputs` plus the clock, zone, seed and the
/// seen/cool-down state — everything `MemoryEngine.generate` reads.
///
/// `photos` is already past the coordinator's cloud-placeholder filter; that
/// filter stays in Swift (plan non-goal).
#[derive(Debug, Clone)]
pub struct GenerationInputs {
    pub photos: Vec<PhotoFile>,
    pub leaf_folders: Vec<LeafFolder>,
    pub contacts: Vec<Contact>,
    /// `People/*` tag path → explicit link.
    pub person_contact_links: HashMap<String, PersonLink>,
    /// `ContactLinker.index`: lowercased full name → contact, first write wins.
    pub contacts_by_lower_name: HashMap<String, Contact>,
    pub birthdays_enabled: bool,
    /// The user's own `People/*` tag, dropped from trip titles. Empty = unset.
    pub me_person_path: String,
    pub hidden_people: HashSet<String>,
    pub now: AppleDate,
    pub time_zone: UtcOffset,
    /// Drives the daily jitter. The day key for a normal run, a time-based
    /// value for force-regenerate.
    pub seed: String,
    /// Memory id → when the user last opened it. −30 within ~6 months.
    pub seen_memory_ids: HashMap<String, AppleDate>,
    /// Cluster key → when the cluster last surfaced. −25 within 3 days.
    pub surfaced_clusters: HashMap<String, AppleDate>,
}

impl GenerationInputs {
    /// A snapshot with an empty library — the shape callers fill in.
    pub fn empty(now: AppleDate, time_zone: UtcOffset, seed: impl Into<String>) -> Self {
        GenerationInputs {
            photos: Vec::new(),
            leaf_folders: Vec::new(),
            contacts: Vec::new(),
            person_contact_links: HashMap::new(),
            contacts_by_lower_name: HashMap::new(),
            birthdays_enabled: true,
            me_person_path: String::new(),
            hidden_people: HashSet::new(),
            now,
            time_zone,
            seed: seed.into(),
            seen_memory_ids: HashMap::new(),
            surfaced_clusters: HashMap::new(),
        }
    }

    pub fn calendar(&self) -> LocalCalendar {
        LocalCalendar::new(self.time_zone)
    }

    /// Does any contact have a birthday on this month/day? The
    /// [Finding 3][crate] early-exit: no contact, no memory, and no reason to
    /// touch a photo.
    pub(crate) fn any_birthday_on(&self, month: u32, day: u32) -> bool {
        self.contacts.iter().any(|c| c.birthday_is(month, day))
    }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// A photo, by index into the caller's table, with its `dateTaken` lifted out.
pub type DatedPhoto = (u32, AppleDate);

/// `allPhotos.compactMap { ($0, $0.dateTaken) }` — in `allPhotos` order.
///
/// Undated photos are dropped here, which is why they are invisible to every
/// generator except birthdays (landmine 12).
pub fn photos_with_dates(photos: &[PhotoFile]) -> Vec<DatedPhoto> {
    photos
        .iter()
        .enumerate()
        .filter_map(|(i, p)| p.date_taken.map(|d| (i as u32, d)))
        .collect()
}

/// `MemoryEngine.memoryDedupWindow` — 60 seconds.
pub const MEMORY_DEDUP_WINDOW: f64 = 60.0;

/// Keep the first photo in any rolling 60-second window of a date-ascending
/// run. A 12-frame burst collapses to one photo — and because this runs
/// **before** every count check, `minPhotos` is a post-dedup threshold
/// (landmine 15).
pub fn dedup_by_time_window(sorted: &[DatedPhoto]) -> Vec<DatedPhoto> {
    let mut out: Vec<DatedPhoto> = Vec::with_capacity(sorted.len());
    let mut last_kept: Option<f64> = None;
    for entry in sorted {
        if let Some(last) = last_kept {
            if entry.1 .0 - last < MEMORY_DEDUP_WINDOW {
                continue;
            }
        }
        out.push(*entry);
        last_kept = Some(entry.1 .0);
    }
    out
}

/// The `[PhotoFile]` overload: photos with no `dateTaken` pass through
/// untouched and do **not** reset the window — there is no signal to dedup them
/// against. Only birthdays ever calls this.
pub fn dedup_photos_by_time_window(photos: &[PhotoFile], indices: &[u32]) -> Vec<u32> {
    let mut out: Vec<u32> = Vec::with_capacity(indices.len());
    let mut last_kept: Option<f64> = None;
    for idx in indices {
        let Some(date) = photos[*idx as usize].date_taken else {
            out.push(*idx);
            continue;
        };
        if let Some(last) = last_kept {
            if date.0 - last < MEMORY_DEDUP_WINDOW {
                continue;
            }
        }
        out.push(*idx);
        last_kept = Some(date.0);
    }
    out
}

/// Sort a dated run ascending, stably.
pub(crate) fn sorted_ascending(mut entries: Vec<DatedPhoto>) -> Vec<DatedPhoto> {
    entries.sort_by(|a, b| a.1 .0.total_cmp(&b.1 .0));
    entries
}

pub(crate) fn ids_of(photos: &[PhotoFile], entries: &[DatedPhoto]) -> Vec<StableId> {
    entries.iter().map(|e| photos[e.0 as usize].id).collect()
}

/// `MemoryEngine.finalize` — the post-processing **every** surfaced memory goes
/// through, including the widget's pre-published days, which is what makes a
/// scheduled item identical to the one generated live on its day.
///
/// Two pinned details (landmine 11):
///
/// - the sampling is `photoIDs[Int(i × count / 75)]`, and
/// - the cover is re-pointed **only when the sampling drops it**, to
///   `photoIDs[count / 2]` *of the sampled list*.
///
/// The subtitle counts the capped photos, not the originals.
pub fn finalize(cal: &LocalCalendar, memories: Vec<Memory>) -> Vec<Memory> {
    const MAX_PHOTOS_PER_MEMORY: usize = 75;
    memories
        .into_iter()
        .map(|mut mem| {
            if mem.photo_ids.len() > MAX_PHOTOS_PER_MEMORY {
                let step = mem.photo_ids.len() as f64 / MAX_PHOTOS_PER_MEMORY as f64;
                let sampled: Vec<StableId> = (0..MAX_PHOTOS_PER_MEMORY)
                    .map(|i| mem.photo_ids[(i as f64 * step) as usize])
                    .collect();
                if !sampled.contains(&mem.cover_photo_id) {
                    mem.cover_photo_id = sampled[sampled.len() / 2];
                }
                mem.photo_ids = sampled;
            }
            mem.subtitle = Some(locale::subtitle_with_count(
                cal,
                mem.date_range,
                mem.photo_ids.len(),
            ));
            mem
        })
        .collect()
}

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

/// Photos below this after dedup do not make a folder event, a density day or
/// a trip.
const MIN_PHOTOS: usize = 15;
/// The calendar generators are allowed a thinner set.
const MIN_ON_THIS_DAY_PHOTOS: usize = 10;

/// `MemoryEngine.generate` — pure over its inputs.
pub fn generate(inputs: &GenerationInputs) -> Vec<Memory> {
    generate_cancellable(inputs, &|| false)
}

/// [`generate`] with a cancellation probe, checked between ladder stages —
/// parity with the `Task.isCancelled` checks the Swift pipeline carries and
/// with the `withTaskCancellationHandler` forwarding around them. A cancelled
/// run returns an empty list, exactly as the Swift does.
pub fn generate_cancellable(
    inputs: &GenerationInputs,
    is_cancelled: &dyn Fn() -> bool,
) -> Vec<Memory> {
    let cal = inputs.calendar();
    let photos = &inputs.photos;
    let today = inputs.now;
    let today_md = cal.month_day(today);
    let current_month_year = (cal.civil(today).month, cal.civil(today).year);

    let dated = photos_with_dates(photos);
    let mut candidates: Vec<Memory> = Vec::new();

    // === 1. On This Day ===
    if let Some(memory) =
        calendar::generate_on_this_day(&cal, photos, today, &dated, MIN_ON_THIS_DAY_PHOTOS)
    {
        candidates.push(memory);
    }

    // === 2. X Years Ago ===
    candidates.extend(calendar::generate_years_ago(
        &cal,
        photos,
        today,
        &dated,
        MIN_ON_THIS_DAY_PHOTOS,
    ));

    // === 3. (Person-over-time memories removed — only birthdays surface
    //        people now. The `personOverTime` case survives for old caches.)

    if is_cancelled() {
        return Vec::new();
    }

    // === 4. Folder-based event memories ===
    let mut by_id: HashMap<StableId, u32> = HashMap::with_capacity(photos.len());
    for (i, photo) in photos.iter().enumerate() {
        by_id.entry(photo.id).or_insert(i as u32);
    }
    for folder in &inputs.leaf_folders {
        let raw: Vec<DatedPhoto> = folder
            .photo_ids
            .iter()
            .filter_map(|id| by_id.get(id))
            .filter_map(|i| photos[*i as usize].date_taken.map(|d| (*i, d)))
            .collect();
        let entries = dedup_by_time_window(&sorted_ascending(raw));
        let (Some(first), Some(last)) = (entries.first(), entries.last()) else {
            continue;
        };
        let last_civil = cal.civil(last.1);
        if entries.len() < MIN_PHOTOS || (last_civil.month, last_civil.year) == current_month_year {
            continue;
        }

        let day_span = cal.day_difference(first.1, last.1);
        let ids = ids_of(photos, &entries);
        candidates.push(Memory {
            id: format!("folder-{}", folder.id),
            kind: MemoryType::FolderEvent,
            title: folder.name.clone(),
            subtitle: None,
            cover_photo_id: ids[ids.len() / 3],
            photo_ids: ids,
            date_range: Some((first.1, last.1)),
            score: 10.0 + (day_span as f64).min(14.0),
            years_ago: None,
            person_name: None,
        });
    }

    // === 5. Photo density ===
    // Swift groups with `Dictionary(grouping:)` and then walks the dictionary,
    // so the candidate order — and therefore which jitter draw each density
    // memory receives — is not reproducible across processes. Here the walk is
    // in first-seen day order. Deterministic, and no fixture can contradict it:
    // every scenario is built so at most one density memory exists.
    let mut day_order: Vec<time::YearMonthDay> = Vec::new();
    let mut by_day: HashMap<time::YearMonthDay, Vec<DatedPhoto>> = HashMap::new();
    for entry in &dated {
        let key = cal.ymd(entry.1);
        by_day
            .entry(key)
            .or_insert_with(|| {
                day_order.push(key);
                Vec::new()
            })
            .push(*entry);
    }
    let avg_per_day = if dated.is_empty() {
        0.0
    } else {
        dated.len() as f64 / by_day.len().max(1) as f64
    };
    // `Int(_:)` truncates toward zero.
    let density_threshold = MIN_PHOTOS.max((avg_per_day * 3.0) as usize);

    for key in &day_order {
        let day_entries = &by_day[key];
        if day_entries.len() < density_threshold {
            continue;
        }
        let day_date = cal.instant_at_midnight(*key);
        // Swift's guard is `!calendar.isDateInToday(dayDate)`, which compares
        // against the *wall clock*, not `today`. Using `today` is the only
        // sensible reading and is a no-op either way: the month/year check on
        // the next line already excludes every day inside today's month.
        if cal.is_same_day(day_date, today) || (key.month, key.year) == current_month_year {
            continue;
        }

        let entries = dedup_by_time_window(&sorted_ascending(day_entries.clone()));
        let (Some(first), Some(last)) = (entries.first(), entries.last()) else {
            continue;
        };
        let ids = ids_of(photos, &entries);
        candidates.push(Memory {
            // Not zero-padded, unlike the ISO calendar ids (landmine 5).
            id: format!("density-{}-{}-{}", key.year, key.month, key.day),
            kind: MemoryType::PhotoDensity,
            title: "A busy day".to_string(),
            subtitle: None,
            cover_photo_id: ids[ids.len() / 2],
            photo_ids: ids,
            date_range: Some((first.1, last.1)),
            score: 8.0,
            years_ago: None,
            person_name: None,
        });
    }

    if is_cancelled() {
        return Vec::new();
    }

    // === 6. Trips ===
    candidates.extend(trips::generate_trip_memories(
        &cal,
        photos,
        &dated,
        today,
        &inputs.me_person_path,
        &inputs.hidden_people,
    ));

    // === 7. Birthdays ===
    if inputs.birthdays_enabled {
        let people = birthdays::PeopleIndex::build(photos);
        candidates.extend(birthdays::generate_birthday_memories(
            inputs,
            &people,
            today_md.month,
            today_md.day,
        ));
    }

    if is_cancelled() {
        return Vec::new();
    }

    let candidates = finalize(&cal, candidates);
    selection::select(inputs, &cal, candidates)
}
