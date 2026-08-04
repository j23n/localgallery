//! `mwg-rs:RegionInfo` — reading, geometry, and the surgical edits the face
//! writer drives.
//!
//! # Whose regions are whose
//!
//! A sidecar's region list is shared property in exactly the way its keyword
//! list is: digiKam, Lightroom, Mylio and Apple Photos all write into it. The
//! crate therefore never treats "region in this file" as "region we may touch".
//! Ownership is recorded in `photo-tools:CoreRegions`
//! ([`crate::schema::PROP_CORE_REGIONS`]) — one claim per region we authored —
//! and a claim is matched against a region in the file **geometrically**, at
//! [`REGION_MATCH_IOU`].
//!
//! The match is **one claim to one region** ([`bind_claims`]): we wrote one box
//! per claim, so at most one box in the file can be that claim's. Anything else
//! overlapping it is a second tool's box on the same face, and stays.
//!
//! Geometry rather than name, on purpose. A name can be edited by the tool that
//! owns the file next (digiKam correcting a spelling), and matching on it would
//! orphan our claim: the region would then be nobody's, and the next write
//! would add a *second* box over the same face. Geometry survives a rename.
//! The reverse mistake — digiKam *moves* our box far enough that the IoU drops
//! — orphans the claim instead, which leaks a region rather than deleting one.
//! That is the direction this crate always errs in.
//!
//! # Merging with somebody else's regions
//!
//! For each region we want to write:
//!
//! * an existing region overlapping it above [`REGION_MATCH_IOU`] that we
//!   **own** is ours to update (name or box changed → rewrite it);
//! * an existing region overlapping it that we do **not** own is somebody
//!   else's box on the same face. It is left exactly as it is, and we do not
//!   add a duplicate beside it — two boxes on one face is worse for every
//!   consumer than a box with the wrong tool's name on it;
//! * no overlap at all → append.
//!
//! Foreign regions are never removed, never reordered, and never rewritten.
//!
//! # AppliedToDimensions
//!
//! MWG areas are *normalized*, so they carry no dependency on the dimensions
//! the file declares — 0.4 is 40% of the width whatever that width is said to
//! be. When a file already has an `AppliedToDimensions`, this crate therefore
//! leaves it alone and writes its normalized rectangles straight in; no
//! rescaling is possible or needed, and rewriting the declared size would be
//! editing somebody else's field for no gain. One case that genuinely is not
//! recoverable: a file whose declared dimensions have a different *aspect
//! ratio* from the image we measured (the photo was rotated after the regions
//! were written). There is no transform to apply without knowing which way it
//! turned, so the normalized values go in as measured — the same answer every
//! other MWG writer gives.
//!
//! When this crate creates the `RegionInfo` envelope itself, it writes an
//! `AppliedToDimensions` from the decoded image's pixel size — that is what
//! makes the block valid for readers that insist on it. It does **not** add one
//! to somebody else's envelope that lacks it. Declaring our image's size over
//! their regions would be asserting something about boxes we did not measure,
//! and if the file was rotated since they were written the assertion would be
//! wrong.

use crate::edit::{self, NodePath};
use crate::model::FaceRegion;
use crate::read::region_from_li;
use crate::schema::*;
use crate::xml::dom::Attr;
use crate::xml::{Document, Element, Node};

/// Overlap above which two regions are considered to be about the same face.
///
/// The Phase 2 plan's figure. It is a *strict* lower bound: `iou > 0.5` means
/// the two boxes agree on more than half of their union, which two different
/// faces in one photo essentially never do, and two tools boxing one face
/// essentially always do.
pub const REGION_MATCH_IOU: f64 = 0.5;

/// Decimal places every coordinate this crate writes is rounded to.
///
/// Six places is ~1/300 of a pixel on a 4000-pixel edge — far below anything a
/// detector resolves — and a fixed width is what makes the bytes of a re-run
/// identical to the bytes of the first run. Rust's float formatting is
/// correctly rounded and platform-independent, so the same `f64` prints the
/// same string on every device.
pub const COORD_PLACES: usize = 6;

/// A normalized MWG area: centre point and size, each 0…1.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Area {
    /// Centre X.
    pub x: f64,
    /// Centre Y.
    pub y: f64,
    /// Width.
    pub w: f64,
    /// Height.
    pub h: f64,
}

