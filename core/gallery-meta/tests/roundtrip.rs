//! Preservation is the whole product. These tests assert that nothing the core
//! does not own can be damaged by a write.

mod common;

use common::{fixture, fixture_str, FIXTURES};
use gallery_meta::model::SidecarView;
use gallery_meta::xml::{parse, serialize};
use gallery_meta::{apply_tags, read_view, TagWriteRequest};

fn request(tags: &[&str]) -> TagWriteRequest {
    TagWriteRequest::new(
        tags.iter().map(|s| s.to_string()),
        "mobileclip-s2-2026.1",
        "2026-08-03T10:00:00Z",
    )
}

fn apply(bytes: &[u8], tags: &[&str]) -> Vec<u8> {
    apply_tags(Some(bytes), &request(tags))
        .expect("apply")
        .bytes
}

// ---------------------------------------------------------------------------
// Parse → serialize
// ---------------------------------------------------------------------------

#[test]
fn every_fixture_survives_parse_and_serialize_unchanged() {
    for name in FIXTURES {
        let original = fixture(name);
        let doc = parse(&original).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(
            serialize(&doc),
            original,
            "{name} did not round trip byte-for-byte"
        );
    }
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

#[test]
fn photo_tools_fixture_reads_back_the_documented_fields() {
    let view = read_view(&fixture("phototools.jpg.xmp")).unwrap();
    assert_eq!(
        view.tags_list,
        vec![
            "Places/Italy/Lazio/Rome/Municipio Roma I",
            "Landmarks/Colosseum",
            "Objects/Structure/Balustrade",
            "Scenes/Urban/Building",
        ]
    );
    assert!(view.subject.contains(&"Colosseum".to_string()));
    assert_eq!(view.hierarchical_subject.len(), 4);
    assert_eq!(view.photo_tools.tagger_version.as_deref(), Some("2026.4"));
    assert_eq!(view.photo_tools.country_code.as_deref(), Some("IT"));
    assert_eq!(view.photo_tools.ocr_text, vec!["Way Out", "Pizza Roma"]);
    assert!(view.photo_tools.ocr_ran.is_some());
    assert!(!view.core.is_present());
}

#[test]
fn digikam_fixture_reads_back_people_and_regions() {
    let view = read_view(&fixture("digikam.jpg.xmp")).unwrap();
    assert_eq!(view.people_tags(), vec!["People/Alice", "People/Bob"]);
    assert_eq!(view.person_in_image, vec!["Alice", "Bob"]);
    assert_eq!(view.regions.len(), 2);
    assert_eq!(view.regions[0].name.as_deref(), Some("Alice"));
    assert_eq!(view.regions[0].kind.as_deref(), Some("Face"));
    assert!((view.regions[0].center_x - 0.4).abs() < 1e-9);
    assert!((view.regions[1].height - 0.14).abs() < 1e-9);
}

#[test]
fn unconventional_prefixes_and_containers_still_read() {
    let view = read_view(&fixture("weird_rdf.jpg.xmp")).unwrap();
    // dc:subject bound to `dcx:` and serialized as a Seq rather than a Bag.
    assert_eq!(view.subject, vec!["Trattoria Da Enzo & Sons", "Carla"]);
    // digiKam:TagsList as a Bag, one entry inside CDATA.
    assert_eq!(view.tags_list, vec!["People/Carla", "Places/Italy/Lazio"]);
    // Attribute-form scalars.
    assert_eq!(view.photo_tools.country_code.as_deref(), Some("IT"));
    assert_eq!(view.photo_tools.tagger_version.as_deref(), Some("2026.4"));
    // Region entirely in attribute form on a self-closing element.
    assert_eq!(view.regions.len(), 1);
    assert_eq!(view.regions[0].name.as_deref(), Some("Carla"));
    assert!((view.regions[0].width - 0.08).abs() < 1e-9);
}

#[test]
fn an_empty_packet_reads_as_empty_rather_than_failing() {
    let view = read_view(&fixture("minimal.jpg.xmp")).unwrap();
    assert_eq!(view, SidecarView::default());
}

// ---------------------------------------------------------------------------
// Writing: preservation
// ---------------------------------------------------------------------------

/// The fields the core must never touch, before and after a write.
fn untouched_projection(view: &SidecarView) -> impl std::fmt::Debug + PartialEq + '_ {
    (
        view.person_in_image.clone(),
        view.regions.clone(),
        view.photo_tools.clone(),
        view.people_tags()
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>(),
    )
}

