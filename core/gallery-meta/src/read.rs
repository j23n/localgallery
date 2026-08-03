//! Typed extraction from a parsed sidecar.
//!
//! The walk is intentionally structure-agnostic: it looks for properties
//! anywhere under the root, matched on namespace URI, and accepts every
//! serialization the ecosystem uses (attribute form, element form, `rdf:Bag` /
//! `rdf:Seq` / `rdf:Alt`, `rdf:parseType='Resource'` structs). Sidecars come
//! from digiKam, Lightroom, exiftool and Apple Photos, and they disagree.

use crate::error::MetaResult;
use crate::model::{AppliedDimensions, FaceRegion, SidecarView};
use crate::schema::*;
use crate::xml::{parse, Document, Element, NsScope};

/// Parse `bytes` and project out everything this crate understands.
pub fn read_view(bytes: &[u8]) -> MetaResult<SidecarView> {
    Ok(view_of(&parse(bytes)?))
}

/// Project a already-parsed document.
pub fn view_of(doc: &Document) -> SidecarView {
    let mut view = SidecarView::default();
    let scope = NsScope::new();
    for node in &doc.nodes {
        if let Some(el) = node.as_element() {
            visit(el, &scope, &mut view);
        }
    }
    view
}

fn visit(el: &Element, outer: &NsScope, view: &mut SidecarView) {
    let scope = outer.extended(el);

    // Attribute form: `<rdf:Description phototools:CountryCode='IT'/>` for
    // scalars, and — because RDF lets a one-entry array collapse onto the tag,
    // which exiftool and Bridge both emit — `<rdf:Description dc:subject='Dog'/>`
    // for the keyword lists. Missing the second form is not merely a read gap:
    // the writer would then add an *element*-form property alongside the
    // attribute and the file would carry the same property twice.
    for attr in el.attrs() {
        if attr.name.starts_with("xmlns") {
            continue;
        }
        let (uri, local) = scope.resolve(&attr.name);
        if let Some(list) = list_field_for(uri, local, view) {
            let value = attr.value.trim();
            if !value.is_empty() {
                list.push(value.to_string());
            }
        } else if uri == Some(NS_PHOTO_TOOLS) {
            absorb_photo_tools_scalar(local, &attr.value, view);
        }
    }

    // Lists **accumulate** rather than assign. A property may legally appear
    // more than once — several `rdf:Description` blocks, or one property split
    // across them — and the last occurrence is not the whole truth. Assigning
    // would hide entries from the ownership planner, which would then claim (and
    // later delete) a keyword a human wrote.
    if scope.matches(el, NS_DC, PROP_SUBJECT) {
        view.subject.extend(collect_list(el, &scope));
    } else if scope.matches(el, NS_DIGIKAM, PROP_TAGS_LIST) {
        view.tags_list.extend(collect_list(el, &scope));
    } else if scope.matches(el, NS_LR, PROP_HIERARCHICAL_SUBJECT) {
        view.hierarchical_subject.extend(collect_list(el, &scope));
    } else if scope.matches(el, NS_IPTC_EXT, PROP_PERSON_IN_IMAGE) {
        view.person_in_image.extend(collect_list(el, &scope));
    } else if scope.matches(el, NS_MWG_RS, PROP_REGION_LIST) {
        view.regions.extend(collect_regions(el, &scope));
        // The region subtree is fully consumed; nothing inside it is ours.
        return;
    } else if scope.matches(el, NS_MWG_RS, PROP_APPLIED_TO_DIMENSIONS) {
        // First occurrence wins: a second RegionInfo in the same packet is
        // malformed, and the first is the one every reader will use.
        if view.applied_dimensions.is_none() {
            view.applied_dimensions = applied_dimensions(el, &scope);
        }
        return;
    } else if scope.resolve(&el.name).0 == Some(NS_PHOTO_TOOLS) {
        let local = el.local_name().to_string();
        match local.as_str() {
            PROP_OCR_TEXT => view.photo_tools.ocr_text.extend(collect_list(el, &scope)),
            PROP_CORE_TAGS => view.core.tags.extend(collect_list(el, &scope)),
            PROP_CORE_SUBJECTS => view.core.subjects.extend(collect_list(el, &scope)),
            PROP_CORE_HIERARCHICAL => view.core.hierarchical.extend(collect_list(el, &scope)),
            PROP_CORE_PEOPLE => view.core.people.extend(collect_list(el, &scope)),
            PROP_CORE_PEOPLE_SUBJECTS => view.core.people_subjects.extend(collect_list(el, &scope)),
            PROP_CORE_PEOPLE_HIERARCHICAL => view
                .core
                .people_hierarchical
                .extend(collect_list(el, &scope)),
            PROP_CORE_REGIONS => view.core.regions.extend(collect_list(el, &scope)),
            _ => absorb_photo_tools_scalar(&local, &el.text(), view),
        }
        return;
    }

    for child in el.child_elements() {
        visit(child, &scope, view);
    }
}

