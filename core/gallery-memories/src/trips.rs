//! `MemoryEngine+Trips.swift`: home-region clustering, away-from-home
//! segmentation, sub-trip splitting along the `Places/*` hierarchy, and title
//! composition.
//!
//! The one branch the fixtures do **not** cover is the global-median fallback
//! that runs when no home cluster is detected: every trip scenario has a real
//! home cluster, and the fallback needs a sparse-GPS library of its own. It is
//! ported here faithfully and is untested by conformance — treat a change to it
//! as unguarded.

use std::collections::{HashMap, HashSet};

use gallery_model::{AppleDate, PhotoFile};

use gallery_model::text;

use crate::locale::country_name;
use crate::time::{YearMonthDay, Zone};
use crate::{
    dedup_by_time_window, ids_of, sorted_ascending, DatedPhoto, Memory, MemoryType, PersonKeys,
};

/// A trip needs this many photos after dedup, parent and sub-trip alike.
const MIN_TRIP_PHOTOS: usize = 15;
/// A gap longer than this inside an away-from-home run splits it in two.
const TRIP_GAP_SECONDS: f64 = 48.0 * 3600.0;

pub fn haversine_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let r = 6371.0;
    let d_lat = (lat2 - lat1) * std::f64::consts::PI / 180.0;
    let d_lon = (lon2 - lon1) * std::f64::consts::PI / 180.0;
    let a = (d_lat / 2.0).sin() * (d_lat / 2.0).sin()
        + (lat1 * std::f64::consts::PI / 180.0).cos()
            * (lat2 * std::f64::consts::PI / 180.0).cos()
            * (d_lon / 2.0).sin()
            * (d_lon / 2.0).sin();
    r * 2.0 * a.sqrt().atan2((1.0 - a).sqrt())
}

/// A quantised GPS cell, ~11 km × 11 km at the equator.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct GridCell {
    pub lat_bin: i64,
    pub lon_bin: i64,
}

impl GridCell {
    const BIN_SIZE_DEGREES: f64 = 0.1;

    pub fn at(lat: f64, lon: f64) -> Self {
        GridCell {
            lat_bin: (lat / Self::BIN_SIZE_DEGREES).floor() as i64,
            lon_bin: (lon / Self::BIN_SIZE_DEGREES).floor() as i64,
        }
    }
}

/// Cells the user has lived in, each expanded by its 8 neighbours so "home" is
/// a ~33 km region rather than one cell a residence might sit on the edge of.
#[derive(Debug, Default)]
pub struct HomeRegions {
    pub primary_count: usize,
    pub cells: HashSet<GridCell>,
}

impl HomeRegions {
    pub fn is_empty(&self) -> bool {
        self.cells.is_empty()
    }

    pub fn contains(&self, lat: f64, lon: f64) -> bool {
        self.cells.contains(&GridCell::at(lat, lon))
    }
}

fn gps(photo: &PhotoFile) -> Option<(f64, f64)> {
    match (photo.gps_latitude, photo.gps_longitude) {
        (Some(lat), Some(lon)) => Some((lat, lon)),
        _ => None,
    }
}

