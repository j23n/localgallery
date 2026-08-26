//! The sidecar write path: read-modify-write with prefix-replace for
//! Objects/Scenes.
//!
//! # What the core owns
//!
//! Exactly three keyword fields (schema §1.1), the CLIP cache fields
//! (schema §1.2), and six sentinel fields:
//!
//! | Field | Content |
//! |---|---|
//! | `dc:subject` | leaf names of the tags we added |
//! | `digiKam:TagsList` | full `/`-separated paths |
//! | `lr:hierarchicalSubject` | full `\|`-separated paths |
//! | `photo-tools:CLIPEmbedding` / `CLIPModel` / `CLIPTimestamp` | cached encoder output |
//! | `photo-tools:Core*` | the sentinel (see [`crate::model::CoreSentinel`]) |
//!
//! `IPTC:Keywords` is *not* written: an XMP sidecar has no IIM section, so
//! photo-tools drops that write too (§1.4). `iptcExt:PersonInImage`,
//! `mwg-rs:RegionInfo`, the OCR fields and the IPTC location fields are all
//! read-only here — Phase 1 has no business in any of them.
//!
//! `photo-tools:TaggerVersion` is the shared skip key (pack version).
//! `CLIPEmbedding` / `CLIPModel` / `CLIPTimestamp` are written when the
//! request carries a vector; a reader treats a mismatched `CLIPModel` as
//! a miss.
//!
//! # Retraction
//!
//! Objects/ and Scenes/ are a **replace set**. Whatever those roots already
//! hold — this agent, photo-tools, an older 2-segment path — is removed and
//! the request's list is written. `photo-tools:TaggerVersion` is the skip
//! key: a sidecar stamped with the running pack is left alone. People/,
//! Places/, Landmarks/ and bare human keywords are not in the replace set.
//!
//! `dc:subject` leaves of a removed path come out only when no surviving
//! tag still needs them. `lr:hierarchicalSubject` follows the same paths.

use std::collections::BTreeSet;

use gallery_vfs::Vfs;

use crate::edit::{self, NodePath};
use crate::error::{MetaError, MetaResult};
use crate::model::SidecarView;
use crate::read::view_of;
use crate::schema::*;
use crate::sidecar::{alt_sidecar_path, sidecar_path};
use crate::tags::{is_content_tag, leaf_of, nfc, nfc_lower, normalize_tag_list, to_lr_path};
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
    /// Base64 of the little-endian `f32` CLIP vector, when this write
    /// carries an embedding. `None` leaves any existing CLIP fields alone —
    /// they may belong to photo-tools.
    pub clip_embedding: Option<String>,
    /// Encoder id for [`Self::clip_embedding`] (pack version).
    pub clip_model: Option<String>,
    /// When the embedding was produced. Same stamp as [`Self::tagged_at`]
    /// on a tagging run.
    pub clip_timestamp: Option<String>,
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
            clip_embedding: None,
            clip_model: None,
            clip_timestamp: None,
        }
    }

    /// Override the agent name (Phase 2 writes faces under its own agent).
    pub fn with_agent(mut self, agent: impl Into<String>) -> Self {
        self.agent = agent.into();
        self
    }

    /// Attach a CLIP embedding. All three fields are written together so a
    /// reader never sees a vector whose model or time is missing.
    pub fn with_clip(
        mut self,
        embedding_b64: impl Into<String>,
        model: impl Into<String>,
        timestamp: impl Into<String>,
    ) -> Self {
        self.clip_embedding = Some(embedding_b64.into());
        self.clip_model = Some(model.into());
        self.clip_timestamp = Some(timestamp.into());
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
///
/// # Concurrency
///
/// This is a read-modify-write over a file other programs also write. If the
/// sidecar changes between the read and the rename, the rename would discard
/// the other writer's work wholesale — digiKam's new face tag, Lightroom's new
/// keyword, gone with no trace. The file is re-stat'd immediately before the
/// write and a mismatch returns [`MetaError::ConcurrentModification`] with
/// nothing written; the caller retries, which re-reads and re-merges.
///
/// The check compares size and whole-second mtime, so it cannot see a
/// same-size write landing inside the same second as ours. Closing that window
/// needs an exchange-with-verification primitive the `Vfs` trait does not have
/// (`renameatx_np(RENAME_EXCL)` on Darwin); the check as it stands turns the
/// common case — a human editing in another app while a tagging run is in
/// flight — from silent data loss into a retry.
pub fn write_tags(
    vfs: &dyn Vfs,
    image_path: &str,
    request: &TagWriteRequest,
) -> MetaResult<WriteOutcome> {
    let target = sidecar_path(image_path);

    // Snapshot of the canonical sidecar as it stood when we read it.
    let before = stat_token(vfs, &target);

    let existing = if before.is_some() {
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
        added: applied.added,
        removed: applied.removed,
        owned: applied.owned,
    })
}

