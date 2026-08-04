//! Video creation date from a QuickTime/ISO-BMFF container.
//!
//! `MetadataReader.readVideoDate` asks `AVURLAsset` for `.creationDate`. What
//! that actually resolves to, and what this module reproduces:
//!
//! 1. **`moov/udta/©day`, and only for QuickTime-branded files.** The identical
//!    atom in an ISO-branded `.mp4` reads as nil — AVFoundation wants
//!    `moov/udta/meta/ilst` there. A parser that accepts `©day` unconditionally
//!    is *more permissive* than the baseline, which is a behaviour change, not
//!    a bug fix (`assets/video/isom_udta.mp4`).
//! 2. **`mvhd` is not consulted.** A file with no `udta` has no creation date
//!    at all, even though `mvhd` carries one; the pipeline then falls back to
//!    filesystem dates (`assets/video/qt_no_date.mov`).
//! 3. **A zone-less `©day` is UTC**, not device-local. EXIF's zone-less dates
//!    are device-local, so the image and video paths disagree about what an
//!    unqualified timestamp means. Both readings are pinned; neither is
//!    negotiable here.

use std::io::{Read, Seek, SeekFrom};

use gallery_model::date::CivilDateTime;
use gallery_vfs::Vfs;

/// The `ftyp` major brand AVFoundation treats as QuickTime.
const QUICKTIME_BRAND: &[u8; 4] = b"qt  ";

/// Ceiling on the `moov` box this reader will pull into memory.
///
/// `moov` holds the sample tables, so it grows with duration rather than with
/// pixels: a couple of MB for an hour of 4K. 64 is far past anything real and
/// still small enough that a corrupt length cannot ask for the world.
const MAX_MOOV_BYTES: u64 = 64 << 20;

/// Ceiling on top-level boxes walked before giving up on a malformed file.
const MAX_TOP_LEVEL_BOXES: usize = 4096;

/// [`read_video_date`] without reading the whole file.
///
/// The enrichment pass runs this over every video in the library, and a video
/// is the one file type in a photo library that is routinely gigabytes. Only
/// two top-level boxes matter — `ftyp` for the brand check and `moov` for the
/// date — and both are found by walking box *headers*, eight bytes at a time.
/// `mdat`, which is all of the size, is never touched.
///
/// The extracted boxes are handed to [`read_video_date`] verbatim, so the
/// pinned AVFoundation quirks (major brand only, no `mvhd` fallback, zone-less
/// `©day` as UTC) are decided in exactly one place.
pub fn read_video_date_at(vfs: &dyn Vfs, path: &str) -> Option<i64> {
    let mut reader = vfs.open(path).ok()?;
    let end = reader.seek(SeekFrom::End(0)).ok()?;
    reader.seek(SeekFrom::Start(0)).ok()?;

    let mut header = [0u8; 16];
    let mut offset = 0u64;
    let mut interesting: Vec<u8> = Vec::new();
    let mut seen_moov = false;

    for _ in 0..MAX_TOP_LEVEL_BOXES {
        if offset + 8 > end {
            break;
        }
        reader.seek(SeekFrom::Start(offset)).ok()?;
        if reader.read_exact(&mut header[..8]).is_err() {
            break;
        }
        let size32 = u32::from_be_bytes(header[0..4].try_into().ok()?) as u64;
        let kind: [u8; 4] = header[4..8].try_into().ok()?;
        let (header_len, size) = match size32 {
            // 64-bit size in the eight bytes that follow the header.
            1 => {
                if reader.read_exact(&mut header[8..16]).is_err() {
                    break;
                }
                (16u64, u64::from_be_bytes(header[8..16].try_into().ok()?))
            }
            // "to end of file" — always the last box.
            0 => (8u64, end - offset),
            n if n < 8 => break, // malformed; a zero-advance would spin
            n => (8u64, n),
        };
        let available = end.saturating_sub(offset).saturating_sub(header_len);
        let payload_len = size.saturating_sub(header_len).min(available);

        let want = match &kind {
            b"ftyp" => Some(payload_len.min(64)),
            b"moov" => Some(payload_len.min(MAX_MOOV_BYTES)),
            _ => None,
        };
        if let Some(want) = want {
            let mut payload = vec![0u8; want as usize];
            reader.seek(SeekFrom::Start(offset + header_len)).ok()?;
            if reader.read_exact(&mut payload).is_err() {
                break;
            }
            // Re-box it at its *real* length so `find_box` walks the copy the
            // same way it would walk the original.
            interesting.extend_from_slice(&((payload.len() + 8) as u32).to_be_bytes());
            interesting.extend_from_slice(&kind);
            interesting.extend_from_slice(&payload);
            seen_moov |= &kind == b"moov";
        }
        offset = offset.checked_add(size)?;
    }

    seen_moov.then(|| read_video_date(&interesting)).flatten()
}