/// A cell qualifies as home when its photos span ≥180 days **and** cover ≥30
/// distinct days. Both together separate "lived here" from "stayed a while":
/// a 3-month trip has wide span but few distinct days; a busy week at home has
/// many distinct days but no span. Both criteria adapt downward for a library
/// younger than ~360 days.
pub fn detect_home_regions(zone: &Zone, photos: &[PhotoFile], geo: &[DatedPhoto]) -> HomeRegions {
    let cal = zone.now();
    struct CellStat {
        first: AppleDate,
        last: AppleDate,
        days: HashSet<YearMonthDay>,
    }
    let mut stats: HashMap<GridCell, CellStat> = HashMap::new();
    for (idx, date) in geo {
        let Some((lat, lon)) = gps(&photos[*idx as usize]) else {
            continue;
        };
        let cell = GridCell::at(lat, lon);
        let day = zone.at(*idx).ymd(*date);
        stats
            .entry(cell)
            .and_modify(|s| {
                if date.0 < s.first.0 {
                    s.first = *date;
                }
                if date.0 > s.last.0 {
                    s.last = *date;
                }
                s.days.insert(day);
            })
            .or_insert_with(|| CellStat {
                first: *date,
                last: *date,
                days: HashSet::from([day]),
            });
    }

    let (Some(first), Some(last)) = (geo.first(), geo.last()) else {
        return HomeRegions::default();
    };
    let total_span_days = cal.day_difference(first.1, last.1);
    let total_distinct_days = geo
        .iter()
        .map(|e| zone.at(e.0).ymd(e.1))
        .collect::<HashSet<_>>()
        .len() as i64;
    let min_span_days = 180.min(30.max(total_span_days / 2));
    let min_distinct_days = 30.min(10.max(total_distinct_days / 4));

    let mut regions = HomeRegions::default();
    for (cell, stat) in &stats {
        let span = cal.day_difference(stat.first, stat.last);
        if span < min_span_days || (stat.days.len() as i64) < min_distinct_days {
            continue;
        }
        regions.primary_count += 1;
        for d_lat in -1..=1 {
            for d_lon in -1..=1 {
                regions.cells.insert(GridCell {
                    lat_bin: cell.lat_bin + d_lat,
                    lon_bin: cell.lon_bin + d_lon,
                });
            }
        }
    }
    regions
}

/// `generateTripMemories`: split the GPS-tagged run into away-from-home
/// stretches and turn each into a trip (plus its sub-trips).
pub fn generate_trip_memories(
    zone: &Zone,
    photos: &[PhotoFile],
    dated: &[DatedPhoto],
    today: AppleDate,
    keys: &PersonKeys,
) -> Vec<Memory> {
    let geo = sorted_ascending(
        dated
            .iter()
            .copied()
            .filter(|(i, _)| gps(&photos[*i as usize]).is_some())
            .collect(),
    );
    if geo.len() < 5 {
        return Vec::new();
    }

    let home = detect_home_regions(zone, photos, &geo);
    // Fallback for libraries too sparse to surface a stable home cluster.
    // NOT covered by any fixture — see the module docs.
    let median_home = if home.is_empty() {
        let mut lats: Vec<f64> = geo
            .iter()
            .filter_map(|e| photos[e.0 as usize].gps_latitude)
            .collect();
        let mut lons: Vec<f64> = geo
            .iter()
            .filter_map(|e| photos[e.0 as usize].gps_longitude)
            .collect();
        lats.sort_by(f64::total_cmp);
        lons.sort_by(f64::total_cmp);
        Some((lats[lats.len() / 2], lons[lons.len() / 2]))
    } else {
        None
    };
    let is_at_home = |photo: &PhotoFile| -> bool {
        let Some((lat, lon)) = gps(photo) else {
            return false;
        };
        match median_home {
            Some((home_lat, home_lon)) => haversine_km(home_lat, home_lon, lat, lon) <= 50.0,
            None => home.contains(lat, lon),
        }
    };

    let mut candidates: Vec<Memory> = Vec::new();
    let mut current: Vec<DatedPhoto> = Vec::new();
    for entry in &geo {
        if is_at_home(&photos[entry.0 as usize]) {
            flush_trip(zone, photos, &current, today, keys, &mut candidates);
            current.clear();
        } else {
            if let Some(last) = current.last() {
                if entry.1 .0 - last.1 .0 > TRIP_GAP_SECONDS {
                    flush_trip(zone, photos, &current, today, keys, &mut candidates);
                    current.clear();
                }
            }
            current.push(*entry);
        }
    }
    flush_trip(zone, photos, &current, today, keys, &mut candidates);
    candidates
}

