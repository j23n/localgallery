//! Namespace-prefix scoping.
//!
//! XMP prefixes are conventional, not normative: digiKam, Lightroom, exiftool
//! and Apple all bind the same URIs to slightly different prefixes, and a
//! sidecar may rebind a prefix halfway down. Everything this crate looks up is
//! therefore matched on **URI + local name**, never on the literal `dc:` text.

use super::dom::Element;

/// Prefix → URI bindings in effect at some point in the tree.
///
/// The empty prefix is the default namespace. Lookups walk backwards so an
/// inner rebinding shadows an outer one.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NsScope {
    bindings: Vec<(String, String)>,
}

impl NsScope {
    /// An empty scope (no namespaces in effect).
    pub fn new() -> Self {
        Self::default()
    }

    /// The scope in effect *inside* `el`: this scope plus `el`'s own `xmlns`
    /// attributes.
    pub fn extended(&self, el: &Element) -> NsScope {
        let mut next = self.clone();
        for attr in el.attrs() {
            if attr.name == "xmlns" {
                next.bindings.push((String::new(), attr.value.clone()));
            } else if let Some(prefix) = attr.name.strip_prefix("xmlns:") {
                next.bindings.push((prefix.to_string(), attr.value.clone()));
            }
        }
        next
    }

    /// URI bound to `prefix` (use `""` for the default namespace).
    pub fn uri_for(&self, prefix: &str) -> Option<&str> {
        self.bindings
            .iter()
            .rev()
            .find(|(p, _)| p == prefix)
            .map(|(_, u)| u.as_str())
    }

    /// The innermost prefix bound to `uri`, if any.
    pub fn prefix_for(&self, uri: &str) -> Option<&str> {
        self.bindings
            .iter()
            .rev()
            .find(|(_, u)| u == uri)
            .map(|(p, _)| p.as_str())
    }

    /// Resolve a qualified name to `(uri, local)`.
    pub fn resolve<'a>(&'a self, qname: &'a str) -> (Option<&'a str>, &'a str) {
        match qname.split_once(':') {
            Some((prefix, local)) => (self.uri_for(prefix), local),
            None => (self.uri_for(""), qname),
        }
    }

    /// Whether `el`'s name resolves to exactly this namespace and local name.
    pub fn matches(&self, el: &Element, uri: &str, local: &str) -> bool {
        let (el_uri, el_local) = self.resolve(&el.name);
        el_local == local && el_uri == Some(uri)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::xml::dom::Attr;

    fn el_with(xmlns: &[(&str, &str)], name: &str) -> Element {
        let mut e = Element::new(name);
        for (k, v) in xmlns {
            e.push_attr(Attr::new(*k, *v));
        }
        e
    }

    #[test]
    fn inner_bindings_shadow_outer_ones() {
        let outer = el_with(&[("xmlns:p", "urn:a")], "root");
        let scope = NsScope::new().extended(&outer);
        assert_eq!(scope.uri_for("p"), Some("urn:a"));

        let inner = el_with(&[("xmlns:p", "urn:b")], "child");
        let inner_scope = scope.extended(&inner);
        assert_eq!(inner_scope.uri_for("p"), Some("urn:b"));
    }

    #[test]
    fn resolve_handles_the_default_namespace() {
        let root = el_with(&[("xmlns", "urn:d")], "root");
        let scope = NsScope::new().extended(&root);
        assert_eq!(scope.resolve("bare"), (Some("urn:d"), "bare"));
        assert_eq!(scope.resolve("q:bare"), (None, "bare"));
    }

    #[test]
    fn matching_is_by_uri_not_by_prefix() {
        let root = el_with(&[("xmlns:whatever", "urn:a")], "root");
        let scope = NsScope::new().extended(&root);
        let subject = Element::new("whatever:subject");
        assert!(scope.matches(&subject, "urn:a", "subject"));
        assert!(!scope.matches(&subject, "urn:other", "subject"));
    }
}
