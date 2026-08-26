//! Reverse-geocoded `Places/*` keywords and the IPTC location fields.
//!
//! photo-tools schema §1.3 / §2.2: one nested `Places/<Country>/…` path plus
//! the structured location fields so the same data shows up in a DAM's
//! Location panel. This module is additive — it never retracts a `Places/*`
//! tag somebody else wrote, and it never overwrites a location scalar that is
//! already on the file. That is the whole ownership story: tagging's
//! `CoreTags` list does not include Places, so a later tagging run cannot
//! retract them, and a photo photo-tools (or a human) already placed is left
//! alone.

use std::collections::BTreeSet;

use gallery_vfs::Vfs;

use crate::edit::{self, NodePath};
use crate::error::{MetaError, MetaResult};
use crate::model::SidecarView;
use crate::read::view_of;
use crate::schema::*;
use crate::sidecar::{alt_sidecar_path, sidecar_path};
use crate::tags::{leaf_of, nfc, nfc_lower, normalize_tag, to_lr_path, PLACES_ROOT};
use crate::write::{edit_list_exact, edit_list_ignore_case, WriteOutcome};
use crate::xml::{parse, serialize, Document};

/// What to write into a sidecar for one reverse-geocoded photo.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PlaceWriteRequest {
    /// Hierarchical path, e.g. `Places/Italy/Lazio/Rome`. Missing levels are
    /// already collapsed by the caller.
    pub path: String,
    /// `photoshop:Country`.
    pub country: Option<String>,
    /// `photoshop:State`.
    pub state: Option<String>,
    /// `photoshop:City`.
    pub city: Option<String>,
    /// `Iptc4xmpCore:Location` (neighbourhood / sublocation).
    pub sublocation: Option<String>,
    /// ISO 3166-1 alpha-2, written to `Iptc4xmpCore:CountryCode` and
    /// `phototools:CountryCode`.
    pub country_code: Option<String>,
}

impl PlaceWriteRequest {
    /// Build a request from a Places path and the IPTC components.
    pub fn new(path: impl Into<String>) -> Self {
        PlaceWriteRequest {
            path: path.into(),
            ..Self::default()
        }
    }
}

/// Apply `request` to an existing sidecar's bytes, or synthesise a new packet.
pub fn apply_places(
    existing: Option<&[u8]>,
    request: &PlaceWriteRequest,
) -> MetaResult<crate::write::AppliedTags> {
    let path = normalize_places_path(&request.path)?;

    let (mut doc, created) = match existing {
        Some(bytes) if !bytes.iter().all(u8::is_ascii_whitespace) => (parse(bytes)?, false),
        _ => (edit::new_envelope(), true),
    };
    let root = edit::find_rdf_root(&doc).ok_or_else(|| MetaError::NotAnXmpPacket {
        detail: "no rdf:RDF element".into(),
    })?;

    let view = view_of(&doc);
    // A Places tag from anyone — photo-tools, a human, a previous run of
    // ours — means the photo is already placed. Adding a second path would
    // fork the taxonomy (two countries on one GPS point) and overwriting
    // would discard a human decision.
    if view.tags_list.iter().any(|t| is_places_tag(t)) {
        return Ok(crate::write::AppliedTags {
            bytes: serialize(&doc),
            added: vec![],
            removed: vec![],
            owned: vec![],
            created,
            changed: false,
        });
    }

    let plan = PlacePlan::build(&view, &path, request);
    apply_plan(&mut doc, &root, &plan);

    let bytes = serialize(&doc);
    let changed = match existing {
        Some(original) if !created => bytes != original,
        _ => true,
    };

    Ok(crate::write::AppliedTags {
        bytes,
        added: plan.tags_to_add.clone(),
        removed: vec![],
        owned: plan.tags_to_add.clone(),
        created,
        changed,
    })
}

