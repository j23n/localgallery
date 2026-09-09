//! The sidecar write path: read-modify-write that retracts only what we own.
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
//! `mwg-rs:RegionInfo`, the OCR fields and the IPTC location fields are
//! not written here — faces and places own those paths.
//!
//! `photo-tools:TaggerVersion` is the shared skip key (pack version).
//! `CLIPEmbedding` / `CLIPModel` / `CLIPTimestamp` are written when the
//! request carries a vector; a reader treats a mismatched `CLIPModel` as
//! a miss.
//!
//! # Ownership and retraction
//!
//! LocalGallery may retract only values recorded as LocalGallery-owned in
//! the sentinel, **including** under `Objects/*` and `Scenes/*`. Each XMP
//! property is planned independently: a pre-existing digiKam `TagsList`
//! entry, Lightroom `hierarchicalSubject` path, or `dc:subject` keyword is
//! neither claimed nor removed just because this request names the same
//! path. Ownership is recorded only for values this write actually inserts.
//!
//! Duplicate occurrences of a property (split `rdf:Description` blocks)
//! are swept only for those owned values. Comparisons against bytes already
//! in the file are NFC (and case-insensitive for `dc:subject`); existing
//! NFD spellings are matched, not rewritten.
//!
//! People/, Places/, Landmarks/ and bare human keywords are not requested
//! by the tagger. `photo-tools:TaggerVersion` is the skip key: a sidecar
//! already stamped with the running pack and whose owned set matches is
//! left alone.

use std::collections::hash_map::DefaultHasher;
use std::collections::BTreeSet;
use std::hash::{Hash, Hasher};

