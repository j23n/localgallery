//! The sidecar write path: read-modify-write with surgical retraction.
//!
//! # What the core owns
//!
//! Exactly three keyword fields (schema §1.1) and five sentinel fields:
//!
//! | Field | Content |
//! |---|---|
//! | `dc:subject` | leaf names of the tags we added |
//! | `digiKam:TagsList` | full `/`-separated paths |
//! | `lr:hierarchicalSubject` | full `\|`-separated paths |
//! | `photo-tools:Core*` | the sentinel (see [`crate::model::CoreSentinel`]) |
//!
//! `IPTC:Keywords` is *not* written: an XMP sidecar has no IIM section, so
//! photo-tools drops that write too (§1.4). `iptcExt:PersonInImage`,
//! `mwg-rs:RegionInfo`, the OCR fields and the IPTC location fields are all
//! read-only here — Phase 1 has no business in any of them.
//!
//! `photo-tools:TaggerVersion` is deliberately never written. It is
//! photo-tools' "already tagged" sentinel (§1.6); stamping it would make
//! photo-tools skip files it has never seen.
//!
//! # Retraction
//!
//! photo-tools retracts its own tags by *root prefix* (`Objects/`, `Scenes/`,
//! …). The core cannot: it writes those same roots, so prefix-based retraction
//! would let each tool delete the other's work. Instead the sentinel records
//! the exact list of tags — and, separately, the exact `dc:subject` leaves —
//! that this agent added. A tag that was already in the file when we arrived is
//! never claimed, and therefore never retracted.

use std::collections::BTreeSet;

use gallery_vfs::Vfs;

use crate::edit::{self, NodePath};
use crate::error::{MetaError, MetaResult};
use crate::model::SidecarView;
use crate::read::view_of;
use crate::schema::*;
use crate::sidecar::{alt_sidecar_path, sidecar_path};
use crate::tags::{leaf_of, normalize_tag_list, to_lr_path};
use crate::xml::{parse, serialize, Document};

/// What to write into a sidecar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagWriteRequest {
    /// The complete set of machine tags for this photo, as hierarchical paths
    /// (`Objects/Animal/Dog`). This is a *replace* set, not an append set:
    /// anything the agent wrote before and that is missing here is retracted.
    pub tags: Vec<String>,
    /// Agent name for the sentinel. Defaults to [`CORE_AGENT`].
    pub agent: String,
    /// Model-pack version that produced `tags`.
    pub model_pack: String,
    /// ISO 8601 UTC timestamp for the sentinel.
    ///
    /// Supplied by the caller rather than read from a clock so the crate stays
    /// pure and the output stays byte-reproducible in tests.
    pub tagged_at: String,
}

impl TagWriteRequest {
    /// A request from this crate's own agent.
    pub fn new(
        tags: impl IntoIterator<Item = String>,
        model_pack: impl Into<String>,
        tagged_at: impl Into<String>,
    ) -> Self {
        TagWriteRequest {
            tags: tags.into_iter().collect(),
            agent: CORE_AGENT.to_string(),
            model_pack: model_pack.into(),
            tagged_at: tagged_at.into(),
        }
    }

    /// Override the agent name (Phase 2 writes faces under its own agent).
    pub fn with_agent(mut self, agent: impl Into<String>) -> Self {
        self.agent = agent.into();
        self
    }
}

/// Result of applying a request to a sidecar's bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedTags {
    /// The new sidecar contents.
    pub bytes: Vec<u8>,
    /// Tags added to `digiKam:TagsList` by this call.
    pub added: Vec<String>,
    /// Tags retracted by this call.
    pub removed: Vec<String>,
    /// The full set the sentinel now claims.
    pub owned: Vec<String>,
    /// Whether a sidecar was synthesised because none existed.
    pub created: bool,
    /// Whether anything at all differs from the input.
    ///
    /// `false` means a re-run found the file already correct — callers should
    /// skip the write so the mtime (and the sidecar-sync storm behind it) stays
    /// put.
    pub changed: bool,
}

