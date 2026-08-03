//! The face half of the sidecar write path: `People/*` keywords and MWG-RS
//! regions.
//!
//! # What the face agent owns
//!
//! | Field | Content |
//! |---|---|
//! | `digiKam:TagsList` | `People/<Name>` paths **we** added |
//! | `dc:subject` | the leaf names **we** added |
//! | `lr:hierarchicalSubject` | the `People\|<Name>` entries **we** added |
//! | `Iptc4xmpExt:PersonInImage` | the projection of the file's `People/*` leaves |
//! | `mwg-rs:RegionInfo` | the regions **we** authored ([`crate::regions`]) |
//! | `photo-tools:CorePeople*` / `CoreRegions` / `CoreFacePack` | the sentinel |
//!
//! Phase 1's [`crate::write`] deliberately refuses all of these; this module is
//! the door the schema doc opens for a face-detector agent (§1.5, §2.1), and it
//! is the only place `People/*` may be written from.
//!
//! # Why the face sentinel is not the tag sentinel
//!
//! `CoreAgent` and `CoreTaggedAt` are shared — one agent, one "last changed"
//! stamp — but every *list* is separate, and so is the pack version
//! (`CoreFacePack` vs `CoreModelPack`). Both halves rewrite their sentinel
//! wholesale from what they now claim, so a shared list would have each pass
//! retract the other's entries, and a shared pack field would have each pass
//! read the other's value as a mismatch and rewrite the file. Two independent
//! passes over one library would then never reach a fixed point.
//!
//! Three separate keyword lists for one root, for the reason §1.7 already
//! gives about `CoreSubjects`: `dc:subject` is lossy and `lr:hierarchicalSubject`
//! is not a projection of `digiKam:TagsList`. A file can carry a flat `Alice`
//! keyword a human typed with no `People/Alice` path anywhere, and adding the
//! path must not license deleting the keyword.
//!
//! # PersonInImage
//!
//! Replaced wholesale from the `People/*` leaves the file carries after the
//! write — photo-tools' rule (§1.1, §2.1), mirrored down to the edge case: it
//! only replaces when there is something to project. When the projection is
//! empty this crate does not clear the field either; it removes only entries
//! matching leaves it previously claimed, so un-naming the last person takes
//! their name out without touching a list Apple Photos or Mylio may have
//! written from somewhere else entirely.
//!
//! "The leaves the file carries" means *all* of them, including names digiKam
//! wrote — the field is a projection of the keyword state, not a record of who
//! put each name there, and publishing it is the entire reason it exists. So a
//! face write to a file that already had `People/Carla` and no `PersonInImage`
//! establishes `PersonInImage = [Carla]`. Nothing is claimed by doing so, and a
//! later retraction leaves it standing.

use std::collections::BTreeSet;

use gallery_vfs::Vfs;

use crate::edit::{self, NodePath};
use crate::error::{MetaError, MetaResult};
use crate::model::SidecarView;
use crate::read::view_of;
use crate::regions::{self, Area, FaceRegionWrite, RegionClaim};
use crate::schema::*;
use crate::sidecar::{alt_sidecar_path, sidecar_path};
use crate::tags::{leaf_of, nfc, nfc_lower, normalize_person, person_tag, to_lr_path};
use crate::write::WriteOutcome;
use crate::xml::{parse, serialize, Document};

/// Everything the face agent wants a photo's sidecar to say.
///
/// This is a **replace** set for one photo, not an append set: whatever the
/// agent claimed here before and does not name now is retracted. Un-naming a
/// cluster and renaming a person are both expressed by handing over the new
/// complete set for each affected file.
#[derive(Debug, Clone, PartialEq)]
pub struct FaceWriteRequest {
    /// The face regions to write. Their names supply the `People/*` keywords.
    pub regions: Vec<FaceRegionWrite>,
    /// Names to write keywords for that have no region of their own.
    ///
    /// Rare but real: a face whose geometry a foreign tool already boxed still
    /// belongs in the keyword list, and the caller may know a person is in a
    /// photo without a box to prove it.
    pub extra_people: Vec<String>,
    /// Pixel size of the decoded image, for `AppliedToDimensions` when the file
    /// has none. `None` skips creating one.
    pub image_size: Option<(u32, u32)>,
    /// Agent name for the sentinel. Defaults to [`CORE_AGENT`].
    pub agent: String,
    /// Face-model-pack version that produced these regions.
    pub face_pack: String,
    /// ISO 8601 UTC timestamp, caller-supplied so the crate stays pure and the
    /// bytes stay reproducible.
    pub tagged_at: String,
}

impl FaceWriteRequest {
    /// A request from this crate's own agent.
    pub fn new(
        regions: impl IntoIterator<Item = FaceRegionWrite>,
        face_pack: impl Into<String>,
        tagged_at: impl Into<String>,
    ) -> Self {
        FaceWriteRequest {
            regions: regions.into_iter().collect(),
            extra_people: Vec::new(),
            image_size: None,
            agent: CORE_AGENT.to_string(),
            face_pack: face_pack.into(),
            tagged_at: tagged_at.into(),
        }
    }

