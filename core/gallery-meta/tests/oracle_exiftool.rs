//! exiftool as the oracle.
//!
//! The unit tests check the writer against *our own* reader, which is exactly
//! the wrong judge for "did we damage somebody else's data". These tests hand
//! the written sidecars to exiftool 13.55 — the same tool photo-tools drives —
//! and assert two things:
//!
//! 1. the fields we meant to write have the values we meant, and
//! 2. **every other field exiftool could see before the write reads back
//!    identically afterwards.**
//!
//! Marked `#[ignore]` because they shell out; run with
//! `cargo test -p gallery-meta -- --include-ignored`.

mod common;

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

use common::{fixture, FIXTURES};
use gallery_meta::{apply_tags, TagWriteRequest};
use serde_json::Value;

const EXIFTOOL: &str = "/opt/homebrew/bin/exiftool";
const PHOTO_TOOLS_CONFIG: &str =
    "/Volumes/My Shared Files/dev_public/photo-tools/src/photo_tools/exiftool_phototools.config";

/// Groups whose values are about the file on disk, not its metadata.
const VOLATILE_GROUPS: &[&str] = &["System", "File", "ExifTool"];

fn have_exiftool() -> bool {
    Path::new(EXIFTOOL).exists()
}

/// `exiftool -j -struct -G1` over one file, flattened to `group:tag -> value`.
fn exiftool_json(path: &Path) -> BTreeMap<String, Value> {
    let mut cmd = Command::new(EXIFTOOL);
    if Path::new(PHOTO_TOOLS_CONFIG).exists() {
        cmd.arg("-config").arg(PHOTO_TOOLS_CONFIG);
    }
    let out = cmd
        .args(["-j", "-struct", "-G1"])
        .arg(path)
        .output()
        .expect("run exiftool");
    assert!(
        out.status.success(),
        "exiftool failed on {}: {}",
        path.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !stderr.contains("Warning"),
        "exiftool warned about {}: {stderr}",
        path.display()
    );

    let parsed: Vec<BTreeMap<String, Value>> =
        serde_json::from_slice(&out.stdout).expect("exiftool JSON");
    let mut map = parsed.into_iter().next().expect("one entry");
    map.retain(|key, _| {
        let group = key.split(':').next().unwrap_or("");
        key != "SourceFile" && !VOLATILE_GROUPS.contains(&group)
    });
    map
}

/// Fields this crate is allowed to change.
fn is_owned(key: &str) -> bool {
    let (group, tag) = key.split_once(':').unwrap_or(("", key));
    match tag {
        "Subject" | "TagsList" | "HierarchicalSubject" => true,
        // The sentinel lives in the photo-tools namespace, whose group name
        // exiftool derives from whatever prefix the file binds to the URI.
        t => group.starts_with("XMP-") && t.starts_with("Core"),
    }
}

fn request(tags: &[&str]) -> TagWriteRequest {
    TagWriteRequest::new(
        tags.iter().map(|s| s.to_string()),
        "mobileclip-s2-2026.1",
        "2026-08-03T10:00:00Z",
    )
}

/// Write `bytes` into a temp dir under `name` and return the path.
fn place(dir: &Path, name: &str, bytes: &[u8]) -> std::path::PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, bytes).unwrap();
    path
}

fn as_list(value: Option<&Value>) -> Vec<String> {
    match value {
        Some(Value::Array(items)) => items
            .iter()
            .map(|v| v.as_str().unwrap_or_default().to_string())
            .collect(),
        Some(Value::String(s)) => vec![s.clone()],
        _ => Vec::new(),
    }
}

/// Find the one key in `map` whose tag part matches `tag`, whatever its group.
fn by_tag<'a>(map: &'a BTreeMap<String, Value>, tag: &str) -> Option<&'a Value> {
    map.iter()
        .find(|(k, _)| k.split_once(':').map(|(_, t)| t) == Some(tag))
        .map(|(_, v)| v)
}

// ---------------------------------------------------------------------------

#[test]
#[ignore = "shells out to exiftool"]
fn exiftool_sees_no_change_in_any_field_we_do_not_own() {
    if !have_exiftool() {
        eprintln!("exiftool not installed; skipping");
        return;
    }
    let dir = tempfile::tempdir().unwrap();

    for name in FIXTURES {
        let original = fixture(name);
        let before_path = place(dir.path(), &format!("before-{name}"), &original);
        let before = exiftool_json(&before_path);

        let written = apply_tags(
            Some(&original),
            &request(&["Objects/Animal/Dog", "Scenes/Nature/Forest"]),
        )
        .unwrap()
        .bytes;
        let after_path = place(dir.path(), &format!("after-{name}"), &written);
        let after = exiftool_json(&after_path);

        for (key, value) in &before {
            if is_owned(key) {
                continue;
            }
            assert_eq!(
                after.get(key),
                Some(value),
                "{name}: {key} changed\nbefore: {value:?}\nafter: {:?}",
                after.get(key)
            );
        }
        for key in before.keys() {
            assert!(after.contains_key(key), "{name}: {key} disappeared");
        }
    }
}