impl Area {
    /// An area clamped into the unit square.
    ///
    /// A detector box can hang off the edge of the image (a face at the
    /// margin), and a negative or >1 coordinate is out of spec for MWG — some
    /// readers drop the whole region over it. Clamping keeps the region, at the
    /// cost of a box that stops at the frame, which is what it looks like
    /// anyway.
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Area {
        let w = w.clamp(0.0, 1.0);
        let h = h.clamp(0.0, 1.0);
        Area {
            x: x.clamp(0.0, 1.0),
            y: y.clamp(0.0, 1.0),
            w,
            h,
        }
    }

    /// From pixel corners `[x0, y0, x1, y1]` and the image size they are in.
    ///
    /// Returns `None` for a degenerate image size or an empty box — a region
    /// with no area is not a face, and dividing by a zero dimension is not a
    /// number this crate is willing to write into somebody's sidecar.
    pub fn from_pixel_box(corners: [f64; 4], image_w: f64, image_h: f64) -> Option<Area> {
        if !(image_w > 0.0 && image_h > 0.0) {
            return None;
        }
        let [x0, y0, x1, y1] = corners;
        let (left, right) = if x0 <= x1 { (x0, x1) } else { (x1, x0) };
        let (top, bottom) = if y0 <= y1 { (y0, y1) } else { (y1, y0) };
        let area = Area::new(
            ((left + right) / 2.0) / image_w,
            ((top + bottom) / 2.0) / image_h,
            (right - left) / image_w,
            (bottom - top) / image_h,
        );
        if area.w <= 0.0 || area.h <= 0.0 || !area.is_finite() {
            return None;
        }
        Some(area)
    }

    /// The area of a parsed region.
    pub fn of(region: &FaceRegion) -> Area {
        Area {
            x: region.center_x,
            y: region.center_y,
            w: region.width,
            h: region.height,
        }
    }

    fn is_finite(&self) -> bool {
        self.x.is_finite() && self.y.is_finite() && self.w.is_finite() && self.h.is_finite()
    }

    /// `(left, top, right, bottom)`.
    fn corners(&self) -> (f64, f64, f64, f64) {
        (
            self.x - self.w / 2.0,
            self.y - self.h / 2.0,
            self.x + self.w / 2.0,
            self.y + self.h / 2.0,
        )
    }

    /// Intersection over union with `other`; 0 when they do not overlap.
    pub fn iou(&self, other: &Area) -> f64 {
        let (al, at, ar, ab) = self.corners();
        let (bl, bt, br, bb) = other.corners();
        let iw = (ar.min(br) - al.max(bl)).max(0.0);
        let ih = (ab.min(bb) - at.max(bt)).max(0.0);
        let inter = iw * ih;
        let union = self.w * self.h + other.w * other.h - inter;
        if union <= 0.0 {
            return 0.0;
        }
        inter / union
    }

    /// Whether the two boxes are about the same face.
    pub fn matches(&self, other: &Area) -> bool {
        self.iou(other) > REGION_MATCH_IOU
    }

    /// The four coordinates as this crate writes them: `x,y,w,h`.
    pub fn to_claim_coords(self) -> String {
        format!(
            "{},{},{},{}",
            fmt(self.x),
            fmt(self.y),
            fmt(self.w),
            fmt(self.h)
        )
    }
}

/// One coordinate, formatted the one way this crate ever formats one.
pub fn fmt(value: f64) -> String {
    format!("{value:.COORD_PLACES$}")
}

/// A face region the core wants in a sidecar.
#[derive(Debug, Clone, PartialEq)]
pub struct FaceRegionWrite {
    /// Person name; already through [`crate::tags::normalize_person`].
    pub name: String,
    /// Where the face is.
    pub area: Area,
}

impl FaceRegionWrite {
    /// The `CoreRegions` claim for this region: the coordinates exactly as they
    /// will be written, a space, then the name.
    ///
    /// The coordinates come first and are fixed-width, so the split is
    /// unambiguous even though a name may contain spaces.
    pub fn claim(&self) -> String {
        format!("{} {}", self.area.to_claim_coords(), self.name)
    }
}

/// A `CoreRegions` entry, parsed back.
#[derive(Debug, Clone, PartialEq)]
pub struct RegionClaim {
    /// Where we put the region when we wrote it.
    pub area: Area,
    /// The name we gave it. May since have been edited in the file.
    pub name: String,
}