/// Apply `request` to an existing sidecar's bytes, or synthesise a new packet.
///
/// The image's filename is not a parameter: an XMP sidecar carries no
/// back-reference to its image, and exiftool writes none. Naming is
/// [`crate::sidecar::sidecar_path`]'s job, and [`write_tags`] is where the two
/// meet.
pub fn apply_tags(existing: Option<&[u8]>, request: &TagWriteRequest) -> MetaResult<AppliedTags> {
    let requested = normalize_tag_list(&request.tags)?;

    let (mut doc, created) = match existing {
        Some(bytes) if !bytes.iter().all(u8::is_ascii_whitespace) => (parse(bytes)?, false),
        _ => (edit::new_envelope(), true),
    };
    let root = edit::find_rdf_root(&doc).ok_or_else(|| MetaError::NotAnXmpPacket {
        detail: "no rdf:RDF element".into(),
    })?;

    let view = view_of(&doc);
    let plan = Plan::build(&view, &requested, request);

    apply_plan(&mut doc, &root, &plan);

    let bytes = serialize(&doc);
    let changed = match existing {
        Some(original) if !created => bytes != original,
        _ => true,
    };

    Ok(AppliedTags {
        bytes,
        added: plan.tags_to_add.clone(),
        removed: plan.tags_to_remove.clone(),
        owned: plan.owned_tags.clone(),
        created,
        changed,
    })
}

/// Outcome of a sidecar write.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriteOutcome {
    /// The sidecar that was (or would have been) written.
    pub sidecar_path: String,
    /// Whether the file did not exist before.
    pub created: bool,
    /// Whether bytes were actually written.
    pub written: bool,
    /// Tags added by this call.
    pub added: Vec<String>,
    /// Tags retracted by this call.
    pub removed: Vec<String>,
    /// The full set the sentinel now claims.
    pub owned: Vec<String>,
}

/// Locate (or create) `image_path`'s sidecar and apply `request` to it.
///
/// Sidecar selection follows photo-tools (§1.4): the canonical
/// `IMG_1234.jpg.xmp` is both read and written; if only the Lightroom-style
/// `IMG_1234.xmp` exists, its contents seed the canonical file so nothing in it
/// is lost. The alt file is left untouched — it is not ours to delete — which
/// does mean it becomes shadowed for readers that prefer the canonical name.
///
/// Nothing is written when the sidecar already says exactly what this request
/// says: re-running the tagger must not churn mtimes and wake the sidecar sync.
pub fn write_tags(
    vfs: &dyn Vfs,
    image_path: &str,
    request: &TagWriteRequest,
) -> MetaResult<WriteOutcome> {
    let target = sidecar_path(image_path);

    let existing = if vfs.exists(&target) {
        Some(vfs.read(&target)?)
    } else {
        match alt_sidecar_path(image_path) {
            Some(alt) if vfs.exists(&alt) => Some(vfs.read(&alt)?),
            _ => None,
        }
    };

    let applied = apply_tags(existing.as_deref(), request)?;
    // `AppliedTags::created` means "there were no bytes to start from"; the
    // *file* is new whenever the canonical path was absent, which also covers
    // the case where the seeding alt sidecar already said everything we want.
    let created = !vfs.exists(&target);
    let written = applied.changed || created;

    if written {
        vfs.write_atomic(&target, &applied.bytes)?;
    }

    Ok(WriteOutcome {
        sidecar_path: target,
        created,
        written,
        added: applied.added,
        removed: applied.removed,
        owned: applied.owned,
    })
}

/// Everything the edit pass needs, computed before any mutation.
struct Plan {
    tags_to_add: Vec<String>,
    tags_to_remove: Vec<String>,
    owned_tags: Vec<String>,
    subjects_to_add: Vec<String>,
    subjects_to_remove: Vec<String>,
    owned_subjects: Vec<String>,
    lr_to_add: Vec<String>,
    lr_to_remove: Vec<String>,
    agent: String,
    model_pack: String,
    tagged_at: String,
    sentinel_is_current: bool,
}

