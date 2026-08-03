#!/usr/bin/env python3
"""Generate the committed test model pack and image fixtures for gallery-ml.

The pack is a *real* model pack — a real ONNX graph with real weights, loaded
by real ONNX Runtime — just a tiny one (~30 KB). A mocked `ImageEncoder` would
test the orchestration and nothing else; the interesting failures live in the
ONNX plumbing: input/output names, NCHW layout, f32 extraction, session
threading.

Everything here is seeded. Re-running the script must reproduce the committed
bytes exactly, or the manifest hashes stop matching and the tests fail loudly.

    python3 -m venv .venv && .venv/bin/pip install onnx numpy pillow
    .venv/bin/python core/gallery-ml/tests/make_test_pack.py

Outputs, all committed:

    tests/testpack/manifest.json          schema 1: tagging only
    tests/testpack/encoder.onnx           tiny conv/pool/matmul net, 64-d out
    tests/testpack/labels.json
    tests/testpack/label_embeddings.f32   6 x 64 f32, little-endian
    tests/facepack/…                      schema 2: the same, plus face models
    tests/facepack/face_detector.onnx     brightness -> per-anchor scores
    tests/facepack/face_embedder.onnx     a copy of encoder.onnx
    tests/fixtures/*.jpg, *.png, *.txt

`testpack` and `facepack` exist as a *pair* on purpose: a pack without face
models must keep tagging exactly as before, and the only way to be sure of that
is to keep running the tagging suite against a pack that has none.

# The synthetic face detector

Real face detection needs a real detector, and the only tests that can prove
this crate drives one correctly are the `#[ignore]`d ones in
`tests/face_real_models.rs` that load the shipped pack. What the committed pack
has to do instead is exercise the *plumbing*: the per-stride output decode, the
anchor-grid layout, NMS, the alignment warp, the embedding call, the cache
round trip and the clustering pass.

So `face_detector.onnx` is a deliberately trivial graph: it reduces the input
to a single mean brightness and turns that into a per-anchor logit through a
fixed slope and a per-anchor bias ramp. Brighter image, more faces — which
makes "this fixture has 0 faces and that one has 4" a property of the fixture
rather than a property of a model nobody can read. Boxes and landmarks are
per-anchor constants placed on a disjoint grid, so NMS has something real to
do and every surviving face crops a different part of the image.

# Choosing thresholds

LABEL_THRESHOLDS below is not guessable: it depends on what the seeded weights
happen to do to the seeded fixtures. The loop is

  1. set every threshold to -1.0 (everything passes),
  2. regenerate, then run
     `cargo test -p gallery-ml --test engine_e2e -- --ignored --nocapture`,
     which prints the score of every label on every fixture,
  3. pick thresholds that split those scores into the tag sets the tests
     assert, and put them here.

That is a one-time cost; afterwards the pack is frozen and any change in the
Rust pipeline that moves a score across one of these lines fails a test, which
is exactly what a golden pack is for.
"""

from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper
from PIL import Image

HERE = Path(__file__).parent
PACK = HERE / "testpack"
FACE_PACK = HERE / "facepack"
FIXTURES = HERE / "fixtures"

PACK_VERSION = "gallery-ml-testpack-1"
FACE_PACK_VERSION = "gallery-ml-facepack-1"
INPUT_SIZE = 64
EMBED_DIM = 64
WEIGHT_SEED = 1234
LABEL_SEED = 99

# Normalization is deliberately *not* the CLIP constants: round numbers make a
# hand-computed golden tensor checkable, and the test pack has no lineage to a
# real training recipe to be faithful to.
MEAN = [0.5, 0.5, 0.5]
STD = [0.5, 0.5, 0.5]

# See the module docstring for how these were chosen. `None` means "inherit the
# root threshold" — Beach is there to exercise that path (and to be a label
# that never fires, which is its own kind of coverage).
#
# The numbers are picked so the three fixtures land on three interestingly
# different outcomes: `gradient`/`meadow` clear three Objects labels and hit
# the cap, `stripes` clears none of them at all, and each fixture's single
# Scenes tag is decided by a different label.
LABEL_THRESHOLDS = {
    "Objects/Animal/Cat": -0.07,
    "Objects/Animal/Dog": 0.06,
    "Objects/Vehicle/Car": 0.22,
    "Scenes/Nature/Beach": None,
    "Scenes/Nature/Forest": 0.01,
    "Scenes/Urban/Street": 0.175,
}
ROOTS = {
    "Objects": {"threshold": 0.60, "max_tags": 2},
    "Scenes": {"threshold": 0.60, "max_tags": 1},
}
# Comfortably larger than any float drift, and larger than the gap between
# each fixture's score and its threshold, so the hysteresis test can tighten
# the pack into the band and watch tags survive.
HYSTERESIS_EPSILON = 0.05

