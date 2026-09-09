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
//!
//! One exception to "already placed": a *strict prefix* (`Places/France` →
//! `Places/France/Île-de-France/Paris`) is an upgrade, not a fork. The first
//! geocode often returns country only (Apple leaves `locality` nil for many
//! European cities). A later pass that actually has the city must be allowed
//! to extend the path; overwriting a different country must not.

use std::collections::BTreeSet;

use gallery_vfs::Vfs;

use crate::edit::{self, NodePath};
use crate::error::{MetaError, MetaResult};
use crate::model::SidecarView;
use crate::read::view_of;
use crate::schema::*;
use crate::sidecar::sidecar_path;
use crate::tags::{leaf_of, nfc, nfc_lower, normalize_tag, to_lr_path, PLACES_ROOT};
use crate::write::{
    commit_sidecar_write, edit_list_exact, edit_list_ignore_case, load_sidecar_for_write,
    WriteOutcome,
};
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

/// A finished Places path has country, region and city (`Places/a/b/c`).
///
/// Shallower tags stay eligible so a later geocode can extend them. Four
/// or more segments is treated as placed: a human or photo-tools city is
/// not overwritten.
pub const PLACES_FINISHED_DEPTH: usize = 4;

/// First `Places/…` entry in document order.
pub fn first_places_tag(tags: impl IntoIterator<Item = impl AsRef<str>>) -> Option<String> {
    tags.into_iter()
        .map(|t| t.as_ref().to_string())
        .find(|t| is_places_tag(t))
}

/// `Places/France` is a strict prefix of `Places/France/Île-de-France/Paris`.
pub fn is_strict_places_prefix(existing: &str, newer: &str) -> bool {
    let a = place_segments(existing);
    let b = place_segments(newer);
    a.first().map(String::as_str) == Some("places")
        && b.len() > a.len()
        && a.iter().zip(b.iter()).all(|(x, y)| x == y)
}

/// How many `/`-separated segments a Places tag has. `None` if it is not one.
pub fn places_depth(tag: &str) -> Option<usize> {
    is_places_tag(tag).then(|| place_segments(tag).len())
}

/// Whether a sidecar's Places tags are still shallow enough to extend.
///
/// No Places tag ⇒ needed. A path of depth ≥ [`PLACES_FINISHED_DEPTH`] ⇒ done.
pub fn places_still_needed(tags: impl IntoIterator<Item = impl AsRef<str>>) -> bool {
    match tags
        .into_iter()
        .filter_map(|t| places_depth(t.as_ref()))
        .max()
    {
        None => true,
        Some(depth) => depth < PLACES_FINISHED_DEPTH,
    }
}

/// `Places/<Country>[/<Region>[/<City>[/<Neighborhood>]]]`, missing levels
/// collapsed. `None` when every field is empty.
pub fn places_path(
    country: Option<&str>,
    state: Option<&str>,
    city: Option<&str>,
    sublocation: Option<&str>,
) -> Option<String> {
    let mut segments = Vec::new();
    for part in [country, state, city, sublocation] {
        if let Some(value) = nonempty(part) {
            segments.push(value);
        }
    }
    if segments.is_empty() {
        return None;
    }
    Some(format!("{PLACES_ROOT}/{}", segments.join("/")))
}

/// Build a write request from already-normalized place fields.
///
/// Duplicate levels (Singapore the city == Singapore the country) are
/// dropped so the path does not read `Places/Singapore/Singapore`.
pub fn place_from_parts(
    country: Option<&str>,
    state: Option<&str>,
    city: Option<&str>,
    sublocation: Option<&str>,
    country_code: Option<&str>,
) -> Option<PlaceWriteRequest> {
    let country = nonempty(country);
    let state = distinct(state, &[country.as_deref()]);
    let city = distinct(city, &[country.as_deref(), state.as_deref()]);
    let sublocation = distinct(
        sublocation,
        &[country.as_deref(), state.as_deref(), city.as_deref()],
    );
    let path = places_path(
        country.as_deref(),
        state.as_deref(),
        city.as_deref(),
        sublocation.as_deref(),
    )?;
    let country_code = nonempty(country_code)
        .map(|cc| cc.to_uppercase())
        .filter(|cc| cc.len() == 2);
    Some(PlaceWriteRequest {
        path,
        country,
        state,
        city,
        sublocation,
        country_code,
    })
}

fn nonempty(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToString::to_string)
}

fn distinct(value: Option<&str>, others: &[Option<&str>]) -> Option<String> {
    let value = nonempty(value)?;
    let key = nfc_lower(&value);
    if others.iter().flatten().any(|other| nfc_lower(other) == key) {
        return None;
    }
    Some(value)
}

