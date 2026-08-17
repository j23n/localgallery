//! The ISO-BMFF `meta` box, for the XMP and Exif items of a HEIF or AVIF file.
//!
//! HEIC is a container of *items*, not a stream with markers: the XMP packet is
//! a byte range recorded in `meta/iloc`, and the only way to reach it is to walk
//! the box tree. That is what [`super::container`] documented as a gap for four
//! phases — an iPhone HEIC carrying embedded `digiKam:TagsList` read as
//! untagged, because nothing here knew where to look.
//!
//! # Bounding
//!
//! Every number in this module comes off disk and every one of them is hostile
//! until proved otherwise. `media/video.rs` already shipped a box walk that
//! spun forever on a 64-bit size smaller than its own header; the rules that
//! fixed it are the rules here:
//!
//! - a box whose size does not cover its own header ends the walk, in **both**
//!   size encodings — a zero advance is a hang on a file the user merely put in
//!   a folder;
//! - boxes are budgeted per level ([`MAX_BOXES`]), so a file made of a million
//!   empty boxes costs a bounded walk;
//! - every slice is taken with `get` and clamped to the buffer, never indexed;
//! - an `iloc` extent is refused unless `construction_method` is 0 (a file
//!   offset) and `data_reference_index` is 0 (this file). The `idat` and
//!   item-relative forms are legal and followable; nothing that writes the
//!   metadata this crate reads emits them, and a form that is never exercised
//!   is a form that is never right;
//! - a `length_size` of 0 means "to the end of the file", which is not a bound,
//!   so an `iloc` that declares it is refused outright;
//! - an item's concatenated extents are capped at [`MAX_ITEM_BYTES`] — two
//!   orders of magnitude past any real XMP packet.
//!
//! The descent is **not recursive**. `meta` → {`iinf` → `infe`, `iloc`} is all
//! of it and it is spelled out, so there is no depth to limit: a nested box
//! this module does not name is stepped over, never entered.

/// The `ftyp` brands that mean "this is HEIF or AVIF".
///
/// The still-image brands and their sequence variants, plus the two generic
/// `mif1`/`msf1` structural brands iPhone and libheif both write. Video brands
/// (`isom`, `mp42`, `qt  `) are deliberately absent: an MP4 has no XMP item to
/// find and letting one in here would only widen what gets parsed.
pub const HEIF_BRANDS: &[&[u8; 4]] = &[
    b"heic", b"heix", b"heim", b"heis", b"hevc", b"hevx", b"hevm", b"hevs", b"mif1", b"mif2",
    b"msf1", b"avif", b"avis",
];

/// The `infe` content type that identifies an XMP item.
const XMP_CONTENT_TYPE: &[u8] = b"application/rdf+xml";

/// Ceiling on boxes walked at one level before giving up on a malformed file.
const MAX_BOXES: usize = 4096;

/// Ceiling on `iinf` entries and `iloc` items read.
const MAX_ITEMS: usize = 4096;

/// Ceiling on extents in one `iloc` item. A real XMP or Exif item is one.
const MAX_EXTENTS: usize = 64;

/// Ceiling on the concatenated bytes of one item.
///
/// A camera's XMP packet is tens of kilobytes and Adobe's extended form reaches
/// a few hundred; 4 MB is far past anything real and small enough that a
/// corrupt `iloc` length cannot ask for the world.
const MAX_ITEM_BYTES: usize = 4 << 20;

/// One contiguous run of an item's payload, in **file** coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ItemExtent {
    /// Absolute offset from the start of the file.
    pub offset: u64,
    /// Bytes at that offset.
    pub length: u64,
}

/// The items this reader cares about, as located by a `meta` box.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct MetaItems {
    /// Extents of the XMP packet item, in order.
    pub xmp: Vec<ItemExtent>,
    /// Extents of the Exif item, in order. Not read here — `kamadak-exif`
    /// locates it for itself — but bounding a prefix read needs to know where
    /// it ends.
    pub exif: Vec<ItemExtent>,
}