    /// Record the decoded image's pixel size, for `AppliedToDimensions`.
    pub fn with_image_size(mut self, width: u32, height: u32) -> Self {
        self.image_size = Some((width, height));
        self
    }

    /// Override the agent name.
    pub fn with_agent(mut self, agent: impl Into<String>) -> Self {
        self.agent = agent.into();
        self
    }
}

/// Result of applying a [`FaceWriteRequest`] to a sidecar's bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedFaces {
    /// The new sidecar contents.
    pub bytes: Vec<u8>,
    /// `People/<Name>` paths added to `digiKam:TagsList` by this call.
    pub people_added: Vec<String>,
    /// `People/<Name>` paths retracted by this call.
    pub people_removed: Vec<String>,
    /// The full set of people the sentinel now claims.
    pub people_owned: Vec<String>,
    /// Regions appended by this call.
    pub regions_added: usize,
    /// Regions removed (retracted or superseded) by this call.
    pub regions_removed: usize,
    /// Regions left to a foreign owner because their box already covered a face
    /// we wanted to write.
    pub regions_deferred: usize,
    /// Whether a sidecar was synthesised because none existed.
    pub created: bool,
    /// Whether anything at all differs from the input. `false` means a re-run
    /// found the file already correct and the caller must not write.
    pub changed: bool,
}

/// Apply `request` to an existing sidecar's bytes, or synthesise a new packet.
///
/// Names are normalized ([`crate::tags::normalize_person`]) on the way in; an
/// unusable one fails the whole call rather than being silently dropped, so a
/// caller never believes it wrote a person it did not.
pub fn apply_faces(
    existing: Option<&[u8]>,
    request: &FaceWriteRequest,
) -> MetaResult<AppliedFaces> {
    let normalized = NormalizedRequest::build(request)?;

    let (mut doc, created) = match existing {
        Some(bytes) if !bytes.iter().all(u8::is_ascii_whitespace) => (parse(bytes)?, false),
        _ => (edit::new_envelope(), true),
    };
    let root = edit::find_rdf_root(&doc).ok_or_else(|| MetaError::NotAnXmpPacket {
        detail: "no rdf:RDF element".into(),
    })?;

    let view = view_of(&doc);
    let plan = FacePlan::build(&view, &normalized, request);
    apply_plan(&mut doc, &root, &plan, request.image_size);

    let bytes = serialize(&doc);
    let changed = match existing {
        Some(original) if !created => bytes != original,
        _ => true,
    };

    Ok(AppliedFaces {
        bytes,
        people_added: plan.people.to_add.clone(),
        people_removed: plan.people.to_remove.clone(),
        people_owned: plan.people.owned.clone(),
        regions_added: plan.regions_to_add.len(),
        regions_removed: plan.regions_to_remove.len(),
        regions_deferred: plan.regions_deferred,
        created,
        changed,
    })
}

/// Locate (or create) `image_path`'s sidecar and apply `request` to it.
///
/// Same sidecar selection, same atomicity and the same
/// [`MetaError::ConcurrentModification`] retry contract as
/// [`crate::write_tags`] — see that function for why the stat token is what it
/// is. Nothing is written when the sidecar already says exactly this.
pub fn write_faces(
    vfs: &dyn Vfs,
    image_path: &str,
    request: &FaceWriteRequest,
) -> MetaResult<WriteOutcome> {
    let target = sidecar_path(image_path);
    let before = stat_token(vfs, &target);

    let existing = if before.is_some() {
        Some(vfs.read(&target)?)
    } else {
        match alt_sidecar_path(image_path) {
            Some(alt) if vfs.exists(&alt) => Some(vfs.read(&alt)?),
            _ => None,
        }
    };

    let applied = apply_faces(existing.as_deref(), request)?;
    let created = before.is_none();
    let written = applied.changed || created;

    if written {
        if stat_token(vfs, &target) != before {
            return Err(MetaError::ConcurrentModification { path: target });
        }
        vfs.write_atomic(&target, &applied.bytes)?;
    }

    Ok(WriteOutcome {
        sidecar_path: target,
        created,
        written,
        added: applied.people_added,
        removed: applied.people_removed,
        owned: applied.people_owned,
    })
}

fn stat_token(vfs: &dyn Vfs, path: &str) -> Option<(u64, Option<i64>)> {
    vfs.stat(path).ok().map(|s| (s.size, s.modified_unix))
}

// ---------------------------------------------------------------------------
// Planning
// ---------------------------------------------------------------------------

/// The request with every name normalized and every list deduplicated and
/// sorted.
///
/// Sorting is what makes the output deterministic: the caller hands regions
/// over in cluster order, which depends on the order faces were detected in.
/// Sorting the set means the same *set* always serializes to the same bytes.
struct NormalizedRequest {
    /// Regions, sorted by `(name, x, y, w, h)`.
    regions: Vec<FaceRegionWrite>,
    /// Every person named, sorted and deduplicated.
    people: Vec<String>,
}

