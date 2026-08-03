//! Namespace URIs, prefixes and field names from
//! `photo-tools/docs/xmp-schema.md`.
//!
//! Prefixes here are only used when this crate *creates* a property; reads
//! always match on URI (see [`crate::xml::NsScope`]).

/// `rdf:` — RDF itself.
pub const NS_RDF: &str = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
/// `x:` — the XMP meta envelope.
pub const NS_X: &str = "adobe:ns:meta/";
/// `dc:` — Dublin Core; holds `dc:subject` (schema §1.1, leaf names).
pub const NS_DC: &str = "http://purl.org/dc/elements/1.1/";
/// `digiKam:` — holds `digiKam:TagsList` (schema §1.1, `/`-separated paths).
pub const NS_DIGIKAM: &str = "http://www.digikam.org/ns/1.0/";
/// `lr:` — Lightroom; holds `lr:hierarchicalSubject` (`|`-separated paths).
pub const NS_LR: &str = "http://ns.adobe.com/lightroom/1.0/";
/// `Iptc4xmpExt:` — holds `PersonInImage` (§1.1) and `ImageRegion` (§2.6).
pub const NS_IPTC_EXT: &str = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/";
/// `Iptc4xmpCore:` — holds `CountryCode` and `Location` (§1.3).
pub const NS_IPTC_CORE: &str = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/";
/// `photoshop:` — holds `City` / `State` / `Country` (§1.3).
pub const NS_PHOTOSHOP: &str = "http://ns.adobe.com/photoshop/1.0/";
/// `mwg-rs:` — Metadata Working Group face regions (§1.5).
///
/// Read-only in Phase 1; Phase 2 makes the core the face-detector agent the
/// schema reserves this root for, so [`crate::faces`] now writes it.
pub const NS_MWG_RS: &str = "http://www.metadataworkinggroup.com/schemas/regions/";
/// `stArea:` — the area struct inside an MWG region.
pub const NS_ST_AREA: &str = "http://ns.adobe.com/xmp/sType/Area#";
/// `stDim:` — the dimensions struct inside an MWG region.
pub const NS_ST_DIM: &str = "http://ns.adobe.com/xap/1.0/sType/Dimensions#";
/// The photo-tools private namespace (schema §1.2).
pub const NS_PHOTO_TOOLS: &str = "https://github.com/j23n/photo-tools/ns/1.0/";

/// Prefix used when this crate creates a `dc:` property.
pub const PREFIX_DC: &str = "dc";
/// Prefix used when this crate creates a `digiKam:` property.
pub const PREFIX_DIGIKAM: &str = "digiKam";
/// Prefix used when this crate creates an `lr:` property.
pub const PREFIX_LR: &str = "lr";
/// Prefix used when this crate creates a photo-tools property.
///
/// The schema doc calls the prefix `photo-tools`, but `-` is legal in an XML
/// name only in non-leading position and exiftool's own config registers
/// `phototools` — which is what every real sidecar contains. We follow the
/// code, not the doc; `MetadataReader.parseXMPBytes` accepts both.
pub const PREFIX_PHOTO_TOOLS: &str = "phototools";
/// Prefix used when this crate creates an `mwg-rs:` property.
pub const PREFIX_MWG_RS: &str = "mwg-rs";
/// Prefix used when this crate creates an `stArea:` field.
pub const PREFIX_ST_AREA: &str = "stArea";
/// Prefix used when this crate creates an `stDim:` field.
pub const PREFIX_ST_DIM: &str = "stDim";
/// Prefix used when this crate creates an `Iptc4xmpExt:` property.
///
/// exiftool writes `Iptc4xmpExt` (not `iptcExt`, which is how the schema doc
/// spells the *group*), and that is what the fixtures contain.
pub const PREFIX_IPTC_EXT: &str = "Iptc4xmpExt";

/// `dc:subject` — leaf keyword names, an `rdf:Bag`.
pub const PROP_SUBJECT: &str = "subject";
/// `digiKam:TagsList` — `/`-separated hierarchical paths, an `rdf:Seq`.
pub const PROP_TAGS_LIST: &str = "TagsList";
/// `lr:hierarchicalSubject` — `|`-separated paths, an `rdf:Bag`.
///
/// Lowercase first letter: exiftool's *tag* is `HierarchicalSubject`, but the
/// serialized XMP property is `lr:hierarchicalSubject`. The schema doc shows
/// the tag name; sidecars contain the property name.
pub const PROP_HIERARCHICAL_SUBJECT: &str = "hierarchicalSubject";
/// `Iptc4xmpExt:PersonInImage` — the projection of `People/*` leaves (§1.1).
///
/// Read-only in Phase 1. [`crate::faces`] rewrites it from the file's
/// `People/*` keywords, the way photo-tools does.
pub const PROP_PERSON_IN_IMAGE: &str = "PersonInImage";
/// `mwg-rs:Regions` — the region container element (exiftool calls the whole
/// struct `RegionInfo`).
pub const PROP_REGIONS: &str = "Regions";
/// `mwg-rs:RegionList` — the bag of regions.
pub const PROP_REGION_LIST: &str = "RegionList";
/// `mwg-rs:AppliedToDimensions` — the pixel size the normalized areas are
/// relative to.
pub const PROP_APPLIED_TO_DIMENSIONS: &str = "AppliedToDimensions";
/// `mwg-rs:Name` — one region's label.
pub const PROP_REGION_NAME: &str = "Name";
/// `mwg-rs:Type` — one region's kind (`Face`, `Pet`, `BarCode`, …).
pub const PROP_REGION_TYPE: &str = "Type";
/// `mwg-rs:Area` — one region's rectangle.
pub const PROP_AREA: &str = "Area";
/// The `mwg-rs:Type` this crate writes. Faces are all it detects.
pub const REGION_TYPE_FACE: &str = "Face";
/// The `stArea:unit` this crate writes — and the only one
/// `MetadataReader.parseMWGRegions` accepts.
pub const AREA_UNIT_NORMALIZED: &str = "normalized";
/// The `stDim:unit` this crate writes.
pub const DIM_UNIT_PIXEL: &str = "pixel";