#[test]
#[ignore = "shells out to exiftool"]
fn exiftool_reads_back_exactly_the_tags_we_wrote() {
    if !have_exiftool() {
        eprintln!("exiftool not installed; skipping");
        return;
    }
    let dir = tempfile::tempdir().unwrap();

    for name in FIXTURES {
        let original = fixture(name);
        let before = exiftool_json(&place(dir.path(), &format!("b2-{name}"), &original));

        let written = apply_tags(
            Some(&original),
            &request(&["Objects/Animal/Dog", "Scenes/Nature/Forest"]),
        )
        .unwrap()
        .bytes;
        let after = exiftool_json(&place(dir.path(), &format!("a2-{name}"), &written));

        let tags = as_list(by_tag(&after, "TagsList"));
        let subject = as_list(by_tag(&after, "Subject"));
        let hierarchical = as_list(by_tag(&after, "HierarchicalSubject"));

        for tag in ["Objects/Animal/Dog", "Scenes/Nature/Forest"] {
            assert!(tags.contains(&tag.to_string()), "{name}: missing {tag}");
        }
        for leaf in ["Dog", "Forest"] {
            assert!(
                subject.contains(&leaf.to_string()),
                "{name}: missing {leaf}"
            );
        }
        for lr in ["Objects|Animal|Dog", "Scenes|Nature|Forest"] {
            assert!(
                hierarchical.contains(&lr.to_string()),
                "{name}: missing {lr}"
            );
        }

        // Nothing pre-existing was dropped from the fields we do own.
        for tag in as_list(by_tag(&before, "TagsList")) {
            assert!(tags.contains(&tag), "{name}: lost tag {tag}");
        }
        for leaf in as_list(by_tag(&before, "Subject")) {
            assert!(subject.contains(&leaf), "{name}: lost subject {leaf}");
        }

        // The sentinel round-trips through exiftool too.
        assert_eq!(
            by_tag(&after, "CoreAgent").and_then(Value::as_str),
            Some("localgallery-core"),
            "{name}"
        );
        assert_eq!(
            as_list(by_tag(&after, "CoreTags")),
            vec!["Objects/Animal/Dog", "Scenes/Nature/Forest"],
            "{name}"
        );
    }
}

#[test]
#[ignore = "shells out to exiftool"]
fn a_full_retraction_restores_the_file_exiftool_first_saw() {
    if !have_exiftool() {
        eprintln!("exiftool not installed; skipping");
        return;
    }
    let dir = tempfile::tempdir().unwrap();

    for name in FIXTURES {
        let original = fixture(name);
        let before = exiftool_json(&place(dir.path(), &format!("b3-{name}"), &original));

        let tagged = apply_tags(Some(&original), &request(&["Objects/Animal/Dog"]))
            .unwrap()
            .bytes;
        let cleared = apply_tags(Some(&tagged), &request(&[])).unwrap().bytes;
        let after = exiftool_json(&place(dir.path(), &format!("a3-{name}"), &cleared));

        for (key, value) in &before {
            // The sentinel legitimately remains, now claiming nothing.
            if key.contains(":Core") {
                continue;
            }
            assert_eq!(
                after.get(key),
                Some(value),
                "{name}: {key} not restored by retraction"
            );
        }
        assert!(as_list(by_tag(&after, "CoreTags")).is_empty(), "{name}");
    }
}

#[test]
#[ignore = "shells out to exiftool"]
fn a_sidecar_created_from_nothing_is_valid_to_exiftool() {
    if !have_exiftool() {
        eprintln!("exiftool not installed; skipping");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let bytes = apply_tags(
        None,
        &request(&["Objects/Animal/Dog", "Scenes/Nature/Forest"]),
    )
    .unwrap()
    .bytes;
    let path = place(dir.path(), "fresh.jpg.xmp", &bytes);
    let map = exiftool_json(&path);

    assert_eq!(
        map.get("XMP-x:XMPToolkit").and_then(Value::as_str),
        Some("gallery-meta")
    );
    assert_eq!(
        as_list(map.get("XMP-digiKam:TagsList")),
        vec!["Objects/Animal/Dog", "Scenes/Nature/Forest"]
    );
    assert_eq!(as_list(map.get("XMP-dc:Subject")), vec!["Dog", "Forest"]);
    assert_eq!(
        as_list(map.get("XMP-lr:HierarchicalSubject")),
        vec!["Objects|Animal|Dog", "Scenes|Nature|Forest"]
    );
    assert_eq!(
        map.get("XMP-phototools:CoreModelPack")
            .and_then(Value::as_str),
        Some("mobileclip-s2-2026.1")
    );
    // photo-tools' own sentinel must be absent, or photo-tools would skip the
    // file on its next run (schema §1.6).
    assert!(
        !map.keys().any(|k| k.ends_with(":TaggerVersion")),
        "{map:?}"
    );
}

#[test]
#[ignore = "shells out to exiftool"]
fn exiftool_can_still_write_to_a_sidecar_we_produced() {
    // The acid test for structural damage: exiftool refuses to rewrite XMP it
    // cannot make sense of, and its own re-serialization must not lose our
    // tags.
    if !have_exiftool() {
        eprintln!("exiftool not installed; skipping");
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let bytes = apply_tags(
        Some(&fixture("digikam.jpg.xmp")),
        &request(&["Objects/Animal/Dog"]),
    )
    .unwrap()
    .bytes;
    let path = place(dir.path(), "rw.jpg.xmp", &bytes);

    let out = Command::new(EXIFTOOL)
        .args(["-overwrite_original", "-XMP-dc:Subject+=Holiday"])
        .arg(&path)
        .output()
        .expect("run exiftool");
    assert!(
        out.status.success(),
        "exiftool could not rewrite our sidecar: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let map = exiftool_json(&path);
    let subject = as_list(map.get("XMP-dc:Subject"));
    assert!(subject.contains(&"Holiday".to_string()));
    assert!(subject.contains(&"Dog".to_string()));
    assert!(as_list(map.get("XMP-digiKam:TagsList")).contains(&"People/Alice".to_string()));
    assert!(map.contains_key("XMP-mwg-rs:RegionInfo"));
}
