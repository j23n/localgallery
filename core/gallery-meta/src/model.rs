//! Typed projection of the parts of a sidecar this crate understands.
//!
//! Everything *not* represented here still survives a read→write cycle — the
//! DOM keeps it. This type exists so the writer can reason about what it owns
//! and so callers (and Phase 2) can inspect a sidecar without touching XML.

/// One MWG-RS face region, normalized coordinates.
///
/// Mirrors `LocalGallery/Models/FaceRegion.swift`, which
/// `MetadataReader.parseMWGRegions` produces from the same bytes. The core
/// never writes these in Phase 1.
#[derive(Debug, Clone, PartialEq)]
pub struct FaceRegion {
    /// `mwg-rs:Name`, when the writer set one.
    pub name: Option<String>,
    /// `mwg-rs:Type` — `Face`, `Pet`, `BarCode`, … Regions with a non-face type
    /// still round-trip; the field is here so Phase 2 can filter.
    pub kind: Option<String>,
    /// Centre X, 0…1.
    pub center_x: f64,
    /// Centre Y, 0…1.
    pub center_y: f64,
    /// Width, 0…1.
    pub width: f64,
    /// Height, 0…1.
    pub height: f64,
}

/// Fields in the photo-tools private namespace (schema §1.2) plus the core's
/// own sentinel fields.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PhotoToolsFields {
    /// `photo-tools:TaggerVersion` — photo-tools' "already tagged" sentinel.
    /// Read so callers can see it; **never written** by this crate.
    pub tagger_version: Option<String>,
    /// `photo-tools:TaggedAt`.
    pub tagged_at: Option<String>,
    /// `photo-tools:CountryCode` (ISO 3166-1 alpha-2).
    pub country_code: Option<String>,
    /// `photo-tools:OCRText` phrases.
    pub ocr_text: Vec<String>,
    /// `photo-tools:OCRRan` timestamp.
    pub ocr_ran: Option<String>,
}

/// The core's sentinel: who tagged, with which model pack, when, and exactly
/// what was added.
///
/// The tag/subject lists are the whole point — they make retraction on re-run
/// surgical instead of prefix-based. photo-tools retracts by root prefix
/// (`Objects/`, `Scenes/`, …), which would let one tool delete the other's
/// tags, since both write those roots.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CoreSentinel {
    /// `photo-tools:CoreAgent`, e.g. `localgallery-core`.
    pub agent: Option<String>,
    /// `photo-tools:CoreModelPack`.
    pub model_pack: Option<String>,
    /// `photo-tools:CoreTaggedAt`, ISO 8601 UTC.
    pub tagged_at: Option<String>,
    /// Hierarchical tag paths the agent added and therefore may retract.
    pub tags: Vec<String>,
    /// `dc:subject` leaves the agent added and therefore may retract.
    pub subjects: Vec<String>,
    /// `lr:hierarchicalSubject` entries (`|`-separated) the agent added and
    /// therefore may retract.
    ///
    /// Not derivable from [`CoreSentinel::tags`]: Lightroom writes
    /// `lr:hierarchicalSubject` without `digiKam:TagsList`, so an entry can
    /// already exist for a path we go on to add elsewhere.
    pub hierarchical: Vec<String>,
}

impl CoreSentinel {
    /// Whether anything at all was recorded.
    pub fn is_present(&self) -> bool {
        self.agent.is_some() || !self.tags.is_empty()
    }
}

/// Everything this crate can name inside a sidecar.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SidecarView {
    /// `dc:subject` — flat leaf keywords, document order.
    pub subject: Vec<String>,
    /// `digiKam:TagsList` — hierarchical paths, document order.
    pub tags_list: Vec<String>,
    /// `lr:hierarchicalSubject` — `|`-separated paths, document order.
    pub hierarchical_subject: Vec<String>,
    /// `Iptc4xmpExt:PersonInImage` — person leaf names.
    pub person_in_image: Vec<String>,
    /// MWG-RS face regions.
    pub regions: Vec<FaceRegion>,
    /// photo-tools namespace fields.
    pub photo_tools: PhotoToolsFields,
    /// This crate's sentinel.
    pub core: CoreSentinel,
}

impl SidecarView {
    /// `digiKam:TagsList` entries under `People/` — the names digiKam owns.
    pub fn people_tags(&self) -> Vec<&str> {
        self.tags_list
            .iter()
            .filter(|t| crate::tags::root_of(t) == crate::tags::PEOPLE_ROOT)
            .map(String::as_str)
            .collect()
    }
}