fn flush_trip(
    zone: &Zone,
    photos: &[PhotoFile],
    entries: &[DatedPhoto],
    today: AppleDate,
    keys: &PersonKeys,
    candidates: &mut Vec<Memory>,
) {
    if entries.len() < MIN_TRIP_PHOTOS {
        return;
    }
    let sorted = dedup_by_time_window(&sorted_ascending(entries.to_vec()));
    if sorted.len() < MIN_TRIP_PHOTOS {
        return;
    }
    let (first, last) = (sorted[0].1, sorted[sorted.len() - 1].1);
    let cal = zone.now();

    let today_civil = cal.civil(today);
    // The trip's own days are read in the photos' offsets: `trip_key` is the
    // memory id AND the cluster key, and an id that shifted with the season
    // would orphan its own cool-down history every March and October.
    let last_civil = zone.at(sorted[sorted.len() - 1].0).civil(last);
    if (last_civil.month, last_civil.year) == (today_civil.month, today_civil.year) {
        return;
    }

    let days = cal.day_difference(first, last).max(1);
    let ids = ids_of(photos, &sorted);
    let start = zone.at(sorted[0].0).civil(first);
    // Density-style, not ISO: no zero padding (landmine 5).
    let trip_key = format!("{}-{}-{}", start.year, start.month, start.day);

    let trip_photos: Vec<u32> = sorted.iter().map(|e| e.0).collect();
    let location = trip_label(photos, &trip_photos);
    let people = trip_people_suffix(photos, &trip_photos, keys, 3);
    candidates.push(Memory {
        id: format!("trip-{trip_key}"),
        kind: MemoryType::Trip,
        title: compose_trip_title(location.as_deref(), people.as_deref()),
        subtitle: None,
        cover_photo_id: ids[ids.len() / 3],
        photo_ids: ids,
        date_range: Some((first, last)),
        score: 20.0 + days as f64 * 1.5,
        years_ago: None,
        person_name: None,
    });

    // Sub-trips: the Buenos Aires leg of a 3-month South America journey. A
    // segment qualifies if it spans ≥2 days, has 15+ photos, and is
    // meaningfully smaller than the parent.
    if days < 5 {
        return;
    }
    let parent_set: HashSet<_> = sorted.iter().map(|e| e.0).collect();
    for seg in split_trip_into_segments(photos, &sorted) {
        if seg.entries.len() < MIN_TRIP_PHOTOS {
            continue;
        }
        let (seg_first, seg_last) = (seg.entries[0].1, seg.entries[seg.entries.len() - 1].1);
        let seg_days = cal.day_difference(seg_first, seg_last).max(1);
        if seg_days < 2 {
            continue;
        }
        let seg_set: HashSet<_> = seg.entries.iter().map(|e| e.0).collect();
        if seg_set == parent_set || seg_set.len() as f64 > parent_set.len() as f64 * 0.85 {
            continue;
        }

        let seg_ids = ids_of(photos, &seg.entries);
        let seg_indices: Vec<u32> = seg.entries.iter().map(|e| e.0).collect();
        let seg_people = trip_people_suffix(photos, &seg_indices, keys, 3);
        candidates.push(Memory {
            id: format!("subtrip-{trip_key}-{}", seg.key),
            kind: MemoryType::Trip,
            title: compose_trip_title(Some(seg.label.as_str()), seg_people.as_deref()),
            subtitle: None,
            cover_photo_id: seg_ids[seg_ids.len() / 3],
            photo_ids: seg_ids,
            date_range: Some((seg_first, seg_last)),
            // Just under the parent so the parent floats first when both
            // surface, but above the generic types.
            score: 15.0 + seg_days as f64 * 1.2,
            years_ago: None,
            person_name: None,
        });
    }
}

// ---------------------------------------------------------------------------
// Segmentation
// ---------------------------------------------------------------------------

/// A consecutive run inside a trip, at one hierarchy level.
pub struct Segment {
    pub label: String,
    pub key: String,
    pub entries: Vec<DatedPhoto>,
}