/// The outcome of looking for the top-level `meta` box.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetaBox<'a> {
    /// Found, and every byte of it is in the buffer.
    Found {
        /// Absolute offset just past the box.
        end: usize,
        /// The box payload, `version`/`flags` included.
        body: &'a [u8],
    },
    /// A box runs past the end of the buffer, so the walk cannot step over it
    /// and a `meta` may still lie ahead. The caller may have more of the file.
    Truncated,
    /// The whole buffer was walked and there is no `meta`.
    Absent,
}

/// Whether `bytes` opens with an `ftyp` box declaring a HEIF or AVIF brand.
///
/// **Major and compatible brands both count.** A HEIC written `mif1`-major with
/// `heic` compatible and one written the other way round are the same file, and
/// which one a given encoder picks is not something a reader gets to depend on.
pub fn is_heif(bytes: &[u8]) -> bool {
    let Step::Box(h) = header_at(bytes, 0) else {
        return false;
    };
    if &h.kind != b"ftyp" {
        return false;
    }
    let end = h.size.min(bytes.len());
    let Some(body) = bytes.get(h.header_len.min(end)..end) else {
        return false;
    };
    // major_brand, minor_version, then the compatible-brand list.
    if body.get(..4).is_some_and(is_heif_brand) {
        return true;
    }
    body.get(8..)
        .is_some_and(|compatible| compatible.chunks_exact(4).any(is_heif_brand))
}

fn is_heif_brand(brand: &[u8]) -> bool {
    HEIF_BRANDS.iter().any(|known| known.as_slice() == brand)
}

/// The XMP packet, if this file has one and it lies inside `bytes`.
///
/// An item located past the end of the buffer comes back as `None` rather than
/// as a partial packet: [`super::prefix`] is what decides how much of the file
/// to hold, and a half-read packet parses to nonsense either way.
pub fn extract_xmp(bytes: &[u8]) -> Option<Vec<u8>> {
    let MetaBox::Found { body, .. } = find_meta(bytes) else {
        return None;
    };
    read_extents(bytes, &meta_items(body).xmp)
}

/// Walk the top-level boxes for `meta`.
pub fn find_meta(bytes: &[u8]) -> MetaBox<'_> {
    let mut i = 0usize;
    for _ in 0..MAX_BOXES {
        match header_at(bytes, i) {
            Step::Box(h) => {
                let Some(end) = i.checked_add(h.size) else {
                    return MetaBox::Absent;
                };
                if &h.kind == b"meta" {
                    return match bytes.get(i + h.header_len..end) {
                        Some(body) => MetaBox::Found { end, body },
                        None => MetaBox::Truncated,
                    };
                }
                if end > bytes.len() {
                    // A box we do not hold all of cannot be stepped over.
                    return MetaBox::Truncated;
                }
                i = end;
            }
            // A clean stop at the last byte is `Absent`; a stub of a header is
            // a buffer that ends mid-file.
            Step::Short => {
                return if i < bytes.len() {
                    MetaBox::Truncated
                } else {
                    MetaBox::Absent
                }
            }
            Step::Malformed => return MetaBox::Absent,
        }
    }
    MetaBox::Absent
}

/// The largest image extent this file *declares*, from the `ispe` properties.
///
/// The point is to have a number **before** decoding. A HEIC's dimensions live
/// in the container, so a caller can refuse a file that claims 40 000 × 40 000
/// without ever handing it to a decoder and asking for the buffer.
///
/// Deliberately the **maximum** over every `ispe`, not the primary item's.
/// Resolving "the primary item's own extent" means `pitm` plus the `ipma`
/// association table, and it would let a file declare a modest primary
/// alongside an enormous auxiliary. The maximum needs neither, and it errs in
/// the only safe direction: a file refused here is a skipped photo, while a
/// file waved through is an allocation nobody bounded.
pub fn max_declared_extent(bytes: &[u8]) -> Option<(u32, u32)> {
    let MetaBox::Found { body, .. } = find_meta(bytes) else {
        return None;
    };
    // `meta` is a FullBox; the QuickTime-shaped fallback is the same one
    // [`meta_items`] makes, for the same reason.
    [4usize, 0]
        .into_iter()
        .filter_map(|skip| body.get(skip..).and_then(largest_ispe))
        .max()
}