/// Creation date as **seconds since the Unix epoch, UTC**.
///
/// `None` when the file is not QuickTime-branded, carries no `moov/udta/©day`,
/// or the atom's text is not a date this reader understands.
pub fn read_video_date(bytes: &[u8]) -> Option<i64> {
    if !is_quicktime_branded(bytes) {
        return None;
    }
    let moov = find_box(bytes, b"moov")?;
    let udta = find_box(moov, b"udta")?;
    // "©day" — the copyright sign is 0xA9 in the MacRoman-flavoured four-CC
    // space QuickTime uses, not UTF-8.
    let day = find_box(udta, &[0xA9, b'd', b'a', b'y'])?;
    // QuickTime text atom: u16 length, u16 language code, then the bytes.
    if day.len() < 4 {
        return None;
    }
    let len = u16::from_be_bytes([day[0], day[1]]) as usize;
    let text = day.get(4..4 + len)?;
    parse_quicktime_date(std::str::from_utf8(text).ok()?)
}

/// Whether `ftyp`'s **major** brand is `qt  `.
///
/// Compatible brands are not consulted: an `isom` file listing `qt  ` as
/// compatible still reads as nil today, and widening that is the exact
/// permissiveness this port is not allowed to add.
fn is_quicktime_branded(bytes: &[u8]) -> bool {
    match find_box(bytes, b"ftyp") {
        Some(ftyp) => ftyp.get(..4) == Some(QUICKTIME_BRAND),
        // No `ftyp` at all is the pre-2001 QuickTime shape, which starts
        // straight in on `moov`. AVFoundation accepts those as QuickTime.
        None => find_box(bytes, b"moov").is_some(),
    }
}

/// Payload of the first top-level box of type `kind` in `data`.
///
/// Handles 64-bit sizes (`size == 1`) and "to end of file" (`size == 0`).
/// Deliberately shallow: callers descend one level at a time, so a `udta`
/// nested inside a `trak` can never be mistaken for the movie's own.
fn find_box<'a>(data: &'a [u8], kind: &[u8; 4]) -> Option<&'a [u8]> {
    let mut i = 0usize;
    while i + 8 <= data.len() {
        let size32 = u32::from_be_bytes(data[i..i + 4].try_into().ok()?) as usize;
        let this_kind = &data[i + 4..i + 8];
        let (header, size) = match size32 {
            1 => {
                let raw = data.get(i + 8..i + 16)?;
                (16, u64::from_be_bytes(raw.try_into().ok()?) as usize)
            }
            0 => (8, data.len() - i),
            n if n < 8 => return None, // malformed; a zero-advance would spin
            n => (8, n),
        };
        let end = i.checked_add(size)?.min(data.len());
        if this_kind == kind {
            return data.get(i + header..end);
        }
        i += size;
    }
    None
}

/// `yyyy-MM-dd'T'HH:mm:ss` with an optional `±HHMM` / `±HH:MM` / `Z` suffix.
///
/// A missing offset means **UTC** (landmine 13). An offset is applied and the
/// result stored as the instant it denotes: `2018-06-15T14:33:07+0530` is
/// `09:03:07Z`, which is what the fixture records.
fn parse_quicktime_date(raw: &str) -> Option<i64> {
    let s = raw.trim().trim_end_matches('\0');
    if s.len() < 19 {
        return None;
    }
    let (stamp, zone) = s.split_at(19);
    let b = stamp.as_bytes();
    if [b[4], b[7], b[13], b[16]] != *b"--::" || b[10] != b'T' {
        return None;
    }
    let num = |range: std::ops::Range<usize>| -> Option<u32> {
        let part = &stamp[range];
        part.bytes().all(|c| c.is_ascii_digit()).then_some(())?;
        part.parse().ok()
    };
    let civil = CivilDateTime {
        year: num(0..4)? as i32,
        month: num(5..7)?,
        day: num(8..10)?,
        hour: num(11..13)?,
        minute: num(14..16)?,
        second: num(17..19)?,
    };
    if !(1..=12).contains(&civil.month) || civil.day < 1 || civil.day > 31 {
        return None;
    }
    Some(civil.as_naive_unix_secs() - parse_offset_secs(zone)?)
}

