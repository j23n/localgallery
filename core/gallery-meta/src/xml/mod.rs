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
    fn unclosed_elements_are_closed_rather_than_dropped() {
        let doc = parse(b"<a><b>x").unwrap();
        let a = doc.nodes[0].as_element().unwrap();
        assert_eq!(a.name, "a");
        assert_eq!(a.child_elements().count(), 1);
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
