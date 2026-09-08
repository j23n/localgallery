//! Freedesktop [Thumbnail Managing Standard] cache.
//!
//! `$XDG_CACHE_HOME/thumbnails/{normal,large,x-large,xx-large}/<md5(file URI)>.png`
//! is what Nautilus, Tumbler and most Linux file managers already write. We
//! read those first and, on a miss, write the same layout so other apps reuse
//! our decode (including HEIC, which tumbler often cannot).
//!
//! Display only. Tagging and faces never read these PNGs — they decode the
//! original through the core's pinned path. The viewer is not a thumbnail;
//! it decodes the file at the window long side (see [`crate::display`]).
//!
//! [Thumbnail Managing Standard]: https://specifications.freedesktop.org/thumbnail/latest/

use std::fs::{self, File};
use std::io::{BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use gallery_model::file_url::file_url_string;
use md5::{Digest, Md5};

use crate::decode::RgbFrame;

/// Spec buckets. Long side must not exceed the named size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThumbSize {
    /// 128 px — `normal/`
    Normal,
    /// 256 px — `large/`
    Large,
    /// 512 px — `x-large/`
    XLarge,
    /// 1024 px — `xx-large/`
    XXLarge,
}

impl ThumbSize {
    /// Long-side cap for this bucket.
    pub fn max_side(self) -> u32 {
        match self {
            ThumbSize::Normal => 128,
            ThumbSize::Large => 256,
            ThumbSize::XLarge => 512,
            ThumbSize::XXLarge => 1024,
        }
    }

    /// Directory name under `thumbnails/`.
    pub fn dir_name(self) -> &'static str {
        match self {
            ThumbSize::Normal => "normal",
            ThumbSize::Large => "large",
            ThumbSize::XLarge => "x-large",
            ThumbSize::XXLarge => "xx-large",
        }
    }

    /// Smallest bucket that can hold `need` CSS/device pixels.
    pub fn for_request(need: u32) -> Self {
        if need <= 128 {
            ThumbSize::Normal
        } else if need <= 256 {
            ThumbSize::Large
        } else if need <= 512 {
            ThumbSize::XLarge
        } else {
            ThumbSize::XXLarge
        }
    }

    fn and_larger(self) -> impl Iterator<Item = ThumbSize> {
        const ALL: [ThumbSize; 4] = [
            ThumbSize::Normal,
            ThumbSize::Large,
            ThumbSize::XLarge,
            ThumbSize::XXLarge,
        ];
        ALL.into_iter()
            .filter(move |s| s.max_side() >= self.max_side())
    }
}

/// `$XDG_CACHE_HOME/thumbnails` (or `~/.cache/thumbnails`).
pub fn cache_root() -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("thumbnails")
}

/// Canonical `file://` URI the spec hashes. Same escaping as the snapshot.
pub fn file_uri(path: &str) -> String {
    file_url_string(path)
}

/// Lowercase hex MD5 of `uri` (the URI string, not the file bytes).
pub fn uri_hash(uri: &str) -> String {
    let digest = Md5::digest(uri.as_bytes());
    format!("{digest:x}")
}

/// Absolute path of the PNG for `uri` in `size`.
pub fn thumb_path(root: &Path, size: ThumbSize, uri: &str) -> PathBuf {
    root.join(size.dir_name())
        .join(format!("{}.png", uri_hash(uri)))
}

/// Load a valid cached thumbnail, trying `want` then any larger bucket.
///
/// `None` if nothing is on disk or the original is newer than the cache.
pub fn lookup(root: &Path, path: &str, want: ThumbSize) -> Option<RgbFrame> {
    if is_inside_thumbnail_cache(root, path) {
        return None;
    }
    let uri = file_uri(path);
    let mtime = file_mtime_secs(Path::new(path))?;
    for size in want.and_larger() {
        let png = thumb_path(root, size, &uri);
        if !is_fresh(&png, mtime) {
            continue;
        }
        let bytes = fs::read(&png).ok()?;
        let img = image::load_from_memory(&bytes).ok()?;
        let img = if img.width().max(img.height()) > want.max_side() {
            img.thumbnail(want.max_side(), want.max_side())
        } else {
            img
        };
        let rgb = img.to_rgb8();
        return Some(RgbFrame {
            width: rgb.width(),
            height: rgb.height(),
            rgb: rgb.into_raw(),
        });
    }
    None
}

/// Decode `path` to `want` and write a spec-compliant PNG into `root`.
pub fn generate(root: &Path, path: &str, want: ThumbSize) -> Option<RgbFrame> {
    if is_inside_thumbnail_cache(root, path) {
        return None;
    }
    let frame = crate::decode::decode_limited(path, want.max_side())?;
    let _ = store(root, path, want, &frame);
    Some(frame)
}

/// `lookup`, then `generate` on a miss.
pub fn load_or_make(root: &Path, path: &str, want: ThumbSize) -> Option<RgbFrame> {
    lookup(root, path, want).or_else(|| generate(root, path, want))
}