use gallery_vfs::{Vfs, VfsError};

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
/// Nothing is written when the *canonical* sidecar already says exactly what
/// this request says: re-running the tagger must not churn mtimes and wake the
/// sidecar sync. A missing canonical file is still created even when a matching
/// alt seeded the merge — the app reads the canonical name.
///
/// # Concurrency
///
/// This is a read-modify-write over a file other programs also write. If the
/// sidecar changes between the read and the rename, the rename would discard
/// the other writer's work wholesale — digiKam's new face tag, Lightroom's new
/// keyword, gone with no trace. Immediately before the atomic replace the
/// canonical file is re-read and compared by content identity (a digest of the
/// bytes we actually parsed). A mismatch returns
/// [`MetaError::ConcurrentModification`] with nothing written; the caller
/// retries, which re-reads and re-merges.
///
/// The `Vfs` trait has no compare-and-swap / exclusive-rename primitive, so a
/// write that lands in the gap after that re-read can still win. The content
/// check closes the same-size, same-second window that a size/mtime token
/// cannot see. Inaccessible files are reported as I/O errors rather than
/// treated as absent.
pub fn write_tags(
    vfs: &dyn Vfs,
    image_path: &str,
    request: &TagWriteRequest,
) -> MetaResult<WriteOutcome> {
    let target = sidecar_path(image_path);
    let seed = load_sidecar_for_write(vfs, image_path)?;
    let applied = apply_tags(seed.existing.as_deref(), request)?;
    let created = seed.canonical.is_none();
    let written = applied.changed || created;

    if written {
        commit_sidecar_write(vfs, &target, seed.canonical.as_deref(), &applied.bytes)?;
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

/// Bytes used to start a sidecar write, plus the canonical file's identity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SidecarSeed {
    /// Canonical sidecar bytes when that path existed. `None` means absent.
    pub canonical: Option<Vec<u8>>,
    /// Bytes to parse: the canonical file, or the Lightroom alt, or nothing.
    pub existing: Option<Vec<u8>>,
}

/// Read the canonical sidecar, falling back to the Lightroom-style alt.
///
/// [`VfsError::NotFound`] is absence. Every other filesystem error — including
/// permission denied — is returned, so an inaccessible sidecar is never
/// treated as a file we may create or replace.
pub(crate) fn load_sidecar_for_write(vfs: &dyn Vfs, image_path: &str) -> MetaResult<SidecarSeed> {
    let target = sidecar_path(image_path);
    match read_present(vfs, &target)? {
        Some(bytes) => Ok(SidecarSeed {
            canonical: Some(bytes.clone()),
            existing: Some(bytes),
        }),
        None => {
            let existing = match alt_sidecar_path(image_path) {
                Some(alt) => read_present(vfs, &alt)?,
                None => None,
            };
            Ok(SidecarSeed {
                canonical: None,
                existing,
            })
        }
    }
}

/// Re-read the canonical sidecar and write only if its bytes still match
/// `expected` (`None` means the path must still be absent).
pub(crate) fn commit_sidecar_write(
    vfs: &dyn Vfs,
    target: &str,
    expected: Option<&[u8]>,
    bytes: &[u8],
) -> MetaResult<()> {
    let now = read_present(vfs, target)?;
    if content_identity(now.as_deref()) != content_identity(expected) {
        return Err(MetaError::ConcurrentModification {
            path: target.to_string(),
        });
    }
    vfs.write_atomic(target, bytes)?;
    Ok(())
}

/// `Ok(None)` when `path` is absent; I/O errors other than not-found propagate.
fn read_present(vfs: &dyn Vfs, path: &str) -> MetaResult<Option<Vec<u8>>> {
    match vfs.stat(path) {
        Ok(_) => match vfs.read(path) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(VfsError::NotFound { .. }) => Err(MetaError::ConcurrentModification {
                path: path.to_string(),
            }),
            Err(e) => Err(e.into()),
        },
        Err(VfsError::NotFound { .. }) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Content identity of a sidecar snapshot. `None` is "file absent".
///
/// Sidecars are small; the digest is only an identity token compared inside
/// one process, so a stable-enough hasher is enough. Comparing the digest
/// rather than holding a second copy of the bytes keeps the concurrent-check
/// path on the `Vfs` read primitive (no extra trait methods).
fn content_identity(bytes: Option<&[u8]>) -> Option<u64> {
    bytes.map(|b| {
        let mut hasher = DefaultHasher::new();
        b.hash(&mut hasher);
        hasher.finish()
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
        // Only Objects/Scenes are requested by the tagger. People/Places/
        // Landmarks stay unless a later agent owns them. `requested` is NFC.
        let requested: Vec<String> = requested
            .iter()
            .filter(|t| is_content_tag(t))
            .cloned()
            .collect();
        let requested_set: BTreeSet<String> = requested.iter().cloned().collect();

        let existing_tags: BTreeSet<String> = view.tags_list.iter().map(|t| nfc(t)).collect();
        let previously_owned_tags: BTreeSet<String> = view
            .core
            .tags
            .iter()
            .map(|t| nfc(t))
            .filter(|t| is_content_tag(t))
            .collect();

        // Retract only what the sentinel says we inserted, and only when this
        // request no longer names it. Foreign Objects/Scenes stay.
        let mut tags_to_remove: Vec<String> = previously_owned_tags
            .iter()
            .filter(|t| !requested_set.contains(*t))
            .cloned()
            .collect();
        tags_to_remove.sort();
        let tags_to_add: Vec<String> = requested
            .iter()
            .filter(|t| !existing_tags.contains(*t))
            .cloned()
            .collect();
        let mut owned_tags: Vec<String> = previously_owned_tags
            .iter()
            .filter(|t| requested_set.contains(*t))
            .cloned()
            .chain(tags_to_add.iter().cloned())
            .collect();
        owned_tags.sort();
        owned_tags.dedup();

        let tags_to_remove_set: BTreeSet<String> = tags_to_remove.iter().cloned().collect();
        let retained: BTreeSet<String> = view
            .tags_list
            .iter()
            .map(|t| nfc(t))
            .filter(|t| !tags_to_remove_set.contains(t))
            .chain(tags_to_add.iter().cloned())
            .collect();
        let retained_leaves: BTreeSet<String> =
            retained.iter().map(|t| nfc_lower(leaf_of(t))).collect();

        // Each keyword property is planned on its own. A pre-existing
        // `dc:subject` leaf is not claimed just because we requested a path
        // that shares it; we only retract leaves the sentinel says we wrote
        // and that nothing surviving still needs.
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
        for tag in &requested {
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
        let previously_owned_lr: BTreeSet<String> =
            view.core.hierarchical.iter().map(|p| nfc(p)).collect();
        let requested_lr: BTreeSet<String> = requested.iter().map(|t| to_lr_path(t)).collect();

        let lr_to_add: Vec<String> = requested_lr
            .iter()
            .filter(|p| !existing_lr.contains(*p))
            .cloned()
            .collect();
        let mut lr_to_remove: Vec<String> = previously_owned_lr
            .iter()
            .filter(|p| !requested_lr.contains(*p))
            .cloned()
            .collect();
        lr_to_remove.sort();
        let mut owned_hierarchical: Vec<String> = previously_owned_lr
            .iter()
            .filter(|p| requested_lr.contains(*p))
            .cloned()
            .chain(lr_to_add.iter().cloned())
            .collect();
        owned_hierarchical.sort();
        owned_hierarchical.dedup();

        let keywords_unchanged = tags_to_add.is_empty()
            && tags_to_remove.is_empty()
            && subjects_to_add.is_empty()
            && subjects_to_remove.is_empty()
            && lr_to_add.is_empty()
            && lr_to_remove.is_empty();
        let sentinel_is_current = view.photo_tools.tagger_version.as_deref()
            == Some(request.model_pack.as_str())
            && keywords_unchanged;

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

    if let (Some(embedding), Some(model), Some(timestamp)) =
        (&plan.clip_embedding, &plan.clip_model, &plan.clip_timestamp)
    {
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
/// Removals sweep **every** occurrence of the property, but only the values
/// the planner marked as owned (the `remove` list). Foreign entries in a
/// later `rdf:Description` are left alone. Additions go to the first
/// occurrence. A property split across two blocks is legal RDF and occurs in
/// the wild; a remove pass that only saw the first occurrence would drop an
/// owned entry from the sentinel while leaving it in the file.
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