/// Locate (or create) `image_path`'s sidecar and apply `request` to it.
///
/// Same sidecar selection, same atomicity and the same
/// [`MetaError::ConcurrentModification`] retry contract as
/// [`crate::write_tags`].
pub fn write_places(
    vfs: &dyn Vfs,
    image_path: &str,
    request: &PlaceWriteRequest,
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

    let applied = apply_places(existing.as_deref(), request)?;
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

fn normalize_places_path(path: &str) -> MetaResult<String> {
    let normalized = normalize_tag(path)?;
    if crate::tags::root_of(&normalized) != PLACES_ROOT {
        return Err(MetaError::InvalidTag {
            tag: path.to_string(),
            reason: "place tags must live under Places/".into(),
        });
    }
    if normalized == PLACES_ROOT {
        return Err(MetaError::InvalidTag {
            tag: path.to_string(),
            reason: "Places/ with no country is not a place".into(),
        });
    }
    Ok(normalized)
}

fn is_places_tag(tag: &str) -> bool {
    crate::tags::root_of(tag).eq_ignore_ascii_case(PLACES_ROOT) && tag.contains('/')
}

struct PlacePlan {
    tags_to_add: Vec<String>,
    subjects_to_add: Vec<String>,
    lr_to_add: Vec<String>,
    country: Option<String>,
    state: Option<String>,
    city: Option<String>,
    sublocation: Option<String>,
    country_code: Option<String>,
}

impl PlacePlan {
    fn build(view: &SidecarView, path: &str, request: &PlaceWriteRequest) -> PlacePlan {
        let existing_tags: BTreeSet<String> = view.tags_list.iter().map(|t| nfc(t)).collect();
        let tags_to_add = if existing_tags.contains(&nfc(path)) {
            vec![]
        } else {
            vec![path.to_string()]
        };

        let existing_subjects: BTreeSet<String> =
            view.subject.iter().map(|s| nfc_lower(s)).collect();
        let leaf = leaf_of(path).to_string();
        let subjects_to_add = if existing_subjects.contains(&nfc_lower(&leaf)) {
            vec![]
        } else {
            vec![leaf]
        };

        let existing_lr: BTreeSet<String> =
            view.hierarchical_subject.iter().map(|p| nfc(p)).collect();
        let lr = to_lr_path(path);
        let lr_to_add = if existing_lr.contains(&nfc(&lr)) {
            vec![]
        } else {
            vec![lr]
        };

        PlacePlan {
            tags_to_add,
            subjects_to_add,
            lr_to_add,
            country: request.country.clone(),
            state: request.state.clone(),
            city: request.city.clone(),
            sublocation: request.sublocation.clone(),
            country_code: request
                .country_code
                .as_deref()
                .map(|cc| cc.trim().to_uppercase())
                .filter(|cc| cc.len() == 2),
        }
    }

    fn touches_anything(&self) -> bool {
        !self.tags_to_add.is_empty()
            || !self.subjects_to_add.is_empty()
            || !self.lr_to_add.is_empty()
            || self.country.is_some()
            || self.state.is_some()
            || self.city.is_some()
            || self.sublocation.is_some()
            || self.country_code.is_some()
    }
}

fn apply_plan(doc: &mut Document, root: &NodePath, plan: &PlacePlan) {
    if !plan.touches_anything() {
        return;
    }

    edit_list_exact(
        doc,
        root,
        NS_DIGIKAM,
        PREFIX_DIGIKAM,
        PROP_TAGS_LIST,
        "Seq",
        &[],
        &plan.tags_to_add,
    );
    edit_list_ignore_case(
        doc,
        root,
        NS_DC,
        PREFIX_DC,
        PROP_SUBJECT,
        "Bag",
        &[],
        &plan.subjects_to_add,
    );
    edit_list_exact(
        doc,
        root,
        NS_LR,
        PREFIX_LR,
        PROP_HIERARCHICAL_SUBJECT,
        "Bag",
        &[],
        &plan.lr_to_add,
    );

    fill_scalar(
        doc,
        root,
        NS_PHOTOSHOP,
        PREFIX_PHOTOSHOP,
        PROP_COUNTRY,
        plan.country.as_deref(),
    );
    fill_scalar(
        doc,
        root,
        NS_PHOTOSHOP,
        PREFIX_PHOTOSHOP,
        PROP_STATE,
        plan.state.as_deref(),
    );
    fill_scalar(
        doc,
        root,
        NS_PHOTOSHOP,
        PREFIX_PHOTOSHOP,
        PROP_CITY,
        plan.city.as_deref(),
    );
    fill_scalar(
        doc,
        root,
        NS_IPTC_CORE,
        PREFIX_IPTC_CORE,
        PROP_LOCATION,
        plan.sublocation.as_deref(),
    );
    fill_scalar(
        doc,
        root,
        NS_IPTC_CORE,
        PREFIX_IPTC_CORE,
        PROP_COUNTRY_CODE,
        plan.country_code.as_deref(),
    );
    fill_scalar(
        doc,
        root,
        NS_PHOTO_TOOLS,
        PREFIX_PHOTO_TOOLS,
        PROP_COUNTRY_CODE,
        plan.country_code.as_deref(),
    );
}

/// Write `value` only when the property is absent. A human (or photo-tools)
/// who already filled City must not be overwritten by a later geocode.
fn fill_scalar(
    doc: &mut Document,
    root: &NodePath,
    uri: &str,
    prefix: &str,
    local: &str,
    value: Option<&str>,
) {
    let Some(value) = value.map(str::trim).filter(|s| !s.is_empty()) else {
        return;
    };
    if edit::find_property(doc, root, uri, local).is_some()
        || edit::find_attr_property(doc, root, uri, local).is_some()
    {
        return;
    }
    edit::set_scalar(doc, root, uri, prefix, local, value);
}

fn stat_token(vfs: &dyn Vfs, path: &str) -> Option<(u64, Option<i64>)> {
    vfs.stat(path).ok().map(|s| (s.size, s.modified_unix))
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_vfs::MemVfs;

    fn req(path: &str) -> PlaceWriteRequest {
        PlaceWriteRequest {
            path: path.into(),
            country: Some("Italy".into()),
            state: Some("Lazio".into()),
            city: Some("Rome".into()),
            sublocation: Some("Municipio Roma I".into()),
            country_code: Some("it".into()),
        }
    }

    #[test]
    fn a_missing_sidecar_is_created_with_places_and_location_fields() {
        let vfs = MemVfs::new();
        vfs.insert("/lib/a.jpg", b"jpeg".to_vec());

        let outcome = write_places(
            &vfs,
            "/lib/a.jpg",
            &req("Places/Italy/Lazio/Rome/Municipio Roma I"),
        )
        .unwrap();
        assert!(outcome.written);
        assert!(outcome.created);
        assert_eq!(
            outcome.added,
            vec!["Places/Italy/Lazio/Rome/Municipio Roma I"]
        );

        let view = crate::read_view(&vfs.read("/lib/a.jpg.xmp").unwrap()).unwrap();
        assert_eq!(
            view.tags_list,
            vec!["Places/Italy/Lazio/Rome/Municipio Roma I"]
        );
        assert_eq!(view.subject, vec!["Municipio Roma I"]);
        assert_eq!(
            view.hierarchical_subject,
            vec!["Places|Italy|Lazio|Rome|Municipio Roma I"]
        );
        assert_eq!(view.photo_tools.country_code.as_deref(), Some("IT"));
    }

    #[test]
    fn an_existing_places_tag_is_left_alone() {
        let vfs = MemVfs::new();
        vfs.insert("/lib/a.jpg", b"jpeg".to_vec());
        crate::write_tags(
            &vfs,
            "/lib/a.jpg",
            &crate::TagWriteRequest::new(
                ["Places/France/Paris".to_string()],
                "pack",
                "2026-08-03T10:00:00Z",
            ),
        )
        .unwrap();

        let outcome = write_places(&vfs, "/lib/a.jpg", &req("Places/Italy/Rome")).unwrap();
        assert!(!outcome.written);
        let view = crate::read_view(&vfs.read("/lib/a.jpg.xmp").unwrap()).unwrap();
        assert_eq!(view.tags_list, vec!["Places/France/Paris"]);
    }

    #[test]
    fn objects_tags_survive_a_places_write() {
        let vfs = MemVfs::new();
        vfs.insert("/lib/a.jpg", b"jpeg".to_vec());
        crate::write_tags(
            &vfs,
            "/lib/a.jpg",
            &crate::TagWriteRequest::new(
                ["Objects/Animal/Dog".to_string()],
                "pack",
                "2026-08-03T10:00:00Z",
            ),
        )
        .unwrap();

        write_places(&vfs, "/lib/a.jpg", &req("Places/Italy/Rome")).unwrap();
        let view = crate::read_view(&vfs.read("/lib/a.jpg.xmp").unwrap()).unwrap();
        assert!(view.tags_list.contains(&"Objects/Animal/Dog".to_string()));
        assert!(view.tags_list.contains(&"Places/Italy/Rome".to_string()));
        assert_eq!(view.core.tags, vec!["Objects/Animal/Dog"]);
    }

    #[test]
    fn a_second_write_is_a_no_op() {
        let vfs = MemVfs::new();
        vfs.insert("/lib/a.jpg", b"jpeg".to_vec());
        assert!(write_places(&vfs, "/lib/a.jpg", &req("Places/Italy/Rome"))
            .unwrap()
            .written);
        let first = vfs.read("/lib/a.jpg.xmp").unwrap();
        assert!(!write_places(&vfs, "/lib/a.jpg", &req("Places/Italy/Rome"))
            .unwrap()
            .written);
        assert_eq!(vfs.read("/lib/a.jpg.xmp").unwrap(), first);
    }

    #[test]
    fn a_root_that_is_not_places_is_rejected() {
        let err = normalize_places_path("Objects/Animal/Dog").unwrap_err();
        assert!(matches!(err, MetaError::InvalidTag { .. }));
    }

    #[test]
    fn a_bare_places_root_is_rejected() {
        let err = normalize_places_path("Places").unwrap_err();
        assert!(matches!(err, MetaError::InvalidTag { .. }));
    }
}