# --------------------------------------------------------------------------
# Face pack constants
# --------------------------------------------------------------------------

#: Detector letterbox edge. Small, but a multiple of both strides, which the
#: manifest validator insists on.
DET_SIZE = 32
DET_STRIDES = [16, 32]
DET_ANCHORS = 2

#: `logit = DET_SLOPE * mean(normalized input) + bias`. The slope is steep
#: enough that the three brightness fixtures land on clearly different face
#: counts rather than near a decision boundary.
DET_SLOPE = 4.0
#: Descending, so brightness walks down the ramp and lights up more anchors.
#: Stride 32's two anchors sit far below the rest — they are there to prove the
#: multi-level decode runs, not to fire on ordinary input.
DET_BIAS = {16: [0.5, -0.5, -1.5, -2.5, -3.5, -4.5, -5.5, -6.5], 32: [-8.0, -9.0]}

#: Boxes, in *letterbox* pixels, one per anchor in flat-index order. Disjoint
#: by construction so NMS keeps all of them and each crop sees different
#: pixels; `finalize`'s suppression is still exercised by the two levels
#: overlapping at the corners.
DET_BOXES = {
    16: [
        (0, 0), (8, 8), (16, 0), (24, 8),
        (0, 16), (8, 24), (16, 16), (24, 24),
    ],
    32: [(24, 0), (0, 24)],
}
DET_BOX_EDGE = 8

DET_SCORE_THRESHOLD = 0.5
DET_NMS_IOU = 0.4
DET_MAX_FACES = 4
DET_MIN_FACE_PIXELS = 8.0

#: `arcface_dst`, mirrored from `core/gallery-ml/src/face/align.rs`. Only used
#: here to place each anchor's landmarks inside its box, so the aligner has a
#: well-conditioned five-point set to fit.
ARCFACE_TEMPLATE = [
    (38.2946, 51.6963),
    (73.5318, 51.5014),
    (56.0252, 71.7366),
    (41.5493, 92.3655),
    (70.7299, 92.2041),
]


# --------------------------------------------------------------------------
# ONNX encoder
# --------------------------------------------------------------------------


def build_encoder() -> onnx.ModelProto:
    """A 5-layer conv net: 1x3x64x64 -> 1x64.

    Small enough to commit, deep enough that a layout bug (NHWC vs NCHW, a
    channel swap) changes the output instead of hiding in the noise. Weights
    are drawn from a fixed-seed generator and scaled so activations stay in a
    sane range without any normalization layers.
    """
    rng = np.random.RandomState(WEIGHT_SEED)

    def w(*shape, scale):
        return (rng.standard_normal(shape) * scale).astype(np.float32)

    initializers = [
        numpy_helper.from_array(w(8, 3, 5, 5, scale=0.20), "conv1_w"),
        numpy_helper.from_array(w(8, scale=0.05), "conv1_b"),
        numpy_helper.from_array(w(16, 8, 3, 3, scale=0.20), "conv2_w"),
        numpy_helper.from_array(w(16, scale=0.05), "conv2_b"),
        numpy_helper.from_array(w(16, EMBED_DIM, scale=0.30), "proj_w"),
        numpy_helper.from_array(w(EMBED_DIM, scale=0.05), "proj_b"),
        numpy_helper.from_array(
            np.array([1, 16], dtype=np.int64), "flat_shape"
        ),
    ]

    nodes = [
        helper.make_node(
            "Conv", ["image", "conv1_w", "conv1_b"], ["c1"],
            kernel_shape=[5, 5], strides=[2, 2], pads=[2, 2, 2, 2],
        ),
        helper.make_node("Relu", ["c1"], ["r1"]),
        helper.make_node(
            "MaxPool", ["r1"], ["p1"], kernel_shape=[2, 2], strides=[2, 2],
        ),
        helper.make_node(
            "Conv", ["p1", "conv2_w", "conv2_b"], ["c2"],
            kernel_shape=[3, 3], strides=[2, 2], pads=[1, 1, 1, 1],
        ),
        helper.make_node("Relu", ["c2"], ["r2"]),
        helper.make_node("GlobalAveragePool", ["r2"], ["gap"]),
        helper.make_node("Reshape", ["gap", "flat_shape"], ["flat"]),
        helper.make_node("MatMul", ["flat", "proj_w"], ["proj"]),
        helper.make_node("Add", ["proj", "proj_b"], ["embedding"]),
    ]

    graph = helper.make_graph(
        nodes,
        "gallery_ml_test_encoder",
        inputs=[
            helper.make_tensor_value_info(
                "image", TensorProto.FLOAT, [1, 3, INPUT_SIZE, INPUT_SIZE]
            )
        ],
        outputs=[
            helper.make_tensor_value_info(
                "embedding", TensorProto.FLOAT, [1, EMBED_DIM]
            )
        ],
        initializer=initializers,
    )
    model = helper.make_model(
        graph,
        producer_name="gallery-ml make_test_pack.py",
        # Opset 13 is old enough that every ORT build in sight supports it and
        # new enough for Reshape-with-initializer.
        opset_imports=[helper.make_opsetid("", 13)],
    )
    # `doc_string` and `model_version` default to values that do not vary, but
    # be explicit: the file's SHA-256 is in the manifest.
    model.model_version = 1
    model.doc_string = ""
    onnx.checker.check_model(model)
    return model