impl NormalizedRequest {
    fn build(request: &FaceWriteRequest) -> MetaResult<NormalizedRequest> {
        let mut regions = Vec::with_capacity(request.regions.len());
        let mut people: Vec<String> = Vec::new();
        for region in &request.regions {
            let name = normalize_person(&region.name)?;
            people.push(name.clone());
            regions.push(FaceRegionWrite {
                name,
                area: region.area,
            });
        }
        for name in &request.extra_people {
            people.push(normalize_person(name)?);
        }
        regions.sort_by(|a, b| {
            a.name
                .cmp(&b.name)
                .then_with(|| a.area.to_claim_coords().cmp(&b.area.to_claim_coords()))
        });
        // Two identical regions for one person are one region.
        regions.dedup_by(|a, b| a.name == b.name && a.area == b.area);
        people.sort();
        people.dedup();
        Ok(NormalizedRequest { regions, people })
    }
}

/// The add/remove/own triple one list property needs.
#[derive(Default)]
struct ListPlan {
    to_add: Vec<String>,
    to_remove: Vec<String>,
    owned: Vec<String>,
}

impl ListPlan {
    fn touches(&self) -> bool {
        !self.to_add.is_empty() || !self.to_remove.is_empty()
    }
}

struct FacePlan {
    people: ListPlan,
    subjects: ListPlan,
    hierarchical: ListPlan,
    /// The whole `PersonInImage` list, when it is being replaced.
    person_in_image: Option<Vec<String>>,
    /// Leaves to take out of `PersonInImage` without replacing the list.
    person_in_image_remove: Vec<String>,
    regions_to_add: Vec<FaceRegionWrite>,
    regions_to_remove: Vec<Area>,
    regions_deferred: usize,
    owned_regions: Vec<String>,
    agent: String,
    face_pack: String,
    tagged_at: String,
    sentinel_is_current: bool,
}

impl FacePlan {
    fn build(view: &SidecarView, req: &NormalizedRequest, raw: &FaceWriteRequest) -> FacePlan {
        let people = plan_people(view, req);
        let (subjects, hierarchical) = plan_projections(view, &people);
        let (regions_to_add, regions_to_remove, regions_deferred, owned_regions) =
            plan_regions(view, req);
        let (person_in_image, person_in_image_remove) = plan_person_in_image(view, &people);

        let sentinel_is_current = view.core.agent.as_deref() == Some(raw.agent.as_str())
            && view.core.face_pack.as_deref() == Some(raw.face_pack.as_str())
            && view.core.people == people.owned
            && view.core.people_subjects == subjects.owned
            && view.core.people_hierarchical == hierarchical.owned
            && view.core.regions == owned_regions;

        FacePlan {
            people,
            subjects,
            hierarchical,
            person_in_image,
            person_in_image_remove,
            regions_to_add,
            regions_to_remove,
            regions_deferred,
            owned_regions,
            agent: raw.agent.clone(),
            face_pack: raw.face_pack.clone(),
            tagged_at: raw.tagged_at.clone(),
            sentinel_is_current,
        }
    }

    fn touches_anything(&self) -> bool {
        self.people.touches()
            || self.subjects.touches()
            || self.hierarchical.touches()
            || !self.regions_to_add.is_empty()
            || !self.regions_to_remove.is_empty()
            || self.person_in_image.is_some()
            || !self.person_in_image_remove.is_empty()
    }
}

/// `digiKam:TagsList` under `People/`.
fn plan_people(view: &SidecarView, req: &NormalizedRequest) -> ListPlan {
    let requested: Vec<String> = req.people.iter().map(|n| person_tag(n)).collect();
    let requested_set: BTreeSet<String> = requested.iter().map(|t| nfc(t)).collect();
    let prev: Vec<String> = view.core.people.iter().map(|t| nfc(t)).collect();
    let existing: BTreeSet<String> = view.tags_list.iter().map(|t| nfc(t)).collect();

    // Retract only what we claimed and no longer want.
    let mut to_remove: Vec<String> = prev
        .iter()
        .filter(|t| !requested_set.contains(*t))
        .cloned()
        .collect();
    to_remove.sort();
    to_remove.dedup();
    // Claim only what was not already there: a `People/Alice` digiKam wrote
    // stays digiKam's, and we never retract it.
    let to_add: Vec<String> = requested
        .iter()
        .filter(|t| !existing.contains(&nfc(t)))
        .cloned()
        .collect();

    let prev_set: BTreeSet<&String> = prev.iter().collect();
    let added_set: BTreeSet<&String> = to_add.iter().collect();
    let owned: Vec<String> = requested
        .iter()
        .filter(|t| prev_set.contains(&nfc(t)) || added_set.contains(t))
        .cloned()
        .collect();

    ListPlan {
        to_add,
        to_remove,
        owned,
    }
}

