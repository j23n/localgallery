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

    tests/testpack/manifest.json
    tests/testpack/encoder.onnx           tiny conv/pool/matmul net, 64-d out
    tests/testpack/labels.json
    tests/testpack/label_embeddings.f32   6 x 64 f32, little-endian
    tests/fixtures/*.jpg, *.png, *.txt

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
FIXTURES = HERE / "fixtures"

PACK_VERSION = "gallery-ml-testpack-1"
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


# --------------------------------------------------------------------------
# Labels
# --------------------------------------------------------------------------


def write_labels() -> tuple[str, str]:
    rng = np.random.RandomState(LABEL_SEED)
    paths = sorted(LABEL_THRESHOLDS)
    matrix = rng.standard_normal((len(paths), EMBED_DIM)).astype(np.float32)
    # L2-normalize here as well as in Rust. Rust normalizes defensively at
    # load; shipping unit rows means the committed file is already what the
    # loader wants, and a bug in either place shows up as a score change.
    matrix /= np.linalg.norm(matrix, axis=1, keepdims=True)

    blob = b"".join(struct.pack("<f", v) for v in matrix.reshape(-1))
    (PACK / "label_embeddings.f32").write_bytes(blob)

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
    (PACK / "labels.json").write_bytes(labels_bytes)
    return sha256(labels_bytes), sha256(blob)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    PACK.mkdir(parents=True, exist_ok=True)

    model_bytes = build_encoder().SerializeToString()
    (PACK / "encoder.onnx").write_bytes(model_bytes)

    labels_sha, embeddings_sha = write_labels()

    manifest = {
        "schema": 1,
        "pack_version": PACK_VERSION,
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
    (PACK / "manifest.json").write_bytes(
        json.dumps(manifest, indent=2, sort_keys=True).encode() + b"\n"
    )

    write_fixtures()

    total = sum(f.stat().st_size for f in PACK.iterdir()) + sum(
        f.stat().st_size for f in FIXTURES.iterdir()
    )
    print(f"wrote {PACK} and {FIXTURES} ({total / 1024:.1f} KiB total)")


if __name__ == "__main__":
    main()
