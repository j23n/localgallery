//! Reading only as much of an image as its metadata can possibly occupy.
//!
//! [`super::read_image_metadata`] used to `read()` the whole file. Enrichment
//! runs it eight-wide over the library, and the library contains RAW files:
//! eight concurrent 100 MB DNGs is 800 MB of transient allocation on a phone,
//! for two things — an EXIF IFD and an XMP packet — that live in a bounded
//! prefix of every container this crate can parse.
//!
//! So the read is bounded instead. Both consumers (`kamadak-exif` and
//! [`super::container::extract_xmp`]) walk the container's own structure from
//! the front, and both stop where pixel data begins; this module finds that
//! point by walking *headers* and hands back the bytes in front of it.
//!
//! # What is deliberately not read
//!
//! | container | boundary | what that costs |
//! |---|---|---|
//! | JPEG | the `SOS` marker | nothing: everything after `SOS` is entropy-coded scan data, which is where both parsers already stopped |
//! | PNG | the first `IDAT` chunk | an `iTXt`/`eXIf` chunk placed *after* the image data is missed. The spec allows it; no writer in the ecosystem does it — libpng, exiftool and ImageMagick all emit text and EXIF chunks ahead of `IDAT` |
//! | TIFF/DNG | [`TIFF_PREFIX_BYTES`] | tag 700 (XMP) or an EXIF IFD stored past 8 MB into a large RAW is missed. Both are written near the front by every camera and by Adobe's converter |
//! | HEIF/AVIF | the far end of the `meta` box and of the items it locates | nothing: `iloc` states exactly where the XMP and Exif items end, so the read stops there instead of at [`DEFAULT_PREFIX_BYTES`]. A file whose items lie past that cap falls back to it and is read exactly as before |
//! | WebP, unrecognised | [`DEFAULT_PREFIX_BYTES`] | nothing for a real photo — 16 MB reads an entire HEIC several times over. It exists so a 4 GB file named `.heic` cannot ask for 4 GB |
//!
//! Every one of those is a *narrowing*: the reader can now miss metadata it
//! would previously have found, and can never find metadata it would previously
//! have missed. A file small enough to fit in the first read is handed back
//! whole, so the overwhelming majority of the library is bit-for-bit unaffected.

use std::io::Read;

use gallery_vfs::Vfs;

use super::isobmff;

/// First read. Sized so almost every file needs exactly one: a JPEG's `APP1`
/// segments sit at the front and the format caps one at 64 KB, and a PNG's
/// ancillary chunks precede `IDAT`.
const FIRST_CHUNK: usize = 64 << 10;

/// Ceiling on one subsequent read, so a file whose metadata region really is
/// large is reached in a handful of syscalls rather than hundreds.
const MAX_CHUNK: usize = 4 << 20;

/// How far a JPEG or PNG walk goes looking for the end of the metadata region.
///
/// A well-formed file reaches `SOS`/`IDAT` in the first chunk; this is the
/// bound for one that does not — a truncated download, or a marker chain that
/// leads nowhere.
const STRUCTURED_SCAN_CAP: usize = 16 << 20;

/// Prefix of a TIFF or DNG that is read. Well past where any camera or
/// converter writes IFD0 and the XMP tag, and far below the 100 MB+ a RAW file
/// reaches.
pub(crate) const TIFF_PREFIX_BYTES: usize = 8 << 20;

/// Prefix read for a container this module cannot walk — HEIF, AVIF, WebP and
/// anything unrecognised. Generous enough to contain a whole HEIC.
pub(crate) const DEFAULT_PREFIX_BYTES: usize = 16 << 20;

