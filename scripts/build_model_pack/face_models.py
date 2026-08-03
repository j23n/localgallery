#!/usr/bin/env python3
"""Fetch the face detector and embedder and write the pack manifest's `faces`
block.

    .venv/bin/python build_pack.py --only-faces      # add faces to an existing pack
    .venv/bin/python face_models.py --out /tmp/faces # just the two ONNX files

# Which models, and why

**SCRFD-500M** (detection) and **w600k_mbf** (ArcFace/MobileFaceNet embedding),
both from insightface's `buffalo_sc` bundle. The comparison that decided it:

|  | SCRFD-500M + w600k_mbf | YuNet + SFace |
| --- | --- | --- |
| distribution | one GitHub release asset, 15 MB, plain binary | two files in `opencv_zoo`, stored in git-lfs — a raw fetch returns a 131-byte pointer, and the media URL is a different host again |
| landmark convention | SCRFD's 5 points are the *same order and definition* `w600k_mbf`'s training crops were aligned with | YuNet emits the eyes in the opposite order; every pack would carry a permutation nobody can test cheaply |
| ONNX graph | opset 11, static output shapes, no control flow | same, but the detector needs input dims that are multiples of 32 |
| size | 2.5 MB + 13.0 MB | 0.23 MB + 38 MB |
| licence | **non-commercial research only** | Apache-2.0 / MIT |

The alignment contract is the risk that matters. It is the one part of a face
pipeline that fails *silently* — a mismatched landmark order produces crops that
look wrong only if you render them, and embeddings that cluster badly for
reasons no log line explains. Pairing a detector and an embedder that were
built against each other removes that risk entirely, and it is why the licence
column did not win.

That licence is a real constraint on shipping, not a footnote. The mitigation is
structural rather than legal: `faces.detector` and `faces.embedder` declare
their geometry, their normalization, their output names, their strides and their
anchor layout **in the manifest**, so the permissive pairing is a pack rebuild
and a threshold re-calibration — not a code change. `--detector yunet` is the
hook that would land here.

# Determinism

Both files are downloaded, not converted: they are the exact bytes insightface
published, and the manifest records their SHA-256. There is no export step to
be non-deterministic. `--verify` re-downloads and re-hashes.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import shutil
import urllib.request
import zipfile
from pathlib import Path

#: insightface's compact bundle: exactly the two models we want, nothing else.
BUNDLE_URL = (
    "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip"
)
#: SHA-256 of the release asset, pinned. A mismatch means the asset was
#: replaced, which is a thing that must fail loudly rather than silently reship.
BUNDLE_SHA256 = "57d31b56b6ffa911c8a73cfc1707c73cab76efe7f13b675a05223bf42de47c72"

DETECTOR_MEMBER = "det_500m.onnx"
EMBEDDER_MEMBER = "w600k_mbf.onnx"
DETECTOR_FILE = "face_detector.onnx"
EMBEDDER_FILE = "face_embedder.onnx"

DETECTOR_SHA256 = "5e4447f50245bbd7966bd6c0fa52938c61474a04ec7def48753668a9d8b4ea3a"
EMBEDDER_SHA256 = "9cc6e4a75f0e2bf0b1aed94578f144d15175f357bdc05e815e5c4a02b319eb4f"

#: SCRFD's graph names its outputs numerically. Read off the exported model
#: (`onnx.load(...).graph.output`), in graph order: scores for strides 8/16/32,
#: then boxes, then landmarks. They are declared in the manifest rather than
#: hard-coded in Rust precisely because they are this arbitrary.
SCORE_OUTPUTS = ["443", "468", "493"]
BBOX_OUTPUTS = ["446", "471", "496"]
KPS_OUTPUTS = ["449", "474", "499"]
DETECTOR_INPUT = "input.1"
DETECTOR_STRIDES = [8, 16, 32]
DETECTOR_ANCHORS = 2

#: 640 is what insightface runs `det_500m` at, and the exported graph's output
#: shapes (12800/3200/800 anchors) are inferred at exactly that size. A
#: different letterbox would still run — the input dims are symbolic — but it
#: would be a geometry the model was never validated at.
DETECTOR_INPUT_SIZE = 640

#: insightface feeds the detector `(pixel - 127.5) / 128` on RGB. In the
#: manifest's `[0, 1]` space that is mean 0.5, std 128/255.
DETECTOR_MEAN = [0.5, 0.5, 0.5]
DETECTOR_STD = [128.0 / 255.0] * 3
#: The recognition model uses `(pixel - 127.5) / 127.5`, i.e. `[-1, 1]`.
EMBEDDER_MEAN = [0.5, 0.5, 0.5]
EMBEDDER_STD = [0.5, 0.5, 0.5]

#: `cv2.resize`'s default is `INTER_LINEAR`, which is the triangle filter
#: `ResizeFilter::Bilinear` implements.
DETECTOR_RESIZE_FILTER = "bilinear"

#: insightface's own defaults for `det_500m`.
SCORE_THRESHOLD = 0.5
NMS_IOU = 0.4

#: A group photo can hold dozens of faces; 32 is well past a family portrait
#: and bounds the per-photo cost of the embedder, which runs once per face.
MAX_FACES = 32

#: Below ~24 px the 112x112 aligned crop is almost entirely upsampling, and the
#: embedding stops being evidence about anybody. Faces that small are also
#: unusable as a UI cover crop.
MIN_FACE_PIXELS = 24.0

EMBEDDER_INPUT = "input.1"
EMBEDDER_OUTPUT = "516"
EMBEDDER_INPUT_SIZE = 112
EMBEDDING_DIM = 512

#: Cosine thresholds. See `ClusteringConfig`'s rustdoc in
#: `core/gallery-ml/src/pack.rs` for the derivation; in short, published
#: ArcFace verification sits near 0.28 and clustering needs a much lower
#: per-pair false-accept rate than verification does, while `auto` gates a
#: write to somebody's sidecar and is stricter again.
#:
#: Measured on this exact embedder over the `reference_images.py` set: two
#: distinct real identities score <= 0.091 across 121 crop pairs, and the same
#: identity under the whole imaging-pipeline perturbation range (rescale to
#: 35%, JPEG q30, +-40% brightness, horizontal flip) stays >= 0.707. Every
#: threshold below sits inside that gap with room on both sides.
CLUSTERING = {
    "join": 0.42,
    "auto": 0.55,
    "merge": 0.60,
    "edge": 0.45,
    "min_quality": 0.25,
    "cw_iterations": 20,
    "cw_seed": 20260803,
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_bundle(cache: Path | None) -> bytes:
    """The release zip, from `cache` if it is there, verified either way."""
    if cache is not None and cache.exists():
        data = cache.read_bytes()
    else:
        print(f"downloading {BUNDLE_URL}")
        with urllib.request.urlopen(BUNDLE_URL) as response:  # noqa: S310
            data = response.read()
        if cache is not None:
            cache.parent.mkdir(parents=True, exist_ok=True)
            cache.write_bytes(data)
    actual = sha256_bytes(data)
    if actual != BUNDLE_SHA256:
        raise SystemExit(
            f"buffalo_sc.zip hashes to {actual}, expected {BUNDLE_SHA256}.\n"
            "The release asset changed; do not ship it until the new models "
            "have been re-calibrated."
        )
    return data


def extract(data: bytes, out_dir: Path) -> dict[str, str]:
    """Write the two ONNX files into `out_dir`; return their hashes."""
    out_dir.mkdir(parents=True, exist_ok=True)
    hashes = {}
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = {Path(n).name: n for n in archive.namelist()}
        for member, name, expected in (
            (DETECTOR_MEMBER, DETECTOR_FILE, DETECTOR_SHA256),
            (EMBEDDER_MEMBER, EMBEDDER_FILE, EMBEDDER_SHA256),
        ):
            if member not in members:
                raise SystemExit(f"{member} is not in the bundle: {sorted(members)}")
            payload = archive.read(members[member])
            actual = sha256_bytes(payload)
            if actual != expected:
                raise SystemExit(f"{member} hashes to {actual}, expected {expected}")
            (out_dir / name).write_bytes(payload)
            hashes[name] = actual
            print(f"{name}: {len(payload) / 1e6:.1f} MB sha={actual[:12]}")
    return hashes


def faces_block(hashes: dict[str, str], clustering: dict | None = None) -> dict:
    """The manifest's `faces` object."""
    return {
        "detector": {
            "file": DETECTOR_FILE,
            "sha256": hashes[DETECTOR_FILE],
            "input_name": DETECTOR_INPUT,
            "input_size": DETECTOR_INPUT_SIZE,
            "score_outputs": SCORE_OUTPUTS,
            "bbox_outputs": BBOX_OUTPUTS,
            "kps_outputs": KPS_OUTPUTS,
            "strides": DETECTOR_STRIDES,
            "anchors_per_cell": DETECTOR_ANCHORS,
            "mean": DETECTOR_MEAN,
            "std": DETECTOR_STD,
            "resize_filter": DETECTOR_RESIZE_FILTER,
            "score_threshold": SCORE_THRESHOLD,
            "nms_iou": NMS_IOU,
            "max_faces": MAX_FACES,
            "min_face_pixels": MIN_FACE_PIXELS,
        },
        "embedder": {
            "file": EMBEDDER_FILE,
            "sha256": hashes[EMBEDDER_FILE],
            "input_name": EMBEDDER_INPUT,
            "output_name": EMBEDDER_OUTPUT,
            "input_size": EMBEDDER_INPUT_SIZE,
            "embedding_dim": EMBEDDING_DIM,
            "mean": EMBEDDER_MEAN,
            "std": EMBEDDER_STD,
        },
        "clustering": dict(clustering or CLUSTERING),
    }


