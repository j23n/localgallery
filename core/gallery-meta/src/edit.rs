//! Low-level surgical edits on a parsed sidecar.
//!
//! Every function here is deliberately narrow: locate one property, change one
//! list, touch nothing else. Navigation is by *index path* from the document
//! root rather than by held reference, because each edit can insert nodes and
//! invalidate positions — so callers re-locate before every mutation. Sidecars
//! are a couple of kilobytes; the walk is free and the alternative is a borrow
//! checker fight that ends in `unsafe`.

use crate::read::{container_of, is_container, is_li};
use crate::schema::NS_RDF;
use crate::xml::dom::Attr;
use crate::xml::{Document, Element, Node, NsScope};

/// Index path from `Document::nodes` down through `Element::children`.
pub(crate) type NodePath = Vec<usize>;

/// Element at `path`, if it is still an element.
pub(crate) fn element_at<'a>(doc: &'a Document, path: &[usize]) -> Option<&'a Element> {
    let (&first, rest) = path.split_first()?;
    let mut el = doc.nodes.get(first)?.as_element()?;
    for &i in rest {
        el = el.children.get(i)?.as_element()?;
    }
    Some(el)
}

/// Element at `path`, mutably.
pub(crate) fn element_at_mut<'a>(doc: &'a mut Document, path: &[usize]) -> Option<&'a mut Element> {
    let (&first, rest) = path.split_first()?;
    let mut el = doc.nodes.get_mut(first)?.as_element_mut()?;
    for &i in rest {
        el = el.children.get_mut(i)?.as_element_mut()?;
    }
    Some(el)
}

/// Namespace scope in effect *inside* the element at `path`.
pub(crate) fn scope_at(doc: &Document, path: &[usize]) -> NsScope {
    let mut scope = NsScope::new();
    let Some((&first, rest)) = path.split_first() else {
        return scope;
    };
    let Some(mut el) = doc.nodes.get(first).and_then(Node::as_element) else {
        return scope;
    };
    scope = scope.extended(el);
    for &i in rest {
        match el.children.get(i).and_then(Node::as_element) {
            Some(child) => {
                scope = scope.extended(child);
                el = child;
            }
            None => break,
        }
    }
    scope
}

/// Locate the `rdf:RDF` element. Searches top-level nodes then their subtrees,
/// so both `x:xmpmeta`-wrapped and bare packets work.
pub(crate) fn find_rdf_root(doc: &Document) -> Option<NodePath> {
    for (i, node) in doc.nodes.iter().enumerate() {
        let Some(el) = node.as_element() else {
            continue;
        };
        let scope = NsScope::new().extended(el);
        if scope.matches(el, NS_RDF, "RDF") {
            return Some(vec![i]);
        }
        if let Some(mut sub) = find_rdf_in(el, &scope) {
            let mut path = vec![i];
            path.append(&mut sub);
            return Some(path);
        }
    }
    None
}

fn find_rdf_in(el: &Element, outer: &NsScope) -> Option<NodePath> {
    for (i, child) in el.children.iter().enumerate() {
        let Some(child_el) = child.as_element() else {
            continue;
        };
        let scope = outer.extended(child_el);
        if scope.matches(child_el, NS_RDF, "RDF") {
            return Some(vec![i]);
        }
        if let Some(mut sub) = find_rdf_in(child_el, &scope) {
            let mut path = vec![i];
            path.append(&mut sub);
            return Some(path);
        }
    }
    None
}

/// Locate the *first* property element (`dc:subject`, `phototools:CoreTags`, …)
/// under `root`, matched by namespace URI and local name.
///
/// "First" is right for the add path — new entries go somewhere, and the
/// occurrence already in the file is the least surprising somewhere. It is
/// wrong for the remove path; see [`find_properties`].
pub(crate) fn find_property(
    doc: &Document,
    root: &[usize],
    uri: &str,
    local: &str,
) -> Option<NodePath> {
    find_properties(doc, root, uri, local).into_iter().next()
}

/// Every occurrence of a property under `root`, in document order.
///
/// A property may legally appear more than once: RDF permits several
/// `rdf:Description` blocks about the same subject, and digiKam, Bridge and
/// hand-edited files all produce them. Anything that *removes* entries has to
/// see all of them, or it will delete an entry from its bookkeeping while
/// leaving the entry itself in the file.
pub(crate) fn find_properties(
    doc: &Document,
    root: &[usize],
    uri: &str,
    local: &str,
) -> Vec<NodePath> {
    let Some(el) = element_at(doc, root) else {
        return Vec::new();
    };
    let scope = scope_at(doc, root);
    let mut found = Vec::new();
    collect_properties_in(el, &scope, uri, local, &mut Vec::new(), &mut found);
    found
        .into_iter()
        .map(|sub| {
            let mut path = root.to_vec();
            path.extend(sub);
            path
        })
        .collect()
}