#[test]
fn writing_tags_leaves_every_foreign_field_alone() {
    for name in FIXTURES {
        let original = fixture(name);
        let before = read_view(&original).unwrap();
        let after_bytes = apply(&original, &["Objects/Animal/Dog", "Scenes/Nature/Forest"]);
        let after = read_view(&after_bytes).unwrap();
        assert_eq!(
            untouched_projection(&before),
            untouched_projection(&after),
            "{name}: a field the core does not own changed"
        );
    }
}

#[test]
fn every_pre_existing_tag_survives_a_write() {
    for name in FIXTURES {
        let original = fixture(name);
        let before = read_view(&original).unwrap();
        let after = read_view(&apply(&original, &["Objects/Animal/Dog"])).unwrap();
        for tag in &before.tags_list {
            assert!(after.tags_list.contains(tag), "{name}: lost tag {tag}");
        }
        for subject in &before.subject {
            assert!(
                after.subject.contains(subject),
                "{name}: lost subject {subject}"
            );
        }
        for lr in &before.hierarchical_subject {
            assert!(
                after.hierarchical_subject.contains(lr),
                "{name}: lost hierarchicalSubject {lr}"
            );
        }
    }
}

#[test]
fn structural_blocks_the_core_ignores_come_through_verbatim() {
    // The MWG region block and the IPTC ImageRegion block are the two places
    // where a naive rewriter would do damage; assert on the raw text, not just
    // the parsed projection.
    let original = fixture_str("digikam.jpg.xmp");
    let region_block = {
        let start = original.find("<mwg-rs:Regions").unwrap();
        let end = original.find("</mwg-rs:Regions>").unwrap();
        original[start..end].to_string()
    };
    let after = String::from_utf8(apply(original.as_bytes(), &["Objects/Animal/Dog"])).unwrap();
    assert!(
        after.contains(&region_block),
        "MWG region block was rewritten"
    );

    let pt = fixture_str("phototools.jpg.xmp");
    let ocr_block = {
        let start = pt.find("<Iptc4xmpExt:ImageRegion>").unwrap();
        let end = pt.find("</Iptc4xmpExt:ImageRegion>").unwrap();
        pt[start..end].to_string()
    };
    let after_pt = String::from_utf8(apply(pt.as_bytes(), &["Objects/Animal/Dog"])).unwrap();
    assert!(
        after_pt.contains(&ocr_block),
        "IPTC ImageRegion block was rewritten"
    );
}

#[test]
fn the_photo_tools_sentinel_is_never_written() {
    // Stamping TaggerVersion would make photo-tools skip files it never tagged
    // (schema §1.6).
    let out = apply_tags(None, &request(&["Objects/Animal/Dog"]))
        .unwrap()
        .bytes;
    let text = String::from_utf8(out).unwrap();
    assert!(!text.contains("TaggerVersion"), "{text}");
    assert!(!text.contains("TaggedAt<"), "{text}");

    // And an existing one is left at its old value.
    let after = read_view(&apply(
        &fixture("phototools.jpg.xmp"),
        &["Objects/Animal/Dog"],
    ))
    .unwrap();
    assert_eq!(after.photo_tools.tagger_version.as_deref(), Some("2026.4"));
}

#[test]
fn the_writer_reuses_the_files_own_prefixes_instead_of_imposing_its_own() {
    let after = String::from_utf8(apply(
        &fixture("weird_rdf.jpg.xmp"),
        &["Objects/Animal/Dog"],
    ))
    .unwrap();
    assert!(after.contains("<dcx:subject>"), "{after}");
    assert!(!after.contains("<dc:subject>"), "{after}");
    assert!(!after.contains("xmlns:dc="), "{after}");
    assert!(after.contains("<dk:TagsList>"), "{after}");
    assert!(!after.contains("xmlns:digiKam"), "{after}");
    // The tag landed in the file's own Bag, not a new container.
    let view = read_view(after.as_bytes()).unwrap();
    assert_eq!(
        view.tags_list,
        vec!["People/Carla", "Places/Italy/Lazio", "Objects/Animal/Dog"]
    );
}