/// Walk `iprp` → `ipco` for `ispe` properties and take the largest.
fn largest_ispe(meta_children: &[u8]) -> Option<(u32, u32)> {
    let mut largest: Option<(u32, u32)> = None;
    for (kind, iprp) in boxes(meta_children) {
        if &kind != b"iprp" {
            continue;
        }
        for (kind, ipco) in boxes(iprp) {
            if &kind != b"ipco" {
                continue;
            }
            for (kind, property) in boxes(ipco) {
                if &kind != b"ispe" {
                    continue;
                }
                // FullBox header, then two 32-bit extents.
                let mut c = Cursor::new(property);
                let (Some(_), Some(_), Some(w), Some(h)) = (c.u8(), c.take(3), c.u32(), c.u32())
                else {
                    continue;
                };
                let area = u64::from(w) * u64::from(h);
                if largest.is_none_or(|(lw, lh)| area > u64::from(lw) * u64::from(lh)) {
                    largest = Some((w, h));
                }
            }
        }
    }
    largest
}

/// Read `iinf` and `iloc` out of a `meta` box body.
pub fn meta_items(meta_body: &[u8]) -> MetaItems {
    // `meta` is a FullBox, so its children start four bytes in. QuickTime's
    // same-named box is *not*, and a writer that copied that shape hides its
    // children at offset 0 instead. Both are tried, the spec's first; the
    // fallback can only fire when the spec-shaped read found no item at all.
    for skip in [4usize, 0] {
        let Some(children) = meta_body.get(skip..) else {
            continue;
        };
        let items = items_from_children(children);
        if !items.xmp.is_empty() || !items.exif.is_empty() {
            return items;
        }
    }
    MetaItems::default()
}

fn items_from_children(children: &[u8]) -> MetaItems {
    let mut kinds: Vec<(u32, ItemKind)> = Vec::new();
    let mut locations: Vec<(u32, Vec<ItemExtent>)> = Vec::new();
    for (kind, body) in boxes(children) {
        match &kind {
            b"iinf" => kinds = parse_iinf(body),
            b"iloc" => locations = parse_iloc(body).unwrap_or_default(),
            _ => {}
        }
    }

    let mut out = MetaItems::default();
    for (id, kind) in kinds {
        let Some((_, extents)) = locations.iter().find(|(located, _)| *located == id) else {
            continue;
        };
        // First entry of each kind wins, so a file declaring two XMP items is
        // read the same way twice rather than concatenated into gibberish.
        let slot = match kind {
            ItemKind::Xmp => &mut out.xmp,
            ItemKind::Exif => &mut out.exif,
        };
        if slot.is_empty() {
            slot.clone_from(extents);
        }
    }
    out
}