/// Country-level splits win when ≥2 countries are present; otherwise regions,
/// otherwise cities. `[]` when there is no variation at any depth.
fn split_trip_into_segments(photos: &[PhotoFile], entries: &[DatedPhoto]) -> Vec<Segment> {
    let countries: HashSet<String> = entries
        .iter()
        .filter_map(|e| photos[e.0 as usize].country_code.as_ref())
        .map(|c| c.to_uppercase())
        .collect();
    if countries.len() >= 2 {
        return consecutive_country_segments(photos, entries);
    }
    consecutive_places_segments(photos, entries, 1)
}

fn consecutive_country_segments(photos: &[PhotoFile], entries: &[DatedPhoto]) -> Vec<Segment> {
    let mut out: Vec<Segment> = Vec::new();
    let mut current: Vec<DatedPhoto> = Vec::new();
    let mut current_code: Option<String> = None;

    for e in entries {
        let code = photos[e.0 as usize]
            .country_code
            .as_ref()
            .map(|c| c.to_uppercase());
        if code != current_code {
            if let Some(prev) = &current_code {
                if !current.is_empty() {
                    out.push(Segment {
                        label: country_name(prev).unwrap_or(prev).to_string(),
                        key: prev.to_lowercase(),
                        entries: std::mem::take(&mut current),
                    });
                }
            }
            current.clear();
            current_code = code;
        }
        if current_code.is_some() {
            current.push(*e);
        }
    }
    if let Some(prev) = &current_code {
        if !current.is_empty() {
            out.push(Segment {
                label: country_name(prev).unwrap_or(prev).to_string(),
                key: prev.to_lowercase(),
                entries: current,
            });
        }
    }
    out
}

/// The photo's longest `Places/*` path with the leading `Places` token dropped,
/// so index 0 is the country, 1 the region, 2 the city.
fn places_segments(photo: &PhotoFile) -> Vec<String> {
    photo
        .hierarchical_tags
        .iter()
        .filter(|t| t.namespace.as_deref().map(str::to_lowercase).as_deref() == Some("places"))
        .map(|t| {
            t.full_path
                .split('/')
                .filter(|s| !s.is_empty())
                .skip(1)
                .map(str::to_string)
                .collect::<Vec<String>>()
        })
        // `max(by: { $0.count < $1.count })`: the first longest wins.
        .fold(None::<Vec<String>>, |acc, segs| match acc {
            Some(best) if best.len() >= segs.len() => Some(best),
            _ => Some(segs),
        })
        .unwrap_or_default()
}