fn collect_properties_in(
    el: &Element,
    outer: &NsScope,
    uri: &str,
    local: &str,
    prefix: &mut NodePath,
    found: &mut Vec<NodePath>,
) {
    for (i, child) in el.children.iter().enumerate() {
        let Some(child_el) = child.as_element() else {
            continue;
        };
        let scope = outer.extended(child_el);
        prefix.push(i);
        if scope.matches(child_el, uri, local) {
            found.push(prefix.clone());
        } else if !is_container(child_el, outer) {
            // Do not descend into list containers: an `<rdf:li>` inside a
            // `dc:subject` Bag is a value, not a property of the same name.
            collect_properties_in(child_el, &scope, uri, local, prefix, found);
        }
        prefix.pop();
    }
}

/// Locate an `rdf:Description` under `root` that carries this property in
/// *attribute* form, returning its path and the attribute's qualified name.
pub(crate) fn find_attr_property(
    doc: &Document,
    root: &[usize],
    uri: &str,
    local: &str,
) -> Option<(NodePath, String)> {
    let root_el = element_at(doc, root)?;
    let root_scope = scope_at(doc, root);
    for (i, child) in root_el.children.iter().enumerate() {
        let Some(desc) = child.as_element() else {
            continue;
        };
        let scope = root_scope.extended(desc);
        for attr in desc.attrs() {
            if attr.name.starts_with("xmlns") {
                continue;
            }
            let (attr_uri, attr_local) = scope.resolve(&attr.name);
            if attr_uri == Some(uri) && attr_local == local {
                let mut path = root.to_vec();
                path.push(i);
                return Some((path, attr.name.clone()));
            }
        }
    }
    None
}

/// Indentation width for the children of the element at `path`.
///
/// exiftool indents one space per nesting level, counting `rdf:RDF`'s children
/// as level 1 regardless of whether an `x:xmpmeta` wrapper is present.
pub(crate) fn child_indent(path: &[usize]) -> usize {
    path.len().max(2) - 1
}

pub(crate) fn indent_text(width: usize) -> String {
    format!("\n{}", " ".repeat(width))
}

/// Position at which a new child line should start: in front of the element's
/// trailing indentation, so the closing tag keeps its own line.
fn line_insert_position(el: &Element) -> usize {
    match el.children.last() {
        Some(last) if last.is_whitespace() => el.children.len() - 1,
        _ => el.children.len(),
    }
}

/// Insert `separator` + `node` as a new child line, restoring the closing-tag
/// indentation if the element had none. Returns the index of `node`.
fn insert_child_line(
    el: &mut Element,
    at: usize,
    separator: String,
    node: Node,
    closing_indent: usize,
) -> usize {
    let had_trailing_ws = el.children.last().is_some_and(Node::is_whitespace);
    el.insert_child(at, Node::Text(separator));
    el.insert_child(at + 1, node);
    if !had_trailing_ws {
        el.push_child(Node::Text(indent_text(closing_indent)));
    }
    at + 1
}

/// Find an `rdf:Description` child of `root` in whose scope `uri` is already
/// bound, returning `(path, prefix)`.
fn find_description_binding(
    doc: &Document,
    root: &[usize],
    uri: &str,
) -> Option<(NodePath, String)> {
    let root_el = element_at(doc, root)?;
    let root_scope = scope_at(doc, root);
    for (i, child) in root_el.children.iter().enumerate() {
        let Some(desc) = child.as_element() else {
            continue;
        };
        let scope = root_scope.extended(desc);
        if !scope.matches(desc, NS_RDF, "Description") {
            continue;
        }
        let Some(prefix) = scope.prefix_for(uri) else {
            continue;
        };
        let mut path = root.to_vec();
        path.push(i);
        return Some((path, prefix.to_string()));
    }
    None
}

