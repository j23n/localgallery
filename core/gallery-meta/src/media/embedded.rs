//! Embedded XMP, read the way ImageIO surfaces it — which is not the way it
//! was written.
//!
//! `MetadataReader` reads an embedded packet through two different doors, and
//! they behave differently:
//!
//! | field | door | consequence |
//! |---|---|---|
//! | tags, country | `CGImageMetadataCopyTags` | matched by **leaf name**, so any namespace declaring `TagsList` or `CountryCode` competes |
//! | regions | `CGImageMetadataCreateXMPData` → the sidecar string parser | ImageIO **re-serialises struct fields alphabetically**, so `Area` always precedes `Name` |
//!
//! That second row is the one that matters. Because the packet is rebuilt
//! before the string parser sees it, the order it was *written* in is erased —
//! and the rebuilt order is precisely the one that breaks the parser's
//! backwards name search. **Every** embedded region in this app comes back
//! shifted: the first unnamed, each later one wearing its predecessor's name,
//! the last name lost. `assets/xmp/regions_digikam_order.jpg` and
//! `…_exiftool_order.jpg` are the same regions written in opposite orders and
//! they produce identical, identically-wrong output.
//!
//! So this module does not read regions out of the packet directly. It parses
//! them properly, re-serialises them the way ImageIO would, and runs the same
//! string parser the sidecar path runs — reproducing the shift by construction
//! rather than by hard-coding an off-by-one.

use crate::read::view_of;
use crate::xml::dom::local_part;
use crate::xml::{escape_text, parse, Element};

use super::swift_xmp::{parse_mwg_regions, SwiftFaceRegion};

/// What the app gets out of an embedded packet.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct EmbeddedXmp {
    /// Every `TagsList` value, in document order.
    pub raw_tags: Vec<String>,
    /// First non-empty `CountryCode`, uppercased.
    pub country_code: Option<String>,
    /// Regions, with the ImageIO name shift applied.
    pub face_regions: Vec<SwiftFaceRegion>,
}

/// Read an embedded packet. A packet that does not parse yields nothing —
/// there is no error surface on this path and never has been.
pub fn read_embedded_xmp(packet: &[u8]) -> EmbeddedXmp {
    let Ok(doc) = parse(packet) else {
        return EmbeddedXmp::default();
    };

    let mut out = EmbeddedXmp::default();
    for node in &doc.nodes {
        if let Some(el) = node.as_element() {
            collect_by_leaf_name(el, &mut out);
        }
    }
    out.face_regions = parse_mwg_regions(&imageio_serialized_regions(&doc));
    out
}

/// Walk the tree collecting properties by **leaf name only**.
///
/// This is the part of ImageIO's behaviour the app depends on without meaning
/// to: `CGImageMetadataTagCopyName` returns the local name, and
/// `MetadataReader` compares it to `"TagsList"` / `"CountryCode"`. IPTC's
/// `Iptc4xmpCore:CountryCode` is therefore an equally valid candidate to
/// `photo-tools:CountryCode`, and whichever is enumerated first wins
/// (`assets/xmp/country_code_namespace_conflict.jpg`). Document order is this
/// port's reading of "first enumerated"; the fixture agrees with it, and there
/// is no other order to observe from outside ImageIO.
fn collect_by_leaf_name(el: &Element, out: &mut EmbeddedXmp) {
    for attr in el.attrs() {
        if attr.name.starts_with("xmlns") {
            continue;
        }
        match local_part(&attr.name) {
            "TagsList" => push_tag(&mut out.raw_tags, &attr.value),
            "CountryCode" => set_country(&mut out.country_code, &attr.value),
            _ => {}
        }
    }
    match el.local_name() {
        "TagsList" => {
            for value in list_values(el) {
                push_tag(&mut out.raw_tags, &value);
            }
            return;
        }
        "CountryCode" => {
            set_country(&mut out.country_code, &el.text());
            return;
        }
        _ => {}
    }
    for child in el.child_elements() {
        collect_by_leaf_name(child, out);
    }
}

fn push_tag(tags: &mut Vec<String>, raw: &str) {
    let value = raw.trim();
    if !value.is_empty() {
        tags.push(value.to_string());
    }
}

/// `countryCode == nil` guards the assignment, so the first non-empty value
/// wins and later ones are ignored. Uppercased on read.
fn set_country(slot: &mut Option<String>, raw: &str) {
    if slot.is_some() {
        return;
    }
    let value = raw.trim();
    if !value.is_empty() {
        *slot = Some(value.to_uppercase());
    }
}

/// `rdf:li` texts of a list-valued property, or the element's own text when it
/// was written without a container.
fn list_values(el: &Element) -> Vec<String> {
    let container = el
        .child_elements()
        .find(|c| matches!(local_part(&c.name), "Bag" | "Seq" | "Alt"));
    match container {
        Some(container) => container
            .child_elements()
            .filter(|c| local_part(&c.name) == "li")
            .map(Element::text)
            .collect(),
        None => vec![el.text()],
    }
}