/// The list field a namespace/local pair names, when it names one.
///
/// Shared by the attribute-form reader and (indirectly) the writer, so the two
/// agree on exactly which properties are arrays.
fn list_field_for<'v>(
    uri: Option<&str>,
    local: &str,
    view: &'v mut SidecarView,
) -> Option<&'v mut Vec<String>> {
    let uri = uri?;
    match (uri, local) {
        (NS_DC, PROP_SUBJECT) => Some(&mut view.subject),
        (NS_DIGIKAM, PROP_TAGS_LIST) => Some(&mut view.tags_list),
        (NS_LR, PROP_HIERARCHICAL_SUBJECT) => Some(&mut view.hierarchical_subject),
        (NS_IPTC_EXT, PROP_PERSON_IN_IMAGE) => Some(&mut view.person_in_image),
        (NS_PHOTO_TOOLS, PROP_OCR_TEXT) => Some(&mut view.photo_tools.ocr_text),
        (NS_PHOTO_TOOLS, PROP_CORE_TAGS) => Some(&mut view.core.tags),
        (NS_PHOTO_TOOLS, PROP_CORE_SUBJECTS) => Some(&mut view.core.subjects),
        (NS_PHOTO_TOOLS, PROP_CORE_HIERARCHICAL) => Some(&mut view.core.hierarchical),
        (NS_PHOTO_TOOLS, PROP_CORE_PEOPLE) => Some(&mut view.core.people),
        (NS_PHOTO_TOOLS, PROP_CORE_PEOPLE_SUBJECTS) => Some(&mut view.core.people_subjects),
        (NS_PHOTO_TOOLS, PROP_CORE_PEOPLE_HIERARCHICAL) => Some(&mut view.core.people_hierarchical),
        (NS_PHOTO_TOOLS, PROP_CORE_REGIONS) => Some(&mut view.core.regions),
        _ => None,
    }
}

fn absorb_photo_tools_scalar(local: &str, value: &str, view: &mut SidecarView) {
    let value = value.trim();
    if value.is_empty() {
        return;
    }
    let owned = || Some(value.to_string());
    match local {
        PROP_TAGGER_VERSION => view.photo_tools.tagger_version = owned(),
        PROP_TAGGED_AT => view.photo_tools.tagged_at = owned(),
        PROP_COUNTRY_CODE => view.photo_tools.country_code = Some(value.to_uppercase()),
        PROP_OCR_RAN => view.photo_tools.ocr_ran = owned(),
        PROP_CORE_AGENT => view.core.agent = owned(),
        PROP_CORE_MODEL_PACK => view.core.model_pack = owned(),
        PROP_CORE_TAGGED_AT => view.core.tagged_at = owned(),
        PROP_CORE_FACE_PACK => view.core.face_pack = owned(),
        _ => {}
    }
}

/// The `rdf:Bag` / `rdf:Seq` / `rdf:Alt` inside a property element.
pub(crate) fn container_of<'a>(el: &'a Element, scope: &NsScope) -> Option<&'a Element> {
    el.child_elements().find(|c| is_container(c, scope))
}

pub(crate) fn is_container(el: &Element, scope: &NsScope) -> bool {
    let scope = scope.extended(el);
    let (uri, local) = scope.resolve(&el.name);
    uri == Some(NS_RDF) && matches!(local, "Bag" | "Seq" | "Alt")
}