/// Parse one `CoreRegions` entry. `None` for anything malformed — a claim we
/// cannot read is a claim we do not act on, which leaks a region rather than
/// deleting an unrelated one.
pub fn parse_claim(entry: &str) -> Option<RegionClaim> {
    let (coords, name) = entry.trim().split_once(' ')?;
    let mut parts = coords.split(',');
    let mut next = || parts.next()?.trim().parse::<f64>().ok();
    let (x, y, w, h) = (next()?, next()?, next()?, next()?);
    if parts.next().is_some() {
        return None;
    }
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    Some(RegionClaim {
        area: Area { x, y, w, h },
        name: name.to_string(),
    })
}

/// Bind claims to regions **one to one**, and say which claim owns each region.
///
/// Returns one entry per element of `regions`: the index of the claim that owns
/// it, or `None` for a region nobody claimed.
///
/// The one-to-one part is the whole point. Two tools boxing the same face
/// produce two regions that both clear [`REGION_MATCH_IOU`] against our single
/// claim, and a per-region "does any claim match" test answers *yes* for both —
/// which makes digiKam's box look like ours and hands it to the retraction
/// path. We wrote one region, so at most one region can be ours: each claim is
/// consumed once, by the region it overlaps best, and everything left over is
/// somebody else's.
///
/// Greedy by descending overlap, ties broken by index, so the binding is a
/// function of its inputs and not of the sort's stability. Greedy rather than
/// optimal (Hungarian): the inputs are a handful of boxes, ties above 0.5 IoU
/// mean two near-identical rectangles either of which is the right answer, and
/// an assignment algorithm here would be precision nobody can observe.
pub fn bind_claims(claims: &[RegionClaim], regions: &[FaceRegion]) -> Vec<Option<usize>> {
    let mut pairs: Vec<(f64, usize, usize)> = Vec::new();
    for (ci, claim) in claims.iter().enumerate() {
        for (ri, region) in regions.iter().enumerate() {
            let iou = claim.area.iou(&Area::of(region));
            if iou > REGION_MATCH_IOU {
                pairs.push((iou, ci, ri));
            }
        }
    }
    pairs.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.1.cmp(&b.1))
            .then_with(|| a.2.cmp(&b.2))
    });

    let mut owner: Vec<Option<usize>> = vec![None; regions.len()];
    let mut claim_taken = vec![false; claims.len()];
    for (_, ci, ri) in pairs {
        if claim_taken[ci] || owner[ri].is_some() {
            continue;
        }
        claim_taken[ci] = true;
        owner[ri] = Some(ci);
    }
    owner
}

// ---------------------------------------------------------------------------
// DOM
// ---------------------------------------------------------------------------

/// The namespaces an authored region block needs bound.
fn region_bindings() -> [(&'static str, &'static str); 3] {
    [
        (PREFIX_MWG_RS, NS_MWG_RS),
        (PREFIX_ST_AREA, NS_ST_AREA),
        (PREFIX_ST_DIM, NS_ST_DIM),
    ]
}

/// Paths into a document's region block.
pub(crate) struct RegionPaths {
    /// The `mwg-rs:Regions` property.
    pub regions: NodePath,
    /// The `rdf:Bag` inside `mwg-rs:RegionList`.
    pub container: NodePath,
}

/// Locate the `rdf:Bag` of regions, without creating anything.
pub(crate) fn find_region_container(doc: &Document, root: &[usize]) -> Option<NodePath> {
    let regions = edit::find_property(doc, root, NS_MWG_RS, PROP_REGIONS)?;
    let list = edit::child_property(doc, &regions, NS_MWG_RS, PROP_REGION_LIST)?;
    let scope = edit::scope_at(doc, &list);
    let el = edit::element_at(doc, &list)?;
    let index = el.children.iter().position(|n| {
        n.as_element()
            .is_some_and(|c| crate::read::is_container(c, &scope))
    })?;
    let mut path = list;
    path.push(index);
    Some(path)
}