impl Plan {
    fn build(view: &SidecarView, requested: &[String], request: &TagWriteRequest) -> Plan {
        let requested_set: BTreeSet<&String> = requested.iter().collect();
        let prev_tags: BTreeSet<&String> = view.core.tags.iter().collect();
        let existing_tags: BTreeSet<&String> = view.tags_list.iter().collect();

        // Retract only what we claimed and no longer want.
        let tags_to_remove: Vec<String> = prev_tags
            .difference(&requested_set)
            .map(|s| (*s).clone())
            .collect();
        // Add only what is not already there — a tag somebody else wrote stays
        // theirs, and we never claim it.
        let tags_to_add: Vec<String> = requested
            .iter()
            .filter(|t| !existing_tags.contains(t))
            .cloned()
            .collect();

        let added_set: BTreeSet<&String> = tags_to_add.iter().collect();
        let owned_tags: Vec<String> = requested
            .iter()
            .filter(|t| prev_tags.contains(t) || added_set.contains(t))
            .cloned()
            .collect();

        // The tags that will be in `digiKam:TagsList` once this write lands.
        let removed_set: BTreeSet<&String> = tags_to_remove.iter().collect();
        let retained_leaves: BTreeSet<String> = existing_tags
            .iter()
            .filter(|t| !removed_set.contains(**t))
            .chain(added_set.iter())
            .map(|t| leaf_of(t).to_lowercase())
            .collect();

        // `dc:subject` is lossy: many paths share one leaf, and humans type
        // bare leaves. Retract a leaf only if we added it *and* no surviving
        // tag still needs it.
        let existing_subjects_lower: BTreeSet<String> =
            view.subject.iter().map(|s| s.to_lowercase()).collect();
        let subjects_to_remove: Vec<String> = view
            .core
            .subjects
            .iter()
            .filter(|s| !retained_leaves.contains(&s.to_lowercase()))
            .cloned()
            .collect();

        let mut subjects_to_add: Vec<String> = Vec::new();
        let mut pending_lower: BTreeSet<String> = BTreeSet::new();
        for tag in &tags_to_add {
            let leaf = leaf_of(tag).to_string();
            let lower = leaf.to_lowercase();
            if existing_subjects_lower.contains(&lower) || pending_lower.contains(&lower) {
                continue;
            }
            pending_lower.insert(lower);
            subjects_to_add.push(leaf);
        }
        subjects_to_add.sort();

        let removed_subjects: BTreeSet<&String> = subjects_to_remove.iter().collect();
        let mut owned_subjects: Vec<String> = view
            .core
            .subjects
            .iter()
            .filter(|s| !removed_subjects.contains(*s))
            .chain(subjects_to_add.iter())
            .cloned()
            .collect();
        owned_subjects.sort();
        owned_subjects.dedup();

        // `lr:hierarchicalSubject` is a pure function of the tag paths, so it
        // needs no ownership list of its own.
        let existing_lr: BTreeSet<&String> = view.hierarchical_subject.iter().collect();
        let retained_lr: BTreeSet<String> = existing_tags
            .iter()
            .filter(|t| !removed_set.contains(**t))
            .chain(added_set.iter())
            .map(|t| to_lr_path(t))
            .collect();
        let lr_to_remove: Vec<String> = tags_to_remove
            .iter()
            .map(|t| to_lr_path(t))
            .filter(|p| !retained_lr.contains(p))
            .collect();
        let lr_to_add: Vec<String> = tags_to_add
            .iter()
            .map(|t| to_lr_path(t))
            .filter(|p| !existing_lr.contains(p))
            .collect();

        let sentinel_is_current = view.core.agent.as_deref() == Some(request.agent.as_str())
            && view.core.model_pack.as_deref() == Some(request.model_pack.as_str())
            && view.core.tags == owned_tags
            && view.core.subjects == owned_subjects;

        Plan {
            tags_to_add,
            tags_to_remove,
            owned_tags,
            subjects_to_add,
            subjects_to_remove,
            owned_subjects,
            lr_to_add,
            lr_to_remove,
            agent: request.agent.clone(),
            model_pack: request.model_pack.clone(),
            tagged_at: request.tagged_at.clone(),
            sentinel_is_current,
        }
    }