/// `dc:subject` leaves and `lr:hierarchicalSubject` entries for the people
/// plan.
///
/// Both retract only entries the *face* half claimed, and additionally never
/// retract one the *tagging* half still claims — the two lists are disjoint in
/// practice, and on the day they are not, a leaf each half wants must not be
/// removed by one and re-added by the other on every alternating run.
fn plan_projections(view: &SidecarView, people: &ListPlan) -> (ListPlan, ListPlan) {
    let people_after: BTreeSet<String> = surviving_people(view, people);

    // --- dc:subject -------------------------------------------------------
    let retained_leaves: BTreeSet<String> =
        people_after.iter().map(|t| nfc_lower(leaf_of(t))).collect();
    let tagger_subjects: BTreeSet<String> =
        view.core.subjects.iter().map(|s| nfc_lower(s)).collect();
    let existing_subjects: BTreeSet<String> = view.subject.iter().map(|s| nfc_lower(s)).collect();

    let mut subjects_to_remove: Vec<String> = view
        .core
        .people_subjects
        .iter()
        .filter(|s| {
            !retained_leaves.contains(&nfc_lower(s)) && !tagger_subjects.contains(&nfc_lower(s))
        })
        .map(|s| nfc(s))
        .collect();
    subjects_to_remove.sort();
    subjects_to_remove.dedup();

    let mut subjects_to_add: Vec<String> = Vec::new();
    let mut pending: BTreeSet<String> = BTreeSet::new();
    for tag in &people.to_add {
        let leaf = leaf_of(tag).to_string();
        let lower = nfc_lower(&leaf);
        if existing_subjects.contains(&lower) || pending.contains(&lower) {
            continue;
        }
        pending.insert(lower);
        subjects_to_add.push(leaf);
    }
    subjects_to_add.sort();

    let removed: BTreeSet<String> = subjects_to_remove.iter().map(|s| nfc_lower(s)).collect();
    let mut subjects_owned: Vec<String> = view
        .core
        .people_subjects
        .iter()
        .map(|s| nfc(s))
        .filter(|s| !removed.contains(&nfc_lower(s)))
        .chain(subjects_to_add.iter().cloned())
        .collect();
    subjects_owned.sort();
    subjects_owned.dedup();

    // --- lr:hierarchicalSubject ------------------------------------------
    let retained_lr: BTreeSet<String> = people_after.iter().map(|t| to_lr_path(t)).collect();
    let tagger_lr: BTreeSet<String> = view.core.hierarchical.iter().map(|p| nfc(p)).collect();
    let existing_lr: BTreeSet<String> = view.hierarchical_subject.iter().map(|p| nfc(p)).collect();

    let lr_to_add: Vec<String> = people
        .to_add
        .iter()
        .map(|t| to_lr_path(t))
        .filter(|p| !existing_lr.contains(p))
        .collect();
    let mut lr_to_remove: Vec<String> = view
        .core
        .people_hierarchical
        .iter()
        .map(|p| nfc(p))
        .filter(|p| !retained_lr.contains(p) && !tagger_lr.contains(p))
        .collect();
    lr_to_remove.sort();
    lr_to_remove.dedup();

    let removed_lr: BTreeSet<&String> = lr_to_remove.iter().collect();
    let mut lr_owned: Vec<String> = view
        .core
        .people_hierarchical
        .iter()
        .map(|p| nfc(p))
        .filter(|p| !removed_lr.contains(p))
        .chain(lr_to_add.iter().cloned())
        .collect();
    lr_owned.sort();
    lr_owned.dedup();

    (
        ListPlan {
            to_add: subjects_to_add,
            to_remove: subjects_to_remove,
            owned: subjects_owned,
        },
        ListPlan {
            to_add: lr_to_add,
            to_remove: lr_to_remove,
            owned: lr_owned,
        },
    )
}

/// The `People/*` entries `digiKam:TagsList` will hold once this write lands.
fn surviving_people(view: &SidecarView, people: &ListPlan) -> BTreeSet<String> {
    let doomed: BTreeSet<String> = people.to_remove.iter().map(|t| nfc(t)).collect();
    view.people_tags()
        .into_iter()
        .map(nfc)
        .filter(|t| !doomed.contains(t))
        .chain(people.to_add.iter().cloned())
        .collect()
}

/// `Iptc4xmpExt:PersonInImage`. See the module docs for the projection rule.
fn plan_person_in_image(
    view: &SidecarView,
    people: &ListPlan,
) -> (Option<Vec<String>>, Vec<String>) {
    // `surviving_people` is a set; the projection wants document order with the
    // additions after it, which is what a reader will see in `TagsList`.
    let doomed: BTreeSet<String> = people.to_remove.iter().map(|t| nfc(t)).collect();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut leaves: Vec<String> = Vec::new();
    for tag in view
        .people_tags()
        .into_iter()
        .map(nfc)
        .filter(|t| !doomed.contains(t))
        .chain(people.to_add.iter().cloned())
    {
        let leaf = leaf_of(&tag).to_string();
        if leaf.is_empty() {
            continue;
        }
        if seen.insert(nfc_lower(&leaf)) {
            leaves.push(leaf);
        }
    }

    if !leaves.is_empty() {
        let current: Vec<String> = view.person_in_image.iter().map(|s| nfc(s)).collect();
        if current == leaves {
            return (None, Vec::new());
        }
        return (Some(leaves), Vec::new());
    }

    // Nothing left to project. Do not clear the field — take out only the
    // leaves of the people we are retracting, so a list somebody else wrote
    // survives.
    let mut retracted: Vec<String> = people
        .to_remove
        .iter()
        .map(|t| leaf_of(t).to_string())
        .filter(|leaf| {
            view.person_in_image
                .iter()
                .any(|p| nfc_lower(p) == nfc_lower(leaf))
        })
        .collect();
    retracted.sort();
    retracted.dedup();
    (None, retracted)
}