fn consecutive_places_segments(
    photos: &[PhotoFile],
    entries: &[DatedPhoto],
    preferred_depth: usize,
) -> Vec<Segment> {
    let per_photo: Vec<Vec<String>> = entries
        .iter()
        .map(|e| places_segments(&photos[e.0 as usize]))
        .collect();
    let distinct_at = |depth: usize| -> usize {
        per_photo
            .iter()
            .filter(|segs| segs.len() > depth)
            .map(|segs| segs[depth].to_lowercase())
            .collect::<HashSet<_>>()
            .len()
    };
    let Some(depth) = (preferred_depth..=2).find(|d| distinct_at(*d) >= 2) else {
        return Vec::new();
    };

    let mut out: Vec<Segment> = Vec::new();
    let mut current: Vec<DatedPhoto> = Vec::new();
    let mut current_label: Option<String> = None;
    let mut current_key: Option<String> = None;

    for (i, e) in entries.iter().enumerate() {
        let segs = &per_photo[i];
        let (label, key) = if segs.len() > depth {
            (
                Some(segs[depth].clone()),
                Some(segs[..=depth].join("-").to_lowercase()),
            )
        } else {
            (None, None)
        };
        if key != current_key {
            if let (Some(l), Some(k)) = (&current_label, &current_key) {
                if !current.is_empty() {
                    out.push(Segment {
                        label: l.clone(),
                        key: k.clone(),
                        entries: std::mem::take(&mut current),
                    });
                }
            }
            current.clear();
            current_label = label;
            current_key = key;
        }
        if current_key.is_some() {
            current.push(*e);
        }
    }
    if let (Some(l), Some(k)) = (current_label, current_key) {
        if !current.is_empty() {
            out.push(Segment {
                label: l,
                key: k,
                entries: current,
            });
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Labelling
// ---------------------------------------------------------------------------

/// An insertion-ordered counter. Replaces the Swift `[String: Int]` walks so
/// nothing downstream depends on hash order — first-seen order, which is what
/// makes `max(by:)`'s keeps-the-first tie behaviour reproducible here.
///
/// The `HashMap` is the index, the `Vec` is the order: a linear `find` per
/// occurrence made this O(occurrences × distinct values), which on a trip whose
/// photos each carry a country code is quadratic in the trip's size.
fn counted(values: impl Iterator<Item = String>) -> Vec<(String, usize)> {
    let mut out: Vec<(String, usize)> = Vec::new();
    let mut slots: HashMap<String, usize> = HashMap::new();
    for v in values {
        match slots.get(&v) {
            Some(slot) => out[*slot].1 += 1,
            None => {
                slots.insert(v.clone(), out.len());
                out.push((v, 1));
            }
        }
    }
    out
}

/// A location title from `Places/*` tags and `photo-tools:CountryCode`, or
/// `None` when there is no tag data at all.
///
/// The 90% rule: when one country dominates, the label collapses to it and a
/// layover stops showing up in the title. Two countries at 50/50 defeat it,
/// which is what `"Argentina & Chile"` in the fixture records.
pub fn trip_label(photos: &[PhotoFile], indices: &[u32]) -> Option<String> {
    let counts = counted(
        indices
            .iter()
            .filter_map(|i| photos[*i as usize].country_code.as_ref())
            .filter(|c| !c.is_empty())
            .cloned(),
    );
    let total: usize = counts.iter().map(|(_, n)| *n).sum();

    if total > 0 {
        // `max(by:)` keeps the first maximal element; ties are unreachable here
        // because a tie cannot also clear the 90% rule (README, nondeterminism
        // note 3).
        let dominant = counts
            .iter()
            .fold(None::<&(String, usize)>, |acc, c| match acc {
                Some(best) if best.1 >= c.1 => Some(best),
                _ => Some(c),
            });
        if let Some((code, n)) = dominant {
            if *n as f64 / total as f64 >= 0.90 {
                // Prefer the most specific shared place ("Hawaii" over "United
                // States") when the hierarchy goes deeper than country level.
                let prefix = deepest_shared_places_prefix(photos, indices);
                if prefix.len() >= 2 {
                    if let Some(leaf) = prefix.last() {
                        return Some(leaf.clone());
                    }
                }
                return Some(country_name(code).unwrap_or(code).to_string());
            }
        }
    }

    if counts.len() >= 2 {
        let mut sorted = counts.clone();
        sorted.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        if sorted.len() > 3 {
            return Some(format!("{} countries", sorted.len()));
        }
        let names: Vec<String> = sorted
            .iter()
            .map(|(c, _)| country_name(c).unwrap_or(c).to_string())
            .collect();
        if names.len() == 2 {
            return Some(format!("{} & {}", names[0], names[1]));
        }
        return Some(format!("{}, {} & {}", names[0], names[1], names[2]));
    }

    let prefix = deepest_shared_places_prefix(photos, indices);
    if let Some(leaf) = prefix.last() {
        return Some(leaf.clone());
    }
    counts
        .first()
        .map(|(code, _)| country_name(code).unwrap_or(code).to_string())
}

/// `"<Location> with X & Y"` / `"A trip to <Location>"` / `"A trip with X"` /
/// `"A trip"`.
pub fn compose_trip_title(location: Option<&str>, people_suffix: Option<&str>) -> String {
    match (location, people_suffix) {
        (Some(loc), Some(names)) => format!("{loc} with {names}"),
        (Some(loc), None) => format!("A trip to {loc}"),
        (None, Some(names)) => format!("A trip with {names}"),
        (None, None) => "A trip".to_string(),
    }
}

/// The `"with"` suffix: the top contributors to a trip's `People/*` tags,
/// minus the user's own tag and the hidden set, reduced to first names.
///
/// Both exclusions go through [`PersonKeys`], so a decomposed `People/Jos\u{00E9}`
/// tag is still recognised as the user's own tag or as hidden — Swift's `==`
/// and `Set.contains` matched canonically and a byte compare does not.
pub fn trip_people_suffix(
    photos: &[PhotoFile],
    indices: &[u32],
    keys: &PersonKeys,
    max_names: usize,
) -> Option<String> {
    let mut counts: Vec<(String, usize)> = Vec::new(); // display name, count
                                                       // Insertion-ordered: the `Vec` is the order, the map is the index. A linear
                                                       // `find` per tag occurrence made this quadratic in the number of tagged
                                                       // faces on a trip, which is exactly the trip a title wants to name.
    let mut slots: HashMap<String, usize> = HashMap::new();
    for idx in indices {
        for tag in &photos[*idx as usize].hierarchical_tags {
            if tag.namespace.as_deref().map(str::to_lowercase).as_deref() != Some("people") {
                continue;
            }
            let key = PersonKeys::key(&tag.full_path);
            if keys.is_me(&key) || keys.is_hidden(&key) {
                continue;
            }
            match slots.get(&key) {
                Some(slot) => counts[*slot].1 += 1,
                None => {
                    slots.insert(key, counts.len());
                    counts.push((tag.display_name.clone(), 1));
                }
            }
        }
    }
    if counts.is_empty() {
        return None;
    }

    // The tiebreak is `localizedCaseInsensitiveCompare`, which collates as if
    // the accents were not there: ICU puts `Émile` before `Eve`, `Özlem` before
    // `Peter` and `åsa` before `Bob`, while a lowercased byte compare puts all
    // three the other way round (the precomposed code points are above ASCII).
    // With equal counts that decides which names reach the title, so
    // `text::collation_key` folds the accents away first.
    //
    // It is **not** full ICU collation: no locale tailorings (Swedish sorts `å`
    // after `z`), no `ß` → `ss` expansion, and non-Latin scripts fall back to
    // code-point order. It agrees with ICU on the Latin-script names this
    // suffix is made of, which is as far as a dependency-free port goes.
    counts.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| text::collation_key(&a.0).cmp(&text::collation_key(&b.0)))
    });
    counts.truncate(max_names);

    let display = disambiguate_first_names(&counts.iter().map(|c| c.0.clone()).collect::<Vec<_>>());
    if display.is_empty() {
        return None;
    }
    Some(join_names(&display))
}

