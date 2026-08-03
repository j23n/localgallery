//! The face half of the writer, against the same fixtures the tag half is
//! judged on.
//!
//! Phase 2 hands the core a field digiKam and Lightroom actively write —
//! `mwg-rs:RegionInfo` — so "preserve everything we do not own" is no longer a
//! claim about fields we never touch. These tests are about the fields we now
//! *do* touch: somebody else's region has to survive us writing beside it.

mod common;

use common::{fixture, fixture_str, FIXTURES};
use gallery_meta::model::SidecarView;
use gallery_meta::{apply_faces, read_view, Area, FaceRegionWrite, FaceWriteRequest, MetaError};

fn region(name: &str, x: f64, y: f64, w: f64, h: f64) -> FaceRegionWrite {
    FaceRegionWrite {
        name: name.to_string(),
        area: Area::new(x, y, w, h),
    }
}

fn request(regions: Vec<FaceRegionWrite>) -> FaceWriteRequest {
    FaceWriteRequest::new(regions, "buffalo_sc-2026.1", "2026-08-03T10:00:00Z")
        .with_image_size(4032, 3024)
}

fn apply(bytes: &[u8], regions: Vec<FaceRegionWrite>) -> Vec<u8> {
    apply_faces(Some(bytes), &request(regions)).unwrap().bytes
}