/// One region already in the file, with the ownership verdict attached.
struct ExistingRegion {
    area: Area,
    /// Whether it is already exactly what we would write for `name`.
    matches_write: Box<dyn Fn(&FaceRegionWrite) -> bool>,
    owned: bool,
}

/// The region merge. Returns `(to add, to remove, deferred, claims)`.
///
/// See [`crate::regions`] for the policy; this is the bookkeeping. The one
/// non-obvious rule is that an *owned* region whose name or box has moved is
/// removed and re-appended rather than edited in place: an `rdf:li` can carry
/// its fields as elements, as attributes, or inside a nested `rdf:Description`,
/// and rewriting all three shapes correctly buys nothing — the element is ours,
/// so replacing it wholesale loses nothing and always produces the same bytes.
#[allow(clippy::type_complexity)]
fn plan_regions(
    view: &SidecarView,
    req: &NormalizedRequest,
) -> (Vec<FaceRegionWrite>, Vec<Area>, usize, Vec<String>) {
    let claims: Vec<RegionClaim> = view
        .core
        .regions
        .iter()
        .filter_map(|c| regions::parse_claim(c))
        .collect();

    let existing: Vec<ExistingRegion> = view
        .regions
        .iter()
        .map(|r| {
            let area = Area::of(r);
            let coords = area.to_claim_coords();
            let name = r.name.as_deref().map(nfc);
            let is_face = r.kind.as_deref() == Some(REGION_TYPE_FACE);
            ExistingRegion {
                area,
                owned: regions::is_claimed(&claims, r),
                matches_write: Box::new(move |w: &FaceRegionWrite| {
                    is_face
                        && coords == w.area.to_claim_coords()
                        && name.as_deref() == Some(nfc(&w.name).as_str())
                }),
            }
        })
        .collect();

    let mut to_add: Vec<FaceRegionWrite> = Vec::new();
    let mut owned_claims: Vec<String> = Vec::new();
    let mut keep: BTreeSet<usize> = BTreeSet::new();
    let mut paired: BTreeSet<usize> = BTreeSet::new();
    let mut deferred = 0usize;

    for wanted in &req.regions {
        // Somebody else already boxed this face: theirs stands, and we add no
        // duplicate. We do not claim it either — it was never ours to retract.
        if existing
            .iter()
            .any(|e| !e.owned && e.area.matches(&wanted.area))
        {
            deferred += 1;
            continue;
        }
        owned_claims.push(wanted.claim());
        let slot = existing
            .iter()
            .enumerate()
            .find(|(i, e)| e.owned && !paired.contains(i) && e.area.matches(&wanted.area))
            .map(|(i, _)| i);
        match slot {
            Some(i) => {
                paired.insert(i);
                if (existing[i].matches_write)(wanted) {
                    keep.insert(i);
                } else {
                    to_add.push(wanted.clone());
                }
            }
            None => to_add.push(wanted.clone()),
        }
    }

    // Every region of ours the request did not keep is retracted. Removal is by
    // area, so a kept region sharing an area with a doomed one would be swept
    // up with it: re-append it rather than lose it.
    let doomed: Vec<Area> = existing
        .iter()
        .enumerate()
        .filter(|(i, e)| e.owned && !keep.contains(i))
        .map(|(_, e)| e.area)
        .collect();
    for i in keep.iter().copied() {
        if doomed.iter().any(|d| *d == existing[i].area) {
            if let Some(w) = req.regions.iter().find(|w| (existing[i].matches_write)(w)) {
                to_add.push(w.clone());
            }
        }
    }
    to_add.sort_by(|a, b| {
        a.name
            .cmp(&b.name)
            .then_with(|| a.area.to_claim_coords().cmp(&b.area.to_claim_coords()))
    });
    to_add.dedup_by(|a, b| a.name == b.name && a.area == b.area);

    owned_claims.sort();
    owned_claims.dedup();
    (to_add, doomed, deferred, owned_claims)
}

// ---------------------------------------------------------------------------
// Applying
// ---------------------------------------------------------------------------

