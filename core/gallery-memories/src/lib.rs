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

use gallery_model::text;
use gallery_model::{AppleDate, PhotoFile, StableId};

pub use scheduled::{compute_scheduled, ScheduledMemory, SCHEDULED_MEMORY_HORIZON_DAYS};
pub use selection::cluster_key;
pub use time::{LocalCalendar, UtcOffset, Zone};

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
#[derive(Debug, Clone)]
pub struct GenerationInputs {
    /// The photo table.
    ///
    /// The **first [`Self::ladder_photo_count`]** entries are the scored pool:
    /// the coordinator's cloud-placeholder filter has already run over them,
    /// and every ladder stage draws from them alone. Anything after that is a
    /// placeholder appended for the **folder-event ladder only** — see
    /// [`Self::ladder_photos`].
    pub photos: Vec<PhotoFile>,
    /// How many leading entries of `photos` the score ladder may draw from.
    ///
    /// Equal to `photos.len()` for a caller with no placeholders, which is
    /// every caller except `MemoryCoordinator`.
    pub ladder_photo_count: usize,
    /// `Calendar.current.timeZone.secondsFromGMT(for: photo.dateTaken)`, one
    /// per entry of `photos`. **May be empty**, meaning "use the offset at
    /// `now` for every photo" — see [`crate::time`] for why per-photo offsets
    /// exist and what an empty table costs.
    pub photo_time_zone_offsets: Vec<i32>,
    /// `Calendar.current.timeZone.secondsFromGMT(for:)` at each horizon day's
    /// local noon, indexed by days from today. **May be empty**, meaning "use
    /// the offset at `now` for every day". Read by [`crate::scheduled`] alone —
    /// see [`Zone::at_horizon_day`] for why the table is longer than the
    /// horizon.
    pub horizon_time_zone_offsets: Vec<i32>,
    pub leaf_folders: Vec<LeafFolder>,
    pub contacts: Vec<Contact>,
    /// `People/*` tag path → explicit link.
    pub person_contact_links: HashMap<String, PersonLink>,
    pub birthdays_enabled: bool,
    /// The user's own `People/*` tag, dropped from trip titles. Empty = unset.
    pub me_person_path: String,
    pub hidden_people: HashSet<String>,
    pub now: AppleDate,
    /// The offset at `now`. Today, the horizon and the penalty windows are all
    /// computed in it.
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
            ladder_photo_count: 0,
            photo_time_zone_offsets: Vec::new(),
            horizon_time_zone_offsets: Vec::new(),
            leaf_folders: Vec::new(),
            contacts: Vec::new(),
            person_contact_links: HashMap::new(),
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

    /// Replace the scored pool. Keeps `ladder_photo_count` and `photos` in step
    /// so a caller with no placeholders cannot get the invariant wrong.
    pub fn with_photos(mut self, photos: Vec<PhotoFile>) -> Self {
        self.ladder_photo_count = photos.len();
        self.photos = photos;
        self
    }

    /// The scored pool: every stage but folder events sees only these.
    ///
    /// Clamped rather than indexed, so a caller that sets the count wrong gets
    /// fewer memories instead of a panic in the middle of a background task.
    pub fn ladder_photos(&self) -> &[PhotoFile] {
        &self.photos[..self.ladder_photo_count.min(self.photos.len())]
    }