// ---------------------------------------------------------------------------
// Writing: the keyword fan-out (schema §1.1)
// ---------------------------------------------------------------------------

#[test]
fn a_tag_fans_out_to_all_three_sidecar_keyword_fields() {
    let out = apply(&fixture("minimal.jpg.xmp"), &["Objects/Animal/Dog"]);
    let view = read_view(&out).unwrap();
    assert_eq!(view.tags_list, vec!["Objects/Animal/Dog"]);
    assert_eq!(view.hierarchical_subject, vec!["Objects|Animal|Dog"]);
    assert_eq!(view.subject, vec!["Dog"]);
}

#[test]
fn iptc_keywords_are_not_attempted_in_a_sidecar() {
    // An XMP sidecar has no IIM section; photo-tools drops the write too (§1.4).
    let out =
        String::from_utf8(apply(&fixture("minimal.jpg.xmp"), &["Objects/Animal/Dog"])).unwrap();
    assert!(!out.contains("Keywords"), "{out}");
}

#[test]
fn person_in_image_is_never_written() {
    // People/* is digiKam's (schema §2.1) and PersonInImage is its projection.
    let before = read_view(&fixture("digikam.jpg.xmp")).unwrap();
    let after = read_view(&apply(&fixture("digikam.jpg.xmp"), &["Objects/Animal/Dog"])).unwrap();
    assert_eq!(before.person_in_image, after.person_in_image);
}

#[test]
fn people_tags_are_rejected_outright() {
    let err = apply_tags(
        Some(&fixture("minimal.jpg.xmp")),
        &request(&["People/Mallory"]),
    )
    .unwrap_err();
    assert!(
        matches!(err, gallery_meta::MetaError::InvalidTag { .. }),
        "{err:?}"
    );
}

// ---------------------------------------------------------------------------
// Writing: ownership and retraction
// ---------------------------------------------------------------------------

#[test]
fn a_retracted_tag_is_removed_from_all_three_fields() {
    let base = fixture("minimal.jpg.xmp");
    let first = apply(&base, &["Objects/Animal/Dog", "Scenes/Nature/Forest"]);
    let second = apply(&first, &["Objects/Animal/Dog"]);
    let view = read_view(&second).unwrap();
    assert_eq!(view.tags_list, vec!["Objects/Animal/Dog"]);
    assert_eq!(view.hierarchical_subject, vec!["Objects|Animal|Dog"]);
    assert_eq!(view.subject, vec!["Dog"]);
    assert_eq!(view.core.tags, vec!["Objects/Animal/Dog"]);
    assert_eq!(view.core.subjects, vec!["Dog"]);
}

#[test]
fn a_tag_the_core_did_not_add_is_never_claimed_and_never_retracted() {
    // photo-tools already wrote Objects/Structure/Balustrade. The core asks for
    // the same tag, then stops asking. It must survive.
    let base = fixture("phototools.jpg.xmp");
    let first = apply_tags(Some(&base), &request(&["Objects/Structure/Balustrade"])).unwrap();
    assert!(first.added.is_empty(), "{:?}", first.added);
    assert!(first.owned.is_empty(), "{:?}", first.owned);

    let second = apply(&first.bytes, &[]);
    let view = read_view(&second).unwrap();
    assert!(view
        .tags_list
        .contains(&"Objects/Structure/Balustrade".to_string()));
    assert!(view.subject.contains(&"Balustrade".to_string()));
}

#[test]
fn a_human_keyword_that_shares_a_leaf_is_not_collateral_damage() {
    // Someone typed the bare keyword "Dog" by hand. We then tag
    // Objects/Animal/Dog (whose leaf is also "Dog") and later retract it.
    let base = apply(&fixture("minimal.jpg.xmp"), &[]);
    let mut doc = String::from_utf8(base).unwrap();
    doc = doc.replace(
        "</rdf:RDF>",
        " <rdf:Description rdf:about=''\n  xmlns:dc='http://purl.org/dc/elements/1.1/'>\n  <dc:subject>\n   <rdf:Bag>\n    <rdf:li>Dog</rdf:li>\n   </rdf:Bag>\n  </dc:subject>\n </rdf:Description>\n</rdf:RDF>",
    );

    let tagged = apply(doc.as_bytes(), &["Objects/Animal/Dog"]);
    let tagged_view = read_view(&tagged).unwrap();
    assert_eq!(tagged_view.subject, vec!["Dog"], "no duplicate leaf");
    assert!(
        tagged_view.core.subjects.is_empty(),
        "the pre-existing leaf must not be claimed: {:?}",
        tagged_view.core.subjects
    );

    let retracted = apply(&tagged, &[]);
    let view = read_view(&retracted).unwrap();
    assert_eq!(view.subject, vec!["Dog"], "human keyword was deleted");
    assert!(view.tags_list.is_empty());
}

