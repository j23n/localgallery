#!/usr/bin/env python3
"""Build a gallery-ml model pack: ONNX image encoder + label prompt embeddings.

    python3 -m venv .venv
    .venv/bin/pip install -r requirements.txt
    .venv/bin/python build_pack.py --out ../../build/model_packs

Writes `<out>/<version>/` containing exactly the four files
`core/gallery-ml/src/pack.rs` documents:

    manifest.json          the only file read by name
    image_encoder.onnx     MobileCLIP-S2 visual tower, fp32
    labels.json            2 386 taxonomy paths + the prompt each embedding came from
    label_embeddings.f32   2 386 x 512 little-endian f32, row-major, labels order

# Why MobileCLIP-S2

The pack ships an image tower and precomputed *text* embeddings, so the model
choice is really a choice of joint embedding space. MobileCLIP-S2
(`datacompdr`) is the one that fits the constraints on all four axes at once:

* it exports to a single-input/single-output ONNX graph with no dynamic control
  flow, which is what `OrtEncoder` can drive and what the CPU EP optimizes;
* its open_clip preprocessing is `Resize(shortest side, bilinear) +
  CenterCrop`, which `gallery_ml::preprocess` already implements exactly — no
  new resize path, no new golden hashes;
* 36 M visual parameters, ~143 MB fp32, ~35 ms/image single-threaded on an M-series
  CPU: a 20 000-photo library is a background afternoon, not a week;
* its zero-shot accuracy beats ViT-B/32 (the model photo-tools' `clip_tagger`
  uses) while being a third of the FLOPs, which matters because the whole point
  of this pack is that it runs on a phone.

SigLIP-base-patch16-224 is the documented fallback if the export ever breaks;
it did not, so it is not what ships. Note that its preprocessing is a *squash*
resize to 224x224 with no crop, which `gallery_ml::preprocess` cannot express —
switching would mean a preprocessing change, a `PREPROCESS_VERSION` bump and
new golden tensor hashes.

# Determinism

Two builds of the same pack version must produce the same bytes, because the
manifest hashes are what the app verifies and what the sidecar sentinel records.
So: seeds fixed, single-threaded torch, weights pinned by `open_clip` pretrained
tag (which resolves to a fixed Hugging Face revision), labels sorted by path,
JSON written with `sort_keys=True` and `repr` floats, and the embedding matrix
written as raw little-endian f32 with no padding. `--verify-determinism`
re-runs the encoder export and the text tower and asserts the hashes match.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np
import torch

import labels as labels_mod

# ---------------------------------------------------------------------------
# Pack constants
# ---------------------------------------------------------------------------

MODEL_NAME = "MobileCLIP-S2"
PRETRAINED = "datacompdr"
PACK_VERSION = "mobileclip-s2-v1"

INPUT_NAME = "image"
OUTPUT_NAME = "embedding"
MODEL_FILE = "image_encoder.onnx"
LABELS_FILE = "labels.json"
EMBEDDINGS_FILE = "label_embeddings.f32"

#: Opset 17 is the newest one ORT 1.22 (the `ort` 2.0-rc.13 prebuilt) supports
#: without falling back to a slower kernel for LayerNorm.
ONNX_OPSET = 17

#: Thresholds, in cosine-similarity units against L2-normalized MobileCLIP-S2
#: embeddings. Not transferable to another model: a different joint space has a
#: different similarity scale, and this one is narrow — p50 of all 2 386 label
#: scores over the reference set is 0.099 and the largest score seen at all is
#: 0.314, so the entire useful range is about 0.05 wide.
#:
#: Measured with `calibrate.py` over the `reference_images.py` set. `Objects` at
#: 0.265 sits in the gap between the last *correct* tag it keeps (the astronaut
#: portrait's `Person/Profession/Astronaut`, 0.2686) and the highest *wrong* tag
#: it drops (the greyscale clock face's `Clothing/Accessory/Bead`, 0.2612, top of
#: a run of round-object labels). `Scenes` at 0.250 sits above the highest wrong
#: scene tag observed (a lawn close-up scoring `Urban/Square` 0.2469) and below
#: the correct ones on the only true scene in the set (the Hubble deep field's
#: `Sky/Galaxy` 0.2706 and `Sky/Constellation` 0.2511).
#:
#: Both are deliberately on the strict side. Phase 1's acceptance floor is "no
#: wrong high-confidence tags; sparse is fine", a wrong tag costs a user more
#: than a missing one, and `hysteresis_epsilon` only ever loosens the bar for
#: tags the core already owns.
ROOT_THRESHOLDS = {"Objects": 0.265, "Scenes": 0.250}

#: How far below its threshold an already-owned tag may fall before the core
#: retracts it. An order of magnitude above the cross-stack score drift measured
#: by `parity.py` (max |delta| 2.2e-3 between the PIL/torch and
#: fast_image_resize/ORT paths on the same JPEGs), and an order of magnitude
#: below the gap between a photo that shows a cat and one that does not.
HYSTERESIS_EPSILON = 0.02

#: MobileCLIP is trained on unnormalized [0, 1] pixels — no mean/std subtraction
#: at all. Not a typo, and not the CLIP constants: `open_clip`'s pretrained cfg
#: for every MobileCLIP tag says `mean=(0,0,0), std=(1,1,1)`.
IMAGE_MEAN = [0.0, 0.0, 0.0]
IMAGE_STD = [1.0, 1.0, 1.0]

#: `open_clip`'s pretrained cfg says `interpolation="bilinear"`,
#: `resize_mode="shortest"`. `ResizeFilter::Bilinear` in `gallery_ml::preprocess`
#: is the same triangle-filter convolution PIL calls `BILINEAR`.
RESIZE_FILTER = "bilinear"

TEXT_BATCH = 256


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, payload: dict) -> bytes:
    """Stable JSON: sorted keys, two-space indent, one trailing newline."""
    data = json.dumps(payload, indent=2, sort_keys=True).encode() + b"\n"
    path.write_bytes(data)
    return data


def load_model(device: str = "cpu"):
    import open_clip

    torch.manual_seed(0)
    torch.set_num_threads(1)
    model, _, preprocess = open_clip.create_model_and_transforms(
        MODEL_NAME, pretrained=PRETRAINED, device=device
    )
    model.eval()
    tokenizer = open_clip.get_tokenizer(MODEL_NAME)
    return model, preprocess, tokenizer


class VisualTower(torch.nn.Module):
    """`model.encode_image` as a standalone single-input module.

    Named arguments matter: `torch.onnx.export` takes the graph input name from
    `input_names`, but the *forward parameter* name is what the exporter uses
    when tracing keyword calls, and keeping them the same removes one way for
    the manifest and the graph to drift apart.
    """

    def __init__(self, visual: torch.nn.Module):
        super().__init__()
        self.visual = visual

    def forward(self, image: torch.Tensor) -> torch.Tensor:  # noqa: D102
        return self.visual(image)


def export_encoder(model, out_path: Path, input_size: int) -> None:
    """Export the reparameterized visual tower to ONNX.

    FastViT (`fastvit_mci2`, MobileCLIP-S2's trunk) trains with over-
    parameterized branches — a 3x3 conv, a 1x1 conv and a skip, each with its
    own BatchNorm — that are mathematically foldable into one convolution at
    inference. `timm.utils.reparameterize_model` does the fold. It is worth
    doing before the export rather than leaving it to ORT's graph optimizer:
    the folded graph is smaller, it runs measurably faster, and it removes the
    branch structure that a future ORT version might fold *differently*.

    The fold is exact in exact arithmetic and near-exact in fp32: measured
    against the unfolded tower it moves raw embedding components by up to
    0.017 (on vectors of norm ~40) and the cosine between the two embeddings
    is 1.0 to f32 precision, i.e. below the resolution of any threshold.
    """
    from timm.utils.model import reparameterize_model

    visual = reparameterize_model(copy.deepcopy(model.visual)).eval()
    tower = VisualTower(visual).eval()
    example = torch.zeros(1, 3, input_size, input_size)
    with torch.no_grad():
        torch.onnx.export(
            tower,
            (example,),
            str(out_path),
            input_names=[INPUT_NAME],
            output_names=[OUTPUT_NAME],
            opset_version=ONNX_OPSET,
            do_constant_folding=True,
            # Batch stays fixed at 1: `OrtEncoder` feeds one image per call and
            # a symbolic batch dimension only costs the CPU EP its static
            # shape inference.
            dynamic_axes=None,
            dynamo=False,
        )


def embed_prompts(model, tokenizer, prompts: list[str]) -> np.ndarray:
    """L2-normalized text embeddings, one row per prompt, in `prompts` order."""
    rows = []
    with torch.no_grad():
        for start in range(0, len(prompts), TEXT_BATCH):
            batch = prompts[start : start + TEXT_BATCH]
            tokens = tokenizer(batch)
            features = model.encode_text(tokens)
            features = features / features.norm(dim=-1, keepdim=True)
            rows.append(features.float().cpu().numpy())
    matrix = np.concatenate(rows, axis=0).astype("<f4")
    norms = np.linalg.norm(matrix.astype(np.float64), axis=1)
    if not np.allclose(norms, 1.0, atol=1e-5):
        raise SystemExit(f"text embeddings are not unit vectors: {norms.min()}..{norms.max()}")
    return matrix


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def build(
    out_root: Path,
    version: str,
    photo_tools_root: Path | None,
    thresholds: dict[str, float],
    verify_determinism: bool,
) -> Path:
    pack_dir = out_root / version
    pack_dir.mkdir(parents=True, exist_ok=True)

    label_list = labels_mod.build_labels(photo_tools_root)
    print(f"labels: {len(label_list)} from {labels_mod.mapping_path(photo_tools_root)}")

    model, preprocess, tokenizer = load_model()
    input_size = model.visual.image_size
    if isinstance(input_size, (tuple, list)):
        if input_size[0] != input_size[1]:
            raise SystemExit(f"non-square model input {input_size} is not supported")
        input_size = input_size[0]
    input_size = int(input_size)

    # Assert the preprocessing the pack claims is the preprocessing open_clip
    # would apply. A pack whose manifest says bilinear/shortest while the model
    # was trained on bicubic/squash is the single most expensive mistake this
    # script could make, and it would show up only as quietly worse tags.
    _assert_preprocessing(preprocess, input_size)

    onnx_path = pack_dir / MODEL_FILE
    export_encoder(model, onnx_path, input_size)
    model_sha = sha256_file(onnx_path)
    print(f"encoder: {onnx_path.name} {onnx_path.stat().st_size / 1e6:.1f} MB sha={model_sha[:12]}")

    matrix = embed_prompts(model, tokenizer, [entry["prompt"] for entry in label_list])
    embed_dim = int(matrix.shape[1])
    blob = matrix.tobytes(order="C")
    (pack_dir / EMBEDDINGS_FILE).write_bytes(blob)
    embeddings_sha = hashlib.sha256(blob).hexdigest()
    print(
        f"embeddings: {EMBEDDINGS_FILE} {len(blob) / 1e6:.1f} MB "
        f"({matrix.shape[0]}x{embed_dim}) sha={embeddings_sha[:12]}"
    )

    labels_payload = {
        "schema": 1,
        "dim": embed_dim,
        "labels": label_list,
    }
    labels_bytes = write_json(pack_dir / LABELS_FILE, labels_payload)
    labels_sha = hashlib.sha256(labels_bytes).hexdigest()

    manifest = {
        "schema": 1,
        "pack_version": version,
        "model": {
            "file": MODEL_FILE,
            "sha256": model_sha,
            "input_name": INPUT_NAME,
            "output_name": OUTPUT_NAME,
            "input_size": input_size,
            "embedding_dim": embed_dim,
            "mean": IMAGE_MEAN,
            "std": IMAGE_STD,
            "resize_filter": RESIZE_FILTER,
        },
        "labels": {"file": LABELS_FILE, "sha256": labels_sha},
        "label_embeddings": {"file": EMBEDDINGS_FILE, "sha256": embeddings_sha},
        "hysteresis_epsilon": HYSTERESIS_EPSILON,
        "roots": {
            root: {"threshold": thresholds[root], "max_tags": labels_mod.ROOT_MAX_TAGS[root]}
            for root in labels_mod.ROOTS
        },
    }
    write_json(pack_dir / "manifest.json", manifest)

    total = sum(f.stat().st_size for f in pack_dir.iterdir())
    print(f"pack: {pack_dir} ({total / 1e6:.1f} MB)")

    if verify_determinism:
        _verify_determinism(model, tokenizer, input_size, label_list, model_sha, embeddings_sha)

    return pack_dir


def _assert_preprocessing(preprocess, input_size: int) -> None:
    """Fail loudly if open_clip's transform is not what the manifest claims."""
    from torchvision.transforms import CenterCrop, Normalize, Resize

    steps = {type(t).__name__: t for t in preprocess.transforms}
    resize = steps.get("Resize")
    crop = steps.get("CenterCrop")
    norm = steps.get("Normalize")
    problems = []
    if not isinstance(resize, Resize) or resize.size != input_size:
        problems.append(f"Resize({getattr(resize, 'size', None)}) != Resize({input_size})")
    if resize is not None and resize.interpolation.value != RESIZE_FILTER:
        problems.append(f"interpolation {resize.interpolation.value} != {RESIZE_FILTER}")
    if not isinstance(crop, CenterCrop) or tuple(crop.size) != (input_size, input_size):
        problems.append(f"CenterCrop({getattr(crop, 'size', None)}) != ({input_size}, {input_size})")
    if not isinstance(norm, Normalize):
        problems.append("no Normalize step")
    else:
        if [float(v) for v in norm.mean] != IMAGE_MEAN:
            problems.append(f"mean {list(norm.mean)} != {IMAGE_MEAN}")
        if [float(v) for v in norm.std] != IMAGE_STD:
            problems.append(f"std {list(norm.std)} != {IMAGE_STD}")
    if problems:
        raise SystemExit(
            "open_clip preprocessing does not match the manifest:\n  " + "\n  ".join(problems)
        )


def _verify_determinism(
    model, tokenizer, input_size: int, label_list, model_sha: str, embeddings_sha: str
) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        again = Path(tmp) / MODEL_FILE
        export_encoder(model, again, input_size)
        again_sha = sha256_file(again)
    matrix = embed_prompts(model, tokenizer, [entry["prompt"] for entry in label_list])
    again_embed_sha = hashlib.sha256(matrix.tobytes(order="C")).hexdigest()
    ok = True
    if again_sha != model_sha:
        print(f"NOT DETERMINISTIC: encoder {model_sha} != {again_sha}", file=sys.stderr)
        ok = False
    if again_embed_sha != embeddings_sha:
        print(
            f"NOT DETERMINISTIC: embeddings {embeddings_sha} != {again_embed_sha}", file=sys.stderr
        )
        ok = False
    print("determinism: re-export reproduced both hashes" if ok else "determinism: FAILED")
    if not ok:
        raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "build" / "model_packs",
        help="directory to create <version>/ under (default: repo build/model_packs, git-ignored)",
    )
    parser.add_argument("--version", default=PACK_VERSION, help="pack version and directory name")
    parser.add_argument(
        "--photo-tools",
        type=Path,
        default=None,
        help=f"photo-tools checkout (default: {labels_mod.DEFAULT_PHOTO_TOOLS})",
    )
    parser.add_argument(
        "--objects-threshold", type=float, default=ROOT_THRESHOLDS["Objects"]
    )
    parser.add_argument("--scenes-threshold", type=float, default=ROOT_THRESHOLDS["Scenes"])
    parser.add_argument(
        "--verify-determinism",
        action="store_true",
        help="re-export and re-embed, assert both hashes reproduce",
    )
    parser.add_argument(
        "--clean", action="store_true", help="delete the pack directory before writing"
    )
    args = parser.parse_args()

    pack_dir = args.out / args.version
    if args.clean and pack_dir.exists():
        shutil.rmtree(pack_dir)

    build(
        out_root=args.out,
        version=args.version,
        photo_tools_root=args.photo_tools,
        thresholds={
            "Objects": args.objects_threshold,
            "Scenes": args.scenes_threshold,
        },
        verify_determinism=args.verify_determinism,
    )


if __name__ == "__main__":
    main()