fn apply_plan(doc: &mut Document, root: &NodePath, plan: &FacePlan, size: Option<(u32, u32)>) {
    if !plan.touches_anything() && plan.sentinel_is_current {
        // Nothing to do — and crucially, do not refresh `CoreTaggedAt`, or
        // every re-run would rewrite every sidecar.
        return;
    }

    crate::write::edit_list_exact(
        doc,
        root,
        NS_DIGIKAM,
        PREFIX_DIGIKAM,
        PROP_TAGS_LIST,
        "Seq",
        &plan.people.to_remove,
        &plan.people.to_add,
    );
    crate::write::edit_list_ignore_case(
        doc,
        root,
        NS_DC,
        PREFIX_DC,
        PROP_SUBJECT,
        "Bag",
        &plan.subjects.to_remove,
        &plan.subjects.to_add,
    );
    crate::write::edit_list_exact(
        doc,
        root,
        NS_LR,
        PREFIX_LR,
        PROP_HIERARCHICAL_SUBJECT,
        "Bag",
        &plan.hierarchical.to_remove,
        &plan.hierarchical.to_add,
    );

    match &plan.person_in_image {
        Some(values) => edit::set_list(
            doc,
            root,
            NS_IPTC_EXT,
            PREFIX_IPTC_EXT,
            PROP_PERSON_IN_IMAGE,
            "Bag",
            values,
        ),
        None => crate::write::edit_list_ignore_case(
            doc,
            root,
            NS_IPTC_EXT,
            PREFIX_IPTC_EXT,
            PROP_PERSON_IN_IMAGE,
            "Bag",
            &plan.person_in_image_remove,
            &[],
        ),
    }

    apply_regions(doc, root, plan, size);

    let pt = PREFIX_PHOTO_TOOLS;
    let scalar = |doc: &mut Document, local: &str, value: &str| {
        edit::set_scalar(doc, root, NS_PHOTO_TOOLS, pt, local, value);
    };
    scalar(doc, PROP_CORE_AGENT, &plan.agent);
    scalar(doc, PROP_CORE_FACE_PACK, &plan.face_pack);
    scalar(doc, PROP_CORE_TAGGED_AT, &plan.tagged_at);
    for (local, values) in [
        (PROP_CORE_PEOPLE, &plan.people.owned),
        (PROP_CORE_PEOPLE_SUBJECTS, &plan.subjects.owned),
        (PROP_CORE_PEOPLE_HIERARCHICAL, &plan.hierarchical.owned),
        (PROP_CORE_REGIONS, &plan.owned_regions),
    ] {
        edit::set_list(doc, root, NS_PHOTO_TOOLS, pt, local, "Bag", values);
    }
}

