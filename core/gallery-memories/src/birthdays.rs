//! `MemoryEngine+Birthdays.swift`, plus the fix `_plans/06` Finding 3 asked
//! for.
//!
//! The Swift builds its person → photos grouping inside every caller, once per
//! horizon day, with an append pattern that defeats copy-on-write and copies
//! the person's whole `[PhotoFile]` array on each insert. That is the ~9-second
//! main-thread stall Finding 3 measured. Here the grouping is a
//! [`PeopleIndex`] of `u32` indices, built **once** per generation or horizon
//! pass, and every no-birthday day exits before it is even consulted.

use std::collections::HashMap;

use gallery_model::PhotoFile;

use crate::{
    dedup_photos_by_time_window, Contact, GenerationInputs, Memory, MemoryType, PersonLink,
};

/// Every photo carrying one `People/*` tag, by that tag's exact path.
#[derive(Debug, Clone)]
pub struct PersonBundle {
    /// `People/Alice Anderson` — original casing, and the memory id's suffix.
    pub full_path: String,
    /// The tag's leaf. Note this is the **tag's** name, not the linked
    /// contact's: `birthday-People/Dave` is titled "Happy birthday, Dave" even
    /// when it is manually linked to a contact called Daniel (landmine 13).
    pub display_name: String,
    /// Indices into the photo table, in `all_photos` order.
    pub photo_indices: Vec<u32>,
}

/// The day-independent half of birthday generation.
#[derive(Debug, Clone, Default)]
pub struct PeopleIndex {
    bundles: Vec<PersonBundle>,
}

impl PeopleIndex {
    /// One pass over the library. First-seen order, which replaces the Swift
    /// `Dictionary` walk — deterministic, and no fixture contradicts it because
    /// every scenario is built so at most one birthday memory exists.
    pub fn build(photos: &[PhotoFile]) -> Self {
        let mut bundles: Vec<PersonBundle> = Vec::new();
        let mut by_path: HashMap<&str, usize> = HashMap::new();
        for (idx, photo) in photos.iter().enumerate() {
            for tag in &photo.hierarchical_tags {
                if tag.namespace.as_deref().map(str::to_lowercase).as_deref() != Some("people") {
                    continue;
                }
                match by_path.get(tag.full_path.as_str()) {
                    Some(slot) => bundles[*slot].photo_indices.push(idx as u32),
                    None => {
                        by_path.insert(&tag.full_path, bundles.len());
                        bundles.push(PersonBundle {
                            full_path: tag.full_path.clone(),
                            display_name: tag.display_name.clone(),
                            photo_indices: vec![idx as u32],
                        });
                    }
                }
            }
        }
        PeopleIndex { bundles }
    }

    pub fn bundles(&self) -> &[PersonBundle] {
        &self.bundles
    }
}

/// `generateBirthdayMemories` for one target `(month, day)`.
///
/// Resolution order is pinned (landmine 13): the **hidden** set is consulted
/// first, then the explicit link — `.disabled` suppresses the tag entirely and
/// `.manual` beats the name auto-match — and only then does the contact's
/// birthday have to match.
pub fn generate_birthday_memories(
    inputs: &GenerationInputs,
    people: &PeopleIndex,
    month: u32,
    day: u32,
) -> Vec<Memory> {
    // Finding 3(b): nobody has a birthday today, so no amount of photo work can
    // produce a memory. The common case for six of every seven horizon days.
    if !inputs.any_birthday_on(month, day) {
        return Vec::new();
    }

    let contact_by_id: HashMap<&str, &Contact> =
        inputs.contacts.iter().map(|c| (c.id.as_str(), c)).collect();
    let photos = &inputs.photos;
    let mut out = Vec::new();

    for bundle in people.bundles() {
        if inputs.hidden_people.contains(&bundle.full_path) {
            continue;
        }
        let contact: Option<&Contact> = match inputs.person_contact_links.get(&bundle.full_path) {
            Some(PersonLink::Disabled) => continue,
            Some(PersonLink::Manual(id)) => contact_by_id.get(id.as_str()).copied(),
            None => inputs
                .contacts_by_lower_name
                .get(&bundle.display_name.to_lowercase()),
        };
        let Some(contact) = contact else { continue };
        if contact.birthday_month != Some(month) || contact.birthday_day != Some(day) {
            continue;
        }

        // Dated photos ascending; undated sort to the FRONT (`.distantPast`),
        // so `ids.last` — the cover — is the most recent dated photo whenever
        // one exists (landmine 12).
        let mut ordered = bundle.photo_indices.clone();
        ordered.sort_by(|a, b| {
            let key = |i: &u32| {
                photos[*i as usize]
                    .date_taken
                    .map_or(crate::selection::DISTANT_PAST, |d| d.0)
            };
            key(a).total_cmp(&key(b))
        });
        let ordered = dedup_photos_by_time_window(photos, &ordered);
        let ids: Vec<_> = ordered.iter().map(|i| photos[*i as usize].id).collect();
        let Some(cover) = ids.last().copied() else {
            continue;
        };

        // Over the dated photos only: a single undated photo must not collapse
        // the range, and the subtitle with it.
        let dated: Vec<_> = ordered
            .iter()
            .filter_map(|i| photos[*i as usize].date_taken)
            .collect();
        let date_range = match (dated.first(), dated.last()) {
            (Some(first), Some(last)) => Some((*first, *last)),
            _ => None,
        };

        out.push(Memory {
            id: format!("birthday-{}", bundle.full_path),
            kind: MemoryType::Birthday,
            title: format!("Happy birthday, {}", bundle.display_name),
            subtitle: None,
            photo_ids: ids,
            cover_photo_id: cover,
            date_range,
            // Well above on-this-day / years-ago, so birthdays float to the
            // front of the rail on the matching day.
            score: 100.0,
            years_ago: None,
            person_name: Some(bundle.display_name.clone()),
        });
    }
    out
}