fn place_segments(tag: &str) -> Vec<String> {
    tag.split('/')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(nfc_lower)
        .collect()
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
    // ours — means the photo is already placed, *unless* it is a strict
    // prefix of the new path. Adding a second country would fork the
    // taxonomy; overwriting a different city would discard a human decision.
    // Extending `Places/France` to `Places/France/Île-de-France/Paris` is
    // the one write that is still ours.
    let plan = match first_places_tag(&view.tags_list) {
        Some(current) if nfc_lower(&current) == nfc_lower(&path) => {
            return Ok(unchanged(&doc, created));
        }
        Some(current) if is_strict_places_prefix(&current, &path) => {
            PlacePlan::upgrade(&view, &current, &path, request)
        }
        Some(_) => return Ok(unchanged(&doc, created)),
        None => PlacePlan::build(&view, &path, request),
    };
    apply_plan(&mut doc, &root, &plan);

    let bytes = serialize(&doc);
    let changed = match existing {
        Some(original) if !created => bytes != original,
        _ => true,
    };

    Ok(crate::write::AppliedTags {
        bytes,
        added: plan.tags_to_add.clone(),
        removed: plan.tags_to_remove.clone(),
        owned: plan.tags_to_add.clone(),
        created,
        changed,
    })
}

fn unchanged(doc: &Document, created: bool) -> crate::write::AppliedTags {
    crate::write::AppliedTags {
        bytes: serialize(doc),
        added: vec![],
        removed: vec![],
        owned: vec![],
        created,
        changed: false,
    }
}

/// Locate (or create) `image_path`'s sidecar and apply `request` to it.
///
/// Same sidecar selection, same atomicity and the same
/// [`MetaError::ConcurrentModification`] retry contract as
/// [`crate::write_tags`]. A missing canonical sidecar is created even when
/// a Lightroom-style alt already carried the place — otherwise
/// `created: true, written: false` would claim a file that was never
/// written, and readers that only look at the canonical name would miss it.
pub fn write_places(
    vfs: &dyn Vfs,
    image_path: &str,
    request: &PlaceWriteRequest,
) -> MetaResult<WriteOutcome> {
    let target = sidecar_path(image_path);
    let seed = load_sidecar_for_write(vfs, image_path)?;
    let applied = apply_places(seed.existing.as_deref(), request)?;
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
    tags_to_remove: Vec<String>,
    subjects_to_add: Vec<String>,
    subjects_to_remove: Vec<String>,
    lr_to_add: Vec<String>,
    lr_to_remove: Vec<String>,
    country: Option<String>,
    state: Option<String>,
    city: Option<String>,
    sublocation: Option<String>,
    country_code: Option<String>,
}

impl PlacePlan {
    fn scalars(
        request: &PlaceWriteRequest,
    ) -> (
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
        Option<String>,
    ) {
        (
            request.country.clone(),
            request.state.clone(),
            request.city.clone(),
            request.sublocation.clone(),
            request
                .country_code
                .as_deref()
                .map(|cc| cc.trim().to_uppercase())
                .filter(|cc| cc.len() == 2),
        )
    }

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