/// Write `frame` as a PNG with `Thumb::URI` and `Thumb::MTime`.
pub fn store(root: &Path, path: &str, size: ThumbSize, frame: &RgbFrame) -> std::io::Result<()> {
    let uri = file_uri(path);
    let dest = thumb_path(root, size, &uri);
    if let Some(dir) = dest.parent() {
        fs::create_dir_all(dir)?;
    }
    let mtime = file_mtime_secs(Path::new(path)).unwrap_or(0);
    let tmp = dest.with_file_name(format!(".{}.tmp-{}", uri_hash(&uri), std::process::id()));
    {
        let file = File::create(&tmp)?;
        let mut encoder = png::Encoder::new(BufWriter::new(file), frame.width, frame.height);
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        let png_err = |e| std::io::Error::new(std::io::ErrorKind::InvalidData, e);
        encoder
            .add_text_chunk("Thumb::URI".into(), uri)
            .map_err(png_err)?;
        encoder
            .add_text_chunk("Thumb::MTime".into(), mtime.to_string())
            .map_err(png_err)?;
        if let Ok(meta) = fs::metadata(path) {
            encoder
                .add_text_chunk("Thumb::Size".into(), meta.len().to_string())
                .map_err(png_err)?;
        }
        encoder
            .add_text_chunk("Software".into(), "LocalGallery".into())
            .map_err(png_err)?;
        let mut writer = encoder.write_header().map_err(png_err)?;
        writer.write_image_data(&frame.rgb).map_err(png_err)?;
        writer.finish().map_err(png_err)?;
    }
    fs::rename(&tmp, &dest).or_else(|_| {
        fs::copy(&tmp, &dest)?;
        fs::remove_file(&tmp)
    })?;
    Ok(())
}

fn is_fresh(png: &Path, original_mtime: i64) -> bool {
    if !png.is_file() {
        return false;
    }
    if let Some(stored) = png_thumb_mtime(png) {
        return stored == original_mtime;
    }
    file_mtime_secs(png).is_some_and(|thumb| thumb >= original_mtime)
}

fn png_thumb_mtime(path: &Path) -> Option<i64> {
    let file = File::open(path).ok()?;
    let decoder = png::Decoder::new(BufReader::new(file));
    let reader = decoder.read_info().ok()?;
    for chunk in &reader.info().uncompressed_latin1_text {
        if chunk.keyword == "Thumb::MTime" {
            return chunk.text.parse().ok();
        }
    }
    None
}

fn file_mtime_secs(path: &Path) -> Option<i64> {
    let modified = fs::metadata(path).ok()?.modified().ok()?;
    Some(
        modified
            .duration_since(SystemTime::UNIX_EPOCH)
            .ok()?
            .as_secs() as i64,
    )
}

fn is_inside_thumbnail_cache(root: &Path, path: &str) -> bool {
    Path::new(path).starts_with(root)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spec_example_hash() {
        // https://specifications.freedesktop.org/thumbnail/latest/thumbsave.html
        let uri = file_uri("/home/jens/photos/me.png");
        assert_eq!(uri, "file:///home/jens/photos/me.png");
        assert_eq!(uri_hash(&uri), "c6ee772d9e49320e97ec29a7eb5b1697");
    }

    #[test]
    fn bucket_for_request_picks_the_smallest_fit() {
        assert_eq!(ThumbSize::for_request(140), ThumbSize::Large);
        assert_eq!(ThumbSize::for_request(256), ThumbSize::Large);
        assert_eq!(ThumbSize::for_request(400), ThumbSize::XLarge);
        assert_eq!(ThumbSize::for_request(1024), ThumbSize::XXLarge);
    }

    #[test]
    fn generate_then_lookup_round_trips_under_a_temp_cache() {
        let dir = tempfile::tempdir().unwrap();
        let photo = dir.path().join("p.jpg");
        std::fs::write(&photo, crate::decode::tests_jpeg()).unwrap();
        let cache = dir.path().join("thumbnails");
        let path = photo.to_str().unwrap();
        let made = generate(&cache, path, ThumbSize::Normal).expect("generate");
        assert!(made.width >= 1 && made.height >= 1);
        let png = thumb_path(&cache, ThumbSize::Normal, &file_uri(path));
        assert!(png.is_file());
        let hit = lookup(&cache, path, ThumbSize::Normal).expect("lookup");
        assert_eq!(hit.width, made.width);
        assert_eq!(hit.height, made.height);
    }

    #[test]
    fn stale_mtime_is_not_reused() {
        let dir = tempfile::tempdir().unwrap();
        let photo = dir.path().join("p.jpg");
        std::fs::write(&photo, crate::decode::tests_jpeg()).unwrap();
        let cache = dir.path().join("thumbnails");
        let path = photo.to_str().unwrap();
        generate(&cache, path, ThumbSize::Normal).unwrap();
        let png = thumb_path(&cache, ThumbSize::Normal, &file_uri(path));
        // Rewrite the PNG with a bogus Thumb::MTime.
        let frame = crate::decode::decode_limited(path, 128).unwrap();
        let file = File::create(&png).unwrap();
        let mut encoder = png::Encoder::new(BufWriter::new(file), frame.width, frame.height);
        encoder.set_color(png::ColorType::Rgb);
        encoder.set_depth(png::BitDepth::Eight);
        encoder
            .add_text_chunk("Thumb::MTime".into(), "1".into())
            .unwrap();
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(&frame.rgb).unwrap();
        writer.finish().unwrap();
        assert!(lookup(&cache, path, ThumbSize::Normal).is_none());
    }
}