/// Append a fresh `rdf:Description` binding each `(prefix, uri)`, laid out the
/// way exiftool lays one out. Returns its path.
///
/// More than one binding is needed for structured properties: an MWG-RS
/// `Regions` block names three namespaces (`mwg-rs`, `stArea`, `stDim`), and
/// putting them all on a Description we author keeps us out of somebody else's
/// tag — mutating a foreign element's attributes would re-serialize its whole
/// attribute list and churn a file we were only meant to add to.
fn create_description(doc: &mut Document, root: &[usize], bindings: &[(&str, &str)]) -> NodePath {
    let indent = child_indent(root);
    let mut desc = Element::new("rdf:Description");
    desc.push_attr(Attr::new("rdf:about", ""));
    let mut raw = " rdf:about=''".to_string();
    for (prefix, uri) in bindings {
        desc.push_attr(Attr::new(format!("xmlns:{prefix}"), *uri));
        raw.push_str(&format!("\n{} xmlns:{prefix}='{uri}'", " ".repeat(indent)));
    }
    // exiftool puts `rdf:about` on the tag line and each xmlns on its own,
    // indented one past the element. Match it so diffs against exiftool-written
    // files stay small.
    desc.set_attrs_raw(raw);

    let root_el = element_at_mut(doc, root).expect("caller located the root");
    let at = line_insert_position(root_el);
    // exiftool leaves a blank line between Descriptions — including before the
    // first one.
    let separator = format!("\n{}", indent_text(indent));
    let index = insert_child_line(root_el, at, separator, Node::Element(desc), indent - 1);

    let mut path = root.to_vec();
    path.push(index);
    path
}

/// Get (or create) the `rdf:Description` that should host a new property in
/// `uri`. Returns `(path, prefix_in_scope)`.
fn description_for(
    doc: &mut Document,
    root: &[usize],
    uri: &str,
    preferred_prefix: &str,
) -> (NodePath, String) {
    if let Some(found) = find_description_binding(doc, root, uri) {
        return found;
    }
    let path = create_description(doc, root, &[(preferred_prefix, uri)]);
    (path, preferred_prefix.to_string())
}

/// Get (or create) a property element, returning its path.
///
/// An existing property is reused whatever prefix it carries, and a new one
/// adopts the prefix the file already binds to `uri` — `preferred_prefix` only
/// applies when the namespace is absent altogether. Note this cannot control
/// how exiftool *names the group*: for a user-defined namespace exiftool keys
/// the family-1 group off the first prefix bound to the URI anywhere in the
/// file, so a sidecar that already says `xmlns:pt='…photo-tools…'` reports
/// `XMP-pt:CoreTags` no matter which prefix we write. Nothing we can do about
/// that from here, and it is equally true of photo-tools' own fields.
pub(crate) fn ensure_property(
    doc: &mut Document,
    root: &[usize],
    uri: &str,
    preferred_prefix: &str,
    local: &str,
) -> NodePath {
    if let Some(path) = find_property(doc, root, uri, local) {
        return path;
    }
    let (desc_path, prefix) = description_for(doc, root, uri, preferred_prefix);
    let indent = child_indent(&desc_path);
    let prop = Element::new(format!("{prefix}:{local}"));

    let desc = element_at_mut(doc, &desc_path).expect("just located");
    let at = line_insert_position(desc);
    let index = insert_child_line(
        desc,
        at,
        indent_text(indent),
        Node::Element(prop),
        indent - 1,
    );

    let mut path = desc_path;
    path.push(index);
    path
}

/// [`ensure_property`] for a property whose *contents* name namespaces beyond
/// its own.
///
/// `bindings[0]` is the property's own namespace and supplies its prefix; the
/// rest are bound alongside it so the struct fields underneath have prefixes to
/// use. An existing property is reused untouched — the extra bindings are only
/// established when this call creates the `rdf:Description`.
pub(crate) fn ensure_struct_property(
    doc: &mut Document,
    root: &[usize],
    local: &str,
    bindings: &[(&str, &str)],
) -> NodePath {
    let (prefix, uri) = bindings[0];
    if let Some(path) = find_property(doc, root, uri, local) {
        return path;
    }
    let desc_path = create_description(doc, root, bindings);
    let indent = child_indent(&desc_path);
    let prop = Element::new(format!("{prefix}:{local}"));

    let desc = element_at_mut(doc, &desc_path).expect("just created");
    let at = line_insert_position(desc);
    let index = insert_child_line(
        desc,
        at,
        indent_text(indent),
        Node::Element(prop),
        indent - 1,
    );
    let mut path = desc_path;
    path.push(index);
    path
}

