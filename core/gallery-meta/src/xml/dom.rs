//! A deliberately dumb XML tree that round-trips.
//!
//! This is not a general XML library. It exists for one job: read somebody
//! else's `.xmp` sidecar, change the handful of properties this crate owns, and
//! write it back so that **every other byte survives**. Consequences:
//!
//! - Text is kept *escaped, verbatim*. We never re-escape text we did not
//!   author, so `&#xE9;` does not silently become `é` (or vice versa).
//! - Whitespace between elements is an ordinary text node, so indentation is
//!   preserved exactly.
//! - An element remembers the raw byte slice of its attribute list and re-emits
//!   it verbatim until something mutates it — that keeps quote style, attribute
//!   order and intra-tag line breaks intact for the ~100% of elements we never
//!   touch.
//! - Empty-element syntax (`<foo/>` vs `<foo></foo>`) is remembered.

/// One quote character around an attribute value.
pub(crate) const QUOTE_SINGLE: u8 = b'\'';
/// Double-quote; only used for elements we author from scratch when the
/// surrounding document already prefers it.
pub(crate) const QUOTE_DOUBLE: u8 = b'"';

/// An attribute in decoded form. `value` is unescaped; serialization
/// re-escapes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attr {
    /// Qualified name exactly as written (`xmlns:dc`, `rdf:about`, `stArea:x`).
    pub name: String,
    /// Unescaped value.
    pub value: String,
    /// Quote character the source used, so a rewritten tag still looks local.
    pub quote: u8,
}

impl Attr {
    /// A single-quoted attribute — exiftool's style, and therefore the style
    /// of nearly every sidecar this crate will meet.
    pub fn new(name: impl Into<String>, value: impl Into<String>) -> Self {
        Attr {
            name: name.into(),
            value: value.into(),
            quote: QUOTE_SINGLE,
        }
    }
}

/// One node of the tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Node {
    /// An element and its subtree.
    Element(Element),
    /// Character data, stored **escaped exactly as it appeared**. Entity and
    /// character references are folded back into this string during parsing.
    Text(String),
    /// `<![CDATA[...]]>`, inner text verbatim.
    CData(String),
    /// `<!-- ... -->`, inner text verbatim.
    Comment(String),
    /// `<? ... ?>`, inner text verbatim (target included). This is how the
    /// `<?xpacket ...?>` wrapper survives.
    Pi(String),
    /// `<?xml ... ?>`, inner text verbatim.
    Decl(String),
    /// `<!DOCTYPE ...>`, inner text verbatim.
    DocType(String),
}

impl Node {
    /// The element, when this node is one.
    pub fn as_element(&self) -> Option<&Element> {
        match self {
            Node::Element(e) => Some(e),
            _ => None,
        }
    }

    /// The element, mutably.
    pub fn as_element_mut(&mut self) -> Option<&mut Element> {
        match self {
            Node::Element(e) => Some(e),
            _ => None,
        }
    }

    /// True for a text node that is only XML whitespace — i.e. indentation.
    pub fn is_whitespace(&self) -> bool {
        matches!(self, Node::Text(t) if t.chars().all(|c| c.is_ascii_whitespace()))
    }
}

/// An XML element.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Element {
    /// Qualified name exactly as written (`rdf:Description`, `dc:subject`).
    pub name: String,
    /// Children in document order, whitespace included.
    pub children: Vec<Node>,
    attrs: Vec<Attr>,
    /// Verbatim source bytes between the element name and the closing `>` (or
    /// `/>`). `None` once attributes are mutated, or for authored elements.
    attrs_raw: Option<String>,
    /// Whether the source wrote this as `<foo/>`.
    empty_syntax: bool,
}

impl Element {
    /// A new element with no attributes and no children, serialized as
    /// `<name/>` until children or attributes are added.
    pub fn new(name: impl Into<String>) -> Self {
        Element {
            name: name.into(),
            children: Vec::new(),
            attrs: Vec::new(),
            attrs_raw: None,
            empty_syntax: true,
        }
    }

    /// Build from parsed pieces. Only the parser calls this.
    pub(crate) fn from_parsed(
        name: String,
        attrs: Vec<Attr>,
        attrs_raw: String,
        empty_syntax: bool,
    ) -> Self {
        Element {
            name,
            children: Vec::new(),
            attrs,
            attrs_raw: Some(attrs_raw),
            empty_syntax,
        }
    }

    /// Attributes in document order.
    pub fn attrs(&self) -> &[Attr] {
        &self.attrs
    }