/// Concatenate an item's extents, clamped to the buffer and capped.
fn read_extents(bytes: &[u8], extents: &[ItemExtent]) -> Option<Vec<u8>> {
    let mut out: Vec<u8> = Vec::new();
    for extent in extents {
        let start = usize::try_from(extent.offset).ok()?;
        let len = usize::try_from(extent.length).ok()?;
        if out.len().checked_add(len)? > MAX_ITEM_BYTES {
            return None;
        }
        out.extend_from_slice(bytes.get(start..start.checked_add(len)?)?);
    }
    (!out.is_empty()).then_some(out)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ItemKind {
    Xmp,
    Exif,
}

/// Item ids and kinds from an `iinf` box body.
///
/// `entry_count` is read past rather than trusted — the `infe` children are
/// walked and budgeted, so a count that disagrees with the payload costs a
/// short list instead of a bad read.
fn parse_iinf(body: &[u8]) -> Vec<(u32, ItemKind)> {
    let mut c = Cursor::new(body);
    let Some(version) = c.u8() else {
        return Vec::new();
    };
    let count_width = if version == 0 { 2 } else { 4 };
    if c.take(3).is_none() || c.take(count_width).is_none() {
        return Vec::new();
    }
    let Some(rest) = body.get(c.at()..) else {
        return Vec::new();
    };

    let mut out = Vec::new();
    for (kind, entry) in boxes(rest) {
        if &kind == b"infe" {
            if let Some(hit) = parse_infe(entry) {
                out.push(hit);
            }
        }
        if out.len() >= MAX_ITEMS {
            break;
        }
    }
    out
}

/// One `infe` entry, if it names an item this reader wants.
fn parse_infe(body: &[u8]) -> Option<(u32, ItemKind)> {
    let mut c = Cursor::new(body);
    let version = c.u8()?;
    c.take(3)?;
    // Versions 0 and 1 have no `item_type` at all; 3 widened the id to 32 bits.
    let typed = version >= 2;
    let id = if version == 3 {
        c.u32()?
    } else {
        u32::from(c.u16()?)
    };
    c.u16()?; // item_protection_index

    if !typed {
        // Untyped entries carry `item_name` then `content_type`, so the MIME
        // form is the only one identifiable — which is all we need.
        c.cstr()?;
        return (c.cstr()? == XMP_CONTENT_TYPE).then_some((id, ItemKind::Xmp));
    }
    let item_type: [u8; 4] = c.take(4)?.try_into().ok()?;
    c.cstr()?; // item_name
    match &item_type {
        b"Exif" => Some((id, ItemKind::Exif)),
        b"mime" => (c.cstr()? == XMP_CONTENT_TYPE).then_some((id, ItemKind::Xmp)),
        _ => None,
    }
}

/// Item locations from an `iloc` box body. `None` for any shape this reader
/// refuses to follow — see the bounding rules on the module.
fn parse_iloc(body: &[u8]) -> Option<Vec<(u32, Vec<ItemExtent>)>> {
    let mut c = Cursor::new(body);
    let version = c.u8()?;
    c.take(3)?;
    let packed = c.u8()?;
    let (offset_size, length_size) = (packed >> 4, packed & 0x0F);
    let packed = c.u8()?;
    let base_offset_size = packed >> 4;
    // The low nibble is `index_size` only from version 1 on; before that it is
    // reserved and no `extent_index` field is present.
    let index_size = if version >= 1 { packed & 0x0F } else { 0 };

    for width in [offset_size, length_size, base_offset_size, index_size] {
        if !matches!(width, 0 | 4 | 8) {
            return None;
        }
    }
    // A zero-width length means "to the end of the file", which is not a bound.
    if length_size == 0 {
        return None;
    }

    let item_count = match version {
        0 | 1 => usize::from(c.u16()?),
        2 => usize::try_from(c.u32()?).ok()?,
        _ => return None,
    };

    let mut out = Vec::new();
    for _ in 0..item_count.min(MAX_ITEMS) {
        let id = if version == 2 {
            c.u32()?
        } else {
            u32::from(c.u16()?)
        };
        let construction = if version >= 1 { c.u16()? & 0x0F } else { 0 };
        let data_reference_index = c.u16()?;
        let base_offset = c.uint(base_offset_size)?;
        let extent_count = usize::from(c.u16()?);
        if extent_count > MAX_EXTENTS {
            // Skipping the extents would leave the cursor mid-item and every
            // later id would be read out of a field that is not an id.
            return None;
        }

        // A followable item is one whose payload is a plain byte range of this
        // file. Its extents are still *read*, so the cursor stays aligned.
        let followable = construction == 0 && data_reference_index == 0;
        let mut extents = Vec::new();
        for _ in 0..extent_count {
            if index_size > 0 {
                c.uint(index_size)?;
            }
            let offset = c.uint(offset_size)?;
            let length = c.uint(length_size)?;
            if let Some(offset) = base_offset.checked_add(offset) {
                extents.push(ItemExtent { offset, length });
            }
        }
        if followable && extents.len() == extent_count && !extents.is_empty() {
            out.push((id, extents));
        }
    }
    Some(out)
}

// ---------------------------------------------------------------------------
// Box walking
// ---------------------------------------------------------------------------

struct Header {
    kind: [u8; 4],
    header_len: usize,
    size: usize,
}

enum Step {
    /// A header whose size can advance the walk.
    Box(Header),
    /// Too few bytes left to read a header. More of the file may follow.
    Short,
    /// A size that would advance the walk by nothing or wrap it backwards.
    Malformed,
}

fn header_at(data: &[u8], at: usize) -> Step {
    let Some(rest) = data.get(at..) else {
        return Step::Short;
    };
    let Some(head) = rest.get(..8) else {
        return Step::Short;
    };
    let size32 = u32::from_be_bytes([head[0], head[1], head[2], head[3]]) as usize;
    let kind = [head[4], head[5], head[6], head[7]];
    let (header_len, size) = match size32 {
        // 64-bit size in the eight bytes after the header.
        1 => {
            let Some(wide) = rest.get(8..16) else {
                return Step::Short;
            };
            let Ok(raw) = <[u8; 8]>::try_from(wide) else {
                return Step::Malformed;
            };
            let Ok(size) = usize::try_from(u64::from_be_bytes(raw)) else {
                return Step::Malformed;
            };
            if size < 16 {
                return Step::Malformed;
            }
            (16usize, size)
        }
        // "to the end of the data" — always the last box.
        0 => (8usize, rest.len()),
        n if n < 8 => return Step::Malformed,
        n => (8usize, n),
    };
    Step::Box(Header {
        kind,
        header_len,
        size,
    })
}

/// The boxes of `data`, each as `(kind, payload)`. Payloads are clamped to the
/// buffer, so a box declaring more than it has yields what it has.
fn boxes(data: &[u8]) -> Boxes<'_> {
    Boxes {
        data,
        at: 0,
        budget: MAX_BOXES,
    }
}