/// Locate — creating what is missing — the region bag.
///
/// `AppliedToDimensions` is established from `dimensions` only when this call
/// creates the envelope; see the module docs for why a foreign envelope without
/// one is left without one.
pub(crate) fn ensure_region_container(
    doc: &mut Document,
    root: &[usize],
    dimensions: Option<(u32, u32)>,
) -> RegionPaths {
    let envelope_existed = edit::find_property(doc, root, NS_MWG_RS, PROP_REGIONS).is_some();
    let regions = edit::ensure_struct_property(doc, root, PROP_REGIONS, &region_bindings());
    mark_resource(doc, &regions);

    let mwg = edit::ensure_ns_binding(doc, &regions, NS_MWG_RS, PREFIX_MWG_RS);

    if !envelope_existed {
        if let Some((w, h)) = dimensions.filter(|(w, h)| *w > 0 && *h > 0) {
            let dim = edit::ensure_ns_binding(doc, &regions, NS_ST_DIM, PREFIX_ST_DIM);
            let indent = edit::child_indent(&regions);
            let el = struct_element(
                &format!("{mwg}:{PROP_APPLIED_TO_DIMENSIONS}"),
                &[
                    (format!("{dim}:w"), w.to_string()),
                    (format!("{dim}:h"), h.to_string()),
                    (format!("{dim}:unit"), DIM_UNIT_PIXEL.to_string()),
                ],
                indent,
            );
            edit::append_child_element(doc, &regions, el);
        }
    }

    let list = match edit::child_property(doc, &regions, NS_MWG_RS, PROP_REGION_LIST) {
        Some(path) => path,
        None => {
            let el = Element::new(format!("{mwg}:{PROP_REGION_LIST}"));
            edit::append_child_element(doc, &regions, el)
        }
    };
    let container = edit::ensure_container(doc, &list, "Bag");
    RegionPaths { regions, container }
}

/// Every region in the bag, paired with nothing — position is implicit in the
/// order, which is document order.
pub(crate) fn regions_in(doc: &Document, container_path: &[usize]) -> Vec<FaceRegion> {
    let scope = edit::scope_at(doc, container_path);
    let Some(container) = edit::element_at(doc, container_path) else {
        return Vec::new();
    };
    container
        .child_elements()
        .filter(|c| crate::read::is_li(c, &scope))
        .filter_map(|li| region_from_li(li, &scope))
        .collect()
}

/// Remove every region whose area is one of `doomed`.
///
/// Matching is on the *identical* area, not on IoU: the areas were read out of
/// this very document a moment ago, so they compare equal bit for bit, and an
/// IoU test here could take a neighbouring foreign region with them.
pub(crate) fn remove_regions(doc: &mut Document, container_path: &[usize], doomed: &[Area]) {
    if doomed.is_empty() {
        return;
    }
    edit::remove_li_elements(doc, container_path, &|li, scope| {
        let Some(region) = region_from_li(li, scope) else {
            return false;
        };
        let area = Area::of(&region);
        doomed.iter().any(|d| {
            (d.x - area.x).abs() < 1e-12
                && (d.y - area.y).abs() < 1e-12
                && (d.w - area.w).abs() < 1e-12
                && (d.h - area.h).abs() < 1e-12
        })
    });
}

/// Append one region, in digiKam's field order.
///
/// **Name, Type, Area — never exiftool's alphabetical Area, Name, Type.**
/// `MetadataReader.parseMWGRegions` finds a region's name by scanning
/// *backwards* from `<mwg-rs:Area`, so with the alphabetical order every
/// region in the file is labelled with its predecessor's name and the first is
/// unnamed (see `tests/metadata_reader_parity.rs`). Writing the order digiKam
/// writes is what makes the app read our people correctly, and costs nothing —
/// exiftool, our own reader and digiKam are all order-blind.
pub(crate) fn append_region(doc: &mut Document, paths: &RegionPaths, region: &FaceRegionWrite) {
    let mwg = edit::ensure_ns_binding(doc, &paths.regions, NS_MWG_RS, PREFIX_MWG_RS);
    let area_prefix = edit::ensure_ns_binding(doc, &paths.regions, NS_ST_AREA, PREFIX_ST_AREA);

    let li_indent = edit::child_indent(&paths.container);
    let field_indent = li_indent + 1;

    let area = struct_element(
        &format!("{mwg}:{PROP_AREA}"),
        &[
            (format!("{area_prefix}:x"), fmt(region.area.x)),
            (format!("{area_prefix}:y"), fmt(region.area.y)),
            (format!("{area_prefix}:w"), fmt(region.area.w)),
            (format!("{area_prefix}:h"), fmt(region.area.h)),
            (
                format!("{area_prefix}:unit"),
                AREA_UNIT_NORMALIZED.to_string(),
            ),
        ],
        field_indent,
    );

    let mut li = Element::new("rdf:li");
    li.push_attr(Attr::new("rdf:parseType", "Resource"));
    push_line(
        &mut li,
        field_indent,
        text_element(&format!("{mwg}:{PROP_REGION_NAME}"), &region.name),
    );
    push_line(
        &mut li,
        field_indent,
        text_element(&format!("{mwg}:{PROP_REGION_TYPE}"), REGION_TYPE_FACE),
    );
    push_line(&mut li, field_indent, area);
    li.push_child(Node::Text(edit::indent_text(li_indent)));

    edit::append_li_element(doc, &paths.container, li);
}