/// Cheap identity of a file's current contents: `None` when absent, otherwise
/// `(size, whole-second mtime)`.
///
/// Not a content hash on purpose — this runs twice per photo across a whole
/// library, and the failure it guards against (another program writing the
/// same sidecar mid-run) reliably changes one or both.
fn stat_token(vfs: &dyn Vfs, path: &str) -> Option<(u64, Option<i64>)> {
    vfs.stat(path).ok().map(|s| (s.size, s.modified_unix))
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
    owned_hierarchical: Vec<String>,
    agent: String,
    model_pack: String,
    tagged_at: String,
    sentinel_is_current: bool,
    clip_embedding: Option<String>,
    clip_model: Option<String>,
    clip_timestamp: Option<String>,
    clip_is_current: bool,
}

    impl Plan {
    fn build(view: &SidecarView, requested: &[String], request: &TagWriteRequest) -> Plan {
        // Only Objects/Scenes are a replace set. People/Places/Landmarks and
        // anything else stay. `requested` is already NFC.
        let requested: Vec<String> = requested
            .iter()
            .filter(|t| is_content_tag(t))
            .cloned()
            .collect();
        let requested_set: BTreeSet<String> = requested.iter().cloned().collect();

        let existing_tags: Vec<String> = view.tags_list.iter().map(|t| nfc(t)).collect();
        let existing_machine: BTreeSet<String> = existing_tags
            .iter()
            .filter(|t| is_content_tag(t))
            .cloned()
            .collect();

        let mut tags_to_remove: Vec<String> = existing_machine
            .iter()
            .filter(|t| !requested_set.contains(*t))
            .cloned()
            .collect();
        tags_to_remove.sort();
        let tags_to_add: Vec<String> = requested
            .iter()
            .filter(|t| !existing_machine.contains(*t))
            .cloned()
            .collect();
        let owned_tags = requested.clone();

        let retained: BTreeSet<String> = existing_tags
            .iter()
            .filter(|t| !is_content_tag(t))
            .cloned()
            .chain(requested.iter().cloned())
            .collect();
        let retained_leaves: BTreeSet<String> = retained
            .iter()
            .map(|t| nfc_lower(leaf_of(t)))
            .collect();

        // `dc:subject` is lossy: a human "Dog" and `Objects/Animal/Dog` share
        // one leaf. Retract only leaves we introduced and that nothing
        // surviving still needs. Machine paths themselves are prefix-replaced
        // above; this is just the flat projection.
        let existing_subjects_lower: BTreeSet<String> =
            view.subject.iter().map(|s| nfc_lower(s)).collect();
        let mut subjects_to_remove: Vec<String> = view
            .core
            .subjects
            .iter()
            .filter(|s| !retained_leaves.contains(&nfc_lower(s)))
            .map(|s| nfc(s))
            .collect();
        subjects_to_remove.sort();
        subjects_to_remove.dedup();

        let mut subjects_to_add: Vec<String> = Vec::new();
        let mut pending_lower: BTreeSet<String> = BTreeSet::new();
        for tag in &tags_to_add {
            let leaf = leaf_of(tag).to_string();
            let lower = nfc_lower(&leaf);
            if existing_subjects_lower.contains(&lower) || pending_lower.contains(&lower) {
                continue;
            }
            pending_lower.insert(lower);
            subjects_to_add.push(leaf);
        }
        subjects_to_add.sort();

        let removed_subjects: BTreeSet<String> =
            subjects_to_remove.iter().map(|s| nfc_lower(s)).collect();
        let mut owned_subjects: Vec<String> = view
            .core
            .subjects
            .iter()
            .map(|s| nfc(s))
            .filter(|s| !removed_subjects.contains(&nfc_lower(s)))
            .chain(subjects_to_add.iter().cloned())
            .collect();
        owned_subjects.sort();
        owned_subjects.dedup();

        let existing_lr: BTreeSet<String> =
            view.hierarchical_subject.iter().map(|p| nfc(p)).collect();
        let lr_to_add: Vec<String> = tags_to_add
            .iter()
            .map(|t| to_lr_path(t))
            .filter(|p| !existing_lr.contains(p))
            .collect();
        let mut lr_to_remove: Vec<String> = tags_to_remove.iter().map(|t| to_lr_path(t)).collect();
        lr_to_remove.sort();
        let mut owned_hierarchical: Vec<String> = owned_tags.iter().map(|t| to_lr_path(t)).collect();
        owned_hierarchical.sort();

        let sentinel_is_current = view.photo_tools.tagger_version.as_deref()
            == Some(request.model_pack.as_str())
            && existing_machine == requested_set;

        let clip_is_current = match (
            &request.clip_embedding,
            &request.clip_model,
            &request.clip_timestamp,
        ) {
            (None, None, None) => true,
            (Some(e), Some(m), Some(_)) => {
                // Timestamp is provenance, not identity: a re-run with the
                // same vector must not rewrite every sidecar just to stamp
                // a new `CLIPTimestamp`.
                view.photo_tools.clip_embedding.as_deref() == Some(e.as_str())
                    && view.photo_tools.clip_model.as_deref() == Some(m.as_str())
            }
            _ => false,
        };

        Plan {
            tags_to_add,
            tags_to_remove,
            owned_tags,
            subjects_to_add,
            subjects_to_remove,
            owned_subjects,
            lr_to_add,
            lr_to_remove,
            owned_hierarchical,
            agent: request.agent.clone(),
            model_pack: request.model_pack.clone(),
            tagged_at: request.tagged_at.clone(),
            sentinel_is_current,
            clip_embedding: request.clip_embedding.clone(),
            clip_model: request.clip_model.clone(),
            clip_timestamp: request.clip_timestamp.clone(),
            clip_is_current,
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

/// How a value the planner holds is matched against an entry already in the
/// file.
///
/// Both variants normalize to NFC (`tags::nfc`). They differ in case, and the
/// rule has to be the same one the planner used to decide what it owns — a
/// claim computed case-insensitively and retracted case-sensitively leaves the
/// entry in the file with nothing claiming it, forever.
#[derive(Clone, Copy, PartialEq, Eq)]
enum MatchMode {
    /// Hierarchical paths: `Objects/Animal/Dog` and `objects/animal/dog` are
    /// different tags, and the taxonomy's casing is meaningful.
    Exact,
    /// `dc:subject` leaves, which the planner compares case-insensitively
    /// because that is how every keyword-aware DAM treats them.
    IgnoreCase,
}

impl MatchMode {
    fn key(self, value: &str) -> String {
        match self {
            MatchMode::Exact => nfc(value),
            MatchMode::IgnoreCase => nfc_lower(value),
        }
    }
}

fn apply_plan(doc: &mut Document, root: &NodePath, plan: &Plan) {
    if !plan.touches_keywords() && plan.sentinel_is_current && plan.clip_is_current {
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
        MatchMode::Exact,
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
        MatchMode::IgnoreCase,
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
        MatchMode::Exact,
    );

    let pt = PREFIX_PHOTO_TOOLS;
    let scalar = |doc: &mut Document, local: &str, value: &str| {
        edit::set_scalar(doc, root, NS_PHOTO_TOOLS, pt, local, value);
    };
    scalar(doc, PROP_TAGGER_VERSION, &plan.model_pack);
    scalar(doc, PROP_TAGGED_AT, &plan.tagged_at);
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
    edit::set_list(
        doc,
        root,
        NS_PHOTO_TOOLS,
        pt,
        PROP_CORE_HIERARCHICAL,
        "Bag",
        &plan.owned_hierarchical,
    );

    if let (Some(embedding), Some(model), Some(timestamp)) = (
        &plan.clip_embedding,
        &plan.clip_model,
        &plan.clip_timestamp,
    ) {
        scalar(doc, PROP_CLIP_EMBEDDING, embedding);
        scalar(doc, PROP_CLIP_MODEL, model);
        scalar(doc, PROP_CLIP_TIMESTAMP, timestamp);
    }
}

/// [`edit_list`] with case-sensitive matching, for [`crate::faces`].
///
/// The face half edits the same three keyword fields under different ownership
/// bookkeeping, and the *matching rule* per field has to be the same one this
/// module uses or the two halves would disagree about whether an entry is
/// present.
#[allow(clippy::too_many_arguments)]
pub(crate) fn edit_list_exact(
    doc: &mut Document,
    root: &NodePath,
    uri: &str,
    prefix: &str,
    local: &str,
    kind: &str,
    remove: &[String],
    add: &[String],
) {
    edit_list(
        doc,
        root,
        uri,
        prefix,
        local,
        kind,
        remove,
        add,
        MatchMode::Exact,
    );
}

/// [`edit_list_exact`] for the fields compared case-insensitively.
#[allow(clippy::too_many_arguments)]
pub(crate) fn edit_list_ignore_case(
    doc: &mut Document,
    root: &NodePath,
    uri: &str,
    prefix: &str,
    local: &str,
    kind: &str,
    remove: &[String],
    add: &[String],
) {
    edit_list(
        doc,
        root,
        uri,
        prefix,
        local,
        kind,
        remove,
        add,
        MatchMode::IgnoreCase,
    );
}

/// Remove then append entries in one list property, creating it only if there
/// is something to add.
///
/// Removals sweep **every** occurrence of the property; additions go to the
/// first. A property split across two `rdf:Description` blocks is legal RDF and
/// occurs in the wild, and a remove pass that only saw the first occurrence
/// would drop the entry from `CoreSubjects`/`CoreTags` while leaving it in the
/// file — the sentinel and the file would then disagree forever.
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
    mode: MatchMode,
) {
    if remove.is_empty() && add.is_empty() {
        return;
    }
    // `<rdf:Description dc:subject='Dog'/>` is legal and invisible to an
    // element-based edit; fold it into element form before touching anything,
    // or the file ends up carrying the property twice.
    edit::migrate_attr_list(doc, root, uri, prefix, local, kind);
    if !remove.is_empty() {
        let doomed: BTreeSet<String> = remove.iter().map(|v| mode.key(v)).collect();
        let paths = edit::find_properties(doc, root, uri, local);
        // Reverse document order: removing one property shifts the indices of
        // its later siblings only, so earlier paths stay valid.
        for (i, prop_path) in paths.iter().enumerate().rev() {
            let container_path = edit::ensure_container(doc, prop_path, kind);
            edit::remove_lis(doc, &container_path, &|text| {
                doomed.contains(&mode.key(text))
            });
            // An emptied property must go entirely: exiftool reads a list with
            // no `rdf:li` as the whitespace between the container tags. The one
            // exception is the occurrence the add pass is about to refill.
            let keep_for_add = i == 0 && !add.is_empty();
            if !keep_for_add && edit::values_at(doc, prop_path).is_empty() {
                edit::remove_property(doc, prop_path);
            }
        }
    }
    if add.is_empty() {
        return;
    }
    let prop_path = edit::ensure_property(doc, root, uri, prefix, local);
    let container_path = edit::ensure_container(doc, &prop_path, kind);
    let present: BTreeSet<String> = edit::list_values(doc, root, uri, local)
        .iter()
        .map(|v| mode.key(v))
        .collect();
    for value in add {
        if present.contains(&mode.key(value)) {
            continue;
        }
        edit::append_li(doc, &container_path, value);
    }
}
