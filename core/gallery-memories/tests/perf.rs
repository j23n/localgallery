//! The Phase-4 performance gate, from `_plans/06-performance-baseline.md`
//! Finding 3: **the 7-day scheduled-memories horizon must complete in < 100 ms**
//! on a 20,000-photo library. The Swift it replaces took ~9 s, on the main
//! thread, after every scan / tag rebuild / hide.
//!
//! `#[ignore]`d because it is a benchmark, not a fixture. Run it with
//!
//! ```sh
//! cd core && cargo test -p gallery-memories --release -- --ignored --nocapture
//! ```
//!
//! A debug build is 10–30× slower and says nothing about the shipping number.

#[path = "support/fixture.rs"]
mod fixture;

use std::collections::HashSet;
use std::time::Instant;

use gallery_memories::{
    compute_scheduled, generate, GenerationInputs, LeafFolder, UtcOffset,
    SCHEDULED_MEMORY_HORIZON_DAYS,
};
use gallery_model::{AppleDate, CivilDateTime, HierarchicalTag, PhotoFile, StableId};

const PHOTO_COUNT: usize = 20_000;
/// Finding 3's gate.
const HORIZON_BUDGET_MS: f64 = 100.0;

fn utc(y: i32, mo: u32, d: u32, h: u32) -> AppleDate {
    AppleDate::from_unix_secs_f64(CivilDateTime::new(y, mo, d, h, 0, 0).as_naive_unix_secs() as f64)
}

/// 20k photos over five years: ~11 a day, 40 people, a home cluster and a
/// scatter of away-from-home GPS, and 400 leaf folders. Deterministic — the
/// shape matters (people-tag density drives the birthday grouping, GPS density
/// drives trip detection), the exact values do not.
fn synthetic_library() -> GenerationInputs {
    let start = utc(2019, 1, 1, 8);
    let mut photos = Vec::with_capacity(PHOTO_COUNT);
    for i in 0..PHOTO_COUNT {
        let path = format!("/fixtures/perf/{:05}.jpg", i);
        let mut p = PhotoFile::new(&path, format!("IMG_{i:05}"), 2_000_000);
        // ~11 photos a day across five years, 7 minutes apart inside a day.
        let day = i / 11;
        let within = (i % 11) as f64 * 420.0;
        p.date_taken = Some(AppleDate(start.0 + day as f64 * 86_400.0 + within));

        let mut tags = vec![HierarchicalTag::new(&format!(
            "People/Person {:02}",
            i % 40
        ))];
        if i % 3 == 0 {
            tags.push(HierarchicalTag::new("Scenes/Beach"));
        }
        if i % 7 == 0 {
            tags.push(HierarchicalTag::new("Places/Italy/Lazio/Rome"));
        }
        p.hierarchical_tags = tags;

        // Mostly home (Berlin), with a two-week trip every 90 days.
        if (day / 90) % 2 == 0 || i % 5 != 0 {
            p.gps_latitude = Some(52.52);
            p.gps_longitude = Some(13.40);
            p.country_code = Some("DE".to_string());
        } else {
            p.gps_latitude = Some(-34.60);
            p.gps_longitude = Some(-58.38);
            p.country_code = Some("AR".to_string());
        }
        photos.push(p);
    }

    let mut inputs = GenerationInputs::empty(utc(2024, 6, 11, 12), UtcOffset::UTC, "2024-06-11");
    inputs.leaf_folders = (0..400)
        .map(|f| LeafFolder {
            id: StableId::for_folder(&format!("/fixtures/perf/folder-{f}")),
            name: format!("Folder {f}"),
            photo_ids: photos[f * 50..(f + 1) * 50].iter().map(|p| p.id).collect(),
        })
        .collect();
    inputs.photos = photos;
    inputs
}

fn millis(f: impl FnOnce()) -> f64 {
    let t = Instant::now();
    f();
    t.elapsed().as_secs_f64() * 1000.0
}

#[test]
#[ignore = "benchmark; run with --release -- --ignored --nocapture"]
fn twenty_thousand_photos_generate_and_a_seven_day_horizon() {
    let mut inputs = None;
    let build_ms = millis(|| inputs = Some(synthetic_library()));
    let inputs = inputs.unwrap();
    println!("library build ({PHOTO_COUNT} photos): {build_ms:8.1} ms");

    let mut selected = 0;
    let generate_ms = millis(|| selected = generate(&inputs).len());
    println!("generate (full ladder):        {generate_ms:8.1} ms  → {selected} memories");

    let mut scheduled = 0;
    let horizon_ms = millis(|| {
        scheduled = compute_scheduled(&inputs, SCHEDULED_MEMORY_HORIZON_DAYS, &HashSet::new()).len()
    });
    println!(
        "scheduled horizon (7 days):    {horizon_ms:8.1} ms  → {scheduled} items  (budget {HORIZON_BUDGET_MS:.0} ms)"
    );

    // The Swift baseline for comparison, from _plans/06: generate 1.7 s
    // off-main, horizon ~9 s ON the main thread.
    assert!(
        horizon_ms < HORIZON_BUDGET_MS,
        "the 7-day horizon took {horizon_ms:.1} ms, over Finding 3's {HORIZON_BUDGET_MS:.0} ms gate"
    );
}