    /// Whether any keyword field changes.
    fn touches_keywords(&self) -> bool {
        !self.tags_to_add.is_empty()
            || !self.tags_to_remove.is_empty()
            || !self.subjects_to_add.is_empty()
            || !self.subjects_to_remove.is_empty()
            || !self.lr_to_add.is_empty()
            || !self.lr_to_remove.is_empty()
    }
}

fn apply_plan(doc: &mut Document, root: &NodePath, plan: &Plan) {
    if !plan.touches_keywords() && plan.sentinel_is_current {
        // Nothing to do — and crucially, do not refresh `CoreTaggedAt`, or
        // every re-run would rewrite every sidecar.
        return;
    }

    edit_list(
        doc,
        root,
        NS_DIGIKAM,
        PREFIX_DIGIKAM,
        PROP_TAGS_LIST,
        "Seq",
        &plan.tags_to_remove,
        &plan.tags_to_add,
    );
    edit_list(
        doc,
        root,
        NS_DC,
        PREFIX_DC,
        PROP_SUBJECT,
        "Bag",
        &plan.subjects_to_remove,
        &plan.subjects_to_add,
    );
    edit_list(
        doc,
        root,
        NS_LR,
        PREFIX_LR,
        PROP_HIERARCHICAL_SUBJECT,
        "Bag",
        &plan.lr_to_remove,
        &plan.lr_to_add,
    );

    let pt = PREFIX_PHOTO_TOOLS;
    let scalar = |doc: &mut Document, local: &str, value: &str| {
        edit::set_scalar(doc, root, NS_PHOTO_TOOLS, pt, local, value);
    };
    scalar(doc, PROP_CORE_AGENT, &plan.agent);
    scalar(doc, PROP_CORE_MODEL_PACK, &plan.model_pack);
    scalar(doc, PROP_CORE_TAGGED_AT, &plan.tagged_at);
    edit::set_list(
        doc,
        root,
        NS_PHOTO_TOOLS,
        pt,
        PROP_CORE_TAGS,
        "Bag",
        &plan.owned_tags,
    );
    edit::set_list(
        doc,
        root,
        NS_PHOTO_TOOLS,
        pt,
        PROP_CORE_SUBJECTS,
        "Bag",
        &plan.owned_subjects,
    );
}

/// Remove then append entries in one list property, creating it only if there
/// is something to add.
#[allow(clippy::too_many_arguments)]
fn edit_list(
    doc: &mut Document,
    root: &NodePath,
    uri: &str,
    prefix: &str,
    local: &str,
    kind: &str,
    remove: &[String],
    add: &[String],
) {
    if !remove.is_empty() {
        if let Some(prop_path) = edit::find_property(doc, root, uri, local) {
            let container_path = edit::ensure_container(doc, &prop_path, kind);
            let doomed: BTreeSet<&str> = remove.iter().map(String::as_str).collect();
            edit::remove_lis(doc, &container_path, &|text| doomed.contains(text));
            // An emptied property must go entirely: exiftool reads a list with
            // no `rdf:li` as the whitespace between the container tags.
            if add.is_empty() && edit::list_values(doc, root, uri, local).is_empty() {
                edit::remove_property(doc, &prop_path);
            }
        }
    }
    if add.is_empty() {
        return;
    }
    let prop_path = edit::ensure_property(doc, root, uri, prefix, local);
    let container_path = edit::ensure_container(doc, &prop_path, kind);
    let present: BTreeSet<String> = edit::list_values(doc, root, uri, local)
        .into_iter()
        .collect();
    for value in add {
        if present.contains(value) {
            continue;
        }
        edit::append_li(doc, &container_path, value);
    }
}