#[test]
fn a_leaf_shared_by_two_owned_tags_survives_retracting_only_one() {
    let base = fixture("minimal.jpg.xmp");
    let first = apply(&base, &["Objects/Animal/Dog", "Toys/Plush/Dog"]);
    let view = read_view(&first).unwrap();
    assert_eq!(view.subject, vec!["Dog"], "leaf written once");

    let second = apply(&first, &["Toys/Plush/Dog"]);
    let view = read_view(&second).unwrap();
    assert_eq!(view.tags_list, vec!["Toys/Plush/Dog"]);
    assert_eq!(view.subject, vec!["Dog"], "leaf still needed");
}

#[test]
fn retracting_everything_empties_only_the_core_owned_entries() {
    let base = fixture("phototools.jpg.xmp");
    let before = read_view(&base).unwrap();
    let tagged = apply(&base, &["Objects/Animal/Dog"]);
    let cleared = apply(&tagged, &[]);
    let view = read_view(&cleared).unwrap();
    assert_eq!(view.tags_list, before.tags_list);
    assert_eq!(view.subject, before.subject);
    assert_eq!(view.hierarchical_subject, before.hierarchical_subject);
    assert!(view.core.tags.is_empty());
}

// ---------------------------------------------------------------------------
// Determinism and idempotence
// ---------------------------------------------------------------------------

#[test]
fn the_same_request_produces_the_same_bytes() {
    for name in FIXTURES {
        let original = fixture(name);
        let a = apply(&original, &["Scenes/Nature/Forest", "Objects/Animal/Dog"]);
        let b = apply(&original, &["Scenes/Nature/Forest", "Objects/Animal/Dog"]);
        assert_eq!(a, b, "{name}: not deterministic");
    }
}

#[test]
fn tag_order_does_not_affect_the_output_bytes() {
    // The tagger emits tags in score order; float drift across architectures
    // reorders near-ties. The bytes must not care (determinism doctrine).
    let original = fixture("minimal.jpg.xmp");
    let a = apply(&original, &["Scenes/Nature/Forest", "Objects/Animal/Dog"]);
    let b = apply(&original, &["Objects/Animal/Dog", "Scenes/Nature/Forest"]);
    assert_eq!(a, b);
}

#[test]
fn a_second_identical_run_is_a_no_op() {
    for name in FIXTURES {
        let original = fixture(name);
        let first = apply_tags(Some(&original), &request(&["Objects/Animal/Dog"])).unwrap();
        assert!(first.changed, "{name}: first run should change the file");

        // A later run with a different timestamp must still be a no-op — the
        // timestamp is only refreshed when something actually changes.
        let later = TagWriteRequest::new(
            ["Objects/Animal/Dog".to_string()],
            "mobileclip-s2-2026.1",
            "2027-01-01T00:00:00Z",
        );
        let second = apply_tags(Some(&first.bytes), &later).unwrap();
        assert!(!second.changed, "{name}: second run rewrote the file");
        assert_eq!(second.bytes, first.bytes, "{name}");
    }
}

#[test]
fn a_new_model_pack_refreshes_the_sentinel_even_with_identical_tags() {
    let first = apply_tags(
        Some(&fixture("minimal.jpg.xmp")),
        &request(&["Objects/Animal/Dog"]),
    )
    .unwrap();
    let upgraded = TagWriteRequest::new(
        ["Objects/Animal/Dog".to_string()],
        "mobileclip-s2-2027.1",
        "2027-01-01T00:00:00Z",
    );
    let second = apply_tags(Some(&first.bytes), &upgraded).unwrap();
    assert!(second.changed);
    let view = read_view(&second.bytes).unwrap();
    assert_eq!(
        view.core.model_pack.as_deref(),
        Some("mobileclip-s2-2027.1")
    );
    assert_eq!(view.core.tagged_at.as_deref(), Some("2027-01-01T00:00:00Z"));
}

