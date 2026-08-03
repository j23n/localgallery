//! quick-xml pull parser → preserving [`Document`].

use quick_xml::events::Event;
use quick_xml::Reader;

use super::dom::{Attr, Document, Element, Node};
use crate::error::{MetaError, MetaResult};

/// Parse an XMP packet.
///
/// Errors on UTF-16 input rather than guessing: the writer would have to
/// re-encode the whole document, and no tool in this ecosystem emits UTF-16
/// sidecars. (`MetadataReader.parseXMPBytes` reads UTF-16 defensively; the
/// *writer* refuses so it cannot silently transcode somebody's file.)
pub fn parse(bytes: &[u8]) -> MetaResult<Document> {
    if bytes.starts_with(&[0xFF, 0xFE]) || bytes.starts_with(&[0xFE, 0xFF]) {
        return Err(MetaError::UnsupportedEncoding {
            detail: "UTF-16 XMP packet; only UTF-8 sidecars can be rewritten".into(),
        });
    }
    let text = std::str::from_utf8(bytes).map_err(|e| MetaError::UnsupportedEncoding {
        detail: format!("not valid UTF-8: {e}"),
    })?;

    let mut reader = Reader::from_str(text);
    let cfg = reader.config_mut();
    cfg.trim_text(false);
    // Sidecars in the wild are not always well-formed to the letter; a
    // mismatched close tag must not cost the user their metadata, and we are
    // not a validator.
    cfg.check_end_names = false;
    cfg.allow_dangling_amp = true;

    let mut doc = Document::default();
    // Stack of elements currently open; `doc.nodes` receives everything once
    // the stack is empty.
    let mut stack: Vec<Element> = Vec::new();

    loop {
        let event = reader.read_event().map_err(|e| MetaError::MalformedXml {
            detail: e.to_string(),
        })?;
        match event {
            Event::Eof => break,
            Event::Start(e) => {
                let el = element_from_start(&e, false)?;
                stack.push(el);
            }
            Event::Empty(e) => {
                let el = element_from_start(&e, true)?;
                push_node(&mut doc, &mut stack, Node::Element(el));
            }
            Event::End(_) => {
                // `check_end_names` is off, so an unmatched end tag can pop an
                // empty stack. Ignore it rather than fail the whole write.
                if let Some(el) = stack.pop() {
                    push_node(&mut doc, &mut stack, Node::Element(el));
                }
            }
            Event::Text(e) => {
                let raw = decode(e.into_inner().as_ref())?;
                push_text(&mut doc, &mut stack, &raw);
            }
            // quick-xml 0.41 surfaces `&amp;` / `&#233;` as their own events.
            // Fold them straight back into the surrounding text so the escaped
            // form survives byte-for-byte.
            Event::GeneralRef(e) => {
                let name = decode(e.into_inner().as_ref())?;
                push_text(&mut doc, &mut stack, &format!("&{name};"));
            }
            Event::CData(e) => {
                let raw = decode(e.into_inner().as_ref())?;
                push_node(&mut doc, &mut stack, Node::CData(raw));
            }
            Event::Comment(e) => {
                let raw = decode(e.into_inner().as_ref())?;
                push_node(&mut doc, &mut stack, Node::Comment(raw));
            }
            Event::PI(e) => {
                let raw = decode(e.into_inner().as_ref())?;
                push_node(&mut doc, &mut stack, Node::Pi(raw));
            }
            Event::Decl(e) => {
                // `BytesDecl` has no `into_inner`; it derefs to the raw bytes
                // between `<?` and `?>`, which is exactly what we re-emit.
                let raw = decode(&e)?;
                push_node(&mut doc, &mut stack, Node::Decl(raw));
            }
            Event::DocType(e) => {
                let raw = decode(e.into_inner().as_ref())?;
                push_node(&mut doc, &mut stack, Node::DocType(raw));
            }
        }
    }

    // Unclosed elements: close them in place rather than dropping the subtree.
    while let Some(el) = stack.pop() {
        push_node(&mut doc, &mut stack, Node::Element(el));
    }

    Ok(doc)
}

fn decode(bytes: &[u8]) -> MetaResult<String> {
    std::str::from_utf8(bytes)
        .map(str::to_string)
        .map_err(|e| MetaError::UnsupportedEncoding {
            detail: format!("not valid UTF-8: {e}"),
        })
}

fn element_from_start(
    e: &quick_xml::events::BytesStart<'_>,
    empty_syntax: bool,
) -> MetaResult<Element> {
    let name = decode(e.name().as_ref())?;
    let mut attrs_raw = decode(e.attributes_raw())?;
    // quick-xml keeps the `/` of a self-closing tag in the raw attribute span
    // when there is no whitespace before it (`<foo bar='1'/>`).
    if empty_syntax {
        if let Some(stripped) = attrs_raw.strip_suffix('/') {
            attrs_raw = stripped.to_string();
        }
    }

    let mut attrs = Vec::new();
    for attr in e.attributes().with_checks(false) {
        let attr = attr.map_err(|err| MetaError::MalformedXml {
            detail: format!("bad attribute in <{name}>: {err}"),
        })?;
        let key = decode(attr.key.as_ref())?;
        let value = super::unescape_text(&decode(attr.value.as_ref())?);
        let quote = quote_char_for(&attrs_raw, &key);
        attrs.push(Attr {
            name: key,
            value,
            quote,
        });
    }
    Ok(Element::from_parsed(name, attrs, attrs_raw, empty_syntax))
}

/// Recover the quote character the source used for `key`, so a tag we have to
/// re-serialize still matches its neighbours.
fn quote_char_for(attrs_raw: &str, key: &str) -> u8 {
    let mut search = attrs_raw;
    while let Some(pos) = search.find(key) {
        let after = &search[pos + key.len()..];
        let trimmed = after.trim_start();
        if let Some(rest) = trimmed.strip_prefix('=') {
            match rest.trim_start().as_bytes().first() {
                Some(&b'"') => return super::dom::QUOTE_DOUBLE,
                Some(&b'\'') => return super::dom::QUOTE_SINGLE,
                _ => {}
            }
        }
        search = &search[pos + key.len()..];
    }
    super::dom::QUOTE_SINGLE
}

/// Append `node` to the innermost open element, or to the document.
fn push_node(doc: &mut Document, stack: &mut [Element], node: Node) {
    match stack.last_mut() {
        Some(parent) => parent.push_child(node),
        None => doc.nodes.push(node),
    }
}

/// Append text, merging with a preceding text node so entity references
/// rejoin their surrounding characters.
fn push_text(doc: &mut Document, stack: &mut [Element], raw: &str) {
    let target = match stack.last_mut() {
        Some(parent) => &mut parent.children,
        None => &mut doc.nodes,
    };
    if let Some(Node::Text(existing)) = target.last_mut() {
        existing.push_str(raw);
        return;
    }
    // `push_child` would clear empty-element syntax, which is what we want for
    // an element that turns out to have text — but only when there is a parent.
    match stack.last_mut() {
        Some(parent) => parent.push_child(Node::Text(raw.to_string())),
        None => doc.nodes.push(Node::Text(raw.to_string())),
    }
}
