//! Run the real `TaggingEngine` over a directory tree and print what it wrote.
//!
//! The acceptance harness for a model pack: `dump_scores` proves the *scores*
//! match the Python reference, this proves the whole engine — queue, hashing,
//! embedding cache, thresholds, sidecar read-modify-write — turns a folder of
//! photos into `.xmp` files somebody would want.
//!
//! ```sh
//! cargo run -p gallery-ml --release --example tag_dir -- \
//!     build/model_packs/mobileclip-s2-v1 /tmp/testlib
//! ```
//!
//! Writes sidecars **in place**, next to the photos, so point it at a copy.
//! Re-running is the cache check: the second pass should report every photo
//! `skipped` (content hash already embedded) and rewrite nothing.
//!
//! Not a test: it needs a real pack (150 MB, never committed) and a real
//! library. It lives in `examples/` so `cargo test` never builds it.

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use gallery_ml::{NoProgress, RunOptions, TaggingEngine};
use gallery_vfs::StdVfs;

/// Extensions `gallery_ml::preprocess` can actually decode. HEIC is the known
/// gap (plan 02, "Remaining"), and enqueuing one would only add a `failed` row.
const EXTENSIONS: &[&str] = &["jpg", "jpeg", "png"];

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let (Some(pack_dir), Some(root)) = (args.next(), args.next()) else {
        eprintln!("usage: tag_dir <pack-dir> <image-dir> [sample-count]");
        return ExitCode::FAILURE;
    };
    let sample: usize = args.next().and_then(|s| s.parse().ok()).unwrap_or(25);

    match run(&pack_dir, Path::new(&root), sample) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("tag_dir: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(pack_dir: &str, root: &Path, sample: usize) -> Result<(), Box<dyn std::error::Error>> {
    let mut photos = Vec::new();
    collect(root, &mut photos)?;
    photos.sort();
    println!("{} decodable photos under {}", photos.len(), root.display());

    // The cache DB lives beside the library so a second run of this example is
    // a genuine warm-cache run rather than a cold one.
    let engine = TaggingEngine::open(
        root.join("gallery-cache.sqlite"),
        pack_dir,
        Arc::new(StdVfs),
    )?;
    let info = engine.pack();
    println!(
        "pack {} — {} labels, dim {}",
        info.version(),
        info.labels.len(),
        info.manifest.model.embedding_dim
    );

    let paths: Vec<String> = photos
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    let queued = engine.enqueue(&paths)?;
    println!("enqueued {queued}");

    let started = std::time::Instant::now();
    let summary = engine.run_with_options(
        &NoProgress,
        &AtomicBool::new(false),
        &RunOptions::default(),
    )?;
    let elapsed = started.elapsed();
    println!(
        "\nrun: processed={} tagged={} written={} cache_hits={} skipped={} failed={} \
         in {:.1}s ({:.0} ms/photo)",
        summary.processed,
        summary.tagged,
        summary.sidecars_written,
        summary.cache_hits,
        summary.skipped,
        summary.failed,
        elapsed.as_secs_f64(),
        elapsed.as_secs_f64() * 1000.0 / (summary.processed.max(1) as f64),
    );

    // Report from the sidecars on disk, not from the engine's return value:
    // the whole point of the phase is that the tags reach a file another tool
    // can read.
    let mut tagged = Vec::new();
    let mut untagged = 0usize;
    for photo in &photos {
        let sidecar = sidecar_path(photo);
        let Ok(text) = std::fs::read_to_string(&sidecar) else {
            untagged += 1;
            continue;
        };
        let core_tags = extract_core_tags(&text);
        if core_tags.is_empty() {
            untagged += 1;
        } else {
            tagged.push((photo.clone(), core_tags));
        }
    }

    println!(
        "sidecars: {} photos carry core tags, {} carry none",
        tagged.len(),
        untagged
    );

    println!("\nsample of {} tagged photos:", sample.min(tagged.len()));
    let stride = (tagged.len() / sample.max(1)).max(1);
    for (photo, tags) in tagged.iter().step_by(stride).take(sample) {
        let name = photo
            .strip_prefix(root)
            .unwrap_or(photo.as_path())
            .to_string_lossy();
        println!("  {name}\n      {}", tags.join(", "));
    }

    Ok(())
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let path = entry?.path();
        if path.is_dir() {
            collect(&path, out)?;
        } else if path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
            .unwrap_or(false)
        {
            out.push(path);
        }
    }
    Ok(())
}

/// `IMG_1234.jpg` -> `IMG_1234.jpg.xmp` (suffix preserved, schema §1.4).
fn sidecar_path(photo: &Path) -> PathBuf {
    let mut name = photo.as_os_str().to_os_string();
    name.push(".xmp");
    PathBuf::from(name)
}

/// The paths listed in the `CoreTags` sentinel — i.e. exactly the tags this
/// core claims ownership of, as opposed to whatever else the sidecar already
/// carried.
///
/// Both spellings of the prefix have to be accepted. `gallery-meta` creates
/// the property as `phototools:` (the schema doc's `photo-tools` is not a
/// legal XML NCName), but a sidecar that already declares the namespace under
/// some other prefix keeps its own — and photo-tools' own writer, which
/// produced most of these fixtures, declares it as `photo-tools:`.
fn extract_core_tags(xmp: &str) -> Vec<String> {
    let Some(start) = xmp
        .find("<phototools:CoreTags>")
        .or_else(|| xmp.find("<photo-tools:CoreTags>"))
    else {
        return Vec::new();
    };
    let tail = &xmp[start..];
    let end = tail
        .find("</phototools:CoreTags>")
        .or_else(|| tail.find("</photo-tools:CoreTags>"))
        .unwrap_or(tail.len());
    tail[..end]
        .split("<rdf:li>")
        .skip(1)
        .filter_map(|chunk| chunk.split("</rdf:li>").next())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}