    /// The offsets this run works in.
    pub fn zone(&self) -> Zone {
        let zone = if self.photo_time_zone_offsets.is_empty() {
            Zone::fixed(self.time_zone)
        } else {
            Zone::new(self.time_zone, self.photo_time_zone_offsets.clone())
        };
        zone.with_horizon_offsets(self.horizon_time_zone_offsets.clone())
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

/// The inputs' person-keyed lookups, in the form Swift compared them.
///
/// Swift's `Set<String>` and `Dictionary` hash by **canonical equivalence**: a
/// `People/Jos\u{00E9}` tag matches a `People/Jose\u{0301}` hidden entry and a
/// contact spelled either way. A byte-keyed Rust `HashMap` splits the two
/// silently, and only for the users whose names carry accents — the ones most
/// likely to have both spellings in play, because Foundation's
/// `URL(fileURLWithPath:)` decomposes while a typed contact name does not.
///
/// Every key is folded once here, per generation, so the lookups downstream
/// stay O(1). Case is **preserved** for tag paths (`nfc`) because Swift kept
/// `People/alice` and `People/Alice` apart, and folded for contact names
/// (`match_key`) because `ContactLinker.index` lowercased them itself.
///
/// Contact **identifiers** are deliberately not folded anywhere: they are
/// opaque `CNContact.identifier` strings, ASCII by construction, and folding
/// them would be pretending a normalisation question exists where it does not.
#[derive(Debug, Clone, Default)]
pub struct PersonKeys {
    hidden_people: HashSet<String>,
    me_person_path: String,
    person_contact_links: HashMap<String, PersonLink>,
    /// `ContactLinker.index`: lowercased full name → contact, first write wins.
    ///
    /// Derived from `contacts` here rather than shipped across the FFI, which
    /// is what stops the app's copy and the core's from disagreeing.
    contacts_by_name: HashMap<String, Contact>,
}

impl PersonKeys {
    pub fn build(inputs: &GenerationInputs) -> Self {
        let mut contacts_by_name: HashMap<String, Contact> =
            HashMap::with_capacity(inputs.contacts.len());
        for c in &inputs.contacts {
            contacts_by_name
                .entry(text::match_key(&c.full_name()))
                .or_insert_with(|| c.clone());
        }
        PersonKeys {
            hidden_people: inputs.hidden_people.iter().map(|p| text::nfc(p)).collect(),
            me_person_path: text::nfc(&inputs.me_person_path),
            person_contact_links: inputs
                .person_contact_links
                .iter()
                .map(|(k, v)| (text::nfc(k), v.clone()))
                .collect(),
            contacts_by_name,
        }
    }

    /// `person_path` folded to the form the three lookups below take. Fold once
    /// per person, not once per lookup.
    pub fn key(person_path: &str) -> String {
        text::nfc(person_path)
    }

    pub fn is_hidden(&self, key: &str) -> bool {
        self.hidden_people.contains(key)
    }

    /// Is this the user's own tag? Always `false` when no "me" tag is set —
    /// an unset `me_person_path` must not match a photo tagged with the empty
    /// string.
    pub fn is_me(&self, key: &str) -> bool {
        !self.me_person_path.is_empty() && self.me_person_path == key
    }

    pub fn link_for(&self, key: &str) -> Option<&PersonLink> {
        self.person_contact_links.get(key)
    }

    /// The auto-match: a contact whose full name equals the tag's leaf.
    pub fn contact_named(&self, display_name: &str) -> Option<&Contact> {
        self.contacts_by_name.get(&text::match_key(display_name))
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
    let zone = inputs.zone();
    let cal = zone.now();
    // The **whole** table, placeholders included. Only the folder-event stage
    // below indexes past `ladder_photo_count`; everything else works off
    // `dated`, which is built from the scored pool alone.
    let photos = &inputs.photos;
    let today = inputs.now;
    let today_md = cal.month_day(today);
    let current_month_year = (cal.civil(today).month, cal.civil(today).year);

    let dated = photos_with_dates(inputs.ladder_photos());
    let mut candidates: Vec<Memory> = Vec::new();

    // === 1. On This Day ===
    if let Some(memory) =
        calendar::generate_on_this_day(&zone, photos, today, &dated, MIN_ON_THIS_DAY_PHOTOS)
    {
        candidates.push(memory);
    }

    // === 2. X Years Ago ===
    candidates.extend(calendar::generate_years_ago(
        &zone,
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
    //
    // The one stage that sees the placeholder tail. The deleted Swift read
    // `folder.photos` — the folder's own array, which the coordinator's
    // cloud-placeholder filter never touched, because that filter only ever
    // applied to `allPhotos`:
    //
    //     for folder in leafFolders {
    //         let withDatesRaw = folder.photos.compactMap { … }
    //
    // Resolving those ids through the *filtered* pool instead would silently
    // drop every non-downloaded photo, pushing placeholder-heavy folders below
    // `MIN_PHOTOS` (they vanish) and giving the survivors a different photo
    // set, cover and subtitle under the same `folder-<id>` id. So the lookup
    // spans the whole table.
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
        let last_civil = zone.at(last.0).civil(last.1);
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
        // The photo's own offset, not the run's: a `density-<y>-<m>-<d>` id
        // that moved with the season would break its own cool-down history.
        let key = zone.at(entry.0).ymd(entry.1);
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
    let keys = PersonKeys::build(inputs);
    candidates.extend(trips::generate_trip_memories(
        &zone, photos, &dated, today, &keys,
    ));

    // === 7. Birthdays ===
    if inputs.birthdays_enabled {
        let people = birthdays::PeopleIndex::build(inputs.ladder_photos());
        candidates.extend(birthdays::generate_birthday_memories(
            inputs,
            &keys,
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

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_model::{CivilDateTime, HierarchicalTag};

    /// Ported from the deleted `MemoryEngineSelectionTests`. The 60-second
    /// window is upstream of every count check in the ladder, so it decides
    /// what `MIN_PHOTOS` means; no fixture states it directly because every
    /// scenario is spaced to survive it.
    fn at(offset: f64) -> AppleDate {
        AppleDate::from_unix_secs_f64(
            CivilDateTime::new(2023, 5, 1, 10, 0, 0).as_naive_unix_secs() as f64 + offset,
        )
    }

    #[test]
    fn dedup_keeps_the_first_entry_of_each_rolling_window() {
        let entries: Vec<DatedPhoto> = [0.0, 30.0, 90.0]
            .iter()
            .enumerate()
            .map(|(i, o)| (i as u32, at(*o)))
            .collect();
        let kept = dedup_by_time_window(&entries);
        // The 30 s shot is inside the first's window; the 90 s one starts anew.
        assert_eq!(kept.iter().map(|e| e.0).collect::<Vec<_>>(), vec![0, 2]);
    }

    /// The `[PhotoFile]` overload: an undated photo passes through and does
    /// **not** reset the window — there is nothing to dedup it against
    /// (landmine 12). Only birthdays ever calls this.
    #[test]
    fn undated_photos_pass_through_the_dedup_without_resetting_the_window() {
        let mut photos: Vec<PhotoFile> = (0..4)
            .map(|i| PhotoFile::new(&format!("/lib/{i}.jpg"), format!("{i}"), 0))
            .collect();
        photos[0].date_taken = Some(at(0.0));
        photos[1].date_taken = None;
        photos[2].date_taken = Some(at(30.0));
        photos[3].date_taken = Some(at(120.0));
        let kept = dedup_photos_by_time_window(&photos, &[0, 1, 2, 3]);
        assert_eq!(kept, vec![0, 1, 3]);
    }

    /// `finalize` is the one post-processing step every surfaced memory goes
    /// through, including the widget's pre-published days.
    #[test]
    fn finalize_subtitles_a_small_memory_without_touching_its_photos() {
        let cal = LocalCalendar::new(UtcOffset::UTC);
        let ids: Vec<StableId> = (0..5)
            .map(|i| StableId::for_photo(&format!("/lib/{i}.jpg")))
            .collect();
        let out = finalize(
            &cal,
            vec![Memory {
                id: "trip-2023-5-1".to_string(),
                kind: MemoryType::Trip,
                title: "A trip".to_string(),
                subtitle: None,
                photo_ids: ids.clone(),
                cover_photo_id: ids[2],
                date_range: None,
                score: 20.0,
                years_ago: None,
                person_name: None,
            }],
        );
        assert_eq!(out[0].photo_ids, ids);
        assert_eq!(out[0].cover_photo_id, ids[2]);
        assert_eq!(out[0].subtitle.as_deref(), Some("5 photos"));
    }

    // -----------------------------------------------------------------------
    // Folder events see the cloud placeholders
    // -----------------------------------------------------------------------

    /// 2019-11-05 10:00 UTC + `i` minutes.
    fn november(i: usize) -> AppleDate {
        AppleDate::from_unix_secs_f64(
            CivilDateTime::new(2019, 11, 5, 10, 0, 0).as_naive_unix_secs() as f64
                + (i as f64) * 120.0,
        )
    }

    fn dated_photo(path: &str, at: AppleDate) -> PhotoFile {
        let mut p = PhotoFile::new(path, "x".to_string(), 1);
        p.date_taken = Some(at);
        p
    }

    /// A folder of 20 photos of which 12 are non-downloaded cloud placeholders,
    /// and the inputs the coordinator would build for it.
    fn folder_with_placeholders() -> (Vec<PhotoFile>, Vec<PhotoFile>, LeafFolder) {
        // Interleaved, not appended: the folder's listing order is the order
        // `photo_ids` records, and a placeholder sitting in the middle is what
        // moves the cover.
        let all: Vec<PhotoFile> = (0..20)
            .map(|i| dated_photo(&format!("/lib/November/{i:02}.jpg"), november(i)))
            .collect();
        let folder = LeafFolder {
            id: StableId::for_folder("/lib/November"),
            name: "November".to_string(),
            photo_ids: all.iter().map(|p| p.id).collect(),
        };
        let (live, placeholders): (Vec<_>, Vec<_>) =
            all.into_iter().enumerate().partition(|(i, _)| i % 5 < 2);
        (
            live.into_iter().map(|(_, p)| p).collect(),
            placeholders.into_iter().map(|(_, p)| p).collect(),
            folder,
        )
    }

    fn folder_inputs(
        live: Vec<PhotoFile>,
        placeholders: Vec<PhotoFile>,
        folder: LeafFolder,
    ) -> GenerationInputs {
        // 2020-03-01, so the folder's November days are outside the current
        // month/year the folder ladder refuses.
        let now = AppleDate::from_unix_secs_f64(
            CivilDateTime::new(2020, 3, 1, 12, 0, 0).as_naive_unix_secs() as f64,
        );
        let ladder_photo_count = live.len();
        let mut photos = live;
        photos.extend(placeholders);
        GenerationInputs {
            photos,
            ladder_photo_count,
            leaf_folders: vec![folder],
            ..GenerationInputs::empty(now, UtcOffset::UTC, "seed")
        }
    }

    /// The parity this exists to hold. The deleted Swift read the folder's own
    /// array, which the cloud-placeholder filter never touched:
    ///
    /// ```text
    /// for folder in leafFolders {
    ///     let withDatesRaw = folder.photos.compactMap { photo -> (PhotoFile, Date)? in
    ///         guard let date = photo.dateTaken else { return nil }
    ///         return (photo, date)
    ///     }.sorted { $0.1 < $1.1 }
    /// ```
    ///
    /// So a folder of 20 photos made a 20-photo memory whether or not 12 of
    /// them were still in the cloud — same membership, same
    /// `ids[ids.count / 3]` cover, same subtitle. Resolving the ids through the
    /// filtered pool alone would have made it an 8-photo folder, which is below
    /// `MIN_PHOTOS` and therefore no memory at all.
    #[test]
    fn a_folder_event_counts_its_cloud_placeholders_exactly_as_the_swift_did() {
        let (live, placeholders, folder) = folder_with_placeholders();
        let every_id: Vec<StableId> = folder.photo_ids.clone();
        let inputs = folder_inputs(live, placeholders, folder);

        let memories = generate(&inputs);
        let event = memories
            .iter()
            .find(|m| m.kind == MemoryType::FolderEvent)
            .expect("the folder event must survive its placeholders");
        assert_eq!(event.photo_ids, every_id, "membership is the folder's own");
        assert_eq!(
            event.cover_photo_id,
            every_id[every_id.len() / 3],
            "the cover is ids[count / 3] of the FULL list"
        );
        assert_eq!(
            event.subtitle.as_deref(),
            Some("Nov 5, 2019 \u{00B7} 20 photos")
        );
    }

    /// The bug, stated as a test: the same folder with the placeholders
    /// withheld falls below `MIN_PHOTOS` and produces nothing at all.
    #[test]
    fn withholding_the_placeholders_deletes_the_folder_event_entirely() {
        let (live, _placeholders, folder) = folder_with_placeholders();
        let inputs = folder_inputs(live, Vec::new(), folder);
        assert!(
            !generate(&inputs)
                .iter()
                .any(|m| m.kind == MemoryType::FolderEvent),
            "8 of 20 photos is under the 15-photo floor — this is what the \
             filtered-pool resolution silently did"
        );
    }

    /// A placeholder is folder-event fuel and *nothing else*: it must not reach
    /// the density day it would otherwise push over the threshold, because the
    /// coordinator excluded it for a reason (no tags, no GPS, no trustworthy
    /// date).
    #[test]
    fn placeholders_stay_out_of_every_other_ladder() {
        let (live, placeholders, folder) = folder_with_placeholders();
        let placeholder_ids: Vec<StableId> = placeholders.iter().map(|p| p.id).collect();
        let inputs = folder_inputs(live, placeholders, folder);
        for memory in generate(&inputs) {
            if memory.kind == MemoryType::FolderEvent {
                continue;
            }
            for id in &placeholder_ids {
                assert!(
                    !memory.photo_ids.contains(id),
                    "{} leaked a placeholder into a {:?}",
                    memory.id,
                    memory.kind
                );
            }
        }
    }

    // -----------------------------------------------------------------------
    // DST: a photo's day must not depend on the season the run happens in
    // -----------------------------------------------------------------------

    const CET: i32 = 3600;
    const CEST: i32 = 2 * 3600;

    fn utc_at(y: i32, mo: u32, d: u32, h: u32, mi: u32) -> AppleDate {
        AppleDate::from_unix_secs_f64(
            CivilDateTime::new(y, mo, d, h, mi, 0).as_naive_unix_secs() as f64
        )
    }

    /// A Berlin library with one dense evening that is **after** local midnight
    /// in summer time and **before** it in winter time.
    ///
    /// 20 photos over 2019-07-14 22:00–22:57 UTC — 00:00–00:57 CEST on July 15,
    /// but 23:00–23:57 CET on July 14 — plus 30 single-photo days so the
    /// density average stays low enough for the dense day to clear
    /// `max(MIN_PHOTOS, avg × 3)`.
    fn berlin_library() -> Vec<PhotoFile> {
        let mut photos: Vec<PhotoFile> = (0..20)
            .map(|i| {
                dated_photo(
                    &format!("/lib/dense-{i:02}.jpg"),
                    // 3 minutes apart, comfortably outside the 60 s dedup.
                    AppleDate(utc_at(2019, 7, 14, 22, 0).0 + i as f64 * 180.0),
                )
            })
            .collect();
        photos.extend((0..30).map(|i| {
            dated_photo(
                &format!("/lib/filler-{i:02}.jpg"),
                AppleDate(utc_at(2019, 9, 1, 12, 0).0 + i as f64 * 86_400.0),
            )
        }));
        photos
    }

    fn berlin_inputs(now: AppleDate, now_offset: i32, per_photo: Option<i32>) -> GenerationInputs {
        let photos = berlin_library();
        let offsets = match per_photo {
            Some(o) => vec![o; photos.len()],
            None => Vec::new(),
        };
        GenerationInputs {
            photo_time_zone_offsets: offsets,
            ..GenerationInputs::empty(now, UtcOffset(now_offset), "seed").with_photos(photos)
        }
    }

    fn density_id(inputs: &GenerationInputs) -> String {
        generate(inputs)
            .into_iter()
            .find(|m| m.kind == MemoryType::PhotoDensity)
            .map(|m| m.id)
            .expect("the dense day must produce a density memory")
    }

    /// The bug, reproduced: with one offset resolved at `now`, the same library
    /// yields a different `density-*` id in January than in July. That id is
    /// also its own cluster key, so the −25 cool-down and the −30 seen penalty
    /// the user's taps wrote against one spelling stop applying to the other —
    /// twice a year, for every DST user.
    #[test]
    fn a_single_run_offset_moves_a_berlin_density_id_between_seasons() {
        let winter = berlin_inputs(utc_at(2020, 1, 15, 12, 0), CET, None);
        let summer = berlin_inputs(utc_at(2020, 7, 15, 12, 0), CEST, None);
        assert_eq!(density_id(&winter), "density-2019-7-14");
        assert_eq!(density_id(&summer), "density-2019-7-15");
    }

    /// The fix: the photo carries the offset that was in force when it was
    /// taken, so both runs agree — and agree on the *summer* answer, which is
    /// the one the photo's own wall clock had.
    #[test]
    fn per_photo_offsets_pin_a_berlin_density_id_across_seasons() {
        let winter = berlin_inputs(utc_at(2020, 1, 15, 12, 0), CET, Some(CEST));
        let summer = berlin_inputs(utc_at(2020, 7, 15, 12, 0), CEST, Some(CEST));
        assert_eq!(density_id(&winter), "density-2019-7-15");
        assert_eq!(density_id(&summer), density_id(&winter));
        assert_eq!(
            cluster_key(&density_id(&winter)),
            cluster_key(&density_id(&summer)),
            "the cool-down key is the id, so it has to be stable too"
        );
    }

    /// `now` still moves with the run: the horizon and the penalty windows are
    /// computed in the offset at `now`, not in any photo's. A photo taken at
    /// 23:30 UTC today is "today" in Berlin summer and yesterday in UTC.
    #[test]
    fn now_keeps_the_runs_own_offset() {
        let inputs = berlin_inputs(utc_at(2020, 7, 15, 22, 30), CEST, Some(CEST));
        assert_eq!(inputs.zone().now().ymd(inputs.now).day, 16);
        assert_eq!(inputs.zone().at(0).offset, UtcOffset(CEST));
    }

    // -----------------------------------------------------------------------
    // Canonical-equivalence keys (Swift `Set<String>` / `Dictionary`)
    // -----------------------------------------------------------------------

    fn person_photo(path: &str, tag: &str, at: AppleDate) -> PhotoFile {
        let mut p = dated_photo(path, at);
        p.hierarchical_tags = vec![HierarchicalTag::new(tag)];
        p
    }

    /// A birthday library for `tag`, on a day the contact below has a birthday.
    fn birthday_inputs(tag: &str) -> GenerationInputs {
        let now = AppleDate::from_unix_secs_f64(
            CivilDateTime::new(2024, 6, 11, 12, 0, 0).as_naive_unix_secs() as f64,
        );
        let photos: Vec<PhotoFile> = (0..3)
            .map(|i| {
                person_photo(
                    &format!("/lib/p-{i}.jpg"),
                    tag,
                    AppleDate::from_unix_secs_f64(
                        CivilDateTime::new(2020, 1, 1, 10, 0, 0).as_naive_unix_secs() as f64
                            + i as f64 * 86_400.0,
                    ),
                )
            })
            .collect();
        GenerationInputs {
            contacts: vec![Contact {
                id: "c-jose".to_string(),
                // Precomposed, the way a typed address-book entry is stored.
                given_name: "Jos\u{00E9}".to_string(),
                family_name: "Ruiz".to_string(),
                birthday_month: Some(6),
                birthday_day: Some(11),
            }],
            ..GenerationInputs::empty(now, UtcOffset::UTC, "seed").with_photos(photos)
        }
    }

    /// The tag comes off a filename, so on Apple platforms it is **decomposed**;
    /// the contact was typed, so it is **precomposed**. Swift's `Dictionary`
    /// matched the two. A byte-keyed map does not, and the birthday memory
    /// silently stops being generated for exactly the people whose names have
    /// accents.
    #[test]
    fn a_decomposed_person_tag_matches_a_precomposed_contact() {
        let decomposed = generate(&birthday_inputs("People/Jose\u{0301} Ruiz"));
        let precomposed = generate(&birthday_inputs("People/Jos\u{00E9} Ruiz"));
        for (label, memories) in [("NFD", &decomposed), ("NFC", &precomposed)] {
            assert!(
                memories.iter().any(|m| m.kind == MemoryType::Birthday),
                "{label} spelling produced no birthday memory"
            );
        }
        // …and the title still uses the TAG's spelling, not the contact's
        // (landmine 13), so the two ids differ even though both resolved.
        assert_eq!(
            decomposed[0].person_name.as_deref(),
            Some("Jose\u{0301} Ruiz")
        );
    }

    /// The hidden set is a Swift `Set<String>`: hiding the precomposed spelling
    /// hides the decomposed tag too. Getting this wrong surfaces a memory the
    /// user explicitly hid — the failure mode is *more* output, which no smoke
    /// test notices.
    #[test]
    fn hiding_a_person_by_either_spelling_hides_both() {
        let mut inputs = birthday_inputs("People/Jose\u{0301} Ruiz");
        inputs.hidden_people = HashSet::from(["People/Jos\u{00E9} Ruiz".to_string()]);
        assert!(!generate(&inputs)
            .iter()
            .any(|m| m.kind == MemoryType::Birthday));
    }

    /// `.disabled` is looked up in a Swift `Dictionary` keyed by the same
    /// paths, so it has to fold identically.
    #[test]
    fn a_person_link_matches_across_spellings_too() {
        let mut inputs = birthday_inputs("People/Jose\u{0301} Ruiz");
        inputs.person_contact_links =
            HashMap::from([("People/Jos\u{00E9} Ruiz".to_string(), PersonLink::Disabled)]);
        assert!(!generate(&inputs)
            .iter()
            .any(|m| m.kind == MemoryType::Birthday));
    }
}