/// Reduce `"First Last"` tag names to the shortest unambiguous form: bare first
/// names, `"First L."` when two share a first name and their last initials
/// differ, and the bare first name again when they do not.
pub fn disambiguate_first_names(names: &[String]) -> Vec<String> {
    struct Parts {
        first: String,
        last_initial: Option<char>,
    }
    let parsed: Vec<Parts> = names
        .iter()
        .map(|raw| {
            let trimmed = raw.trim();
            let tokens: Vec<&str> = trimmed.split(' ').filter(|s| !s.is_empty()).collect();
            Parts {
                first: tokens.first().map_or(trimmed, |t| t).to_string(),
                last_initial: if tokens.len() >= 2 {
                    tokens.last().and_then(|t| t.chars().next())
                } else {
                    None
                },
            }
        })
        .collect();

    let mut groups: Vec<(String, Vec<usize>)> = Vec::new();
    for (i, p) in parsed.iter().enumerate() {
        let key = p.first.to_lowercase();
        match groups.iter_mut().find(|(k, _)| *k == key) {
            Some((_, idxs)) => idxs.push(i),
            None => groups.push((key, vec![i])),
        }
    }

    let mut out = vec![String::new(); parsed.len()];
    for (_, indices) in groups {
        if indices.len() == 1 {
            out[indices[0]] = parsed[indices[0]].first.clone();
            continue;
        }
        let initials: Vec<String> = indices
            .iter()
            .filter_map(|i| {
                parsed[*i]
                    .last_initial
                    .map(|c| c.to_uppercase().to_string())
            })
            .collect();
        let distinct = initials.iter().collect::<HashSet<_>>().len() == indices.len();
        for i in indices {
            match (distinct, parsed[i].last_initial) {
                (true, Some(li)) => out[i] = format!("{} {}.", parsed[i].first, li.to_uppercase()),
                _ => out[i] = parsed[i].first.clone(),
            }
        }
    }
    out
}

