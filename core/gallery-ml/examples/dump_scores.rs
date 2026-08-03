//! Dump the tagger's per-label scores for a set of images, as JSON.
//!
//! The Rust half of the model-pack parity harness
//! (`scripts/build_model_pack/parity.py`): the Python side computes the same
//! numbers with open_clip's own preprocessing and encoder, and the two are
//! compared label-for-label. Anything that moves pixels — a resize kernel, a
//! crop rounding rule, the EXIF orientation pass — shows up here as a score
//! delta, which is the only way to find out that the pack's `resize_filter`
//! and the model's training transform have drifted apart.
//!
//! ```sh
//! cargo run -p gallery-ml --release --example dump_scores -- \
//!     build/model_packs/mobileclip-s2-v1 /tmp/refimgs/*.jpg > /tmp/rust.json
//! ```
//!
//! Not a test: it needs a real pack (150 MB, never committed) and real photos.
//! It lives in `examples/` so `cargo test` never builds it and `cargo run
//! --example` always can.

use std::collections::BTreeSet;
use std::process::ExitCode;

use gallery_ml::encoder::{ImageEncoder, OrtEncoder};
use gallery_ml::pack::{normalize, sha256_hex, ModelPack};
use gallery_ml::preprocess::preprocess;
use gallery_ml::tagger::ZeroShotTagger;

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let Some(pack_dir) = args.next() else {
        eprintln!("usage: dump_scores <pack-dir> <image>...");
        return ExitCode::FAILURE;
    };
    let images: Vec<String> = args.collect();
    if images.is_empty() {
        eprintln!("usage: dump_scores <pack-dir> <image>...");
        return ExitCode::FAILURE;
    }

    match run(&pack_dir, &images) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("dump_scores: {e}");
            ExitCode::FAILURE
        }
    }
}

fn run(pack_dir: &str, images: &[String]) -> Result<String, Box<dyn std::error::Error>> {
    let pack = ModelPack::load(pack_dir)?;
    let cfg = pack.preprocess_config();
    let encoder = OrtEncoder::new(
        &pack.model_bytes,
        &pack.manifest.model.input_name,
        &pack.manifest.model.output_name,
        pack.manifest.model.input_size,
        pack.manifest.model.embedding_dim,
        1,
    )?;
    let tagger = ZeroShotTagger::new(&pack);
    let owned = BTreeSet::new();

    let label_paths: Vec<&str> = pack.labels.iter().map(|l| l.path.as_str()).collect();

    let mut entries = Vec::with_capacity(images.len());
    for path in images {
        let bytes = std::fs::read(path)?;
        let tensor = preprocess(path, &bytes, &cfg)?;
        let raw = encoder.embed(&tensor)?;
        let embedding = normalize(&raw).ok_or("degenerate embedding")?;

        // Score every label, not just the survivors: parity is about the whole
        // distribution, and a threshold that happens to hide a disagreement is
        // exactly the disagreement worth seeing.
        let scores: Vec<f32> = pack
            .labels
            .iter()
            .map(|label| dot(&embedding, &label.embedding))
            .collect();
        let tags = tagger.tags(&raw, &owned);

        entries.push(format!(
            "{{\"path\":{},\"content_sha256\":\"{}\",\"tensor_sha256\":\"{}\",\
             \"embedding\":{},\"scores\":{},\"tags\":{}}}",
            json_string(path),
            sha256_hex(&bytes),
            sha256_hex(&tensor.to_le_bytes()),
            json_floats(&embedding),
            json_floats(&scores),
            json_strings(tags.iter().map(String::as_str)),
        ));
    }

    Ok(format!(
        "{{\"pack_version\":{},\"backend\":{},\"labels\":{},\"images\":[{}]}}",
        json_string(pack.version()),
        json_string(encoder.backend_name()),
        json_strings(label_paths.into_iter()),
        entries.join(","),
    ))
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    let mut sum = 0.0f64;
    for (x, y) in a.iter().zip(b.iter()) {
        sum += f64::from(*x) * f64::from(*y);
    }
    sum as f32
}

/// Enough JSON escaping for file paths and taxonomy labels.
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn json_strings<'a>(items: impl Iterator<Item = &'a str>) -> String {
    let parts: Vec<String> = items.map(json_string).collect();
    format!("[{}]", parts.join(","))
}

/// Full f32 precision, so the Python side compares numbers and not roundings.
fn json_floats(values: &[f32]) -> String {
    let parts: Vec<String> = values.iter().map(|v| format!("{v:.9}")).collect();
    format!("[{}]", parts.join(","))
}
