//! Finding the XMP packet inside an image file.
//!
//! **Content sniffing, not extensions.** ImageIO decides what a file is by
//! looking at its bytes, and the scanner decides by looking at its name — so a
//! PNG called `.jpg` is read fine and a JPEG called `.txt` never arrives
//! (fixture landmine 16, `assets/containers/`). Dispatching on the extension
//! here would quietly re-introduce the disagreement in the wrong direction.
//!
//! # Coverage, and what is missing
//!
//! JPEG (`APP1`), PNG (`iTXt`) and TIFF/DNG (tag 700) are handled. **HEIF and
//! AVIF are not**: their XMP lives in an ISO-BMFF `meta` box behind `iinf`/
//! `iloc`, no fixture exercises it, and a hand-rolled box walk that nothing
//! checks is worse than a documented gap. What that costs in practice is
//! narrow — EXIF dates and GPS in HEIC come through `kamadak-exif`, and the
//! tags/regions this app cares about are written to `.xmp` sidecars — but an
//! iPhone HEIC carrying embedded `digiKam:TagsList` would read as untagged.
//! See the port notes before the Swift swap.

/// Extract the XMP packet, if the container has one and this module can find
/// it. The bytes are the packet as stored — decoding is
/// [`super::swift_xmp::decode_xmp_text`]'s job.
pub fn extract_xmp(bytes: &[u8]) -> Option<Vec<u8>> {
    match bytes {
        [0xFF, 0xD8, ..] => jpeg_xmp(bytes),
        [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, ..] => png_xmp(bytes),
        [b'I', b'I', 0x2A, 0x00, ..] | [b'M', b'M', 0x00, 0x2A, ..] => tiff_xmp(bytes),
        _ => None,
    }
}

/// The APP1 marker segment that carries XMP starts with this NUL-terminated
/// namespace URI.
const JPEG_XMP_HEADER: &[u8] = b"http://ns.adobe.com/xap/1.0/\0";

/// Walk JPEG marker segments looking for the XMP `APP1`.
///
/// Stops at `SOS` (`0xDA`): everything after it is entropy-coded scan data,
/// where a `0xFF 0xE1` byte pair means nothing at all.
///
/// Adobe's *extended* XMP (a second `APP1` with the
/// `http://ns.adobe.com/xmp/extension/` header, used when a packet exceeds
/// 64 KB) is not reassembled. ImageIO does reassemble it; no fixture covers it.
fn jpeg_xmp(bytes: &[u8]) -> Option<Vec<u8>> {
    let mut i = 2usize;
    while i + 1 < bytes.len() {
        if bytes[i] != 0xFF {
            return None; // Not at a marker boundary — the file is malformed.
        }
        let marker = bytes[i + 1];
        match marker {
            // Standalone markers: no length field.
            0xD8 | 0xD9 | 0x01 | 0xD0..=0xD7 => {
                i += 2;
                continue;
            }
            0xDA => return None, // start of scan
            _ => {}
        }
        if i + 4 > bytes.len() {
            return None;
        }
        let len = u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]) as usize;
        if len < 2 || i + 2 + len > bytes.len() {
            return None;
        }
        let payload = &bytes[i + 4..i + 2 + len];
        if marker == 0xE1 {
            if let Some(packet) = payload.strip_prefix(JPEG_XMP_HEADER) {
                return Some(packet.to_vec());
            }
        }
        i += 2 + len;
    }
    None
}

/// PNG keyword for an XMP `iTXt` chunk.
const PNG_XMP_KEYWORD: &[u8] = b"XML:com.adobe.xmp";

/// Walk PNG chunks looking for the XMP `iTXt`.
///
/// A *compressed* `iTXt` (compression flag 1, zlib) is skipped rather than
/// inflated — this crate has no deflate dependency and every writer in the
/// ecosystem stores XMP uncompressed, as the spec recommends.
fn png_xmp(bytes: &[u8]) -> Option<Vec<u8>> {
    let mut i = 8usize;
    while i + 8 <= bytes.len() {
        let len = u32::from_be_bytes(bytes[i..i + 4].try_into().ok()?) as usize;
        let kind = &bytes[i + 4..i + 8];
        let data_start = i + 8;
        let data_end = data_start.checked_add(len)?;
        if data_end + 4 > bytes.len() {
            return None;
        }
        if kind == b"iTXt" {
            // The chunk layout after the keyword: NUL, compression flag,
            // compression method, language tag NUL, translated keyword NUL,
            // then the text. Matching the flag as a literal `0` is what skips
            // a zlib-compressed packet.
            let data = &bytes[data_start..data_end];
            let prefix: Vec<u8> = PNG_XMP_KEYWORD.iter().copied().chain([0u8, 0u8]).collect();
            if let Some([_method, tail @ ..]) = data.strip_prefix(prefix.as_slice()) {
                let after_lang = skip_nul_terminated(tail)?;
                let text = skip_nul_terminated(after_lang)?;
                return Some(text.to_vec());
            }
        }
        if kind == b"IEND" {
            return None;
        }
        i = data_end + 4; // + CRC
    }
    None
}