/// Drop the whole `mwg-rs:Regions` property when its list has been emptied.
///
/// exiftool reads a container with no `rdf:li` as the whitespace between its
/// tags, so an emptied list surfaces as a garbage string rather than as absent.
pub(crate) fn prune_empty_regions(doc: &mut Document, paths: &RegionPaths) {
    if !regions_in(doc, &paths.container).is_empty() {
        return;
    }
    edit::remove_property(doc, &paths.regions);
}

/// `<name attrs…>` with `rdf:parseType='Resource'` and one text child per field.
fn struct_element(name: &str, fields: &[(String, String)], indent: usize) -> Element {
    let mut el = Element::new(name);
    el.push_attr(Attr::new("rdf:parseType", "Resource"));
    for (field, value) in fields {
        push_line(&mut el, indent + 1, text_element(field, value));
    }
    el.push_child(Node::Text(edit::indent_text(indent)));
    el
}

fn text_element(name: &str, value: &str) -> Element {
    let mut el = Element::new(name);
    el.set_text(value);
    el
}

fn push_line(parent: &mut Element, indent: usize, child: Element) {
    parent.push_child(Node::Text(edit::indent_text(indent)));
    parent.push_child(Node::Element(child));
}

/// Give a struct-valued property `rdf:parseType='Resource'` if it has neither
/// that nor any content yet — i.e. if we just created it.
fn mark_resource(doc: &mut Document, path: &[usize]) {
    let needs = edit::element_at(doc, path).is_some_and(|el| {
        el.child_elements().next().is_none()
            && !el
                .attrs()
                .iter()
                .any(|a| crate::xml::dom::local_part(&a.name) == "parseType")
    });
    if needs {
        if let Some(el) = edit::element_at_mut(doc, path) {
            el.set_attr("rdf:parseType", "Resource");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn area(x: f64, y: f64, w: f64, h: f64) -> Area {
        Area::new(x, y, w, h)
    }

    #[test]
    fn identical_boxes_have_an_iou_of_one() {
        let a = area(0.5, 0.5, 0.2, 0.2);
        assert!((a.iou(&a) - 1.0).abs() < 1e-12);
        assert!(a.matches(&a));
    }

    #[test]
    fn disjoint_boxes_do_not_match() {
        let a = area(0.2, 0.2, 0.1, 0.1);
        let b = area(0.8, 0.8, 0.1, 0.1);
        assert_eq!(a.iou(&b), 0.0);
        assert!(!a.matches(&b));
    }

    #[test]
    fn the_match_threshold_is_strictly_above_a_half() {
        // Two equal boxes offset so the intersection is exactly 1/3 of the
        // union: below the bar. Then a much smaller offset: above it.
        let a = area(0.5, 0.5, 0.2, 0.2);
        let half = area(0.6, 0.5, 0.2, 0.2);
        assert!(half.iou(&a) < REGION_MATCH_IOU, "{}", half.iou(&a));
        let close = area(0.51, 0.5, 0.2, 0.2);
        assert!(close.matches(&a), "{}", close.iou(&a));
    }

    #[test]
    fn a_box_of_no_area_never_matches_anything() {
        let empty = Area {
            x: 0.5,
            y: 0.5,
            w: 0.0,
            h: 0.0,
        };
        assert_eq!(empty.iou(&empty), 0.0);
    }

    #[test]
    fn pixel_boxes_become_centre_form() {
        let a = Area::from_pixel_box([100.0, 200.0, 300.0, 600.0], 1000.0, 2000.0).unwrap();
        assert!((a.x - 0.2).abs() < 1e-12);
        assert!((a.y - 0.2).abs() < 1e-12);
        assert!((a.w - 0.2).abs() < 1e-12);
        assert!((a.h - 0.2).abs() < 1e-12);
    }

    #[test]
    fn a_pixel_box_with_swapped_corners_still_comes_out_right_way_up() {
        let a = Area::from_pixel_box([300.0, 600.0, 100.0, 200.0], 1000.0, 2000.0).unwrap();
        assert!(a.w > 0.0 && a.h > 0.0);
        assert!((a.x - 0.2).abs() < 1e-12);
    }

    #[test]
    fn degenerate_pixel_boxes_are_refused() {
        assert!(Area::from_pixel_box([0.0, 0.0, 10.0, 10.0], 0.0, 100.0).is_none());
        assert!(Area::from_pixel_box([10.0, 10.0, 10.0, 10.0], 100.0, 100.0).is_none());
    }

    #[test]
    fn a_box_hanging_off_the_frame_is_clamped_rather_than_dropped() {
        let a = Area::new(-0.1, 1.4, 0.3, 0.2);
        assert_eq!(a.x, 0.0);
        assert_eq!(a.y, 1.0);
    }

    #[test]
    fn claims_round_trip_through_their_text_form() {
        let write = FaceRegionWrite {
            name: "Ada Lovelace".to_string(),
            area: area(0.4, 0.35, 0.12, 0.16),
        };
        let claim = write.claim();
        assert_eq!(claim, "0.400000,0.350000,0.120000,0.160000 Ada Lovelace");
        let parsed = parse_claim(&claim).unwrap();
        assert_eq!(parsed.name, "Ada Lovelace");
        assert!(parsed.area.matches(&write.area));
    }

    #[test]
    fn malformed_claims_parse_to_nothing_rather_than_to_something_wrong() {
        for bad in [
            "",
            "Alice",
            "0.1,0.2,0.3 Alice",
            "0.1,0.2,0.3,0.4,0.5 Alice",
            "0.1,0.2,0.3,x Alice",
            "0.1,0.2,0.3,0.4 ",
        ] {
            assert!(parse_claim(bad).is_none(), "{bad:?} should not parse");
        }
    }

    fn face_at(x: f64, y: f64, w: f64, h: f64) -> FaceRegion {
        FaceRegion {
            name: None,
            kind: Some("Face".into()),
            center_x: x,
            center_y: y,
            width: w,
            height: h,
        }
    }

    /// The bug this function exists for: our box and digiKam's box over one
    /// face both clear the IoU bar against our single claim. Only one of them
    /// can be ours.
    #[test]
    fn one_claim_binds_to_one_region_not_to_every_overlapping_one() {
        let claim = parse_claim("0.400000,0.350000,0.120000,0.160000 Alice").unwrap();
        let ours = face_at(0.4, 0.35, 0.12, 0.16);
        let digikam = face_at(0.405, 0.352, 0.125, 0.163);
        assert!(
            Area::of(&digikam).matches(&claim.area),
            "the fixture must actually overlap, or it tests nothing"
        );

        let owner = bind_claims(
            std::slice::from_ref(&claim),
            &[ours.clone(), digikam.clone()],
        );
        assert_eq!(owner, vec![Some(0), None], "the better overlap wins");

        // And the order the regions appear in the file cannot change the answer.
        let owner = bind_claims(&[claim], &[digikam, ours]);
        assert_eq!(owner, vec![None, Some(0)]);
    }

    #[test]
    fn two_claims_over_two_faces_bind_to_their_own_boxes() {
        let a = parse_claim("0.200000,0.200000,0.100000,0.100000 Alice").unwrap();
        let b = parse_claim("0.800000,0.800000,0.100000,0.100000 Bob").unwrap();
        let owner = bind_claims(
            &[a, b],
            &[face_at(0.8, 0.8, 0.1, 0.1), face_at(0.2, 0.2, 0.1, 0.1)],
        );
        assert_eq!(owner, vec![Some(1), Some(0)]);
    }

    #[test]
    fn a_claim_whose_region_is_gone_binds_to_nothing() {
        let a = parse_claim("0.200000,0.200000,0.100000,0.100000 Alice").unwrap();
        assert_eq!(
            bind_claims(&[a], &[face_at(0.8, 0.8, 0.1, 0.1)]),
            vec![None]
        );
    }

    #[test]
    fn coordinates_format_to_a_fixed_width() {
        assert_eq!(fmt(0.4), "0.400000");
        assert_eq!(fmt(1.0), "1.000000");
        assert_eq!(fmt(0.123_456_789), "0.123457");
    }
}
