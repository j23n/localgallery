#!/usr/bin/env python3
"""Build the Phase-3 metadata conformance asset tree.

Writes `core/fixtures/scan-conformance/assets/` — the adversarial file set the
Swift `MetadataConformanceTests` harness runs the *current* `MetadataReader`
over. The assets are committed; regenerate only when adding a case:

    python3 scripts/gen_conformance_assets.py
    # then regenerate the expectation JSON, see the fixture README

Everything is deterministic: the base images are 8x8 blobs embedded below as
base64 (no ImageMagick dependency, no encoder-version drift), the videos are
hand-assembled QuickTime containers, and every XMP packet is written
byte-for-byte (exiftool `-xmp<=` embeds the packet verbatim, which is what
lets the MWG region-ordering fixtures pin element order).

Requires: exiftool (EXIF writes + XMP packet embedding).
"""

from __future__ import annotations

import base64
import os
import shutil
import struct
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "core", "fixtures", "scan-conformance", "assets")

# 8x8 baseline JPEG / PNG. Small enough that the whole tree stays well under
# the 2 MB fixture budget even with ~50 files.
BASE_JPG = base64.b64decode(
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkI"
    "CQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQ"
    "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAAIAAgDAREA"
    "AhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABgQAAIDAAAAAAAAAAAAAAAAAAABFmOR/8QA"
    "FQEBAQAAAAAAAAAAAAAAAAAABwj/xAAXEQADAQAAAAAAAAAAAAAAAAAAGGOh/9oADAMBAAIRAxEA"
    "PwAbT25aOK1xwo5ga6f/2Q=="
)
BASE_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAIEAIAAAAb/fWfAAAAMElEQVQY02NkYGhoYCABsKhMEjIn"
    "SYPqJCEzEm0QJtGGySQ6ieZ+YPz///9/UjQAAHBSCxTvaKLzAAAAAElFTkSuQmCC"
)

# --------------------------------------------------------------------------
# XMP helpers
# --------------------------------------------------------------------------

NS = (
    'xmlns:digiKam="http://www.digikam.org/ns/1.0/"\n'
    '    xmlns:photo-tools="https://github.com/j23n/photo-tools/ns/1.0/"\n'
    '    xmlns:phototools="https://github.com/j23n/photo-tools/ns/1.0/"\n'
    '    xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"\n'
    '    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"\n'
    '    xmlns:dc="http://purl.org/dc/elements/1.1/"\n'
    '    xmlns:exif="http://ns.adobe.com/exif/1.0/"\n'
    '    xmlns:mwg-rs="http://www.metadataworkinggroup.com/schemas/regions/"\n'
    '    xmlns:stArea="http://ns.adobe.com/xmp/sType/Area#"\n'
    '    xmlns:stDim="http://ns.adobe.com/xap/1.0/sType/Dimensions#"'
)


def packet(body: str) -> str:
    return (
        '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="localgallery-conformance-fixture">\n'
        ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        '  <rdf:Description rdf:about=""\n    ' + NS + ">\n"
        + body
        + "  </rdf:Description>\n"
        " </rdf:RDF>\n"
        "</x:xmpmeta>\n"
        '<?xpacket end="w"?>\n'
    )


def tags_list(paths, open_tag="<digiKam:TagsList>") -> str:
    items = "".join(f"     <rdf:li>{p}</rdf:li>\n" for p in paths)
    return f"   {open_tag}\n    <rdf:Seq>\n{items}    </rdf:Seq>\n   </digiKam:TagsList>\n"


def seq(prop, paths) -> str:
    items = "".join(f"     <rdf:li>{p}</rdf:li>\n" for p in paths)
    return f"   <{prop}>\n    <rdf:Bag>\n{items}    </rdf:Bag>\n   </{prop}>\n"


def area_attr(x, y, w, h, unit="normalized", close=True) -> str:
    u = f' stArea:unit="{unit}"' if unit is not None else ""
    tail = "/>" if close else ">"
    return f'<mwg-rs:Area stArea:x="{x}" stArea:y="{y}" stArea:w="{w}" stArea:h="{h}"{u}{tail}'


def region_info(lis: str) -> str:
    return (
        "   <mwg-rs:Regions rdf:parseType=\"Resource\">\n"
        "    <mwg-rs:AppliedToDimensions stDim:w=\"8\" stDim:h=\"8\" stDim:unit=\"pixel\"/>\n"
        "    <mwg-rs:RegionList>\n"
        "     <rdf:Seq>\n"
        f"{lis}"
        "     </rdf:Seq>\n"
        "    </mwg-rs:RegionList>\n"
        "   </mwg-rs:Regions>\n"
    )