/// Bind `uri` to `prefix` on the nearest ancestor of `path` (inclusive) if it
/// is not already in scope there, and return the prefix to use for it.
///
/// The fallback for a file that carries an `mwg-rs:Regions` block without
/// binding `stArea` anywhere an authored child could see it. Rare enough that
/// re-serializing that element's attribute list is an acceptable price for
/// emitting well-formed XML.
pub(crate) fn ensure_ns_binding(
    doc: &mut Document,
    path: &[usize],
    uri: &str,
    preferred_prefix: &str,
) -> String {
    if let Some(prefix) = scope_at(doc, path).prefix_for(uri) {
        return prefix.to_string();
    }
    if let Some(el) = element_at_mut(doc, path) {
        el.set_attr(format!("xmlns:{preferred_prefix}"), uri);
    }
    preferred_prefix.to_string()
}

/// Get (or create) the `rdf:Bag` / `rdf:Seq` inside a property.
///
/// `kind` is only used when creating: `digiKam:TagsList` is a `Seq`, every
/// other keyword field is a `Bag` (that is what exiftool emits, and digiKam
/// round-trips it).
pub(crate) fn ensure_container(doc: &mut Document, prop_path: &[usize], kind: &str) -> NodePath {
    let scope = scope_at(doc, prop_path);
    if let Some(prop) = element_at(doc, prop_path) {
        if let Some(index) = prop.child_element_index(|c| is_container(c, &scope)) {
            let mut path = prop_path.to_vec();
            path.push(index);
            return path;
        }
    }

    let indent = child_indent(prop_path);
    // A property that already holds bare text is being upgraded to a list; keep
    // the text as the first entry rather than losing it.
    let existing_text = element_at(doc, prop_path)
        .map(Element::text)
        .unwrap_or_default();

    let mut container = Element::new(format!("rdf:{kind}"));
    if !existing_text.is_empty() {
        let mut li = Element::new("rdf:li");
        li.set_text(&existing_text);
        container.push_child(Node::Text(indent_text(indent + 1)));
        container.push_child(Node::Element(li));
        container.push_child(Node::Text(indent_text(indent)));
    }

    let prop = element_at_mut(doc, prop_path).expect("just located");
    prop.children.clear();
    prop.push_child(Node::Text(indent_text(indent)));
    prop.push_child(Node::Element(container));
    prop.push_child(Node::Text(indent_text(indent - 1)));

    let mut path = prop_path.to_vec();
    path.push(1);
    path
}

/// Append `value` as an `<rdf:li>` inside the container at `path`.
///
/// Indentation copies the whitespace in front of an existing entry when there
/// is one, so an insert into a digiKam- or Lightroom-formatted file matches its
/// neighbours instead of imposing exiftool's layout.
pub(crate) fn append_li(doc: &mut Document, container_path: &[usize], value: &str) {
    let mut li = Element::new("rdf:li");
    li.set_text(value);
    append_li_element(doc, container_path, li);
}

/// [`append_li`] for an `<rdf:li>` the caller has already built — a region
/// entry, say, whose children are a whole struct rather than one text node.
pub(crate) fn append_li_element(doc: &mut Document, container_path: &[usize], li: Element) {
    let indent = child_indent(container_path);
    let scope = scope_at(doc, container_path);
    let container = element_at_mut(doc, container_path).expect("caller located the container");

    let last_li = container
        .children
        .iter()
        .rposition(|n| n.as_element().is_some_and(|e| is_li(e, &scope)));
    let separator = last_li
        .and_then(|i| i.checked_sub(1))
        .and_then(|i| match &container.children[i] {
            Node::Text(t) if t.chars().all(|c| c.is_ascii_whitespace()) => Some(t.clone()),
            _ => None,
        })
        .unwrap_or_else(|| indent_text(indent));

    let at = match last_li {
        Some(i) => i + 1,
        None => line_insert_position(container),
    };
    insert_child_line(container, at, separator, Node::Element(li), indent - 1);
}

/// Remove every `<rdf:li>` in the container whose text matches `should_remove`,
/// taking the whitespace in front of it along so indentation does not drift.
pub(crate) fn remove_lis(
    doc: &mut Document,
    container_path: &[usize],
    should_remove: &dyn Fn(&str) -> bool,
) {
    remove_li_elements(doc, container_path, &|el, _| should_remove(&el.text()));
}