// ---------------------------------------------------------------------------
// Creating a sidecar from nothing
// ---------------------------------------------------------------------------

#[test]
fn a_created_sidecar_is_a_well_formed_xmp_packet() {
    let applied = apply_tags(None, &request(&["Objects/Animal/Dog"])).unwrap();
    assert!(applied.created);
    let text = String::from_utf8(applied.bytes.clone()).unwrap();
    assert!(text.starts_with("<?xpacket begin="), "{text}");
    assert!(
        text.contains("<x:xmpmeta xmlns:x='adobe:ns:meta/'"),
        "{text}"
    );
    assert!(
        text.contains("<rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"),
        "{text}"
    );
    assert!(text.trim_end().ends_with("<?xpacket end='w'?>"), "{text}");

    // And it survives its own round trip.
    let doc = parse(&applied.bytes).unwrap();
    assert_eq!(serialize(&doc), applied.bytes);
}

#[test]
fn empty_bytes_are_treated_as_a_missing_sidecar() {
    let applied = apply_tags(Some(b"   \n"), &request(&["Objects/Animal/Dog"])).unwrap();
    assert!(applied.created);
    assert_eq!(read_view(&applied.bytes).unwrap().tags_list.len(), 1);
}

#[test]
fn a_non_xmp_document_is_refused_rather_than_clobbered() {
    let err = apply_tags(
        Some(b"<html><body>hi</body></html>"),
        &request(&["Objects/Animal/Dog"]),
    )
    .unwrap_err();
    assert!(
        matches!(err, gallery_meta::MetaError::NotAnXmpPacket { .. }),
        "{err:?}"
    );
}

#[test]
fn an_emptied_list_property_is_removed_rather_than_left_blank() {
    // `<dc:subject><rdf:Bag></rdf:Bag></dc:subject>` is not "no keywords" to
    // exiftool — it reads the whitespace between the tags as the value. Remove
    // the property, and the Description around it if that empties it.
    let tagged = apply_tags(None, &request(&["Objects/Animal/Dog"]))
        .unwrap()
        .bytes;
    let cleared = String::from_utf8(apply(&tagged, &[])).unwrap();

    for absent in [
        "dc:subject",
        "digiKam:TagsList",
        "lr:hierarchicalSubject",
        "CoreTags",
        "CoreSubjects",
        "xmlns:dc",
    ] {
        assert!(!cleared.contains(absent), "{absent} survived:\n{cleared}");
    }
    // The sentinel itself stays, now claiming nothing.
    assert!(cleared.contains("<phototools:CoreAgent>localgallery-core"));
}

#[test]
fn tag_and_retract_cycles_do_not_accumulate_whitespace() {
    let base = fixture("phototools.jpg.xmp");
    let mut state = base.clone();
    let mut snapshots = Vec::new();
    for _ in 0..3 {
        state = apply(&state, &["Objects/Animal/Dog", "Scenes/Nature/Forest"]);
        snapshots.push(state.clone());
        state = apply(&state, &[]);
        snapshots.push(state.clone());
    }
    assert_eq!(snapshots[0], snapshots[2], "tagged form drifted");
    assert_eq!(snapshots[2], snapshots[4], "tagged form drifted");
    assert_eq!(snapshots[1], snapshots[3], "retracted form drifted");
    assert_eq!(snapshots[3], snapshots[5], "retracted form drifted");
}

#[test]
fn the_created_layout_matches_exiftools_house_style() {
    // Not a correctness requirement, but a diff against an exiftool-written
    // sidecar should be about content, not whitespace.
    let text = String::from_utf8(
        apply_tags(None, &request(&["Objects/Animal/Dog"]))
            .unwrap()
            .bytes,
    )
    .unwrap();
    assert!(
        text.contains("\n\n <rdf:Description rdf:about=''\n  xmlns:dc='http://purl.org/dc/elements/1.1/'>\n  <dc:subject>\n   <rdf:Bag>\n    <rdf:li>Dog</rdf:li>\n   </rdf:Bag>\n  </dc:subject>\n </rdf:Description>"),
        "{text}"
    );
}