        let (country, state, city, sublocation, country_code) = Self::scalars(request);
        PlacePlan {
            tags_to_add,
            tags_to_remove: vec![],
            subjects_to_add,
            subjects_to_remove: vec![],
            lr_to_add,
            lr_to_remove: vec![],
            country,
            state,
            city,
            sublocation,
            country_code,
        }
    }

    fn upgrade(
        view: &SidecarView,
        current: &str,
        path: &str,
        request: &PlaceWriteRequest,
    ) -> PlacePlan {
        let mut plan = Self::build(view, path, request);
        plan.tags_to_remove = vec![current.to_string()];
        let old_leaf = leaf_of(current).to_string();
        let new_leaf = leaf_of(path).to_string();
        if nfc_lower(&old_leaf) != nfc_lower(&new_leaf) {
            plan.subjects_to_remove = vec![old_leaf];
        }
        plan.lr_to_remove = vec![to_lr_path(current)];
        plan
    }

    fn touches_anything(&self) -> bool {
        !self.tags_to_add.is_empty()
            || !self.tags_to_remove.is_empty()
            || !self.subjects_to_add.is_empty()
            || !self.subjects_to_remove.is_empty()
            || !self.lr_to_add.is_empty()
            || !self.lr_to_remove.is_empty()
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
        &plan.tags_to_remove,
        &plan.tags_to_add,
    );
    edit_list_ignore_case(
        doc,
        root,
        NS_DC,
        PREFIX_DC,
        PROP_SUBJECT,
        "Bag",
        &plan.subjects_to_remove,
        &plan.subjects_to_add,
    );
    edit_list_exact(
        doc,
        root,
        NS_LR,
        PREFIX_LR,
        PROP_HIERARCHICAL_SUBJECT,
        "Bag",
        &plan.lr_to_remove,
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
        // A human / photo-tools placement, not a tagging write — `write_tags`
        // will not plant `Places/*` (that root is not in its replace set).
        vfs.insert(
            "/lib/a.jpg.xmp",
            br#"<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
 <rdf:Description rdf:about="" xmlns:digiKam="http://www.digikam.org/ns/1.0/">
  <digiKam:TagsList><rdf:Seq><rdf:li>Places/France/Paris</rdf:li></rdf:Seq></digiKam:TagsList>
 </rdf:Description>
</rdf:RDF>
</x:xmpmeta>"#
                .to_vec(),
        );

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
        assert!(
            write_places(&vfs, "/lib/a.jpg", &req("Places/Italy/Rome"))
                .unwrap()
                .written
        );
        let first = vfs.read("/lib/a.jpg.xmp").unwrap();
        assert!(
            !write_places(&vfs, "/lib/a.jpg", &req("Places/Italy/Rome"))
                .unwrap()
                .written
        );
        assert_eq!(vfs.read("/lib/a.jpg.xmp").unwrap(), first);
    }

    #[test]
    fn a_matching_alt_sidecar_still_creates_the_canonical_file() {
        let vfs = MemVfs::new();
        vfs.insert("/lib/a.jpg", b"jpeg".to_vec());
        let seeded = apply_places(None, &req("Places/Italy/Rome")).unwrap().bytes;
        vfs.insert("/lib/a.xmp", seeded);
        let outcome = write_places(&vfs, "/lib/a.jpg", &req("Places/Italy/Rome")).unwrap();
        assert!(outcome.created, "{outcome:?}");
        assert!(outcome.written, "{outcome:?}");
        assert!(vfs.exists("/lib/a.jpg.xmp"));
        assert!(
            vfs.exists("/lib/a.xmp"),
            "the alt file is not ours to delete"
        );
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

    #[test]
    fn a_country_only_tag_is_extended_with_the_city() {
        let vfs = MemVfs::new();
        vfs.insert("/lib/eiffel.jpg", b"jpeg".to_vec());
        let country = PlaceWriteRequest {
            path: "Places/France".into(),
            country: Some("France".into()),
            country_code: Some("FR".into()),
            ..Default::default()
        };
        assert!(
            write_places(&vfs, "/lib/eiffel.jpg", &country)
                .unwrap()
                .written
        );

        let with_city = PlaceWriteRequest {
            path: "Places/France/Île-de-France/Paris".into(),
            country: Some("France".into()),
            state: Some("Île-de-France".into()),
            city: Some("Paris".into()),
            country_code: Some("FR".into()),
            ..Default::default()
        };
        assert!(
            write_places(&vfs, "/lib/eiffel.jpg", &with_city)
                .unwrap()
                .written
        );

        let view = crate::read_view(&vfs.read("/lib/eiffel.jpg.xmp").unwrap()).unwrap();
        assert_eq!(view.tags_list, vec!["Places/France/Île-de-France/Paris"]);
        assert!(!view.tags_list.iter().any(|t| t == "Places/France"));
        assert_eq!(view.subject, vec!["Paris"]);
    }

    #[test]
    fn a_different_country_is_not_overwritten() {
        let vfs = MemVfs::new();
        vfs.insert("/lib/a.jpg", b"jpeg".to_vec());
        write_places(&vfs, "/lib/a.jpg", &req("Places/Italy/Rome")).unwrap();
        let france = PlaceWriteRequest {
            path: "Places/France/Paris".into(),
            country: Some("France".into()),
            city: Some("Paris".into()),
            country_code: Some("FR".into()),
            ..Default::default()
        };
        assert!(!write_places(&vfs, "/lib/a.jpg", &france).unwrap().written);
        let view = crate::read_view(&vfs.read("/lib/a.jpg.xmp").unwrap()).unwrap();
        assert_eq!(view.tags_list, vec!["Places/Italy/Rome"]);
    }

    #[test]
    fn prefix_compare_is_case_insensitive_and_strict() {
        assert!(is_strict_places_prefix(
            "Places/France",
            "Places/France/Île-de-France/Paris"
        ));
        assert!(is_strict_places_prefix(
            "Places/France/Île-de-France",
            "Places/France/Île-de-France/Paris"
        ));
        assert!(!is_strict_places_prefix(
            "Places/France/Paris",
            "Places/France/Île-de-France/Paris"
        ));
        assert!(!is_strict_places_prefix("Places/France", "Places/France"));
        assert!(!is_strict_places_prefix(
            "Places/Italy",
            "Places/France/Paris"
        ));
    }

    #[test]
    fn places_still_needed_treats_city_depth_as_finished() {
        assert!(places_still_needed(Vec::<String>::new()));
        assert!(places_still_needed(["Places/France"]));
        assert!(places_still_needed(["Places/France/Île-de-France"]));
        assert!(!places_still_needed(["Places/France/Île-de-France/Paris"]));
        assert!(!places_still_needed([
            "Places/France/Île-de-France/Paris/Louvre"
        ]));
    }

    #[test]
    fn place_from_parts_collapses_duplicate_levels() {
        let singapore =
            place_from_parts(Some("Singapore"), None, Some("Singapore"), None, Some("sg")).unwrap();
        assert_eq!(singapore.path, "Places/Singapore");
        assert_eq!(singapore.country_code.as_deref(), Some("SG"));
        assert!(singapore.city.is_none());

        let tokyo = place_from_parts(
            Some("Japan"),
            Some("Tokyo"),
            Some("Tokyo"),
            None,
            Some("JP"),
        )
        .unwrap();
        assert_eq!(tokyo.path, "Places/Japan/Tokyo");
        assert!(tokyo.city.is_none());
    }
}