# --------------------------------------------------------------------------
# ONNX face detector
# --------------------------------------------------------------------------


def anchor_centres(stride: int) -> list[tuple[float, float]]:
    """Flat anchor order: row-major over the grid, anchors adjacent.

    This mirrors `face::detect::anchor_centre`. If the two ever disagree the
    committed pack's boxes land on the wrong anchors and the engine tests fail,
    which is the point of writing it out twice.
    """
    cells = DET_SIZE // stride
    return [
        (float(x * stride), float(y * stride))
        for y in range(cells)
        for x in range(cells)
        for _ in range(DET_ANCHORS)
    ]


def anchor_geometry(stride: int) -> tuple[np.ndarray, np.ndarray]:
    """`(bbox [N,4], kps [N,10])` in the stride units the decode expects."""
    centres = anchor_centres(stride)
    boxes, kps = [], []
    for (cx, cy), (x0, y0) in zip(centres, DET_BOXES[stride]):
        x1, y1 = x0 + DET_BOX_EDGE, y0 + DET_BOX_EDGE
        # decode: bbox = [cx - l*s, cy - t*s, cx + r*s, cy + b*s]
        boxes.append(
            [(cx - x0) / stride, (cy - y0) / stride, (x1 - cx) / stride, (y1 - cy) / stride]
        )
        # decode: point_j = (cx + dx_j*s, cy + dy_j*s)
        k = DET_BOX_EDGE / 112.0
        row = []
        for tx, ty in ARCFACE_TEMPLATE:
            row += [(x0 + tx * k - cx) / stride, (y0 + ty * k - cy) / stride]
        kps.append(row)
    return np.array(boxes, dtype=np.float32), np.array(kps, dtype=np.float32)


