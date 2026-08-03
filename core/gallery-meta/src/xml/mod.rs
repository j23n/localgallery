//! Preservation-first XML: a tree, a parser, a serializer, namespace scoping.

pub mod dom;
pub mod ns;
mod parse;
mod serialize;

pub use dom::{Attr, Document, Element, Node};
pub use ns::NsScope;
pub use parse::parse;
pub use serialize::serialize;

/// Unescape XML text/attribute content.
///
/// Falls back to the raw string on anything unrecognised (a dangling `&`, an
/// entity from a DTD we never saw). Preservation beats correctness here: the
/// raw form is what gets written back out either way.
pub fn unescape_text(raw: &str) -> String {
    match quick_xml::escape::unescape(raw) {
        Ok(cow) => cow.into_owned(),
        Err(_) => raw.to_string(),
    }
}

/// Escape a string for use as element text.
///
/// Only the three characters that must be escaped in content are touched, so
/// values we author look like exiftool's (which does the same).
pub fn escape_text(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(src: &str) -> String {
        let doc = parse(src.as_bytes()).expect("parse");
        String::from_utf8(serialize(&doc)).expect("utf8")
    }

    #[test]
    fn unmodified_documents_round_trip_byte_for_byte() {
        for src in [
            "<a/>",
            "<a></a>",
            "<a b='1' c=\"2\"/>",
            "<a>\n  <b>text</b>\n</a>\n",
            "<?xpacket begin='\u{feff}' id='W5M0Mp'?>\n<x:xmpmeta xmlns:x='adobe:ns:meta/'>\n</x:xmpmeta>\n<?xpacket end='w'?>",
            "<a><!-- keep me --><![CDATA[<raw>]]></a>",
            "<a>Rome &amp; Lazio &#xE9; &lt;b&gt;</a>",
            "<a\n  b='1'\n  c='2'>x</a>",
            "<?xml version='1.0'?><a/>",
            // The space after DOCTYPE is mandatory, and the spacing inside is
            // the author's; both have to come back byte for byte.
            "<!DOCTYPE x><a/>",
            "<!DOCTYPE  x  ><a/>",
            "<?xml version='1.0'?>\n<!DOCTYPE xmpmeta SYSTEM 'xmp.dtd'>\n<a/>\n",
            "<!DOCTYPE a [<!ENTITY e 'x'>]>\n<a/>",
            // A UTF-8 BOM is not part of the XML, but it is part of the file.
            "\u{feff}<a/>",
            "\u{feff}<?xml version='1.0'?>\n<a>x</a>\n",
        ] {
            assert_eq!(round_trip(src), src, "round trip changed:\n{src}");
        }
    }

    #[test]
    fn entity_references_rejoin_their_text_node() {
        let doc = parse(b"<a>Rome &amp; Lazio</a>").unwrap();
        let root = doc.nodes[0].as_element().unwrap();
        assert_eq!(root.children.len(), 1);
        assert_eq!(root.text(), "Rome & Lazio");
    }

    #[test]
    fn attribute_values_are_decoded_but_re_emitted_verbatim() {
        let doc = parse(b"<a t='x &amp; y'/>").unwrap();
        let root = doc.nodes[0].as_element().unwrap();
        assert_eq!(root.attr("t"), Some("x & y"));
        assert_eq!(
            String::from_utf8(serialize(&doc)).unwrap(),
            "<a t='x &amp; y'/>"
        );
    }

    #[test]
    fn mutating_an_attribute_re_serializes_the_whole_tag() {
        let mut doc = parse(b"<a t=\"1\" u=\"2\"/>").unwrap();
        doc.nodes[0].as_element_mut().unwrap().set_attr("t", "9");
        assert_eq!(
            String::from_utf8(serialize(&doc)).unwrap(),
            "<a t=\"9\" u=\"2\"/>"
        );
    }

    #[test]
    fn authored_text_is_escaped() {
        let mut el = Element::new("dc:title");
        el.set_text("Fish & <Chips>");
        let doc = Document {
            nodes: vec![Node::Element(el)],
        };
        assert_eq!(
            String::from_utf8(serialize(&doc)).unwrap(),
            "<dc:title>Fish &amp; &lt;Chips&gt;</dc:title>"
        );
    }

    #[test]
    fn unclosed_elements_at_eof_are_a_parse_error() {
        // Auto-closing would let a truncated file parse clean and then be
        // rewritten in its amputated form — a permanent, silent loss.
        let err = parse(b"<a><b>x").unwrap_err();
        assert!(
            matches!(err, crate::error::MetaError::MalformedXml { .. }),
            "{err:?}"
        );
    }

    #[test]
    fn a_sidecar_truncated_mid_document_is_refused() {
        let whole = "<?xpacket begin='' id='W5M0Mp'?>\n<x:xmpmeta xmlns:x='adobe:ns:meta/'>\n <rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>\n  <rdf:Description rdf:about=''/>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>\n";
        assert!(parse(whole.as_bytes()).is_ok());
        let cut = &whole[..whole.find("</rdf:RDF>").unwrap()];
        let err = parse(cut.as_bytes()).unwrap_err();
        assert!(
            matches!(err, crate::error::MetaError::MalformedXml { .. }),
            "{err:?}"
        );
    }

    #[test]
    fn pathologically_deep_nesting_is_refused_instead_of_overflowing_the_stack() {
        // 20k levels is 140 KB of `<a>`. Every walk over the tree is recursive
        // — including the derived Drop — so without a cap this aborts the
        // process rather than failing the row.
        let depth = 20_000;
        let mut src = String::with_capacity(depth * 8);
        src.push_str(&"<a>".repeat(depth));
        src.push_str(&"</a>".repeat(depth));
        let err = parse(src.as_bytes()).unwrap_err();
        assert!(
            matches!(err, crate::error::MetaError::MalformedXml { .. }),
            "{err:?}"
        );

        // Real XMP nests about ten deep; that must keep working.
        let ok = format!("{}{}", "<a>".repeat(20), "</a>".repeat(20));
        assert!(parse(ok.as_bytes()).is_ok());
    }

    #[test]
    fn utf16_input_is_refused_rather_than_transcoded() {
        let err = parse(&[0xFF, 0xFE, 0x3C, 0x00]).unwrap_err();
        assert!(matches!(
            err,
            crate::error::MetaError::UnsupportedEncoding { .. }
        ));
    }
}