    /// Value of the attribute with this exact qualified name.
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|a| a.name == name)
            .map(|a| a.value.as_str())
    }

    /// Value of the first attribute whose local part (after `:`) matches.
    ///
    /// Prefixes are not fixed in XMP — `stArea:x` may arrive as `stArea:x` or,
    /// from a writer that bound the URI to a different prefix, as `sa:x`.
    /// Callers that already know the namespace URI use this after checking it.
    pub fn attr_local(&self, local: &str) -> Option<&str> {
        self.attrs
            .iter()
            .find(|a| local_part(&a.name) == local)
            .map(|a| a.value.as_str())
    }

    /// Set (or add) an attribute. Drops the verbatim attribute source.
    pub fn set_attr(&mut self, name: impl Into<String>, value: impl Into<String>) {
        let name = name.into();
        let value = value.into();
        self.attrs_raw = None;
        match self.attrs.iter_mut().find(|a| a.name == name) {
            Some(a) => a.value = value,
            None => {
                let quote = self.attrs.first().map(|a| a.quote).unwrap_or(QUOTE_SINGLE);
                self.attrs.push(Attr { name, value, quote });
            }
        }
    }

    /// Remove the attribute with this exact qualified name, returning its
    /// value. Drops the verbatim attribute source.
    pub fn remove_attr(&mut self, name: &str) -> Option<String> {
        let index = self.attrs.iter().position(|a| a.name == name)?;
        self.attrs_raw = None;
        Some(self.attrs.remove(index).value)
    }

    /// Append an attribute without checking for duplicates. Parser/authoring
    /// helper.
    pub fn push_attr(&mut self, attr: Attr) {
        self.attrs_raw = None;
        self.attrs.push(attr);
    }

    /// Local part of the element name (after the prefix).
    pub fn local_name(&self) -> &str {
        local_part(&self.name)
    }

    /// Namespace prefix, or `None` for an unprefixed name.
    pub fn prefix(&self) -> Option<&str> {
        self.name.split_once(':').map(|(p, _)| p)
    }

    /// Child elements, skipping text/comments.
    pub fn child_elements(&self) -> impl Iterator<Item = &Element> {
        self.children.iter().filter_map(Node::as_element)
    }

    /// Index of the first child element satisfying `pred`.
    pub fn child_element_index(&self, pred: impl Fn(&Element) -> bool) -> Option<usize> {
        self.children
            .iter()
            .position(|n| n.as_element().is_some_and(&pred))
    }

    /// Concatenated text of this element's direct text children, unescaped and
    /// trimmed. Struct-valued properties return whitespace, hence the trim.
    pub fn text(&self) -> String {
        let mut out = String::new();
        for child in &self.children {
            match child {
                Node::Text(t) => out.push_str(&crate::xml::unescape_text(t)),
                Node::CData(t) => out.push_str(t),
                _ => {}
            }
        }
        out.trim().to_string()
    }

    /// Replace all children with a single text node carrying `value`.
    pub fn set_text(&mut self, value: &str) {
        self.children = vec![Node::Text(crate::xml::escape_text(value))];
        self.empty_syntax = false;
    }

    /// Whether the source used `<foo/>` syntax and no children were added.
    pub fn is_empty_syntax(&self) -> bool {
        self.empty_syntax && self.children.is_empty()
    }

    /// Append a child, leaving empty-element syntax behind.
    pub fn push_child(&mut self, node: Node) {
        self.empty_syntax = false;
        self.children.push(node);
    }

    /// Insert a child at `index`, leaving empty-element syntax behind.
    pub fn insert_child(&mut self, index: usize, node: Node) {
        self.empty_syntax = false;
        self.children.insert(index, node);
    }

    /// The verbatim attribute source, if still valid.
    pub(crate) fn attrs_raw(&self) -> Option<&str> {
        self.attrs_raw.as_deref()
    }

    /// Pin the exact bytes to emit for this element's attribute list.
    ///
    /// Used when authoring an `rdf:Description`, so a sidecar this crate
    /// creates is laid out the way exiftool lays one out (`rdf:about` and each
    /// `xmlns` on their own line) instead of one long tag. `raw` must be a
    /// faithful rendering of `attrs()` — any later `set_attr` discards it.
    pub(crate) fn set_attrs_raw(&mut self, raw: impl Into<String>) {
        self.attrs_raw = Some(raw.into());
    }
}

/// A parsed document: everything at the top level, in order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Document {
    /// Top-level nodes — the xpacket PI, the root element, trailing newline, …
    pub nodes: Vec<Node>,
}

impl Document {
    /// Index of the first top-level element node.
    pub fn root_index(&self) -> Option<usize> {
        self.nodes.iter().position(|n| n.as_element().is_some())
    }
}

/// `dc:subject` → `subject`; an unprefixed name is returned whole.
pub fn local_part(qname: &str) -> &str {
    match qname.split_once(':') {
        Some((_, local)) => local,
        None => qname,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_part_splits_on_the_first_colon_only() {
        assert_eq!(local_part("dc:subject"), "subject");
        assert_eq!(local_part("subject"), "subject");
        // Not legal XML, but we must not panic on it.
        assert_eq!(local_part("a:b:c"), "b:c");
    }

    #[test]
    fn set_attr_invalidates_the_verbatim_source() {
        let mut el = Element::from_parsed(
            "rdf:Description".into(),
            vec![Attr::new("rdf:about", "")],
            " rdf:about=''".into(),
            false,
        );
        assert_eq!(el.attrs_raw(), Some(" rdf:about=''"));
        el.set_attr("xmlns:dc", "http://purl.org/dc/elements/1.1/");
        assert_eq!(el.attrs_raw(), None);
        assert_eq!(el.attrs().len(), 2);
    }

    #[test]
    fn whitespace_detection_ignores_content_nodes() {
        assert!(Node::Text("\n  ".into()).is_whitespace());
        assert!(!Node::Text("\n Rome ".into()).is_whitespace());
        assert!(!Node::Element(Element::new("x")).is_whitespace());
    }
}