def build_face_detector() -> onnx.ModelProto:
    """`1x3xSxS -> per-stride (score, bbox, kps)`.

    Scores come from one scalar — the mean of the normalized input — through a
    per-anchor affine and a sigmoid. Boxes and landmarks are constants. See the
    module docstring for why a *trivial* detector is the right thing to commit.
    """
    initializers = [
        numpy_helper.from_array(np.full((3, 1), 1.0 / 3.0, dtype=np.float32), "chan_mean"),
        numpy_helper.from_array(np.array([1, 3], dtype=np.int64), "chw_shape"),
    ]
    nodes = [
        helper.make_node("GlobalAveragePool", ["input"], ["gap"]),
        helper.make_node("Reshape", ["gap", "chw_shape"], ["chan"]),
        helper.make_node("MatMul", ["chan", "chan_mean"], ["mean"]),
    ]
    outputs = []

    for stride in DET_STRIDES:
        n = len(DET_BIAS[stride])
        assert n == (DET_SIZE // stride) ** 2 * DET_ANCHORS, stride
        boxes, kps = anchor_geometry(stride)
        initializers += [
            numpy_helper.from_array(
                np.full((1, n), DET_SLOPE, dtype=np.float32), f"slope_{stride}"
            ),
            numpy_helper.from_array(
                np.array(DET_BIAS[stride], dtype=np.float32), f"bias_{stride}"
            ),
            numpy_helper.from_array(np.array([n, 1], dtype=np.int64), f"score_shape_{stride}"),
            numpy_helper.from_array(boxes, f"bbox_{stride}"),
            numpy_helper.from_array(kps, f"kps_{stride}"),
        ]
        nodes += [
            helper.make_node(
                "Gemm", ["mean", f"slope_{stride}", f"bias_{stride}"], [f"logit_{stride}"]
            ),
            helper.make_node("Sigmoid", [f"logit_{stride}"], [f"prob_{stride}"]),
            helper.make_node(
                "Reshape", [f"prob_{stride}", f"score_shape_{stride}"], [f"score_{stride}"]
            ),
            # `Identity` rather than exporting an initializer directly: an ONNX
            # graph output must be produced by a node.
            helper.make_node("Identity", [f"bbox_{stride}"], [f"box_{stride}"]),
            helper.make_node("Identity", [f"kps_{stride}"], [f"kp_{stride}"]),
        ]
        outputs += [
            helper.make_tensor_value_info(f"score_{stride}", TensorProto.FLOAT, [n, 1]),
            helper.make_tensor_value_info(f"box_{stride}", TensorProto.FLOAT, [n, 4]),
            helper.make_tensor_value_info(f"kp_{stride}", TensorProto.FLOAT, [n, 10]),
        ]

    graph = helper.make_graph(
        nodes,
        "gallery_ml_test_face_detector",
        inputs=[
            helper.make_tensor_value_info(
                "input", TensorProto.FLOAT, [1, 3, DET_SIZE, DET_SIZE]
            )
        ],
        outputs=outputs,
        initializer=initializers,
    )
    model = helper.make_model(
        graph,
        producer_name="gallery-ml make_test_pack.py",
        opset_imports=[helper.make_opsetid("", 13)],
    )
    model.model_version = 1
    model.doc_string = ""
    onnx.checker.check_model(model)
    return model


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------


def gradient(w: int, h: int, seed: int) -> Image.Image:
    """A deterministic, structured, non-flat image.

    Structure matters: a flat colour makes every convolution output the same
    thing, and the resize/crop geometry becomes untestable.
    """
    rng = np.random.RandomState(seed)
    ys, xs = np.mgrid[0:h, 0:w]
    r = (xs * 255 // max(w - 1, 1)).astype(np.float64)
    g = (ys * 255 // max(h - 1, 1)).astype(np.float64)
    b = ((xs + ys) * 127 // max(w + h - 2, 1)).astype(np.float64)
    arr = np.stack([r, g, b], axis=-1) + rng.uniform(-12, 12, size=(h, w, 3))
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


def stripes(w: int, h: int, period: int) -> Image.Image:
    ys, xs = np.mgrid[0:h, 0:w]
    on = ((xs // period) + (ys // period)) % 2
    arr = np.stack(
        [on * 220 + 20, (1 - on) * 200 + 30, ((xs + ys) % 256)], axis=-1
    )
    return Image.fromarray(arr.astype(np.uint8), "RGB")


def write_fixtures() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)

    # The golden-tensor fixture. Non-square on purpose so the shortest-side
    # resize and the center crop both do real work.
    gradient(96, 64, seed=7).save(
        FIXTURES / "gradient.jpg", "JPEG", quality=92, optimize=False
    )
    stripes(80, 120, 9).save(
        FIXTURES / "stripes.jpg", "JPEG", quality=92, optimize=False
    )
    gradient(70, 70, seed=21).save(FIXTURES / "meadow.png", "PNG", optimize=False)

    # Orientation trio, in PNG so the comparison can be exact: JPEG's lossy
    # round trip would make "rotate then encode" and "encode then rotate"
    # differ by a few LSBs and turn an equality assertion into a tolerance
    # argument.
    base = gradient(96, 64, seed=33)
    base.save(FIXTURES / "orient_none.png", "PNG", optimize=False)
    exif = Image.Exif()
    exif[0x0112] = 6  # Rotate 90 CW
    base.save(FIXTURES / "orient_6.png", "PNG", optimize=False, exif=exif)
    base.transpose(Image.Transpose.ROTATE_270).save(
        FIXTURES / "orient_pre.png", "PNG", optimize=False
    )

    # A JPEG header with nothing behind it: decodes must fail as Decode, not
    # UnsupportedFormat, and must not take the run down.
    (FIXTURES / "broken.jpg").write_bytes(b"\xff\xd8\xff\xe0\x00\x10JFIF" + b"\x00" * 24)
    # Not an image at all: skipped on extension, before a byte is read.
    (FIXTURES / "notes.txt").write_bytes(b"not a photo\n")

    # Face fixtures. The synthetic detector reads mean brightness, so these
    # three are the same structured pattern at three exposures and land on
    # three different face counts. Structure (rather than a flat fill) matters
    # twice over: the aligned crops must differ between anchors, or every face
    # in a photo would embed identically and the clustering pass would have
    # nothing to do.
    for name, level in (("face_dark.png", 0.15), ("face_mid.png", 0.5), ("face_bright.png", 0.85)):
        brightness(64, 64, seed=5, level=level).save(
            FIXTURES / name, "PNG", optimize=False
        )

    write_real_face()


def write_real_face() -> None:
    """`face.jpg`: a real photograph of a real face, for the alignment golden.

    Synthetic fixtures cannot serve here. The golden pins the exact 112x112
    tensor the aligner produces from a five-point landmark set, and a landmark
    set only means anything on top of a face — the whole transform is defined
    by where the eyes, nose and mouth actually are.

    `skimage.data.astronaut()` is NASA's portrait of Eileen Collins: public
    domain, redistributable, and already the reference photo Phase 1's
    threshold calibration used (`scripts/build_model_pack/reference_images.py`).
    Downscaled to 256x256 so the committed fixture is ~21 KB.

    Skipped, with a note, when scikit-image is not installed: the file is
    committed, and nothing in the test suite needs to regenerate it.
    """
    try:
        import skimage.data as data
    except ImportError:
        print("skipping face.jpg (pip install scikit-image to regenerate)")
        return
    image = Image.fromarray(np.asarray(data.astronaut()), "RGB").resize(
        (256, 256), Image.LANCZOS
    )
    image.save(FIXTURES / "face.jpg", "JPEG", quality=88, optimize=False)

    grey = np.asarray(data.camera())
    second = Image.fromarray(np.stack([grey] * 3, axis=-1), "RGB").resize(
        (256, 256), Image.LANCZOS
    )
    second.save(FIXTURES / "face2.jpg", "JPEG", quality=88, optimize=False)


def brightness(w: int, h: int, seed: int, level: float) -> Image.Image:
    """`gradient`'s structure, compressed into a band around `level`."""
    arr = np.asarray(gradient(w, h, seed), dtype=np.float64) / 255.0
    # Keep a quarter of the original contrast so the mean is dominated by
    # `level` and the crops still differ from each other.
    arr = np.clip(level + (arr - 0.5) * 0.25, 0.0, 1.0)
    return Image.fromarray(np.round(arr * 255).astype(np.uint8), "RGB")


# --------------------------------------------------------------------------
# Labels
# --------------------------------------------------------------------------


def write_labels(pack: Path) -> tuple[str, str]:
    rng = np.random.RandomState(LABEL_SEED)
    paths = sorted(LABEL_THRESHOLDS)
    matrix = rng.standard_normal((len(paths), EMBED_DIM)).astype(np.float32)
    # L2-normalize here as well as in Rust. Rust normalizes defensively at
    # load; shipping unit rows means the committed file is already what the
    # loader wants, and a bug in either place shows up as a score change.
    matrix /= np.linalg.norm(matrix, axis=1, keepdims=True)

    blob = b"".join(struct.pack("<f", v) for v in matrix.reshape(-1))
    (pack / "label_embeddings.f32").write_bytes(blob)

    labels = {
        "schema": 1,
        "dim": EMBED_DIM,
        "labels": [
            {
                k: v
                for k, v in (
                    ("path", p),
                    ("prompt", f"a photo of {p.rsplit('/', 1)[1].lower()}"),
                    ("threshold", LABEL_THRESHOLDS[p]),
                )
                if v is not None
            }
            for p in paths
        ],
    }
    labels_bytes = json.dumps(labels, indent=2, sort_keys=True).encode() + b"\n"
    (pack / "labels.json").write_bytes(labels_bytes)
    return sha256(labels_bytes), sha256(blob)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tagging_manifest(pack: Path, schema: int, version: str) -> dict:
    """The shared half of both packs: encoder, labels, thresholds."""
    model_bytes = build_encoder().SerializeToString()
    (pack / "encoder.onnx").write_bytes(model_bytes)
    labels_sha, embeddings_sha = write_labels(pack)
    return {
        "schema": schema,
        "pack_version": version,
        "model": {
            "file": "encoder.onnx",
            "sha256": sha256(model_bytes),
            "input_name": "image",
            "output_name": "embedding",
            "input_size": INPUT_SIZE,
            "embedding_dim": EMBED_DIM,
            "mean": MEAN,
            "std": STD,
            "resize_filter": "catmull_rom",
        },
        "labels": {"file": "labels.json", "sha256": labels_sha},
        "label_embeddings": {
            "file": "label_embeddings.f32",
            "sha256": embeddings_sha,
        },
        "hysteresis_epsilon": HYSTERESIS_EPSILON,
        "roots": ROOTS,
    }


def write_manifest(pack: Path, manifest: dict) -> None:
    (pack / "manifest.json").write_bytes(
        json.dumps(manifest, indent=2, sort_keys=True).encode() + b"\n"
    )


def write_face_pack() -> None:
    """`facepack`: `testpack` plus the two synthetic face models."""
    FACE_PACK.mkdir(parents=True, exist_ok=True)
    manifest = tagging_manifest(FACE_PACK, schema=2, version=FACE_PACK_VERSION)

    detector_bytes = build_face_detector().SerializeToString()
    (FACE_PACK / "face_detector.onnx").write_bytes(detector_bytes)
    # The embedder *is* the tagging encoder. Nothing about the face pipeline
    # cares what produced a 64-d vector, and reusing the graph keeps the
    # committed pack small and removes one more set of seeded weights whose
    # behaviour nobody could predict anyway. `input_size` 64 means the
    # ArcFace template is scaled by 64/112, which exercises `template_for`.
    embedder_bytes = (FACE_PACK / "encoder.onnx").read_bytes()
    (FACE_PACK / "face_embedder.onnx").write_bytes(embedder_bytes)

    manifest["faces"] = {
        "detector": {
            "file": "face_detector.onnx",
            "sha256": sha256(detector_bytes),
            "input_name": "input",
            "input_size": DET_SIZE,
            "score_outputs": [f"score_{s}" for s in DET_STRIDES],
            "bbox_outputs": [f"box_{s}" for s in DET_STRIDES],
            "kps_outputs": [f"kp_{s}" for s in DET_STRIDES],
            "strides": DET_STRIDES,
            "anchors_per_cell": DET_ANCHORS,
            "mean": MEAN,
            "std": STD,
            "resize_filter": "bilinear",
            "score_threshold": DET_SCORE_THRESHOLD,
            "nms_iou": DET_NMS_IOU,
            "max_faces": DET_MAX_FACES,
            "min_face_pixels": DET_MIN_FACE_PIXELS,
        },
        "embedder": {
            "file": "face_embedder.onnx",
            "sha256": sha256(embedder_bytes),
            "input_name": "image",
            "output_name": "embedding",
            "input_size": INPUT_SIZE,
            "embedding_dim": EMBED_DIM,
            "mean": MEAN,
            "std": STD,
        },
    }
    write_manifest(FACE_PACK, manifest)


def main() -> None:
    PACK.mkdir(parents=True, exist_ok=True)
    write_manifest(PACK, tagging_manifest(PACK, schema=1, version=PACK_VERSION))
    write_face_pack()
    write_fixtures()

    total = sum(
        f.stat().st_size
        for d in (PACK, FACE_PACK, FIXTURES)
        for f in d.iterdir()
    )
    print(f"wrote {PACK}, {FACE_PACK} and {FIXTURES} ({total / 1024:.1f} KiB total)")


if __name__ == "__main__":
    main()