fn apply_regions(doc: &mut Document, root: &NodePath, plan: &FacePlan, size: Option<(u32, u32)>) {
    if plan.regions_to_add.is_empty() && plan.regions_to_remove.is_empty() {
        return;
    }
    // Only create the envelope when there is something to put in it: a
    // retraction-only pass on a file whose regions all came from elsewhere must
    // not leave an empty `RegionInfo` behind.
    let paths = if plan.regions_to_add.is_empty() {
        match regions::find_region_container(doc, root) {
            Some(container) => {
                let mut regions_path = container.clone();
                // container → RegionList → Regions
                regions_path.pop();
                regions_path.pop();
                regions::RegionPaths {
                    regions: regions_path,
                    container,
                }
            }
            None => return,
        }
    } else {
        regions::ensure_region_container(doc, root, size)
    };

    regions::remove_regions(doc, &paths.container, &plan.regions_to_remove);
    for region in &plan.regions_to_add {
        regions::append_region(doc, &paths, region);
    }
    regions::prune_empty_regions(doc, &paths);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read::read_view;

    fn region(name: &str, x: f64, y: f64, w: f64, h: f64) -> FaceRegionWrite {
        FaceRegionWrite {
            name: name.to_string(),
            area: Area::new(x, y, w, h),
        }
    }

    fn request(regions: Vec<FaceRegionWrite>) -> FaceWriteRequest {
        FaceWriteRequest::new(regions, "buffalo_sc-2026.1", "2026-08-03T10:00:00Z")
            .with_image_size(4032, 3024)
    }

    #[test]
    fn a_fresh_sidecar_carries_the_person_in_every_keyword_field() {
        let out =
            apply_faces(None, &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)])).unwrap();
        let view = read_view(&out.bytes).unwrap();
        assert_eq!(view.tags_list, vec!["People/Alice"]);
        assert_eq!(view.subject, vec!["Alice"]);
        assert_eq!(view.hierarchical_subject, vec!["People|Alice"]);
        assert_eq!(view.person_in_image, vec!["Alice"]);
        assert_eq!(view.regions.len(), 1);
        assert_eq!(view.regions[0].name.as_deref(), Some("Alice"));
        assert_eq!(view.regions[0].kind.as_deref(), Some("Face"));
        assert_eq!(view.core.people, vec!["People/Alice"]);
        assert_eq!(view.core.face_pack.as_deref(), Some("buffalo_sc-2026.1"));
        assert_eq!(view.core.regions.len(), 1);
        assert!(out.created && out.changed);
    }

    #[test]
    fn re_applying_the_same_request_changes_nothing() {
        let first =
            apply_faces(None, &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)])).unwrap();
        let second = apply_faces(
            Some(&first.bytes),
            &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)]),
        )
        .unwrap();
        assert!(
            !second.changed,
            "{}",
            String::from_utf8_lossy(&second.bytes)
        );
        assert_eq!(second.bytes, first.bytes);
    }

    #[test]
    fn two_runs_from_nothing_produce_identical_bytes() {
        let people = vec![
            region("Bob", 0.7, 0.3, 0.1, 0.14),
            region("Alice", 0.4, 0.35, 0.12, 0.16),
        ];
        let shuffled = vec![
            region("Alice", 0.4, 0.35, 0.12, 0.16),
            region("Bob", 0.7, 0.3, 0.1, 0.14),
        ];
        let a = apply_faces(None, &request(people)).unwrap().bytes;
        let b = apply_faces(None, &request(shuffled)).unwrap().bytes;
        assert_eq!(a, b);
    }

    #[test]
    fn retracting_a_person_removes_their_keyword_and_their_region() {
        let named = apply_faces(None, &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)]))
            .unwrap()
            .bytes;
        let cleared = apply_faces(Some(&named), &request(Vec::new())).unwrap();
        let view = read_view(&cleared.bytes).unwrap();
        assert!(view.tags_list.is_empty(), "{:?}", view.tags_list);
        assert!(view.subject.is_empty());
        assert!(view.hierarchical_subject.is_empty());
        assert!(view.person_in_image.is_empty());
        assert!(view.regions.is_empty());
        assert!(view.core.people.is_empty());
        assert!(view.core.regions.is_empty());
    }

    #[test]
    fn a_rename_swaps_the_name_in_both_places() {
        let named = apply_faces(None, &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)]))
            .unwrap()
            .bytes;
        let renamed = apply_faces(
            Some(&named),
            &request(vec![region("Alicia", 0.4, 0.35, 0.12, 0.16)]),
        )
        .unwrap();
        let view = read_view(&renamed.bytes).unwrap();
        assert_eq!(view.tags_list, vec!["People/Alicia"]);
        assert_eq!(view.subject, vec!["Alicia"]);
        assert_eq!(view.person_in_image, vec!["Alicia"]);
        assert_eq!(view.regions.len(), 1, "no duplicate box");
        assert_eq!(view.regions[0].name.as_deref(), Some("Alicia"));
    }

    #[test]
    fn an_invalid_name_fails_the_call_rather_than_being_dropped() {
        let err = apply_faces(
            None,
            &request(vec![region("Alice/Smith", 0.4, 0.35, 0.1, 0.1)]),
        )
        .unwrap_err();
        assert!(matches!(err, MetaError::InvalidTag { .. }), "{err:?}");
    }

    /// A sidecar somebody else's face tool wrote: a `People/Alice` keyword and
    /// a region, with no `Core*` sentinel anywhere.
    const FOREIGN: &str = "<?xpacket begin='' id='W5M0Mp'?>\n\
<x:xmpmeta xmlns:x='adobe:ns:meta/'>\n\
<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>\n\
 <rdf:Description rdf:about=''\n\
  xmlns:digiKam='http://www.digikam.org/ns/1.0/'\n\
  xmlns:dc='http://purl.org/dc/elements/1.1/'\n\
  xmlns:mwg-rs='http://www.metadataworkinggroup.com/schemas/regions/'\n\
  xmlns:stArea='http://ns.adobe.com/xmp/sType/Area#'>\n\
  <digiKam:TagsList><rdf:Seq><rdf:li>People/Alice</rdf:li></rdf:Seq></digiKam:TagsList>\n\
  <dc:subject><rdf:Bag><rdf:li>Alice</rdf:li></rdf:Bag></dc:subject>\n\
  <mwg-rs:Regions rdf:parseType='Resource'>\n\
   <mwg-rs:RegionList><rdf:Bag>\n\
    <rdf:li rdf:parseType='Resource'>\n\
     <mwg-rs:Name>Alice</mwg-rs:Name>\n\
     <mwg-rs:Type>Face</mwg-rs:Type>\n\
     <mwg-rs:Area rdf:parseType='Resource'>\n\
      <stArea:x>0.400000</stArea:x><stArea:y>0.350000</stArea:y>\n\
      <stArea:w>0.120000</stArea:w><stArea:h>0.160000</stArea:h>\n\
      <stArea:unit>normalized</stArea:unit>\n\
     </mwg-rs:Area>\n\
    </rdf:li>\n\
   </rdf:Bag></mwg-rs:RegionList>\n\
  </mwg-rs:Regions>\n\
 </rdf:Description>\n\
</rdf:RDF>\n\
</x:xmpmeta>\n\
<?xpacket end='w'?>\n";

    #[test]
    fn a_person_the_file_already_names_is_never_claimed_and_never_retracted() {
        // We write the same person the file already carries: nothing is added,
        // nothing is claimed.
        let out = apply_faces(
            Some(FOREIGN.as_bytes()),
            &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)]),
        )
        .unwrap();
        let view = read_view(&out.bytes).unwrap();
        assert_eq!(view.tags_list, vec!["People/Alice"], "no duplicate keyword");
        assert!(view.core.people.is_empty(), "we did not put it there");
        assert_eq!(view.regions.len(), 1, "no duplicate box");
        assert!(view.core.regions.is_empty(), "the box is not ours either");
        assert_eq!(out.regions_deferred, 1);

        // And a later retraction leaves both alone.
        let cleared = apply_faces(Some(&out.bytes), &request(Vec::new())).unwrap();
        let after = read_view(&cleared.bytes).unwrap();
        assert_eq!(after.tags_list, vec!["People/Alice"]);
        assert_eq!(after.regions.len(), 1);
        assert_eq!(after.subject, vec!["Alice"]);
    }

    #[test]
    fn a_foreign_box_over_the_same_face_wins_and_ours_is_not_added() {
        // A different person's name on a box in the same place: the foreign
        // region stands, but the keyword is still ours to add.
        let out = apply_faces(
            Some(FOREIGN.as_bytes()),
            &request(vec![region("Bob", 0.41, 0.35, 0.12, 0.16)]),
        )
        .unwrap();
        let view = read_view(&out.bytes).unwrap();
        assert_eq!(view.regions.len(), 1, "no second box on one face");
        assert_eq!(view.regions[0].name.as_deref(), Some("Alice"));
        assert!(view.core.regions.is_empty());
        assert!(view.tags_list.contains(&"People/Bob".to_string()));
        assert_eq!(view.core.people, vec!["People/Bob"]);
    }

    #[test]
    fn a_second_person_elsewhere_in_the_frame_is_appended_beside_the_foreign_one() {
        let out = apply_faces(
            Some(FOREIGN.as_bytes()),
            &request(vec![region("Bob", 0.8, 0.7, 0.1, 0.14)]),
        )
        .unwrap();
        let view = read_view(&out.bytes).unwrap();
        assert_eq!(view.regions.len(), 2);
        assert_eq!(
            view.regions[0].name.as_deref(),
            Some("Alice"),
            "foreign first"
        );
        assert_eq!(view.regions[1].name.as_deref(), Some("Bob"));
        assert_eq!(view.core.regions.len(), 1, "only ours is claimed");
        assert_eq!(view.person_in_image, vec!["Alice", "Bob"]);
    }

    #[test]
    fn a_retraction_on_a_file_with_only_foreign_regions_creates_no_envelope() {
        let out = apply_faces(None, &request(Vec::new())).unwrap();
        let view = read_view(&out.bytes).unwrap();
        assert!(view.regions.is_empty());
        assert!(
            !String::from_utf8_lossy(&out.bytes).contains("mwg-rs:Regions"),
            "an empty RegionInfo must not be created"
        );
    }

    #[test]
    fn the_tagging_halfs_claims_are_never_touched() {
        let tagged = crate::apply_tags(
            None,
            &crate::TagWriteRequest::new(
                ["Objects/Animal/Dog".to_string()],
                "mobileclip-s2-2026.1",
                "2026-08-03T09:00:00Z",
            ),
        )
        .unwrap()
        .bytes;
        let faced = apply_faces(
            Some(&tagged),
            &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)]),
        )
        .unwrap()
        .bytes;
        let view = read_view(&faced).unwrap();
        assert_eq!(view.core.tags, vec!["Objects/Animal/Dog"]);
        assert_eq!(view.core.subjects, vec!["Dog"]);
        assert_eq!(
            view.core.model_pack.as_deref(),
            Some("mobileclip-s2-2026.1")
        );
        assert_eq!(view.core.face_pack.as_deref(), Some("buffalo_sc-2026.1"));

        // And the tagging half then finds its own sentinel current: the two
        // passes reach a fixed point instead of rewriting each other forever.
        let again = crate::apply_tags(
            Some(&faced),
            &crate::TagWriteRequest::new(
                ["Objects/Animal/Dog".to_string()],
                "mobileclip-s2-2026.1",
                "2026-08-03T11:00:00Z",
            ),
        )
        .unwrap();
        assert!(
            !again.changed,
            "the tagger rewrote a file it had nothing to say about"
        );

        let face_again = apply_faces(
            Some(&faced),
            &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)]),
        )
        .unwrap();
        assert!(!face_again.changed);
    }

    #[test]
    fn a_name_only_this_agent_claims_still_leaves_a_humans_flat_keyword_alone() {
        // The file carries a hand-typed `Alice` keyword and no People path.
        let human = "<?xpacket begin='' id='W5M0Mp'?>\n\
<x:xmpmeta xmlns:x='adobe:ns:meta/'>\n\
<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>\n\
 <rdf:Description rdf:about='' xmlns:dc='http://purl.org/dc/elements/1.1/'>\n\
  <dc:subject><rdf:Bag><rdf:li>Alice</rdf:li></rdf:Bag></dc:subject>\n\
 </rdf:Description>\n\
</rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>\n";
        let named = apply_faces(
            Some(human.as_bytes()),
            &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)]),
        )
        .unwrap()
        .bytes;
        let mid = read_view(&named).unwrap();
        assert_eq!(mid.subject, vec!["Alice"], "no duplicate leaf");
        assert!(mid.core.people_subjects.is_empty(), "the leaf was not ours");

        let cleared = apply_faces(Some(&named), &request(Vec::new()))
            .unwrap()
            .bytes;
        let after = read_view(&cleared).unwrap();
        assert_eq!(after.subject, vec!["Alice"], "the human's keyword survived");
        assert!(after.tags_list.is_empty());
    }
}