/// [`remove_lis`] with the whole element in hand.
///
/// A region entry has no text of its own — everything about it lives in child
/// elements or attributes — so the predicate needs the element and the
/// namespace scope it sits in.
pub(crate) fn remove_li_elements(
    doc: &mut Document,
    container_path: &[usize],
    should_remove: &dyn Fn(&Element, &NsScope) -> bool,
) {
    let scope = scope_at(doc, container_path);
    let Some(container) = element_at_mut(doc, container_path) else {
        return;
    };
    let mut i = 0;
    while i < container.children.len() {
        let hit = container.children[i]
            .as_element()
            .is_some_and(|e| is_li(e, &scope) && should_remove(e, &scope));
        if !hit {
            i += 1;
            continue;
        }
        container.children.remove(i);
        if i > 0 && container.children[i - 1].is_whitespace() {
            container.children.remove(i - 1);
            i -= 1;
        }
    }
}

/// Append `el` as a new child *line* of the element at `path`, indented for its
/// depth. Returns the new element's path.
pub(crate) fn append_child_element(doc: &mut Document, path: &[usize], el: Element) -> NodePath {
    let indent = child_indent(path);
    let Some(parent) = element_at_mut(doc, path) else {
        return path.to_vec();
    };
    let at = line_insert_position(parent);
    let index = insert_child_line(
        parent,
        at,
        indent_text(indent),
        Node::Element(el),
        indent - 1,
    );
    let mut child = path.to_vec();
    child.push(index);
    child
}

/// Index of the first child element of `path` matching `uri`/`local`.
pub(crate) fn child_property(
    doc: &Document,
    path: &[usize],
    uri: &str,
    local: &str,
) -> Option<NodePath> {
    let scope = scope_at(doc, path);
    let el = element_at(doc, path)?;
    let index = el.children.iter().position(|n| {
        n.as_element()
            .is_some_and(|c| scope.extended(c).matches(c, uri, local))
    })?;
    let mut out = path.to_vec();
    out.push(index);
    Some(out)
}

/// Remove the element at `path`, taking the indentation in front of it along.
fn remove_element(doc: &mut Document, path: &[usize]) {
    let Some((&index, parent_path)) = path.split_last() else {
        return;
    };
    let children: &mut Vec<Node> = if parent_path.is_empty() {
        &mut doc.nodes
    } else {
        match element_at_mut(doc, parent_path) {
            Some(parent) => &mut parent.children,
            None => return,
        }
    };
    if index >= children.len() {
        return;
    }
    children.remove(index);
    if index > 0 && children[index - 1].is_whitespace() {
        children.remove(index - 1);
    }
}

/// Whether an `rdf:Description` now carries nothing but its own scaffolding.
fn is_vacant_description(el: &Element, scope: &NsScope) -> bool {
    scope.matches(el, NS_RDF, "Description")
        && el.child_elements().next().is_none()
        && el.attrs().iter().all(|a| {
            a.name == "xmlns" || a.name.starts_with("xmlns:") || a.name.ends_with(":about")
        })
}

/// Remove a property, and the `rdf:Description` around it if that leaves the
/// Description holding nothing.
///
/// Deleting the property outright — rather than leaving an empty `rdf:Bag` —
/// matters: exiftool reads `<x><rdf:Bag></rdf:Bag></x>` as the *whitespace
/// between the tags*, so an emptied list surfaces as a garbage string value
/// instead of as absent.
pub(crate) fn remove_property(doc: &mut Document, prop_path: &[usize]) {
    remove_element(doc, prop_path);
    let Some((_, desc_path)) = prop_path.split_last() else {
        return;
    };
    if desc_path.is_empty() {
        return;
    }
    let scope = scope_at(doc, desc_path);
    let vacant = element_at(doc, desc_path).is_some_and(|el| is_vacant_description(el, &scope));
    if vacant {
        remove_element(doc, desc_path);
    }
}

/// Set a scalar property, preferring whatever form the file already uses.
pub(crate) fn set_scalar(
    doc: &mut Document,
    root: &[usize],
    uri: &str,
    preferred_prefix: &str,
    local: &str,
    value: &str,
) {
    if let Some((desc_path, attr_name)) = find_attr_property(doc, root, uri, local) {
        if let Some(desc) = element_at_mut(doc, &desc_path) {
            desc.set_attr(attr_name, value);
            return;
        }
    }
    let prop_path = ensure_property(doc, root, uri, preferred_prefix, local);
    if let Some(prop) = element_at_mut(doc, &prop_path) {
        prop.set_text(value);
    }
}