fn skip_nul_terminated(bytes: &[u8]) -> Option<&[u8]> {
    let end = bytes.iter().position(|&b| b == 0)?;
    Some(&bytes[end + 1..])
}

/// TIFF tag 700 in IFD0 holds the XMP packet as a byte array.
fn tiff_xmp(bytes: &[u8]) -> Option<Vec<u8>> {
    let little = bytes[0] == b'I';
    let u16_at = |off: usize| -> Option<u16> {
        let raw = bytes.get(off..off + 2)?.try_into().ok()?;
        Some(if little {
            u16::from_le_bytes(raw)
        } else {
            u16::from_be_bytes(raw)
        })
    };
    let u32_at = |off: usize| -> Option<u32> {
        let raw = bytes.get(off..off + 4)?.try_into().ok()?;
        Some(if little {
            u32::from_le_bytes(raw)
        } else {
            u32::from_be_bytes(raw)
        })
    };

    let ifd0 = u32_at(4)? as usize;
    let count = u16_at(ifd0)? as usize;
    for n in 0..count {
        let entry = ifd0 + 2 + n * 12;
        if u16_at(entry)? != 700 {
            continue;
        }
        let value_count = u32_at(entry + 8)? as usize;
        // Types 1 (BYTE), 2 (ASCII) and 7 (UNDEFINED) are all one byte wide;
        // anything else is not an XMP packet.
        if !matches!(u16_at(entry + 2)?, 1 | 2 | 7) {
            return None;
        }
        // ≤ 4 bytes live inline, which no real packet is.
        let offset = if value_count <= 4 {
            entry + 8
        } else {
            u32_at(entry + 8)? as usize
        };
        return bytes.get(offset..offset + value_count).map(<[u8]>::to_vec);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jpeg_with_app1(header: &[u8], payload: &[u8]) -> Vec<u8> {
        let mut out = vec![0xFF, 0xD8];
        let body: Vec<u8> = header.iter().chain(payload).copied().collect();
        out.extend_from_slice(&[0xFF, 0xE1]);
        out.extend_from_slice(&((body.len() + 2) as u16).to_be_bytes());
        out.extend_from_slice(&body);
        out.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x02]);
        out
    }

    #[test]
    fn finds_the_xmp_app1_and_skips_the_exif_one() {
        let mut file = vec![0xFF, 0xD8];
        // An EXIF APP1 first, which must not be mistaken for the packet.
        let exif = b"Exif\0\0MM\0*";
        file.extend_from_slice(&[0xFF, 0xE1]);
        file.extend_from_slice(&((exif.len() + 2) as u16).to_be_bytes());
        file.extend_from_slice(exif);
        file.extend_from_slice(&jpeg_with_app1(JPEG_XMP_HEADER, b"<x:xmpmeta/>")[2..]);

        assert_eq!(extract_xmp(&file).as_deref(), Some(&b"<x:xmpmeta/>"[..]));
    }

    #[test]
    fn a_truncated_jpeg_yields_nothing_instead_of_reading_past_the_end() {
        let file = vec![0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0xFF];
        assert_eq!(extract_xmp(&file), None);
        assert_eq!(extract_xmp(&[0xFF, 0xD8]), None);
        assert_eq!(extract_xmp(&[]), None);
    }

    #[test]
    fn png_itxt_is_read_and_a_compressed_one_is_skipped() {
        fn png(compression_flag: u8) -> Vec<u8> {
            let mut data = PNG_XMP_KEYWORD.to_vec();
            data.extend_from_slice(&[0, compression_flag, 0, 0, 0]);
            data.extend_from_slice(b"<x:xmpmeta/>");
            let mut out = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
            out.extend_from_slice(&(data.len() as u32).to_be_bytes());
            out.extend_from_slice(b"iTXt");
            out.extend_from_slice(&data);
            out.extend_from_slice(&[0, 0, 0, 0]); // CRC
            out.extend_from_slice(&[0, 0, 0, 0]);
            out.extend_from_slice(b"IEND");
            out.extend_from_slice(&[0, 0, 0, 0]);
            out
        }
        assert_eq!(extract_xmp(&png(0)).as_deref(), Some(&b"<x:xmpmeta/>"[..]));
        assert_eq!(
            extract_xmp(&png(1)),
            None,
            "zlib-compressed iTXt is skipped"
        );
    }

    #[test]
    fn unknown_containers_report_nothing_rather_than_guessing() {
        assert_eq!(extract_xmp(b"not an image at all"), None);
    }
}