def li_name_then_area(name, area) -> str:
    return (
        "      <rdf:li rdf:parseType=\"Resource\">\n"
        f"       <mwg-rs:Name>{name}</mwg-rs:Name>\n"
        "       <mwg-rs:Type>Face</mwg-rs:Type>\n"
        f"       {area}\n"
        "      </rdf:li>\n"
    )


def li_area_then_name(name, area) -> str:
    """exiftool serialises struct fields alphabetically: Area before Name."""
    return (
        "      <rdf:li rdf:parseType=\"Resource\">\n"
        f"       {area}\n"
        f"       <mwg-rs:Name>{name}</mwg-rs:Name>\n"
        "       <mwg-rs:Type>Face</mwg-rs:Type>\n"
        "      </rdf:li>\n"
    )


# --------------------------------------------------------------------------
# QuickTime / MP4 builder
# --------------------------------------------------------------------------

MATRIX = struct.pack(">9i", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)


def _box(t: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", 8 + len(payload)) + t + payload


def _full(t: bytes, ver: int, flags: int, payload: bytes) -> bytes:
    return _box(t, struct.pack(">B3s", ver, flags.to_bytes(3, "big")) + payload)


def make_movie(day_text: str | None, brand: bytes = b"qt  ") -> bytes:
    """Minimal single-track container. `day_text` becomes `moov/udta/©day`."""
    ct = 0  # 1904 epoch; AVAsset.creationDate does not read mvhd, only ©day.
    mvhd = _full(
        b"mvhd", 0, 0,
        struct.pack(">IIII", ct, ct, 600, 0)
        + struct.pack(">ih10s", 0x00010000, 0x0100, b"\x00" * 10)
        + MATRIX + b"\x00" * 24 + struct.pack(">I", 2),
    )
    tkhd = _full(
        b"tkhd", 0, 0x7,
        struct.pack(">IIIII", ct, ct, 1, 0, 0)
        + b"\x00" * 8 + struct.pack(">hhh2s", 0, 0, 0, b"\x00\x00")
        + MATRIX + struct.pack(">II", 8 << 16, 8 << 16),
    )
    mdhd = _full(b"mdhd", 0, 0, struct.pack(">IIIIHH", ct, ct, 600, 0, 0x55C4, 0))
    hdlr = _full(b"hdlr", 0, 0, b"mhlr" + b"vide" + b"\x00" * 12 + b"\x00")
    vmhd = _full(b"vmhd", 0, 1, struct.pack(">HHHH", 0, 0, 0, 0))
    dref = _full(b"dref", 0, 0, struct.pack(">I", 1) + _full(b"url ", 0, 1, b""))
    sample_entry = (
        b"\x00" * 6 + struct.pack(">H", 1)
        + struct.pack(">HHIII", 0, 0, 0, 0, 0)
        + struct.pack(">HHIIIH", 8, 8, 0x00480000, 0x00480000, 0, 1)
        + b"\x00" * 32 + struct.pack(">Hh", 24, -1)
    )
    stbl = _box(b"stbl", (
        _full(b"stsd", 0, 0, struct.pack(">I", 1) + _box(b"jpeg", sample_entry))
        + _full(b"stts", 0, 0, struct.pack(">I", 0))
        + _full(b"stsc", 0, 0, struct.pack(">I", 0))
        + _full(b"stsz", 0, 0, struct.pack(">II", 0, 0))
        + _full(b"stco", 0, 0, struct.pack(">I", 0))
    ))
    trak = _box(b"trak", tkhd + _box(b"mdia", mdhd + hdlr + _box(b"minf", vmhd + _box(b"dinf", dref) + stbl)))
    parts = [mvhd, trak]
    if day_text is not None:
        t = day_text.encode("utf-8")
        parts.append(_box(b"udta", _box(b"\xa9day", struct.pack(">HH", len(t), 0) + t)))
    return (
        _box(b"ftyp", brand + struct.pack(">I", 0x20050300) + brand)
        + _box(b"moov", b"".join(parts))
        + _box(b"mdat", b"")
    )


# --------------------------------------------------------------------------
# HEIF builder
# --------------------------------------------------------------------------
#
# Hand-assembled for the same reason `make_movie` is: an encoder in the loop
# would make the fixture a function of whatever libheif the generating machine
# had. These carry no pixels at all — the metadata reader never decodes, and a
# real HEVC payload would cost far more than the 2 MB fixture budget allows.
# The mirror of this builder lives in `gallery-meta/src/media/isobmff.rs`'s
# tests; both write `iloc` version 1 with 32-bit offsets, construction method 0.

XMP_MIME = b"application/rdf+xml"


def _infe(item_id: int, item_type: bytes, content_type: bytes | None) -> bytes:
    body = struct.pack(">HH", item_id, 0) + item_type + b"\x00"
    if content_type is not None:
        body += content_type + b"\x00"
    return _full(b"infe", 2, 0, body)


def _iloc(entries: list[tuple[int, int, int]]) -> bytes:
    # offset_size 4, length_size 4, base_offset_size 0, index_size 0.
    body = b"\x44\x00" + struct.pack(">H", len(entries))
    for item_id, offset, length in entries:
        body += struct.pack(">HHHH", item_id, 0, 0, 1)  # id, method 0, dref 0, 1 extent
        body += struct.pack(">II", offset, length)
    return _full(b"iloc", 1, 0, body)


def make_heic(items: list[tuple[bytes, bytes | None, bytes]], brand: bytes = b"heic") -> bytes:
    """`ftyp` + `meta` + `mdat`, with every item at the offset `iloc` records.

    `items` is (item_type, content_type, payload). Assembled twice because the
    `iloc` offsets have to name an `mdat` that sits after the `iloc` itself;
    every field is fixed-width, so the second pass is byte-identical in size.
    """
    ftyp = _box(b"ftyp", brand + struct.pack(">I", 0) + brand + b"mif1")
    hdlr = _full(b"hdlr", 0, 0, b"\x00" * 4 + b"pict" + b"\x00" * 12 + b"\x00")

    def meta_for(mdat_start: int) -> bytes:
        infes = b""
        entries: list[tuple[int, int, int]] = []
        at = mdat_start + 8  # past the `mdat` header
        for n, (item_type, content_type, payload) in enumerate(items):
            infes += _infe(n + 1, item_type, content_type)
            entries.append((n + 1, at, len(payload)))
            at += len(payload)
        iinf = _full(b"iinf", 0, 0, struct.pack(">H", len(items)) + infes)
        return _full(b"meta", 0, 0, hdlr + iinf + _iloc(entries))

    meta = meta_for(len(ftyp) + len(meta_for(0)))
    mdat = _box(b"mdat", b"".join(payload for _t, _c, payload in items))
    return ftyp + meta + mdat


def exif_item_payload(jpeg_path: str) -> bytes:
    """The Exif item body for a HEIF, taken from a JPEG exiftool just wrote.

    A HEIF Exif item is a four-byte offset to the TIFF header followed by the
    TIFF block — the same block a JPEG carries in its `APP1` after `Exif\\0\\0`.
    Lifting it keeps one exiftool invocation as the source of both files'
    EXIF and avoids hand-rolling an IFD writer.
    """
    with open(jpeg_path, "rb") as f:
        data = f.read()
    i = 2
    while i + 4 <= len(data):
        if data[i] != 0xFF:
            break
        marker = data[i + 1]
        if marker in (0xD8, 0xD9, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        if marker == 0xDA:
            break
        length = struct.unpack(">H", data[i + 2:i + 4])[0]
        payload = data[i + 4:i + 2 + length]
        if marker == 0xE1 and payload.startswith(b"Exif\x00\x00"):
            return struct.pack(">I", 0) + payload[6:]
        i += 2 + length
    sys.exit(f"no Exif APP1 in {jpeg_path}")


# --------------------------------------------------------------------------
# writers
# --------------------------------------------------------------------------

def write(name: str, data: bytes) -> None:
    path = os.path.join(OUT, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def jpg(name: str, exif_args: list[str] | None = None, xmp: str | None = None) -> None:
    write(name, BASE_JPG)
    path = os.path.join(OUT, name)
    if exif_args:
        run(["exiftool", "-overwrite_original", *exif_args, path])
    if xmp is not None:
        blob = path + ".packet.tmp"
        with open(blob, "w", encoding="utf-8") as f:
            f.write(xmp)
        run(["exiftool", "-overwrite_original", f"-xmp<={blob}", path])
        os.remove(blob)


def sidecar(name: str, xmp: str, encoding: str = "utf-8") -> None:
    if encoding == "utf-16":
        write(name, xmp.encode("utf-16"))  # BOM-prefixed, per the XMP spec
    else:
        write(name, xmp.encode("utf-8"))


def run(cmd: list[str]) -> None:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd)}\n{r.stdout}{r.stderr}")


# --------------------------------------------------------------------------
# the fixture set
# --------------------------------------------------------------------------

def build() -> None:
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)

    # ---- 1. EXIF dates ---------------------------------------------------
    # Full house: original + digitized + TIFF + subseconds + offset. The
    # reader's format string has no subsecond/offset field — both are dropped.
    jpg("exif/full.jpg", [
        "-EXIF:DateTimeOriginal=2021:07:04 08:09:10",
        "-EXIF:CreateDate=2021:07:04 08:09:11",
        "-EXIF:ModifyDate=2021:07:04 08:09:12",
        "-EXIF:SubSecTimeOriginal=250",
        "-EXIF:OffsetTimeOriginal=+02:00",
        "-EXIF:Orientation#=6",
        "-EXIF:Make=Conformance",
        "-EXIF:Model=Fixture",
    ])
    # DateTimeOriginal absent -> DateTimeDigitized wins.
    jpg("exif/digitized_only.jpg", ["-EXIF:CreateDate=2019:03:02 14:33:07"])
    # Both absent -> TIFF DateTime (exiftool: ModifyDate) wins.
    jpg("exif/tiff_datetime_only.jpg", ["-EXIF:ModifyDate=2018:11:30 21:45:00"])
    # "0000:00:00 00:00:00" is a real camera sentinel. It PARSES (proleptic
    # Gregorian year 0) rather than falling through to the digitized value.
    # `#=` bypasses exiftool's PrintConv validation, which is the only way
    # to plant values a camera can emit but exiftool refuses to write.
    jpg("exif/zero_date.jpg", [
        "-EXIF:DateTimeOriginal#=0000:00:00 00:00:00",
        "-EXIF:CreateDate=2020:05:05 05:05:05",
    ])
    # Hour 24 — the non-lenient formatter's behaviour is the spec here.
    jpg("exif/hour_24.jpg", ["-EXIF:DateTimeOriginal#=2021:07:04 24:00:00"])
    # Out-of-range month/day; non-lenient parse should reject and fall through.
    jpg("exif/impossible_date.jpg", [
        "-EXIF:DateTimeOriginal#=2021:13:45 08:09:10",
        "-EXIF:CreateDate=2021:07:04 08:09:10",
    ])
    # No EXIF at all.
    jpg("exif/none.jpg")

    # ---- 2. GPS ----------------------------------------------------------
    jpg("gps/north_east.jpg", [
        "-EXIF:GPSLatitude=41.9028", "-EXIF:GPSLatitudeRef=N",
        "-EXIF:GPSLongitude=12.4964", "-EXIF:GPSLongitudeRef=E",
        "-EXIF:GPSAltitude=21.5", "-EXIF:GPSAltitudeRef=0",
    ])
    # Southern + western hemisphere, plus altitude *below* sea level. The
    # reader negates on the refs but ignores altitude entirely.
    jpg("gps/south_west.jpg", [
        "-EXIF:GPSLatitude=33.8688", "-EXIF:GPSLatitudeRef=S",
        "-EXIF:GPSLongitude=151.2093", "-EXIF:GPSLongitudeRef=W",
        "-EXIF:GPSAltitude=120.0", "-EXIF:GPSAltitudeRef=1",
    ])
    # Latitude only — the reader requires both, so nothing is reported.
    jpg("gps/lat_only.jpg", ["-EXIF:GPSLatitude=41.9028", "-EXIF:GPSLatitudeRef=N"])
    # Refs absent: `latRef == "S"` is false, so both stay positive.
    jpg("gps/no_refs.jpg", ["-EXIF:GPSLatitude=41.9028", "-EXIF:GPSLongitude=12.4964"])
    # Zero island + a lowercase ref (the comparison is case-sensitive).
    jpg("gps/zero_and_lowercase_ref.jpg", [
        "-EXIF:GPSLatitude=0", "-EXIF:GPSLatitudeRef#=s",
        "-EXIF:GPSLongitude=0.0001", "-EXIF:GPSLongitudeRef#=w",
    ])

    # ---- 3. Embedded XMP -------------------------------------------------
    jpg("xmp/tagslist.jpg", xmp=packet(
        tags_list(["People/Alice", "Places/Italy/Lazio/Rome", "Objects/Bicycle"])
    ))
    # Three competing tag vocabularies. Only digiKam:TagsList is read; the
    # other two are invisible to the app.
    jpg("xmp/tag_sources_disagree.jpg", xmp=packet(
        tags_list(["People/Alice"])
        + seq("lr:hierarchicalSubject", ["People|Bob", "Places|France"])
        + seq("dc:subject", ["carol", "dog"])
    ))
    jpg("xmp/country_code.jpg", xmp=packet(
        "   <photo-tools:CountryCode>it</photo-tools:CountryCode>\n"
    ))
    # `CountryCode` is matched by LEAF NAME only, so IPTC's own CountryCode
    # is an equally valid candidate; the first tag enumerated wins.
    jpg("xmp/country_code_namespace_conflict.jpg", xmp=packet(
        "   <photo-tools:CountryCode>IT</photo-tools:CountryCode>\n"
        "   <Iptc4xmpCore:CountryCode>FR</Iptc4xmpCore:CountryCode>\n"
    ))
    jpg("xmp/regions_digikam_order.jpg", xmp=packet(region_info(
        li_name_then_area("Alice", area_attr("0.25", "0.30", "0.10", "0.12"))
        + li_name_then_area("Bob", area_attr("0.60", "0.32", "0.11", "0.13"))
    )))
    jpg("xmp/regions_exiftool_order.jpg", xmp=packet(region_info(
        li_area_then_name("Alice", area_attr("0.25", "0.30", "0.10", "0.12"))
        + li_area_then_name("Bob", area_attr("0.60", "0.32", "0.11", "0.13"))
    )))
    # Tags AND regions AND country in one packet, with no sidecar next to it.
    jpg("xmp/full_embedded.jpg",
        exif_args=["-EXIF:DateTimeOriginal=2022:02:22 22:22:22"],
        xmp=packet(
            tags_list(["People/Alice", "People/Bob"])
            + "   <photo-tools:CountryCode>de</photo-tools:CountryCode>\n"
            + region_info(li_name_then_area("Alice", area_attr("0.1", "0.2", "0.3", "0.4")))
        ))

    # ---- 4. Sidecar-only -------------------------------------------------
    jpg("sidecar/only.jpg")
    sidecar("sidecar/only.jpg.xmp", packet(
        tags_list(["People/Dana", "Scenes/Beach"])
        + "   <photo-tools:CountryCode>pt</photo-tools:CountryCode>\n"
        + region_info(li_name_then_area("Dana", area_attr("0.4", "0.4", "0.2", "0.2")))
    ))

    # Every conflicting field at once — the precedence table in one file.
    jpg("sidecar/conflict.jpg", xmp=packet(
        tags_list(["People/Alice", "Objects/Car"])
        + "   <photo-tools:CountryCode>IT</photo-tools:CountryCode>\n"
        + region_info(li_name_then_area("EmbeddedFace", area_attr("0.11", "0.12", "0.13", "0.14")))
    ))
    sidecar("sidecar/conflict.jpg.xmp", packet(
        tags_list(["people/alice", "Scenes/Beach"])
        + "   <photo-tools:CountryCode>FR</photo-tools:CountryCode>\n"
        + region_info(li_name_then_area("SidecarFace", area_attr("0.51", "0.52", "0.53", "0.54")))
    ))

    # Sidecar carries no regions -> the embedded ones survive.
    jpg("sidecar/no_regions.jpg", xmp=packet(
        region_info(li_name_then_area("EmbeddedOnly", area_attr("0.21", "0.22", "0.23", "0.24")))
    ))
    sidecar("sidecar/no_regions.jpg.xmp", packet(tags_list(["Scenes/Forest"])))

    # Sidecar fills the country gap when the embedded packet has none.
    jpg("sidecar/country_gap.jpg", xmp=packet(tags_list(["Objects/Boat"])))
    sidecar("sidecar/country_gap.jpg.xmp", packet(
        "   <photo-tools:CountryCode>no</photo-tools:CountryCode>\n"
    ))

    # Dates and GPS in a sidecar are read by nobody.
    jpg("sidecar/date_and_gps_ignored.jpg")
    sidecar("sidecar/date_and_gps_ignored.jpg.xmp", packet(
        "   <exif:DateTimeOriginal>1999:09:09 09:09:09</exif:DateTimeOriginal>\n"
        "   <exif:GPSLatitude>48,51.29N</exif:GPSLatitude>\n"
        "   <exif:GPSLongitude>2,17.40E</exif:GPSLongitude>\n"
    ))

    # Alternate prefix accepted by the scalar reader.
    jpg("sidecar/alt_prefix_country.jpg")
    sidecar("sidecar/alt_prefix_country.jpg.xmp", packet(
        "   <phototools:CountryCode>se</phototools:CountryCode>\n"
    ))

    # `<digiKam:TagsList ` (attributes on the open tag) is the second probe.
    jpg("sidecar/tagslist_with_attributes.jpg")
    sidecar("sidecar/tagslist_with_attributes.jpg.xmp", packet(
        tags_list(["Places/Norway"], open_tag='<digiKam:TagsList xml:lang="x-default">')
    ))

    # Empty / whitespace-only rdf:li entries are dropped.
    jpg("sidecar/empty_tag_entries.jpg")
    sidecar("sidecar/empty_tag_entries.jpg.xmp", packet(
        "   <digiKam:TagsList>\n    <rdf:Seq>\n"
        "     <rdf:li></rdf:li>\n"
        "     <rdf:li>   </rdf:li>\n"
        "     <rdf:li>  Places/Spain  </rdf:li>\n"
        "    </rdf:Seq>\n   </digiKam:TagsList>\n"
    ))

    # Case-insensitive dedup, first spelling wins.
    jpg("sidecar/duplicate_case.jpg")
    sidecar("sidecar/duplicate_case.jpg.xmp", packet(
        tags_list(["People/Alice", "people/alice", "PEOPLE/ALICE", "People/Alice/Child"])
    ))

    # rdf:Bag instead of rdf:Seq — the parser only looks for rdf:li inside
    # the TagsList block, so the container type is irrelevant.
    jpg("sidecar/tagslist_bag.jpg")
    sidecar("sidecar/tagslist_bag.jpg.xmp", packet(
        "   <digiKam:TagsList>\n    <rdf:Bag>\n"
        "     <rdf:li>Objects/Lamp</rdf:li>\n"
        "    </rdf:Bag>\n   </digiKam:TagsList>\n"
    ))

    # Truncated packet: the opening TagsList tag is there, the closing one is
    # not, so the whole block is skipped.
    jpg("sidecar/truncated_tagslist.jpg")
    sidecar("sidecar/truncated_tagslist.jpg.xmp",
            packet("   <digiKam:TagsList>\n    <rdf:Seq>\n     <rdf:li>Places/Ghost</rdf:li>\n")
            .split("</digiKam:TagsList>")[0])

    # Not XML at all.
    jpg("sidecar/garbage.jpg")
    sidecar("sidecar/garbage.jpg.xmp", "this is not an XMP packet at all\n")

    # UTF-16 packet (BOM-prefixed) — the UTF-8 decode fails, the fallback wins.
    jpg("sidecar/utf16.jpg")
    sidecar("sidecar/utf16.jpg.xmp", packet(tags_list(["Places/Iceland"])), encoding="utf-16")

    # Namespace marker present, no parseable Area: the "parser bug" warning
    # path. Output is still an empty region list.
    jpg("sidecar/mwg_marker_no_areas.jpg")
    sidecar("sidecar/mwg_marker_no_areas.jpg.xmp", packet(
        "   <mwg-rs:Regions rdf:parseType=\"Resource\">\n"
        "    <mwg-rs:RegionList><rdf:Seq/></mwg-rs:RegionList>\n"
        "   </mwg-rs:Regions>\n"
    ))

    # ---- 5. Region serialisation variants (sidecars: byte-exact order) ---
    jpg("regions/digikam_order.jpg")
    sidecar("regions/digikam_order.jpg.xmp", packet(region_info(
        li_name_then_area("Alice", area_attr("0.25", "0.30", "0.10", "0.12"))
        + li_name_then_area("Bob", area_attr("0.60", "0.32", "0.11", "0.13"))
        + li_name_then_area("Carol", area_attr("0.80", "0.34", "0.09", "0.14"))
    )))

    # exiftool writes struct fields alphabetically: Area precedes Name. The
    # backwards Name lookup therefore lands on the PREVIOUS region's name.
    jpg("regions/exiftool_order.jpg")
    sidecar("regions/exiftool_order.jpg.xmp", packet(region_info(
        li_area_then_name("Alice", area_attr("0.25", "0.30", "0.10", "0.12"))
        + li_area_then_name("Bob", area_attr("0.60", "0.32", "0.11", "0.13"))
        + li_area_then_name("Carol", area_attr("0.80", "0.34", "0.09", "0.14"))
    )))

    # Name as an attribute on a self-closing-style rdf:li (Apple Photos shape).
    jpg("regions/name_as_attribute.jpg")
    sidecar("regions/name_as_attribute.jpg.xmp", packet(region_info(
        '      <rdf:li mwg-rs:Name="Erin" mwg-rs:Type="Face" rdf:parseType="Resource">\n'
        f'       {area_attr("0.40", "0.41", "0.20", "0.21")}\n'
        "      </rdf:li>\n"
    )))

    # Area coords as child elements rather than attributes.
    jpg("regions/element_form_area.jpg")
    sidecar("regions/element_form_area.jpg.xmp", packet(region_info(
        "      <rdf:li rdf:parseType=\"Resource\">\n"
        "       <mwg-rs:Name>Frank</mwg-rs:Name>\n"
        "       <mwg-rs:Area rdf:parseType=\"Resource\">\n"
        "        <stArea:x>0.5</stArea:x>\n"
        "        <stArea:y>0.55</stArea:y>\n"
        "        <stArea:w>0.1</stArea:w>\n"
        "        <stArea:h>0.11</stArea:h>\n"
        "        <stArea:unit>normalized</stArea:unit>\n"
        "       </mwg-rs:Area>\n"
        "      </rdf:li>\n"
    )))

    # unit="pixel" is rejected; a missing unit is accepted.
    jpg("regions/unit_variants.jpg")
    sidecar("regions/unit_variants.jpg.xmp", packet(region_info(
        li_name_then_area("PixelUnit", area_attr("10", "12", "4", "4", unit="pixel"))
        + li_name_then_area("NoUnit", area_attr("0.7", "0.7", "0.05", "0.05", unit=None))
        + li_name_then_area("MixedCase", area_attr("0.8", "0.8", "0.05", "0.05", unit="Normalized"))
    )))

    # The Name sits further back than the 2 KB look-behind window.
    jpg("regions/name_beyond_lookback.jpg")
    sidecar("regions/name_beyond_lookback.jpg.xmp", packet(region_info(
        "      <rdf:li rdf:parseType=\"Resource\">\n"
        "       <mwg-rs:Name>Grace</mwg-rs:Name>\n"
        "       <mwg-rs:Description>" + ("x" * 2500) + "</mwg-rs:Description>\n"
        f'       {area_attr("0.3", "0.3", "0.05", "0.05")}\n'
        "      </rdf:li>\n"
    )))

    # Unterminated Area as the LAST region: skipped outright.
    jpg("regions/malformed_last.jpg")
    sidecar("regions/malformed_last.jpg.xmp", packet(region_info(
        li_name_then_area("Hank", area_attr("0.2", "0.2", "0.1", "0.1"))
        + "      <rdf:li rdf:parseType=\"Resource\">\n"
        "       <mwg-rs:Name>Ivan</mwg-rs:Name>\n"
        f'       {area_attr("0.9", "0.9", "0.05", "0.05", close=False)}\n'
        "      </rdf:li>\n"
    )))

    # Unterminated Area FIRST, a well-formed element-form Area after it: the
    # look-ahead for `</mwg-rs:Area>` reaches across and swallows the second.
    jpg("regions/malformed_first.jpg")
    sidecar("regions/malformed_first.jpg.xmp", packet(region_info(
        "      <rdf:li rdf:parseType=\"Resource\">\n"
        "       <mwg-rs:Name>Judy</mwg-rs:Name>\n"
        f'       {area_attr("0.1", "0.1", "0.1", "0.1", close=False)}\n'
        "      </rdf:li>\n"
        "      <rdf:li rdf:parseType=\"Resource\">\n"
        "       <mwg-rs:Name>Karl</mwg-rs:Name>\n"
        "       <mwg-rs:Area rdf:parseType=\"Resource\">\n"
        "        <stArea:x>0.6</stArea:x>\n"
        "        <stArea:y>0.6</stArea:y>\n"
        "        <stArea:w>0.2</stArea:w>\n"
        "        <stArea:h>0.2</stArea:h>\n"
        "        <stArea:unit>normalized</stArea:unit>\n"
        "       </mwg-rs:Area>\n"
        "      </rdf:li>\n"
    )))

    # Non-numeric coordinate -> the whole region is dropped.
    jpg("regions/non_numeric_coords.jpg")
    sidecar("regions/non_numeric_coords.jpg.xmp", packet(region_info(
        li_name_then_area("Bad", area_attr("nope", "0.2", "0.1", "0.1"))
        + li_name_then_area("Good", area_attr("0.3", "0.3", "0.1", "0.1"))
    )))

    # Unnamed region (OCR-style rectangle) -> name stays nil.
    jpg("regions/unnamed.jpg")
    sidecar("regions/unnamed.jpg.xmp", packet(region_info(
        "      <rdf:li rdf:parseType=\"Resource\">\n"
        "       <mwg-rs:Type>BarCode</mwg-rs:Type>\n"
        f'       {area_attr("0.05", "0.05", "0.02", "0.02")}\n'
        "      </rdf:li>\n"
    )))

    # ---- 6. Non-JPEG / degenerate containers -----------------------------
    write("containers/plain.png", BASE_PNG)
    # PNG carrying an XMP packet (iTXt chunk written by exiftool).
    write("containers/png_with_xmp.png", BASE_PNG)
    blob = os.path.join(OUT, "containers", "png_with_xmp.packet.tmp")
    with open(blob, "w", encoding="utf-8") as f:
        f.write(packet(tags_list(["Places/Japan/Kyoto"])
                       + "   <photo-tools:CountryCode>jp</photo-tools:CountryCode>\n"))
    run(["exiftool", "-overwrite_original", f"-xmp<={blob}",
         os.path.join(OUT, "containers", "png_with_xmp.png")])
    os.remove(blob)

    # HEIF: the XMP packet is an *item* in a `meta` box, not a marker segment.
    # One with a packet, one with Exif only, and one where both are present and
    # the XMP item sits behind a kilobyte of `mdat` the reader must step over.
    heic_xmp = packet(tags_list(["Places/Japan/Kyoto"])
                      + "   <photo-tools:CountryCode>jp</photo-tools:CountryCode>\n"
                      ).encode("utf-8")
    write("containers/heif_xmp.heic", make_heic([(b"mime", XMP_MIME, heic_xmp)]))

    jpg("containers/heif_exif.donor.tmp.jpg", ["-EXIF:DateTimeOriginal=2022:09:18 11:22:33"])
    donor = os.path.join(OUT, "containers", "heif_exif.donor.tmp.jpg")
    exif_payload = exif_item_payload(donor)
    os.remove(donor)
    write("containers/heif_exif.heic", make_heic([(b"Exif", None, exif_payload)]))
    # Exif first, XMP second: `iloc` is what says where each one starts, and a
    # reader that assumed the packet was at the front of `mdat` would read the
    # TIFF block instead.
    write("containers/heif_both.heic", make_heic([
        (b"Exif", None, exif_payload),
        (b"mime", XMP_MIME, heic_xmp),
    ]))
    # `mif1` major brand with `heic` only in the compatible list — how libheif
    # and some Android encoders write the same file.
    write("containers/heif_mif1_brand.heic",
          make_heic([(b"mime", XMP_MIME, heic_xmp)], brand=b"mif1"))

    write("containers/zero_byte.jpg", b"")
    write("containers/truncated.jpg", BASE_JPG[:40])
    # Wrong extensions in both directions.
    write("containers/actually_png.jpg", BASE_PNG)
    write("containers/actually_jpeg.txt", BASE_JPG)
    # A sidecar next to a zero-byte photo still contributes everything.
    sidecar("containers/zero_byte.jpg.xmp", packet(tags_list(["Scenes/Void"])))

    # ---- 7. Filenames ----------------------------------------------------
    jpg("names/spaces and (parens).jpg", ["-EXIF:DateTimeOriginal=2020:01:02 03:04:05"])
    jpg("names/emoji \U0001f335 cactus.jpg", ["-EXIF:DateTimeOriginal=2020:01:02 03:04:06"])
    jpg("names/UPPER.JPG", ["-EXIF:DateTimeOriginal=2020:01:02 03:04:07"])
    jpg("names/dotted.name.v2.jpg", ["-EXIF:DateTimeOriginal=2020:01:02 03:04:08"])
    sidecar("names/dotted.name.v2.jpg.xmp", packet(tags_list(["Objects/Kite"])))

    # ---- 8. Videos -------------------------------------------------------
    # QuickTime `udta/©day` with an explicit UTC offset.
    write("video/qt_utc.mov", make_movie("2015-01-02T03:04:05+0000"))
    # Non-UTC offset — the reader must apply it (14:33:07+0530 = 09:03:07Z).
    write("video/qt_offset.mov", make_movie("2018-06-15T14:33:07+0530"))
    # Zone-less ©day: AVFoundation reads it as UTC, not device-local.
    write("video/qt_naive.mov", make_movie("2019-09-09T09:09:09"))
    # No udta at all.
    write("video/qt_no_date.mov", make_movie(None))
    # A QuickTime-branded file with an .mp4 extension still resolves.
    write("video/qt_branded.mp4", make_movie("2016-12-24T18:00:00+0100"))
    # An ISO-branded MP4 with the same `udta/©day`: AVFoundation ignores it
    # (iTunes-style `moov/udta/meta/ilst` would be required).
    write("video/isom_udta.mp4", make_movie("2017-07-07T07:07:07+0000", brand=b"isom"))

    total = 0
    count = 0
    for root, _dirs, files in os.walk(OUT):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
            count += 1
    print(f"wrote {count} files, {total} bytes -> {os.path.relpath(OUT, REPO)}")
    if total > 2_000_000:
        sys.exit("fixture tree exceeded the 2 MB budget")


if __name__ == "__main__":
    if shutil.which("exiftool") is None:
        sys.exit("exiftool is required (brew install exiftool)")
    build()
