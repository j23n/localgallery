//! [`Document`] → bytes. The inverse of [`super::parse`], byte-for-byte for
//! any document that was not mutated.

use super::dom::{Document, Element, Node, QUOTE_DOUBLE};

/// Serialize a document.
pub fn serialize(doc: &Document) -> Vec<u8> {
    let mut out = String::new();
    for node in &doc.nodes {
        write_node(node, &mut out);
    }
    out.into_bytes()
}

fn write_node(node: &Node, out: &mut String) {
    match node {
        Node::Text(raw) => out.push_str(raw),
        Node::CData(raw) => {
            out.push_str("<![CDATA[");
            out.push_str(raw);
            out.push_str("]]>");
        }
        Node::Comment(raw) => {
            out.push_str("<!--");
            out.push_str(raw);
            out.push_str("-->");
        }
        Node::Pi(raw) | Node::Decl(raw) => {
            out.push_str("<?");
            out.push_str(raw);
            out.push_str("?>");
        }
        Node::DocType(raw) => {
            out.push_str("<!DOCTYPE");
            out.push_str(raw);
            out.push('>');
        }
        Node::Element(el) => write_element(el, out),
    }
}

fn write_element(el: &Element, out: &mut String) {
    out.push('<');
    out.push_str(&el.name);
    match el.attrs_raw() {
        Some(raw) => out.push_str(raw),
        None => {
            for attr in el.attrs() {
                let q = attr.quote as char;
                out.push(' ');
                out.push_str(&attr.name);
                out.push('=');
                out.push(q);
                out.push_str(&escape_attr(&attr.value, attr.quote));
                out.push(q);
            }
        }
    }
    if el.is_empty_syntax() {
        out.push_str("/>");
        return;
    }
    out.push('>');
    for child in &el.children {
        write_node(child, out);
    }
    out.push_str("</");
    out.push_str(&el.name);
    out.push('>');
}

/// Escape a value for an attribute delimited by `quote`.
///
/// Only the delimiter in use is escaped, matching what every XMP writer does —
/// escaping both quote styles would gratuitously churn files we rewrite.
fn escape_attr(value: &str, quote: u8) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' if quote == QUOTE_DOUBLE => out.push_str("&quot;"),
            '\'' if quote != QUOTE_DOUBLE => out.push_str("&apos;"),
            '\n' => out.push_str("&#xA;"),
            '\r' => out.push_str("&#xD;"),
            '\t' => out.push_str("&#x9;"),
            _ => out.push(c),
        }
    }
    out
}