/// `"Anna"` / `"Anna & Bob"` / `"Anna, Bob & Charlie"`.
pub fn join_names(names: &[String]) -> String {
    match names.len() {
        0 => String::new(),
        1 => names[0].clone(),
        2 => format!("{} & {}", names[0], names[1]),
        n => format!("{} & {}", names[..n - 1].join(", "), names[n - 1]),
    }
}

/// The longest `Places/*` path shared by every photo that carries one. Photos
/// with no `Places/*` tag are skipped (collapse-on-missing-levels, per
/// photo-tools xmp-schema.md §2.2).
pub fn deepest_shared_places_prefix(photos: &[PhotoFile], indices: &[u32]) -> Vec<String> {
    let per_photo: Vec<Vec<String>> = indices
        .iter()
        .map(|i| places_segments(&photos[*i as usize]))
        .filter(|segs| !segs.is_empty())
        .collect();
    let Some(first) = per_photo.first() else {
        return Vec::new();
    };
    let mut prefix = first.clone();
    for segs in &per_photo[1..] {
        let limit = prefix.len().min(segs.len());
        let mut i = 0;
        while i < limit && prefix[i].to_lowercase() == segs[i].to_lowercase() {
            i += 1;
        }
        prefix.truncate(i);
        if prefix.is_empty() {
            break;
        }
    }
    prefix
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn first_names_disambiguate_only_when_they_collide() {
        assert_eq!(
            disambiguate_first_names(&names(&["Anna Meyer", "Ben Meyer"])),
            names(&["Anna", "Ben"])
        );
        assert_eq!(
            disambiguate_first_names(&names(&["Anna Meyer", "Anna Schmidt"])),
            names(&["Anna M.", "Anna S."])
        );
        // Same initial, so the disambiguation cannot help and is dropped.
        assert_eq!(
            disambiguate_first_names(&names(&["Anna Meyer", "Anna Mueller"])),
            names(&["Anna", "Anna"])
        );
        assert_eq!(
            disambiguate_first_names(&names(&["Anna", "Anna Meyer"])),
            names(&["Anna", "Anna"]),
            "a mononym has no initial to disambiguate with"
        );
    }

    /// One photo per name, so every name has count 1 and the **tiebreak alone**
    /// decides which two reach the title.
    fn people_photos(names: &[&str]) -> Vec<PhotoFile> {
        names
            .iter()
            .enumerate()
            .map(|(i, n)| {
                let mut p = PhotoFile::new(&format!("/lib/{i}.jpg"), "x".to_string(), 1);
                p.hierarchical_tags =
                    vec![gallery_model::HierarchicalTag::new(&format!("People/{n}"))];
                p
            })
            .collect()
    }

    /// The three pairs a lowercased **byte** compare gets backwards. With equal
    /// counts the tiebreak decides which names make the title, so this is not
    /// cosmetic: `Émile & Eve` and `Eve & Émile` are different titles, and only
    /// one of them is what `localizedCaseInsensitiveCompare` produced.
    #[test]
    fn the_people_tiebreak_collates_accented_names_the_way_icu_does() {
        let keys = PersonKeys::default();
        for (accented, plain) in [("Émile", "Eve"), ("Özlem", "Peter"), ("åsa", "Bob")] {
            let photos = people_photos(&[plain, accented]);
            assert_eq!(
                trip_people_suffix(&photos, &[0, 1], &keys, 2).as_deref(),
                Some(format!("{accented} & {plain}").as_str()),
                "{accented} must precede {plain}"
            );
        }
    }

    /// …and the truncation to `max_names` runs *after* that sort, so a wrong
    /// tiebreak does not merely reorder the title — it drops a name from it.
    #[test]
    fn the_tiebreak_decides_which_names_survive_the_truncation() {
        let photos = people_photos(&["Eve", "Émile", "Zoe"]);
        assert_eq!(
            trip_people_suffix(&photos, &[0, 1, 2], &PersonKeys::default(), 1).as_deref(),
            Some("Émile")
        );
    }

    /// Counts still win over the tiebreak — the accented-name fix must not
    /// reorder a name that simply appears more often.
    #[test]
    fn a_higher_count_still_beats_the_collation_order() {
        let mut photos = people_photos(&["Zoe", "Émile"]);
        photos.push(photos[0].clone());
        photos[2] = {
            let mut p = PhotoFile::new("/lib/2.jpg", "x".to_string(), 1);
            p.hierarchical_tags = vec![gallery_model::HierarchicalTag::new("People/Zoe")];
            p
        };
        assert_eq!(
            trip_people_suffix(&photos, &[0, 1, 2], &PersonKeys::default(), 2).as_deref(),
            Some("Zoe & Émile")
        );
    }

    #[test]
    fn name_lists_use_an_ampersand_for_the_last_pair() {
        assert_eq!(join_names(&names(&["Anna"])), "Anna");
        assert_eq!(join_names(&names(&["Anna", "Ben"])), "Anna & Ben");
        assert_eq!(
            join_names(&names(&["Anna", "Ben", "Cara"])),
            "Anna, Ben & Cara"
        );
    }

    #[test]
    fn titles_cover_all_four_input_combinations() {
        assert_eq!(
            compose_trip_title(Some("Chile"), Some("Anna")),
            "Chile with Anna"
        );
        assert_eq!(compose_trip_title(Some("Chile"), None), "A trip to Chile");
        assert_eq!(compose_trip_title(None, Some("Anna")), "A trip with Anna");
        assert_eq!(compose_trip_title(None, None), "A trip");
    }

    #[test]
    fn grid_cells_floor_toward_negative_infinity() {
        // A naive truncating cast puts -34.60 and -34.55 in the same cell as
        // -34.5 and shifts every southern-hemisphere home region by one bin.
        assert_eq!(GridCell::at(-34.60, -58.38).lat_bin, -346);
        assert_eq!(GridCell::at(-34.60, -58.38).lon_bin, -584);
        assert_eq!(GridCell::at(52.52, 13.40).lat_bin, 525);
    }
}