/// Rebuild the packet's regions in ImageIO's canonical shape: struct fields in
/// alphabetical order (`Area`, `Name`, `Type`), attributes likewise.
///
/// The regions themselves are read by [`crate::read`], i.e. properly, by
/// namespace URI and in either serialisation — which is also what ImageIO's
/// own parse does. Only the *output* order is a model of ImageIO, and it is
/// the only part the string parser can see.
fn imageio_serialized_regions(doc: &crate::xml::Document) -> String {
    let view = view_of(doc);
    if view.regions.is_empty() {
        return String::new();
    }
    let mut out = String::from("<mwg-rs:Regions><mwg-rs:RegionList><rdf:Seq>");
    for region in &view.regions {
        out.push_str("<rdf:li rdf:parseType=\"Resource\">");
        out.push_str(&format!(
            "<mwg-rs:Area stArea:h=\"{}\" stArea:unit=\"normalized\" stArea:w=\"{}\" \
             stArea:x=\"{}\" stArea:y=\"{}\"/>",
            region.height, region.width, region.center_x, region.center_y
        ));
        if let Some(name) = &region.name {
            out.push_str(&format!("<mwg-rs:Name>{}</mwg-rs:Name>", escape_text(name)));
        }
        if let Some(kind) = &region.kind {
            out.push_str(&format!("<mwg-rs:Type>{}</mwg-rs:Type>", escape_text(kind)));
        }
        out.push_str("</rdf:li>");
    }
    out.push_str("</rdf:Seq></mwg-rs:RegionList></mwg-rs:Regions>");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const NS: &str = "xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#' \
         xmlns:digiKam='http://www.digikam.org/ns/1.0/' \
         xmlns:dk='http://example.invalid/other/' \
         xmlns:photo-tools='https://github.com/j23n/photo-tools/ns/1.0/' \
         xmlns:Iptc4xmpCore='http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/' \
         xmlns:mwg-rs='http://www.metadataworkinggroup.com/schemas/regions/' \
         xmlns:stArea='http://ns.adobe.com/xmp/sType/Area#'";

    fn packet(body: &str) -> String {
        format!("<rdf:RDF {NS}><rdf:Description rdf:about=''>{body}</rdf:Description></rdf:RDF>")
    }

    fn region_li(name: &str, x: &str, y: &str, w: &str, h: &str, name_first: bool) -> String {
        let area = format!(
            "<mwg-rs:Area stArea:x='{x}' stArea:y='{y}' stArea:w='{w}' stArea:h='{h}' \
             stArea:unit='normalized'/>"
        );
        let name = format!("<mwg-rs:Name>{name}</mwg-rs:Name><mwg-rs:Type>Face</mwg-rs:Type>");
        let inner = if name_first {
            format!("{name}{area}")
        } else {
            format!("{area}{name}")
        };
        format!("<rdf:li rdf:parseType='Resource'>{inner}</rdf:li>")
    }

    fn regions(name_first: bool) -> String {
        packet(&format!(
            "<mwg-rs:Regions rdf:parseType='Resource'><mwg-rs:RegionList><rdf:Seq>{}{}\
             </rdf:Seq></mwg-rs:RegionList></mwg-rs:Regions>",
            region_li("Alice", "0.25", "0.30", "0.10", "0.12", name_first),
            region_li("Bob", "0.60", "0.32", "0.11", "0.13", name_first),
        ))
    }

    #[test]
    fn the_written_field_order_is_erased_and_both_come_back_shifted() {
        let digikam = read_embedded_xmp(regions(true).as_bytes());
        let exiftool = read_embedded_xmp(regions(false).as_bytes());
        assert_eq!(
            digikam.face_regions, exiftool.face_regions,
            "ImageIO re-serialises, so the input order cannot survive"
        );
        let named: Vec<Option<&str>> = digikam
            .face_regions
            .iter()
            .map(|r| r.name.as_deref())
            .collect();
        assert_eq!(
            named,
            vec![None, Some("Alice")],
            "region 0 is unnamed and Bob's name is lost — the pinned bug"
        );
        assert_eq!(digikam.face_regions[0].center_x, 0.25);
        assert_eq!(digikam.face_regions[1].center_x, 0.6);
    }

    #[test]
    fn tags_are_matched_by_leaf_name_across_namespaces() {
        // `dk:` is a completely unrelated namespace that happens to declare a
        // `TagsList`. ImageIO surfaces its leaf name, so the app reads it.
        let xmp = packet(
            "<digiKam:TagsList><rdf:Seq><rdf:li>People/Alice</rdf:li></rdf:Seq></digiKam:TagsList>\
             <dk:TagsList><rdf:Seq><rdf:li>People/Bob</rdf:li></rdf:Seq></dk:TagsList>",
        );
        assert_eq!(
            read_embedded_xmp(xmp.as_bytes()).raw_tags,
            vec!["People/Alice", "People/Bob"]
        );
    }

    #[test]
    fn the_first_country_code_enumerated_wins_and_is_uppercased() {
        let xmp = packet(
            "<photo-tools:CountryCode>it</photo-tools:CountryCode>\
             <Iptc4xmpCore:CountryCode>FR</Iptc4xmpCore:CountryCode>",
        );
        assert_eq!(
            read_embedded_xmp(xmp.as_bytes()).country_code.as_deref(),
            Some("IT")
        );
    }

    #[test]
    fn a_packet_that_does_not_parse_yields_nothing() {
        assert_eq!(
            read_embedded_xmp(b"<not xml at all"),
            EmbeddedXmp::default()
        );
    }
}