/// Seconds to subtract to reach UTC. Absent or `Z` ⇒ 0.
fn parse_offset_secs(zone: &str) -> Option<i64> {
    let zone = zone.trim();
    if zone.is_empty() || zone == "Z" {
        return Some(0);
    }
    let (sign, rest) = match zone.as_bytes().first()? {
        b'+' => (1i64, &zone[1..]),
        b'-' => (-1i64, &zone[1..]),
        _ => return None,
    };
    let digits: String = rest.chars().filter(char::is_ascii_digit).collect();
    if digits.len() != 4 || rest.chars().any(|c| !c.is_ascii_digit() && c != ':') {
        return None;
    }
    let hours: i64 = digits[..2].parse().ok()?;
    let minutes: i64 = digits[2..].parse().ok()?;
    Some(sign * (hours * 3600 + minutes * 60))
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_model::date::AppleDate;

    fn utc(secs: i64) -> String {
        AppleDate::from_unix_secs_f64(secs as f64).to_utc_string()
    }

    fn boxed(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut out = ((payload.len() + 8) as u32).to_be_bytes().to_vec();
        out.extend_from_slice(kind);
        out.extend_from_slice(payload);
        out
    }

    fn movie(day: Option<&str>, brand: &[u8; 4]) -> Vec<u8> {
        let mut ftyp = brand.to_vec();
        ftyp.extend_from_slice(&[0, 0, 0, 0]);
        ftyp.extend_from_slice(brand);
        let mut moov = Vec::new();
        // A decoy `udta` inside a `trak`, to prove the descent is shallow.
        moov.extend_from_slice(&boxed(
            b"trak",
            &boxed(
                b"udta",
                &boxed(
                    &[0xA9, b'd', b'a', b'y'],
                    &text_atom("1999-01-01T00:00:00Z"),
                ),
            ),
        ));
        if let Some(day) = day {
            moov.extend_from_slice(&boxed(
                b"udta",
                &boxed(&[0xA9, b'd', b'a', b'y'], &text_atom(day)),
            ));
        }
        let mut out = boxed(b"ftyp", &ftyp);
        out.extend_from_slice(&boxed(b"moov", &moov));
        out.extend_from_slice(&boxed(b"mdat", b""));
        out
    }

    fn text_atom(text: &str) -> Vec<u8> {
        let mut out = (text.len() as u16).to_be_bytes().to_vec();
        out.extend_from_slice(&0u16.to_be_bytes());
        out.extend_from_slice(text.as_bytes());
        out
    }

    #[test]
    fn an_explicit_utc_offset_reads_as_written() {
        let secs = read_video_date(&movie(Some("2015-01-02T03:04:05+0000"), b"qt  ")).unwrap();
        assert_eq!(utc(secs), "2015-01-02T03:04:05.000Z");
    }

    #[test]
    fn a_non_utc_offset_is_applied() {
        let secs = read_video_date(&movie(Some("2018-06-15T14:33:07+0530"), b"qt  ")).unwrap();
        assert_eq!(utc(secs), "2018-06-15T09:03:07.000Z");
    }

    #[test]
    fn a_zone_less_day_is_utc_not_device_local() {
        let secs = read_video_date(&movie(Some("2019-09-09T09:09:09"), b"qt  ")).unwrap();
        assert_eq!(
            utc(secs),
            "2019-09-09T09:09:09.000Z",
            "the video path and the EXIF path disagree here, on purpose"
        );
    }

    #[test]
    fn an_iso_branded_file_reports_nothing_even_with_the_same_atom() {
        assert_eq!(
            read_video_date(&movie(Some("2017-07-07T07:07:07+0000"), b"isom")),
            None
        );
    }

    #[test]
    fn a_file_with_no_udta_reports_nothing() {
        assert_eq!(read_video_date(&movie(None, b"qt  ")), None);
    }

    #[test]
    fn garbage_is_not_a_video() {
        assert_eq!(read_video_date(b""), None);
        assert_eq!(read_video_date(b"not a movie at all"), None);
        // A box claiming a size smaller than its own header must not loop.
        assert_eq!(read_video_date(&[0, 0, 0, 1, b'f', b't', b'y', b'p']), None);
    }

    /// The streaming reader must agree with the whole-file one on every shape
    /// the fixtures pin — and must not read the payload to get there.
    #[test]
    fn the_streaming_reader_agrees_with_the_whole_file_one() {
        use gallery_vfs::{StdVfs, Vfs};

        let dir = tempfile::tempdir().unwrap();
        let cases: Vec<(&str, Vec<u8>)> = vec![
            ("utc.mov", movie(Some("2015-01-02T03:04:05+0000"), b"qt  ")),
            ("offset.mov", movie(Some("2018-06-15T14:33:07+0530"), b"qt  ")),
            ("naive.mov", movie(Some("2019-09-09T09:09:09"), b"qt  ")),
            ("isom.mp4", movie(Some("2017-07-07T07:07:07+0000"), b"isom")),
            ("nodate.mov", movie(None, b"qt  ")),
            ("garbage.mov", b"not a movie at all".to_vec()),
            ("empty.mov", Vec::new()),
        ];
        for (name, mut bytes) in cases {
            // A fat `mdat` after `moov`, so a reader that slurps the file
            // would be doing something visibly different from one that walks
            // box headers.
            if !bytes.is_empty() {
                bytes.extend_from_slice(&boxed(b"mdat", &vec![0u8; 4 << 20]));
            }
            let path = dir.path().join(name);
            std::fs::write(&path, &bytes).unwrap();
            assert_eq!(
                read_video_date_at(&StdVfs::new(), path.to_str().unwrap()),
                read_video_date(&bytes),
                "{name}"
            );
        }

        // A file that does not exist is not a video.
        assert_eq!(
            read_video_date_at(&StdVfs::new(), "/definitely/not/here.mov"),
            None
        );
        // …and neither is a directory the VFS refuses to open as a file.
        assert!(StdVfs::new().exists(dir.path().to_str().unwrap()));
    }

    /// `moov` before `ftyp` is unusual and legal; the brand check still has to
    /// see the `ftyp`, so the walk cannot stop at the first interesting box.
    #[test]
    fn a_movie_whose_moov_precedes_its_ftyp_still_has_its_brand_checked() {
        use gallery_vfs::StdVfs;

        let moov = boxed(
            b"moov",
            &boxed(
                b"udta",
                &boxed(
                    &[0xA9, b'd', b'a', b'y'],
                    &text_atom("2015-01-02T03:04:05+0000"),
                ),
            ),
        );
        let mut ftyp_payload = b"isom".to_vec();
        ftyp_payload.extend_from_slice(&[0, 0, 0, 0]);
        ftyp_payload.extend_from_slice(b"isom");

        let mut bytes = moov;
        bytes.extend_from_slice(&boxed(b"ftyp", &ftyp_payload));

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("reordered.mp4");
        std::fs::write(&path, &bytes).unwrap();
        assert_eq!(
            read_video_date_at(&StdVfs::new(), path.to_str().unwrap()),
            None,
            "an ISO brand behind the moov must still disqualify the file"
        );
        assert_eq!(read_video_date_at(&StdVfs::new(), path.to_str().unwrap()), read_video_date(&bytes));
    }

    #[test]
    fn offsets_parse_in_every_spelling_the_wild_uses() {
        assert_eq!(parse_offset_secs(""), Some(0));
        assert_eq!(parse_offset_secs("Z"), Some(0));
        assert_eq!(parse_offset_secs("+0000"), Some(0));
        assert_eq!(parse_offset_secs("+05:30"), Some(19_800));
        assert_eq!(parse_offset_secs("-0800"), Some(-28_800));
        assert_eq!(parse_offset_secs("+5"), None);
        assert_eq!(parse_offset_secs("nonsense"), None);
    }
}