/// The two regions the digiKam fixture carries, as raw text.
fn digikam_region_blocks() -> Vec<String> {
    let text = fixture_str("digikam.jpg.xmp");
    text.match_indices("<rdf:li rdf:parseType='Resource'>")
        .map(|(start, _)| {
            let end = text[start..].find("</rdf:li>").unwrap() + start;
            text[start..end].to_string()
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Preservation
// ---------------------------------------------------------------------------

#[test]
fn a_foreign_region_survives_us_writing_one_beside_it_byte_for_byte() {
    let blocks = digikam_region_blocks();
    assert_eq!(blocks.len(), 2, "fixture changed");

    let after = String::from_utf8(apply(
        &fixture("digikam.jpg.xmp"),
        vec![region("Carol", 0.2, 0.8, 0.1, 0.1)],
    ))
    .unwrap();

    for block in &blocks {
        assert!(
            after.contains(block),
            "a digiKam-authored region was rewritten:\n{block}"
        );
    }
    let view = read_view(after.as_bytes()).unwrap();
    assert_eq!(view.regions.len(), 3);
    assert_eq!(view.regions[2].name.as_deref(), Some("Carol"));
    // Their AppliedToDimensions is left exactly as it was: our areas are
    // normalized, so there is nothing to rescale and nothing to correct.
    assert_eq!(view.applied_dimensions.as_ref().unwrap().width, 4032.0);
    assert_eq!(view.applied_dimensions.as_ref().unwrap().height, 3024.0);
}

#[test]
fn everything_the_face_half_does_not_own_comes_through_a_write_unchanged() {
    for name in FIXTURES {
        let original = fixture(name);
        let before = read_view(&original).unwrap();
        let after =
            read_view(&apply(&original, vec![region("Carol", 0.2, 0.8, 0.1, 0.1)])).unwrap();

        assert_eq!(before.photo_tools, after.photo_tools, "{name}: photo-tools");
        assert_eq!(before.core.tags, after.core.tags, "{name}: CoreTags");
        assert_eq!(
            before.core.model_pack, after.core.model_pack,
            "{name}: CoreModelPack"
        );
        for tag in &before.tags_list {
            assert!(after.tags_list.contains(tag), "{name}: lost tag {tag}");
        }
        for subject in &before.subject {
            assert!(
                after.subject.contains(subject),
                "{name}: lost subject {subject}"
            );
        }
        // Every region that was there is still there, unmoved.
        for r in &before.regions {
            assert!(
                after.regions.contains(r),
                "{name}: lost region {:?}",
                r.name
            );
        }
        assert_eq!(
            &after.regions[..before.regions.len()],
            &before.regions[..],
            "{name}: foreign regions were reordered"
        );
    }
}

#[test]
fn a_person_digikam_already_boxed_and_named_is_left_entirely_to_digikam() {
    // The fixture's Alice sits at (0.4, 0.35, 0.12, 0.16) with the keyword
    // already present. Writing the same person must add nothing anywhere.
    let out = apply_faces(
        Some(&fixture("digikam.jpg.xmp")),
        &request(vec![region("Alice", 0.4, 0.35, 0.12, 0.16)]),
    )
    .unwrap();
    let view = read_view(&out.bytes).unwrap();
    assert_eq!(out.regions_deferred, 1);
    assert_eq!(out.regions_added, 0);
    assert_eq!(view.regions.len(), 2);
    assert!(view.core.regions.is_empty());
    assert!(view.core.people.is_empty());
    assert_eq!(view.people_tags(), vec!["People/Alice", "People/Bob"]);
}

#[test]
fn the_weird_fixture_is_read_and_extended_without_imposing_our_prefixes() {
    // `weird_rdf` binds mwg-rs to `mw:` and stArea to `sa:`, and writes its one
    // region entirely in attribute form on a self-closing element.
    let original = fixture("weird_rdf.jpg.xmp");
    let before = read_view(&original).unwrap();
    assert_eq!(before.regions.len(), 1);

    let after_bytes = apply(&original, vec![region("Dana", 0.9, 0.9, 0.05, 0.05)]);
    let after = read_view(&after_bytes).unwrap();
    assert_eq!(after.regions.len(), 2);
    assert_eq!(after.regions[0], before.regions[0]);
    assert_eq!(after.regions[1].name.as_deref(), Some("Dana"));

    let text = String::from_utf8(after_bytes).unwrap();
    assert!(!text.contains("xmlns:mwg-rs"), "a second binding was added");
    assert!(!text.contains("xmlns:stArea"), "a second binding was added");
}

// ---------------------------------------------------------------------------
// Naming, renaming, un-naming
// ---------------------------------------------------------------------------

#[test]
fn a_rename_leaves_every_foreign_field_where_it_was() {
    let original = fixture("digikam.jpg.xmp");
    let blocks = digikam_region_blocks();

    let named = apply(&original, vec![region("Carol", 0.2, 0.8, 0.1, 0.1)]);
    let renamed = apply(&named, vec![region("Caroline", 0.2, 0.8, 0.1, 0.1)]);
    let view = read_view(&renamed).unwrap();

    assert_eq!(view.regions.len(), 3, "no duplicate box");
    assert!(view
        .regions
        .iter()
        .any(|r| r.name.as_deref() == Some("Caroline")));
    assert!(!view
        .regions
        .iter()
        .any(|r| r.name.as_deref() == Some("Carol")));
    assert!(view.tags_list.contains(&"People/Caroline".to_string()));
    assert!(!view.tags_list.contains(&"People/Carol".to_string()));
    assert_eq!(view.people_tags().len(), 3, "Alice and Bob still there");

    let text = String::from_utf8(renamed).unwrap();
    for block in &blocks {
        assert!(text.contains(block), "a digiKam region was rewritten");
    }
}

#[test]
fn un_naming_restores_the_file_the_reader_first_saw() {
    for name in FIXTURES {
        let original = fixture(name);
        let before = read_view(&original).unwrap();

        let named = apply(&original, vec![region("Carol", 0.2, 0.82, 0.1, 0.1)]);
        let cleared = apply(&named, Vec::new());
        let after = read_view(&cleared).unwrap();

        assert_eq!(before.regions, after.regions, "{name}: regions");
        assert_eq!(before.subject, after.subject, "{name}: dc:subject");
        assert_eq!(before.tags_list, after.tags_list, "{name}: TagsList");
        assert_eq!(
            before.hierarchical_subject, after.hierarchical_subject,
            "{name}: lr"
        );
        assert_eq!(before.photo_tools, after.photo_tools, "{name}: photo-tools");
        // `PersonInImage` is a *projection*, not a claim: it comes back as the
        // leaves of whatever `People/*` the file still carries, which for a
        // file that had people before we arrived is more than it started with.
        // Nothing is lost — see the projection test below.
        assert_eq!(
            after.person_in_image,
            after.person_leaves(),
            "{name}: PersonInImage drifted from the People/* leaves"
        );
    }
}

#[test]
fn person_in_image_is_the_projection_of_every_people_entry_not_only_ours() {
    let out = apply(
        &fixture("digikam.jpg.xmp"),
        vec![region("Carol", 0.2, 0.8, 0.1, 0.1)],
    );
    let view = read_view(&out).unwrap();
    assert_eq!(view.person_in_image, vec!["Alice", "Bob", "Carol"]);
}

#[test]
fn the_projection_is_established_even_from_people_somebody_else_wrote() {
    // `weird_rdf` carries `People/Carla` and no PersonInImage at all. Writing
    // faces to it publishes the projection, which is the point of the field
    // (§1.1) and exactly what photo-tools does on any write of its own.
    let before = read_view(&fixture("weird_rdf.jpg.xmp")).unwrap();
    assert!(before.person_in_image.is_empty());

    let named = apply(
        &fixture("weird_rdf.jpg.xmp"),
        vec![region("Carol", 0.2, 0.82, 0.1, 0.1)],
    );
    assert_eq!(
        read_view(&named).unwrap().person_in_image,
        vec!["Carla", "Carol"]
    );

    // Un-naming takes ours back out and leaves theirs.
    let cleared = apply(&named, Vec::new());
    assert_eq!(read_view(&cleared).unwrap().person_in_image, vec!["Carla"]);
}

// ---------------------------------------------------------------------------
// Idempotence and determinism
// ---------------------------------------------------------------------------

#[test]
fn a_second_identical_write_changes_nothing_on_any_fixture() {
    for name in FIXTURES {
        let people = vec![
            region("Carol", 0.2, 0.82, 0.1, 0.1),
            region("Dana", 0.9, 0.12, 0.06, 0.08),
        ];
        let first = apply_faces(Some(&fixture(name)), &request(people.clone())).unwrap();
        let second = apply_faces(Some(&first.bytes), &request(people)).unwrap();
        assert!(
            !second.changed,
            "{name}: a no-op re-run would have rewritten the sidecar"
        );
        assert_eq!(second.bytes, first.bytes, "{name}");
    }
}

#[test]
fn the_bytes_are_a_function_of_the_set_not_of_the_order_it_arrived_in() {
    for name in FIXTURES {
        let forward = vec![
            region("Carol", 0.2, 0.82, 0.1, 0.1),
            region("Dana", 0.9, 0.12, 0.06, 0.08),
        ];
        let backward = vec![
            region("Dana", 0.9, 0.12, 0.06, 0.08),
            region("Carol", 0.2, 0.82, 0.1, 0.1),
        ];
        assert_eq!(
            apply(&fixture(name), forward),
            apply(&fixture(name), backward),
            "{name}"
        );
    }
}

#[test]
fn an_empty_request_on_a_file_we_never_touched_is_still_a_sentinel_write() {
    // Symmetry with the tag half: "we looked and found nobody" has to be
    // distinguishable from "never ran", so the sentinel goes in even with
    // nothing to claim. It settles after one write.
    let first = apply_faces(Some(&fixture("minimal.jpg.xmp")), &request(Vec::new())).unwrap();
    assert!(first.changed);
    let second = apply_faces(Some(&first.bytes), &request(Vec::new())).unwrap();
    assert!(!second.changed);
    let view = read_view(&first.bytes).unwrap();
    assert!(view.core.has_faces());
    assert!(view.core.people.is_empty());
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

#[test]
fn an_unusable_name_fails_the_whole_call() {
    for bad in ["", "  ", "People/Alice", "Ali\u{0}ce"] {
        let err = apply_faces(None, &request(vec![region(bad, 0.4, 0.35, 0.1, 0.1)])).unwrap_err();
        assert!(
            matches!(err, MetaError::InvalidTag { .. }),
            "{bad:?}: {err:?}"
        );
    }
}

#[test]
fn an_empty_packet_still_reads_as_empty_after_the_new_fields() {
    // Guards the `SidecarView::default()` equality the minimal fixture pins:
    // adding face fields to the view must not make an empty sidecar non-empty.
    assert_eq!(
        read_view(&fixture("minimal.jpg.xmp")).unwrap(),
        SidecarView::default()
    );
}