/// Move a list property out of attribute form and into element form.
///
/// RDF lets a single-valued array collapse onto the tag —
/// `<rdf:Description dc:subject='Dog'/>` — and exiftool and Bridge both emit
/// that. The element-based editor cannot see it, so without this step an
/// addition would create a *second*, element-form `dc:subject` beside the
/// attribute and the file would carry the same property twice, with different
/// values, for every reader to disagree over.
///
/// A no-op when the property is absent or already in element form.
pub(crate) fn migrate_attr_list(
    doc: &mut Document,
    root: &[usize],
    uri: &str,
    preferred_prefix: &str,
    local: &str,
    kind: &str,
) {
    let Some((desc_path, attr_name)) = find_attr_property(doc, root, uri, local) else {
        return;
    };
    let Some(desc) = element_at_mut(doc, &desc_path) else {
        return;
    };
    let value = desc.remove_attr(&attr_name).unwrap_or_default();
    let value = value.trim().to_string();
    if value.is_empty() {
        return;
    }
    let prop_path = ensure_property(doc, root, uri, preferred_prefix, local);
    let container_path = ensure_container(doc, &prop_path, kind);
    if !values_at(doc, &prop_path).contains(&value) {
        append_li(doc, &container_path, &value);
    }
}

/// Replace a list property's entries wholesale, creating it if needed.
pub(crate) fn set_list(
    doc: &mut Document,
    root: &[usize],
    uri: &str,
    preferred_prefix: &str,
    local: &str,
    kind: &str,
    values: &[String],
) {
    // Fold any attribute form in first, so the property exists in exactly one
    // shape before we replace its contents (or delete it).
    migrate_attr_list(doc, root, uri, preferred_prefix, local, kind);
    if values.is_empty() {
        if let Some(prop_path) = find_property(doc, root, uri, local) {
            remove_property(doc, &prop_path);
        }
        return;
    }
    let prop_path = ensure_property(doc, root, uri, preferred_prefix, local);
    let container_path = ensure_container(doc, &prop_path, kind);
    remove_lis(doc, &container_path, &|_| true);
    for value in values {
        append_li(doc, &container_path, value);
    }
}

/// Read a list property's current entries across **every** occurrence, in
/// document order (empty when absent).
pub(crate) fn list_values(doc: &Document, root: &[usize], uri: &str, local: &str) -> Vec<String> {
    find_properties(doc, root, uri, local)
        .iter()
        .flat_map(|path| values_at(doc, path))
        .collect()
}

/// Entries of the one list property at `prop_path`.
pub(crate) fn values_at(doc: &Document, prop_path: &[usize]) -> Vec<String> {
    let scope = scope_at(doc, prop_path);
    let Some(prop) = element_at(doc, prop_path) else {
        return Vec::new();
    };
    match container_of(prop, &scope) {
        Some(container) => {
            let inner = scope.extended(container);
            container
                .child_elements()
                .filter(|c| is_li(c, &inner))
                .map(Element::text)
                .collect()
        }
        None => {
            let text = prop.text();
            if text.is_empty() {
                Vec::new()
            } else {
                vec![text]
            }
        }
    }
}

/// The XMP toolkit string this crate stamps into a sidecar it creates.
///
/// Kept version-free on purpose: bumping the crate must not change the bytes of
/// every sidecar we write. Provenance lives in the `CoreAgent` /
/// `CoreModelPack` sentinel instead.
pub(crate) const XMP_TOOLKIT: &str = "gallery-meta";

/// A brand-new, empty XMP packet in exiftool's exact layout.
pub(crate) fn new_envelope() -> Document {
    let mut rdf = Element::new("rdf:RDF");
    rdf.push_attr(Attr::new("xmlns:rdf", NS_RDF));
    rdf.set_attrs_raw(format!(" xmlns:rdf='{NS_RDF}'"));
    rdf.push_child(Node::Text("\n".into()));

    let mut meta = Element::new("x:xmpmeta");
    meta.push_attr(Attr::new("xmlns:x", crate::schema::NS_X));
    meta.push_attr(Attr::new("x:xmptk", XMP_TOOLKIT));
    meta.set_attrs_raw(format!(
        " xmlns:x='{}' x:xmptk='{XMP_TOOLKIT}'",
        crate::schema::NS_X
    ));
    meta.push_child(Node::Text("\n".into()));
    meta.push_child(Node::Element(rdf));
    meta.push_child(Node::Text("\n".into()));

    Document {
        nodes: vec![
            Node::Pi("xpacket begin='\u{feff}' id='W5M0MpCehiHzreSzNTczkc9d'".into()),
            Node::Text("\n".into()),
            Node::Element(meta),
            Node::Text("\n".into()),
            Node::Pi("xpacket end='w'".into()),
            Node::Text("\n".into()),
        ],
    }
}