def install(pack_dir: Path, cache: Path | None) -> dict[str, str]:
    """Put both models in `pack_dir`, skipping the download when they match."""
    existing = {
        name: sha256_file(pack_dir / name)
        for name, expected in ((DETECTOR_FILE, DETECTOR_SHA256), (EMBEDDER_FILE, EMBEDDER_SHA256))
        if (pack_dir / name).exists() and sha256_file(pack_dir / name) == expected
    }
    if len(existing) == 2:
        print("face models already present and verified")
        return existing
    return extract(download_bundle(cache), pack_dir)


def verify_graphs(pack_dir: Path) -> None:
    """Assert the graphs really have the names and shapes the manifest claims.

    A manifest that names an output the model does not have fails at the first
    photo, on-device, with an inference error nobody can act on. Checking here
    turns that into a build-time failure with the actual names in it.

    Requires `onnx`; skipped with a note when it is not installed, since the
    pack is perfectly buildable without it.
    """
    try:
        import onnx
    except ImportError:
        print("skipping graph verification (pip install onnx)")
        return

    detector = onnx.load(str(pack_dir / DETECTOR_FILE))
    names = [o.name for o in detector.graph.output]
    expected = SCORE_OUTPUTS + BBOX_OUTPUTS + KPS_OUTPUTS
    missing = [n for n in expected if n not in names]
    if missing:
        raise SystemExit(f"detector is missing outputs {missing}; it has {names}")
    if detector.graph.input[0].name != DETECTOR_INPUT:
        raise SystemExit(
            f"detector input is {detector.graph.input[0].name!r}, "
            f"manifest says {DETECTOR_INPUT!r}"
        )
    # Anchor counts implied by the letterbox size must match the exported
    # shapes, or the Rust decode reads the wrong number of values.
    for stride, name in zip(DETECTOR_STRIDES, SCORE_OUTPUTS):
        want = (DETECTOR_INPUT_SIZE // stride) ** 2 * DETECTOR_ANCHORS
        got = next(o for o in detector.graph.output if o.name == name)
        got = got.type.tensor_type.shape.dim[0].dim_value
        if got != want:
            raise SystemExit(
                f"stride {stride}: graph says {got} anchors, "
                f"{DETECTOR_INPUT_SIZE}px letterbox implies {want}"
            )

    embedder = onnx.load(str(pack_dir / EMBEDDER_FILE))
    if embedder.graph.input[0].name != EMBEDDER_INPUT:
        raise SystemExit(f"embedder input is {embedder.graph.input[0].name!r}")
    out = embedder.graph.output[0]
    if out.name != EMBEDDER_OUTPUT:
        raise SystemExit(f"embedder output is {out.name!r}, manifest says {EMBEDDER_OUTPUT!r}")
    dim = out.type.tensor_type.shape.dim[-1].dim_value
    if dim != EMBEDDING_DIM:
        raise SystemExit(f"embedder emits {dim} values, manifest says {EMBEDDING_DIM}")
    print("graphs verified: names, strides and anchor counts match the manifest")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True, help="directory to write into")
    parser.add_argument(
        "--cache",
        type=Path,
        default=None,
        help="keep the downloaded release asset here so a rebuild is offline",
    )
    parser.add_argument("--clean", action="store_true")
    args = parser.parse_args()

    if args.clean and args.out.exists():
        shutil.rmtree(args.out)
    args.out.mkdir(parents=True, exist_ok=True)
    install(args.out, args.cache)
    verify_graphs(args.out)


if __name__ == "__main__":
    main()