struct Boxes<'a> {
    data: &'a [u8],
    at: usize,
    budget: usize,
}

impl<'a> Iterator for Boxes<'a> {
    type Item = ([u8; 4], &'a [u8]);

    fn next(&mut self) -> Option<Self::Item> {
        self.budget = self.budget.checked_sub(1)?;
        let Step::Box(h) = header_at(self.data, self.at) else {
            return None;
        };
        let end = self.at.checked_add(h.size)?.min(self.data.len());
        let body = self.data.get((self.at + h.header_len).min(end)..end)?;
        self.at = self.at.checked_add(h.size)?;
        Some((h.kind, body))
    }
}

// ---------------------------------------------------------------------------
// Field reading
// ---------------------------------------------------------------------------

/// A forward-only reader over a box body. Every accessor is fallible, so a
/// short body ends a parse instead of indexing past it.
struct Cursor<'a> {
    data: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Cursor { data, at: 0 }
    }

    fn at(&self) -> usize {
        self.at
    }

    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.at.checked_add(n)?;
        let out = self.data.get(self.at..end)?;
        self.at = end;
        Some(out)
    }

    fn u8(&mut self) -> Option<u8> {
        self.take(1).map(|b| b[0])
    }

    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_be_bytes(self.take(2)?.try_into().ok()?))
    }

    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_be_bytes(self.take(4)?.try_into().ok()?))
    }

    /// A big-endian unsigned integer `width` bytes wide. Only 0, 4 and 8 are
    /// legal widths; 0 is the spec's "field absent", which reads as zero and
    /// consumes nothing.
    fn uint(&mut self, width: u8) -> Option<u64> {
        match width {
            0 => Some(0),
            4 => self.u32().map(u64::from),
            8 => Some(u64::from_be_bytes(self.take(8)?.try_into().ok()?)),
            _ => None,
        }
    }

    /// A NUL-terminated string. An unterminated one is malformed, not empty.
    fn cstr(&mut self) -> Option<&'a [u8]> {
        let rest = self.data.get(self.at..)?;
        let n = rest.iter().position(|&b| b == 0)?;
        self.at += n + 1;
        Some(&rest[..n])
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// One item of a synthetic HEIF: its four-CC type, the MIME content type
    /// when that type is `mime`, and its payload.
    pub(crate) struct Item<'a> {
        pub kind: &'a [u8; 4],
        pub content_type: Option<&'a str>,
        pub payload: &'a [u8],
    }

    pub(crate) fn xmp_item(packet: &[u8]) -> Item<'_> {
        Item {
            kind: b"mime",
            content_type: Some("application/rdf+xml"),
            payload: packet,
        }
    }

    pub(crate) fn exif_item(payload: &[u8]) -> Item<'_> {
        Item {
            kind: b"Exif",
            content_type: None,
            payload,
        }
    }

    fn boxed(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut out = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        out.extend_from_slice(kind);
        out.extend_from_slice(payload);
        out
    }

    fn full(kind: &[u8; 4], version: u8, payload: &[u8]) -> Vec<u8> {
        let mut body = vec![version, 0, 0, 0];
        body.extend_from_slice(payload);
        boxed(kind, &body)
    }

    fn infe(id: u16, item: &Item) -> Vec<u8> {
        let mut body = id.to_be_bytes().to_vec();
        body.extend_from_slice(&0u16.to_be_bytes()); // protection index
        body.extend_from_slice(item.kind);
        body.push(0); // empty item_name
        if let Some(ct) = item.content_type {
            body.extend_from_slice(ct.as_bytes());
            body.push(0);
        }
        full(b"infe", 2, &body)
    }

    /// `iloc` version 1, 32-bit offsets and lengths, one extent per item.
    fn iloc(entries: &[(u16, u32, u32)]) -> Vec<u8> {
        let mut body = vec![0x44, 0x00]; // offset_size 4, length_size 4, base 0
        body.extend_from_slice(&(entries.len() as u16).to_be_bytes());
        for (id, offset, length) in entries {
            body.extend_from_slice(&id.to_be_bytes());
            body.extend_from_slice(&0u16.to_be_bytes()); // construction method 0
            body.extend_from_slice(&0u16.to_be_bytes()); // data reference 0
            body.extend_from_slice(&1u16.to_be_bytes()); // extent count
            body.extend_from_slice(&offset.to_be_bytes());
            body.extend_from_slice(&length.to_be_bytes());
        }
        full(b"iloc", 1, &body)
    }

    /// A synthetic HEIF: `ftyp`, a `meta` describing every item, then an `mdat`
    /// holding their payloads at the absolute offsets `iloc` records.
    ///
    /// Assembled twice so the `iloc` offsets can name the `mdat` the `iloc`
    /// itself sits in front of. The field widths are fixed, so the second pass
    /// produces a `meta` of exactly the first pass's size.
    pub(crate) fn heif(brand: &[u8; 4], items: &[Item], padding: usize) -> Vec<u8> {
        let mut ftyp_body = brand.to_vec();
        ftyp_body.extend_from_slice(&0u32.to_be_bytes());
        ftyp_body.extend_from_slice(brand);
        let ftyp = boxed(b"ftyp", &ftyp_body);

        let build = |mdat_start: u32| -> Vec<u8> {
            let mut iinf_body = (items.len() as u16).to_be_bytes().to_vec();
            let mut entries = Vec::new();
            let mut at = mdat_start + 8 + padding as u32;
            for (n, item) in items.iter().enumerate() {
                let id = n as u16 + 1;
                iinf_body.extend_from_slice(&infe(id, item));
                entries.push((id, at, item.payload.len() as u32));
                at += item.payload.len() as u32;
            }
            let mut meta_body = full(b"hdlr", 0, b"\0\0\0\0pict\0\0\0\0\0\0\0\0\0\0\0\0\0");
            meta_body.extend_from_slice(&full(b"iinf", 0, &iinf_body));
            meta_body.extend_from_slice(&iloc(&entries));
            full(b"meta", 0, &meta_body)
        };

        let meta = build(0);
        let meta = build((ftyp.len() + meta.len()) as u32);

        let mut mdat_payload = vec![0x5A; padding];
        for item in items {
            mdat_payload.extend_from_slice(item.payload);
        }
        let mut out = ftyp;
        out.extend_from_slice(&meta);
        out.extend_from_slice(&boxed(b"mdat", &mdat_payload));
        out
    }

    const PACKET: &[u8] = b"<x:xmpmeta><digiKam:TagsList/></x:xmpmeta>";

    #[test]
    fn brands_are_recognised_by_major_and_by_compatible() {
        assert!(is_heif(&heif(b"heic", &[], 0)));
        assert!(is_heif(&heif(b"mif1", &[], 0)));
        assert!(is_heif(&heif(b"avif", &[], 0)));
        // A major brand outside the set is still HEIF if it lists one.
        let mut body = b"isom".to_vec();
        body.extend_from_slice(&0u32.to_be_bytes());
        body.extend_from_slice(b"isomheic");
        assert!(is_heif(&boxed(b"ftyp", &body)));
        // …and a plain MP4 is not.
        assert!(!is_heif(&heif(b"mp42", &[], 0)));
        assert!(!is_heif(b""));
        assert!(!is_heif(b"\xFF\xD8\xFF\xE0 not a box at all"));
    }

    #[test]
    fn the_xmp_item_is_found_past_a_fat_mdat_prefix() {
        let file = heif(b"heic", &[exif_item(b"EXIFBYTES"), xmp_item(PACKET)], 4096);
        assert_eq!(extract_xmp(&file).as_deref(), Some(PACKET));
    }

    #[test]
    fn a_heif_with_only_exif_has_no_packet() {
        let file = heif(b"heic", &[exif_item(b"EXIFBYTES")], 0);
        assert_eq!(extract_xmp(&file), None);

        let MetaBox::Found { body, .. } = find_meta(&file) else {
            panic!("meta box");
        };
        let items = meta_items(body);
        assert!(items.xmp.is_empty());
        assert_eq!(items.exif.len(), 1, "the Exif item is still located");
    }

    /// The bound that matters most: an `iloc` offset is a number in a file, and
    /// a file can say anything. None of these may panic, hang, or hand back
    /// bytes that were never in the item.
    #[test]
    fn hostile_containers_yield_nothing_rather_than_reading_past_the_end() {
        let good = heif(b"heic", &[xmp_item(PACKET)], 0);

        // Truncated at every length: the walk must terminate on all of them.
        for cut in 0..good.len() {
            assert_eq!(extract_xmp(&good[..cut]), None, "truncated to {cut}");
        }

        // An `iloc` extent pointing past EOF.
        let mut past_eof = good.clone();
        let at = find_subsequence(&past_eof, b"iloc").unwrap() + 12;
        past_eof[at..at + 4].copy_from_slice(&u32::MAX.to_be_bytes());
        assert_eq!(extract_xmp(&past_eof), None);

        // …and an extent whose *length* runs off the end.
        let mut long = good.clone();
        long[at + 4..at + 8].copy_from_slice(&u32::MAX.to_be_bytes());
        assert_eq!(extract_xmp(&long), None);

        // A box claiming a size smaller than its own header, in both encodings.
        assert_eq!(extract_xmp(&[0, 0, 0, 1, b'f', b't', b'y', b'p']), None);
        let mut wide = 1u32.to_be_bytes().to_vec();
        wide.extend_from_slice(b"meta");
        wide.extend_from_slice(&0u64.to_be_bytes());
        assert_eq!(find_meta(&wide), MetaBox::Absent);

        // A `meta` with no `iinf` at all.
        let bare = {
            let mut ftyp = b"heic".to_vec();
            ftyp.extend_from_slice(&0u32.to_be_bytes());
            ftyp.extend_from_slice(b"heic");
            let mut out = boxed(b"ftyp", &ftyp);
            out.extend_from_slice(&full(b"meta", 0, &iloc(&[(1, 0, 4)])));
            out
        };
        assert_eq!(extract_xmp(&bare), None);
    }

    /// `construction_method` 1 (`idat`) and 2 (another item) are legal and are
    /// deliberately not followed — following them would read the wrong bytes.
    #[test]
    fn a_non_file_construction_method_is_refused_not_misread() {
        let mut file = heif(b"heic", &[xmp_item(PACKET)], 0);
        let at = find_subsequence(&file, b"iloc").unwrap() + 4;
        // Past version/flags, the two width bytes and item_count, the id: the
        // construction-method half-word.
        let method = at + 4 + 2 + 2 + 2;
        file[method..method + 2].copy_from_slice(&1u16.to_be_bytes());
        assert_eq!(extract_xmp(&file), None);
    }

    /// A million empty boxes is a legal file and must cost a bounded walk.
    #[test]
    fn a_box_storm_terminates() {
        let mut file = {
            let mut ftyp = b"heic".to_vec();
            ftyp.extend_from_slice(&0u32.to_be_bytes());
            ftyp.extend_from_slice(b"heic");
            boxed(b"ftyp", &ftyp)
        };
        for _ in 0..(MAX_BOXES * 2) {
            file.extend_from_slice(&boxed(b"free", b""));
        }
        assert_eq!(extract_xmp(&file), None);
        assert_eq!(find_meta(&file), MetaBox::Absent);
    }

    #[test]
    fn an_infe_naming_something_else_is_not_mistaken_for_xmp() {
        let file = heif(
            b"heic",
            &[
                Item {
                    kind: b"mime",
                    content_type: Some("text/plain"),
                    payload: b"just a note",
                },
                xmp_item(PACKET),
            ],
            0,
        );
        assert_eq!(extract_xmp(&file).as_deref(), Some(PACKET));
    }

    /// The pre-decode bound. A number that is wrong here is a buffer nobody
    /// sized, so the hostile shapes matter as much as the well-formed one.
    #[test]
    fn the_declared_extent_is_read_before_anything_is_decoded() {
        fn with_ispe(extents: &[(u32, u32)]) -> Vec<u8> {
            let mut ipco = Vec::new();
            for (w, h) in extents {
                let mut body = vec![0u8, 0, 0, 0];
                body.extend_from_slice(&w.to_be_bytes());
                body.extend_from_slice(&h.to_be_bytes());
                ipco.extend_from_slice(&boxed(b"ispe", &body));
            }
            let mut ftyp = b"heic".to_vec();
            ftyp.extend_from_slice(&0u32.to_be_bytes());
            ftyp.extend_from_slice(b"heic");
            let mut out = boxed(b"ftyp", &ftyp);
            out.extend_from_slice(&full(b"meta", 0, &boxed(b"iprp", &boxed(b"ipco", &ipco))));
            out
        }

        assert_eq!(
            max_declared_extent(&with_ispe(&[(4032, 3024)])),
            Some((4032, 3024))
        );
        // The largest wins, whatever order the properties appear in.
        assert_eq!(
            max_declared_extent(&with_ispe(&[(320, 240), (4032, 3024), (64, 64)])),
            Some((4032, 3024))
        );
        // An absurd claim is *reported*, not clamped — refusing it is the
        // caller's decision and it needs the real number to make it.
        assert_eq!(
            max_declared_extent(&with_ispe(&[(u32::MAX, u32::MAX)])),
            Some((u32::MAX, u32::MAX))
        );
        // Nothing to report is `None`, not a zero that reads as "tiny".
        assert_eq!(max_declared_extent(&with_ispe(&[])), None);
        assert_eq!(max_declared_extent(&heif(b"heic", &[], 0)), None);
        assert_eq!(max_declared_extent(b"not a container"), None);

        // A truncated `ispe` yields nothing rather than half a dimension.
        let mut cut = with_ispe(&[(4032, 3024)]);
        cut.truncate(cut.len() - 4);
        assert_eq!(max_declared_extent(&cut), None);
    }

    fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack
            .windows(needle.len())
            .position(|window| window == needle)
    }
}