/// photo-tools sentinel — **never written by this crate.** Writing it would
/// make photo-tools skip files it has not actually tagged (schema §1.6).
pub const PROP_TAGGER_VERSION: &str = "TaggerVersion";
/// photo-tools' own last-tagged timestamp. Read only.
pub const PROP_TAGGED_AT: &str = "TaggedAt";
/// Geocoded country code (§1.2). Read only.
pub const PROP_COUNTRY_CODE: &str = "CountryCode";
/// OCR phrases (§1.2). Read only — never touched.
pub const PROP_OCR_TEXT: &str = "OCRText";
/// OCR provenance marker (§1.2). Read only.
pub const PROP_OCR_RAN: &str = "OCRRan";

/// Sentinel: which agent wrote the tags recorded in [`PROP_CORE_TAGS`].
///
/// New field in the photo-tools namespace; needs a §5 version entry in the
/// schema doc before Phase 1 ships.
pub const PROP_CORE_AGENT: &str = "CoreAgent";
/// Sentinel: model-pack version that produced the recorded tags.
pub const PROP_CORE_MODEL_PACK: &str = "CoreModelPack";
/// Sentinel: ISO 8601 UTC timestamp of the last core write.
pub const PROP_CORE_TAGGED_AT: &str = "CoreTaggedAt";
/// Sentinel: the exact hierarchical tag paths this agent added, an `rdf:Bag`.
pub const PROP_CORE_TAGS: &str = "CoreTags";
/// Sentinel: the exact `dc:subject` leaves this agent added, an `rdf:Bag`.
///
/// Separate from [`PROP_CORE_TAGS`] because `dc:subject` is lossy — several
/// hierarchical tags collapse to one leaf, and humans type bare leaves. Without
/// this list a retraction could delete a keyword a person typed.
pub const PROP_CORE_SUBJECTS: &str = "CoreSubjects";
/// Sentinel: the exact `lr:hierarchicalSubject` entries this agent added, an
/// `rdf:Bag`.
///
/// Separate from [`PROP_CORE_TAGS`] for the same reason [`PROP_CORE_SUBJECTS`]
/// is: `lr:hierarchicalSubject` is *not* a pure function of
/// `digiKam:TagsList`. Lightroom writes `lr:hierarchicalSubject` and no
/// `digiKam:TagsList` at all, so a file can arrive carrying
/// `Objects|Animal|Dog` that nobody here put there. Without this list, adding
/// and later retracting `Objects/Animal/Dog` would delete the user's entry.
pub const PROP_CORE_HIERARCHICAL: &str = "CoreHierarchical";

/// Sentinel: face-model-pack version that produced the recorded people and
/// regions.
///
/// Separate from [`PROP_CORE_MODEL_PACK`] because the two halves of the core
/// ship independently versioned models and run as independent passes. Sharing
/// one field would make each pass see the other's value as a mismatch and
/// rewrite the file, forever.
pub const PROP_CORE_FACE_PACK: &str = "CoreFacePack";
/// Sentinel: the exact `People/<Name>` paths this agent added to
/// `digiKam:TagsList`, an `rdf:Bag`.
///
/// Separate from [`PROP_CORE_TAGS`] for the same reason
/// [`PROP_CORE_FACE_PACK`] is separate: the tagging pass rewrites `CoreTags`
/// wholesale from what *it* now claims, and a `People/*` entry in that list
/// would be retracted by the next tagging run.
pub const PROP_CORE_PEOPLE: &str = "CorePeople";
/// Sentinel: the exact `dc:subject` leaves the face half added, an `rdf:Bag`.
///
/// Its own list rather than a projection of [`PROP_CORE_PEOPLE`]: a file can
/// already carry a flat `Alice` keyword a human typed while carrying no
/// `People/Alice` path, so adding the path must not license deleting the
/// keyword.
pub const PROP_CORE_PEOPLE_SUBJECTS: &str = "CorePeopleSubjects";
/// Sentinel: the exact `lr:hierarchicalSubject` entries the face half added,
/// an `rdf:Bag`.
pub const PROP_CORE_PEOPLE_HIERARCHICAL: &str = "CorePeopleHierarchical";
/// Sentinel: the MWG-RS regions this agent authored, an `rdf:Bag`.
///
/// One entry per region, `"<x>,<y>,<w>,<h> <Name>"` — the normalized
/// centre-form rectangle exactly as it was written, a space, then the name.
/// The geometry is what identifies the region (see
/// [`crate::regions::REGION_MATCH_IOU`]); the name is carried so the field is
/// legible in a sidecar and so a rename can find its regions without
/// re-deriving them from the cluster database.
pub const PROP_CORE_REGIONS: &str = "CoreRegions";

/// The agent name this crate stamps into [`PROP_CORE_AGENT`].
pub const CORE_AGENT: &str = "localgallery-core";