/// The bytes of `path` that can possibly carry metadata.
///
/// An unopenable file, and one whose reads fail partway, both come back as
/// however much was read — nothing, for a missing file. That matches what the
/// whole-file read did: [`super::read_image_metadata`] treats an unreadable
/// image as an image with no metadata, because the `.xmp` beside it is read
/// either way (`assets/containers/zero_byte.jpg`).
pub fn read_metadata_prefix(vfs: &dyn Vfs, path: &str) -> Vec<u8> {
    let Ok(mut reader) = vfs.open(path) else {
        return Vec::new();
    };
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = FIRST_CHUNK;

    loop {
        let want = chunk.min(cap_for(&buf).saturating_sub(buf.len()));
        if want == 0 {
            break;
        }
        let more = append(&mut *reader, &mut buf, want);
        if let Some(end) = metadata_end(&buf) {
            buf.truncate(end);
            return buf;
        }
        if !more {
            break; // end of file, or a read that failed
        }
        chunk = chunk.saturating_mul(4).min(MAX_CHUNK);
    }

    let cap = cap_for(&buf);
    buf.truncate(buf.len().min(cap));
    buf
}

/// Append up to `want` more bytes. `false` once the stream is exhausted or a
/// read failed — whatever was read stays in `buf` either way.
fn append(reader: &mut dyn Read, buf: &mut Vec<u8>, want: usize) -> bool {
    let start = buf.len();
    buf.resize(start + want, 0);
    let mut filled = start;
    let mut exhausted = true;
    while filled < buf.len() {
        match reader.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    if filled == buf.len() {
        exhausted = false;
    }
    buf.truncate(filled);
    !exhausted
}

/// How far this container is allowed to be read. An empty buffer has not
/// declared itself yet, so it gets the loosest cap.
fn cap_for(bytes: &[u8]) -> usize {
    match bytes {
        [0xFF, 0xD8, ..] | [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, ..] => {
            STRUCTURED_SCAN_CAP
        }
        [b'I', b'I', 0x2A, 0x00, ..] | [b'M', b'M', 0x00, 0x2A, ..] => TIFF_PREFIX_BYTES,
        _ => DEFAULT_PREFIX_BYTES,
    }
}

/// Where the metadata region ends, if that is visible in `bytes` yet.
///
/// `None` means the walk ran out of bytes mid-structure and the caller should
/// read more (or stop, if there is no more).
fn metadata_end(bytes: &[u8]) -> Option<usize> {
    match bytes {
        [0xFF, 0xD8, ..] => jpeg_end(bytes),
        [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, ..] => png_end(bytes),
        _ => heif_end(bytes).or_else(|| {
            // TIFF, a HEIF whose `meta` is not in hand yet, and everything
            // unrecognised have no cheap structural boundary; their cap *is*
            // the boundary, reached by reading up to it.
            let cap = cap_for(bytes);
            (bytes.len() >= cap).then_some(cap)
        }),
    }
}

/// Where a HEIF's metadata region ends: past the `meta` box, and past the far
/// end of every item it locates.
///
/// `None` for anything that is not a HEIF, and for one whose `meta` box or
/// located items are not all in the buffer yet — which is the read loop's
/// signal to fetch more, bounded by [`cap_for`] exactly as before. So this can
/// only ever *shorten* a HEIF read, never lengthen one.
fn heif_end(bytes: &[u8]) -> Option<usize> {
    if !isobmff::is_heif(bytes) {
        return None;
    }
    let isobmff::MetaBox::Found { end, body } = isobmff::find_meta(bytes) else {
        return None;
    };
    let items = isobmff::meta_items(body);
    let mut needed = end;
    for extent in items.xmp.iter().chain(&items.exif) {
        let far = extent.offset.saturating_add(extent.length);
        needed = needed.max(usize::try_from(far).unwrap_or(usize::MAX));
    }
    (needed <= bytes.len()).then_some(needed)
}

/// Offset just past the `SOS` marker, where JPEG scan data begins.
///
/// The same marker walk [`super::container::extract_xmp`] does, minus the
/// payload inspection.
fn jpeg_end(bytes: &[u8]) -> Option<usize> {
    let mut i = 2usize;
    loop {
        if i + 1 >= bytes.len() {
            return None;
        }
        if bytes[i] != 0xFF {
            return Some(i); // malformed: stop where the parsers stop
        }
        let marker = bytes[i + 1];
        match marker {
            // Standalone markers carry no length field.
            0xD8 | 0xD9 | 0x01 | 0xD0..=0xD7 => {
                i += 2;
                continue;
            }
            // Start of scan: everything after it is entropy-coded pixel data.
            0xDA => return Some(i + 2),
            _ => {}
        }
        if i + 4 > bytes.len() {
            return None;
        }
        let len = u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
        if len < 2 {
            return Some(i); // malformed
        }
        i = i.checked_add(2 + len)?;
    }
}

/// Offset of the first `IDAT` (or `IEND`) chunk header — where PNG pixel data
/// begins and the ancillary chunks both parsers read have ended.
fn png_end(bytes: &[u8]) -> Option<usize> {
    let mut i = 8usize;
    loop {
        if i + 8 > bytes.len() {
            return None;
        }
        let len = u32::from_be_bytes(bytes[i..i + 4].try_into().ok()?) as usize;
        let kind = &bytes[i + 4..i + 8];
        if kind == b"IDAT" || kind == b"IEND" {
            return Some(i);
        }
        // length + type + payload + CRC
        i = i.checked_add(12)?.checked_add(len)?;
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::{Seek, SeekFrom};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    use gallery_vfs::MemVfs;

    /// A [`MemVfs`] that counts every byte handed out through a reader — the
    /// only way to assert "this did not slurp the file".
    pub(crate) struct CountingVfs {
        inner: MemVfs,
        read: Arc<AtomicU64>,
    }

    struct Counting {
        inner: Box<dyn gallery_vfs::ReadSeek + Send>,
        counter: Arc<AtomicU64>,
    }

    impl Read for Counting {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let n = self.inner.read(buf)?;
            self.counter.fetch_add(n as u64, Ordering::Relaxed);
            Ok(n)
        }
    }

    impl Seek for Counting {
        fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
            self.inner.seek(pos)
        }
    }

    impl CountingVfs {
        pub(crate) fn new() -> Self {
            CountingVfs {
                inner: MemVfs::new(),
                read: Arc::new(AtomicU64::new(0)),
            }
        }
        pub(crate) fn insert(&self, path: &str, bytes: Vec<u8>) {
            self.inner.insert(path, bytes);
        }
        pub(crate) fn bytes_read(&self) -> u64 {
            self.read.load(Ordering::Relaxed)
        }
    }

    impl Vfs for CountingVfs {
        fn open(
            &self,
            path: &str,
        ) -> gallery_vfs::VfsResult<Box<dyn gallery_vfs::ReadSeek + Send>> {
            Ok(Box::new(Counting {
                inner: self.inner.open(path)?,
                counter: Arc::clone(&self.read),
            }))
        }
        fn stat(&self, path: &str) -> gallery_vfs::VfsResult<gallery_vfs::Stat> {
            self.inner.stat(path)
        }
        fn list(&self, dir: &str) -> gallery_vfs::VfsResult<Vec<gallery_vfs::Entry>> {
            self.inner.list(dir)
        }
        fn stat_entry(&self, path: &str) -> gallery_vfs::VfsResult<gallery_vfs::Entry> {
            self.inner.stat_entry(path)
        }
        fn write_atomic(&self, path: &str, bytes: &[u8]) -> gallery_vfs::VfsResult<()> {
            self.inner.write_atomic(path, bytes)
        }
        fn exists(&self, path: &str) -> bool {
            self.inner.exists(path)
        }
    }

    /// A JPEG whose XMP `APP1` is at the front and whose scan data is `bulk`
    /// bytes of nothing.
    pub(crate) fn fat_jpeg(packet: &[u8], bulk: usize) -> Vec<u8> {
        let mut out = vec![0xFF, 0xD8];
        let mut body = b"http://ns.adobe.com/xap/1.0/\0".to_vec();
        body.extend_from_slice(packet);
        out.extend_from_slice(&[0xFF, 0xE1]);
        out.extend_from_slice(&((body.len() + 2) as u16).to_be_bytes());
        out.extend_from_slice(&body);
        out.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x02]);
        out.extend_from_slice(&vec![0x5A; bulk]);
        out
    }

    /// A PNG with one XMP `iTXt`, then `bulk` bytes of `IDAT`.
    pub(crate) fn fat_png(packet: &[u8], bulk: usize) -> Vec<u8> {
        let mut data = b"XML:com.adobe.xmp".to_vec();
        data.extend_from_slice(&[0, 0, 0, 0, 0]);
        data.extend_from_slice(packet);
        let mut out = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(b"iTXt");
        out.extend_from_slice(&data);
        out.extend_from_slice(&[0, 0, 0, 0]); // CRC
        out.extend_from_slice(&(bulk as u32).to_be_bytes());
        out.extend_from_slice(b"IDAT");
        out.extend_from_slice(&vec![0x5A; bulk]);
        out.extend_from_slice(&[0, 0, 0, 0]); // CRC
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.extend_from_slice(b"IEND");
        out.extend_from_slice(&[0, 0, 0, 0]);
        out
    }

    #[test]
    fn a_jpegs_prefix_stops_at_the_start_of_scan() {
        let vfs = CountingVfs::new();
        vfs.insert("/lib/fat.jpg", fat_jpeg(b"<x:xmpmeta/>", 8 << 20));

        let prefix = read_metadata_prefix(&vfs, "/lib/fat.jpg");
        assert!(prefix.len() < 1024, "prefix was {} bytes", prefix.len());
        assert_eq!(prefix.last().copied(), Some(0xDA), "SOS is the boundary");
        assert_eq!(
            vfs.bytes_read(),
            FIRST_CHUNK as u64,
            "one chunk, off an 8 MB file"
        );
        assert_eq!(
            super::super::extract_xmp(&prefix).as_deref(),
            Some(&b"<x:xmpmeta/>"[..]),
            "the packet has to survive the truncation"
        );
    }

    #[test]
    fn a_pngs_prefix_stops_at_the_first_idat() {
        let vfs = CountingVfs::new();
        vfs.insert("/lib/fat.png", fat_png(b"<x:xmpmeta/>", 8 << 20));

        let prefix = read_metadata_prefix(&vfs, "/lib/fat.png");
        assert!(prefix.len() < 1024, "prefix was {} bytes", prefix.len());
        assert_eq!(vfs.bytes_read(), FIRST_CHUNK as u64);
        assert_eq!(
            super::super::extract_xmp(&prefix).as_deref(),
            Some(&b"<x:xmpmeta/>"[..])
        );
    }

    #[test]
    fn a_tiff_is_capped_rather_than_walked() {
        let vfs = CountingVfs::new();
        let mut file = vec![b'I', b'I', 0x2A, 0x00];
        file.extend_from_slice(&vec![0u8; (TIFF_PREFIX_BYTES * 2) - 4]);
        vfs.insert("/lib/raw.dng", file);

        let prefix = read_metadata_prefix(&vfs, "/lib/raw.dng");
        assert_eq!(prefix.len(), TIFF_PREFIX_BYTES);
        assert_eq!(
            vfs.bytes_read(),
            TIFF_PREFIX_BYTES as u64,
            "a 16 MB RAW must cost 8 MB, not 16"
        );
    }

    #[test]
    fn an_unrecognised_container_is_capped_too() {
        let vfs = CountingVfs::new();
        vfs.insert(
            "/lib/mystery.heic",
            vec![0x11; DEFAULT_PREFIX_BYTES + (1 << 20)],
        );
        assert_eq!(
            read_metadata_prefix(&vfs, "/lib/mystery.heic").len(),
            DEFAULT_PREFIX_BYTES
        );
        assert_eq!(vfs.bytes_read(), DEFAULT_PREFIX_BYTES as u64);
    }

    /// `iloc` says where the items end, so a HEIC costs the front of the file
    /// rather than the 16 MB cap an unwalkable container gets.
    #[test]
    fn a_heifs_prefix_stops_where_iloc_says_its_items_do() {
        use super::super::isobmff::tests::{heif, xmp_item};

        let vfs = CountingVfs::new();
        let packet = br#"<digiKam:TagsList><rdf:Seq><rdf:li>Scenes/Beach</rdf:li></rdf:Seq></digiKam:TagsList>"#;
        let mut file = heif(b"heic", &[xmp_item(packet)], 0);
        // Pixel data after the items, which no metadata read needs.
        file.extend_from_slice(&vec![0x5A; 8 << 20]);
        vfs.insert("/lib/photo.heic", file);

        let prefix = read_metadata_prefix(&vfs, "/lib/photo.heic");
        assert!(prefix.len() < 1024, "prefix was {} bytes", prefix.len());
        assert_eq!(
            vfs.bytes_read(),
            FIRST_CHUNK as u64,
            "one chunk, off an 8 MB file"
        );
        assert_eq!(
            super::super::extract_xmp(&prefix).as_deref(),
            Some(&packet[..]),
            "the packet has to survive the truncation"
        );
    }

    /// An item beyond the first chunk is still reached — the loop reads on
    /// until `iloc`'s far end is in hand, and no further.
    #[test]
    fn a_heif_whose_items_sit_past_the_first_chunk_is_read_to_them_and_no_more() {
        use super::super::isobmff::tests::{heif, xmp_item};

        let vfs = CountingVfs::new();
        let packet = b"<x:xmpmeta><digiKam:TagsList/></x:xmpmeta>";
        let padding = 1 << 20;
        let mut file = heif(b"heic", &[xmp_item(packet)], padding);
        file.extend_from_slice(&vec![0x5A; 8 << 20]);
        vfs.insert("/lib/far.heic", file);

        let prefix = read_metadata_prefix(&vfs, "/lib/far.heic");
        assert!(
            prefix.len() > padding && prefix.len() < padding + 4096,
            "prefix was {} bytes for a packet {padding} bytes in",
            prefix.len()
        );
        assert_eq!(
            super::super::extract_xmp(&prefix).as_deref(),
            Some(&packet[..])
        );
        assert!(
            vfs.bytes_read() < (DEFAULT_PREFIX_BYTES as u64),
            "read {} bytes, which is the unwalkable-container cap",
            vfs.bytes_read()
        );
    }

    #[test]
    fn small_files_are_read_whole_and_missing_ones_are_empty() {
        let vfs = CountingVfs::new();
        vfs.insert("/lib/tiny.bin", b"not an image at all".to_vec());
        assert_eq!(
            read_metadata_prefix(&vfs, "/lib/tiny.bin"),
            b"not an image at all"
        );
        vfs.insert("/lib/zero.jpg", Vec::new());
        assert!(read_metadata_prefix(&vfs, "/lib/zero.jpg").is_empty());
        assert!(read_metadata_prefix(&vfs, "/lib/absent.jpg").is_empty());
    }

    /// A container that never reaches its boundary — a truncated download —
    /// must settle for what it has instead of asking for bytes that are not
    /// there, and must terminate while doing it.
    #[test]
    fn a_truncated_container_terminates() {
        let vfs = CountingVfs::new();
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE1];
        jpeg.extend_from_slice(&0xFFFFu16.to_be_bytes());
        jpeg.extend_from_slice(&[0u8; 100]);
        vfs.insert("/lib/cut.jpg", jpeg.clone());
        assert_eq!(read_metadata_prefix(&vfs, "/lib/cut.jpg"), jpeg);

        // …and a PNG whose chunk length points past the end of the universe.
        let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        png.extend_from_slice(&u32::MAX.to_be_bytes());
        png.extend_from_slice(b"tEXt");
        vfs.insert("/lib/cut.png", png.clone());
        assert_eq!(read_metadata_prefix(&vfs, "/lib/cut.png"), png);
    }
}