#[cfg(test)]
mod prefix_tests {
    use super::*;
    use gallery_model::HierarchicalTag;

    /// Ported from the deleted `MemoryEngineTripTests`. The trip conformance
    /// scenario exercises this through a two-country trip; these are the
    /// single-photo and no-overlap edges it cannot reach.
    fn tagged(path: &str, tags: &[&str]) -> PhotoFile {
        let mut p = PhotoFile::new(path, "x".to_string(), 0);
        p.hierarchical_tags = tags.iter().map(|t| HierarchicalTag::new(t)).collect();
        p
    }

    #[test]
    fn the_shared_places_prefix_is_the_deepest_one_every_tagged_photo_agrees_on() {
        let rome = tagged("/lib/rome.jpg", &["Places/Italy/Lazio/Rome"]);
        let milan = tagged("/lib/milan.jpg", &["Places/Italy/Lombardy/Milan"]);
        let bern = tagged("/lib/bern.jpg", &["Places/Switzerland/Bern"]);
        let untagged = tagged("/lib/untagged.jpg", &[]);

        let photos = vec![rome, milan, bern, untagged];
        // An untagged photo does not veto the shared prefix.
        assert_eq!(
            deepest_shared_places_prefix(&photos, &[0, 1, 3]),
            vec!["Italy".to_string()]
        );
        // Two countries share nothing below `Places`.
        assert!(deepest_shared_places_prefix(&photos, &[0, 2]).is_empty());
        // Nothing tagged at all.
        assert!(deepest_shared_places_prefix(&photos, &[3]).is_empty());
    }
}