pub(crate) fn is_li(el: &Element, scope: &NsScope) -> bool {
    let scope = scope.extended(el);
    scope.matches(el, NS_RDF, "li")
}

/// Values of a list-valued property.
///
/// A property written without a container (`<dc:subject>Rome</dc:subject>`,
/// which some writers emit for single values) reads as a one-element list.
fn collect_list(el: &Element, outer: &NsScope) -> Vec<String> {
    let scope = outer.extended(el);
    match container_of(el, &scope) {
        Some(container) => {
            let inner = scope.extended(container);
            container
                .child_elements()
                .filter(|c| is_li(c, &inner))
                .map(|li| li.text())
                .filter(|v| !v.is_empty())
                .collect()
        }
        None => {
            let text = el.text();
            if text.is_empty() {
                Vec::new()
            } else {
                vec![text]
            }
        }
    }
}

fn collect_regions(region_list: &Element, outer: &NsScope) -> Vec<FaceRegion> {
    let scope = outer.extended(region_list);
    let Some(container) = container_of(region_list, &scope) else {
        return Vec::new();
    };
    let inner = scope.extended(container);
    container
        .child_elements()
        .filter(|c| is_li(c, &inner))
        .filter_map(|li| region_from_li(li, &inner))
        .collect()
}

/// `mwg-rs:AppliedToDimensions` in either serialization.
fn applied_dimensions(el: &Element, outer: &NsScope) -> Option<AppliedDimensions> {
    let scope = outer.extended(el);
    let num = |local: &str| {
        field_value(el, &scope, NS_ST_DIM, local).and_then(|v| v.trim().parse::<f64>().ok())
    };
    Some(AppliedDimensions {
        width: num("w")?,
        height: num("h")?,
        unit: field_value(el, &scope, NS_ST_DIM, "unit"),
    })
}

/// One region out of an `<rdf:li>`, in whichever serialization the writer used.
///
/// `pub(crate)` so [`crate::regions`] can pair a parsed region with the exact
/// `rdf:li` it came from — the merge has to decide about *elements*, not about
/// a flat list of values.
pub(crate) fn region_from_li(li: &Element, outer: &NsScope) -> Option<FaceRegion> {
    let scope = outer.extended(li);
    let (area, area_scope) = find_descendant(li, &scope, NS_MWG_RS, "Area")?;

    // `MetadataReader.parseMWGRegions` accepts a region with no explicit unit
    // but rejects a non-normalized one; match that so the two readers agree.
    let unit = field_value(area, &area_scope, NS_ST_AREA, "unit");
    if let Some(unit) = &unit {
        if !unit.eq_ignore_ascii_case("normalized") {
            return None;
        }
    }
    let num = |local: &str| {
        field_value(area, &area_scope, NS_ST_AREA, local).and_then(|v| v.trim().parse::<f64>().ok())
    };
    Some(FaceRegion {
        name: field_value(li, &scope, NS_MWG_RS, "Name"),
        kind: field_value(li, &scope, NS_MWG_RS, "Type"),
        center_x: num("x")?,
        center_y: num("y")?,
        width: num("w")?,
        height: num("h")?,
    })
}

/// A struct field in either serialization: an attribute on `el`, or a child
/// element anywhere beneath it.
fn field_value(el: &Element, scope: &NsScope, uri: &str, local: &str) -> Option<String> {
    for attr in el.attrs() {
        let (attr_uri, attr_local) = scope.resolve(&attr.name);
        if attr_uri == Some(uri) && attr_local == local {
            return Some(attr.value.clone());
        }
    }
    find_descendant(el, scope, uri, local).map(|(found, _)| found.text())
}

/// Depth-first search for a descendant element in a given namespace.
fn find_descendant<'a>(
    el: &'a Element,
    outer: &NsScope,
    uri: &str,
    local: &str,
) -> Option<(&'a Element, NsScope)> {
    let scope = outer.extended(el);
    for child in el.child_elements() {
        let child_scope = scope.extended(child);
        if child_scope.matches(child, uri, local) {
            return Some((child, child_scope));
        }
        if let Some(found) = find_descendant(child, &scope, uri, local) {
            return Some(found);
        }
    }
    None
}
