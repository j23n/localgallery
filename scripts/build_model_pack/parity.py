#!/usr/bin/env python3
"""Compare the Rust tagging pipeline against the Python reference, per label.

    # 1. the Rust side
    cargo run -p gallery-ml --release --example dump_scores -- \
        build/model_packs/mobileclip-s2-v1 /tmp/refimgs/*.jpg > /tmp/rust.json

    # 2. the Python side, and the comparison
    .venv/bin/python parity.py --pack build/model_packs/mobileclip-s2-v1 \
        --rust /tmp/rust.json --images /tmp/refimgs

# What is actually being compared

Both sides score the *same label embeddings* (Python reads them out of the
pack's `label_embeddings.f32`, exactly as the Rust loader does), so the label
matrix cancels out and what is left is the image half of the pipeline:

    Python:  PIL decode -> PIL Resize(bilinear) -> CenterCrop -> torch encoder
    Rust:    zune-jpeg  -> fast_image_resize     -> center crop -> ORT encoder

Those cannot agree bit-for-bit and are not meant to. PIL and
`fast_image_resize` implement the same triangle filter but accumulate in
different orders and round differently, and ORT's fused CPU kernels are not
torch's. The gate is therefore behavioural, not numeric:

* **top-k label sets identical** for every image — the tags a user would see
  do not depend on which stack computed them;
* **max |delta score| small** — reported, and expected to sit around 1e-3,
  which is where `hysteresis_epsilon` (0.02) was sized from.

`--encoder onnx` runs the Python side through onnxruntime on the exported graph
instead of through torch, which isolates the preprocessing difference from the
encoder difference: the residue left when the encoder is held identical is
purely the resize.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def load_pack(pack_dir: Path):
    manifest = json.loads((pack_dir / "manifest.json").read_text())
    labels = json.loads((pack_dir / manifest["labels"]["file"]).read_text())
    dim = labels["dim"]
    raw = (pack_dir / manifest["label_embeddings"]["file"]).read_bytes()
    matrix = np.frombuffer(raw, dtype="<f4").reshape(len(labels["labels"]), dim)
    return manifest, labels, matrix


def pil_preprocess(path: Path, size: int, mean, std) -> np.ndarray:
    """open_clip's transform, written out so there is no doubt what it does.

    `Image.BILINEAR` here is the same antialiased triangle filter torchvision
    dispatches to for a PIL input, and `reducing_gap=None` keeps it a single
    convolution rather than PIL's two-stage box-then-filter shortcut — the
    Rust side has no such shortcut.
    """
    from PIL import ImageOps

    image = Image.open(path)
    # `gallery_ml::preprocess` applies the EXIF orientation explicitly; PIL does
    # not, so do it here too or a rotated fixture would compare a rotated image
    # against an upright one.
    image = ImageOps.exif_transpose(image).convert("RGB")
    w, h = image.size
    scale = size / min(w, h)
    rw, rh = max(round(w * scale), size), max(round(h * scale), size)
    image = image.resize((rw, rh), Image.BILINEAR, reducing_gap=None)
    left, top = (rw - size) // 2, (rh - size) // 2
    image = image.crop((left, top, left + size, top + size))

    array = np.asarray(image, dtype=np.float32) / 255.0
    array = (array - np.asarray(mean, dtype=np.float32)) / np.asarray(std, dtype=np.float32)
    return array.transpose(2, 0, 1)[None, ...]


def torch_encoder(manifest):
    import torch

    import build_pack

    model, _, _ = build_pack.load_model()
    from timm.utils.model import reparameterize_model
    import copy

    visual = reparameterize_model(copy.deepcopy(model.visual)).eval()

    def encode(tensor: np.ndarray) -> np.ndarray:
        with torch.no_grad():
            return visual(torch.from_numpy(tensor)).float().numpy().reshape(-1)

    return encode


def onnx_encoder(pack_dir: Path, manifest):
    import onnxruntime as ort

    options = ort.SessionOptions()
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(
        str(pack_dir / manifest["model"]["file"]), options, providers=["CPUExecutionProvider"]
    )
    input_name = manifest["model"]["input_name"]
    output_name = manifest["model"]["output_name"]

    def encode(tensor: np.ndarray) -> np.ndarray:
        return session.run([output_name], {input_name: tensor})[0].reshape(-1)

    return encode


def unit(vector: np.ndarray) -> np.ndarray:
    return (vector.astype(np.float64) / np.linalg.norm(vector.astype(np.float64))).astype(
        np.float32
    )


def tag(scores: np.ndarray, label_paths, manifest) -> list[str]:
    """The Rust tagger's gating, minus hysteresis (nothing is owned here)."""
    roots = manifest["roots"]
    by_root: dict[str, list[tuple[float, str]]] = {}
    for score, path in zip(scores, label_paths):
        root = path.split("/", 1)[0]
        cfg = roots.get(root)
        if cfg is None or score < cfg["threshold"]:
            continue
        by_root.setdefault(root, []).append((float(score), path))
    out = []
    for root, entries in by_root.items():
        entries.sort(key=lambda e: (-e[0], e[1]))
        out.extend(path for _, path in entries[: roots[root]["max_tags"]])
    return sorted(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--rust", type=Path, required=True, help="dump_scores JSON")
    parser.add_argument("--images", type=Path, help="unused; paths come from the Rust JSON")
    parser.add_argument("--encoder", choices=("torch", "onnx"), default="torch")
    parser.add_argument("--topk", type=int, default=10)
    parser.add_argument(
        "--max-delta",
        type=float,
        default=0.01,
        help="fail if any |score_python - score_rust| exceeds this",
    )
    parser.add_argument("--json", type=Path, help="write the full comparison here")
    args = parser.parse_args()

    manifest, labels, matrix = load_pack(args.pack)
    label_paths = [entry["path"] for entry in labels["labels"]]
    rust = json.loads(args.rust.read_text())
    if rust["labels"] != label_paths:
        return fail("the Rust dump's label order does not match labels.json")
    if rust["pack_version"] != manifest["pack_version"]:
        return fail(f"pack version mismatch: {rust['pack_version']} vs {manifest['pack_version']}")

    size = manifest["model"]["input_size"]
    mean, std = manifest["model"]["mean"], manifest["model"]["std"]
    encode = (
        torch_encoder(manifest) if args.encoder == "torch" else onnx_encoder(args.pack, manifest)
    )

    # Normalize the label matrix the way `pack::resolve_labels` does, so any
    # residual non-unit rows cannot show up as a "parity" difference.
    label_matrix = matrix.astype(np.float64)
    label_matrix /= np.linalg.norm(label_matrix, axis=1, keepdims=True)

    worst_delta = 0.0
    worst_where = ""
    worst_cos = 1.0
    failures = []
    report = []

    for entry in rust["images"]:
        path = Path(entry["path"])
        tensor = pil_preprocess(path, size, mean, std)
        embedding = unit(encode(tensor))
        scores = (label_matrix @ embedding.astype(np.float64)).astype(np.float32)
        rust_scores = np.asarray(entry["scores"], dtype=np.float32)

        delta = np.abs(scores.astype(np.float64) - rust_scores.astype(np.float64))
        index = int(delta.argmax())
        if delta[index] > worst_delta:
            worst_delta = float(delta[index])
            worst_where = f"{path.name} / {label_paths[index]}"

        rust_embedding = np.asarray(entry["embedding"], dtype=np.float64)
        cos = float(rust_embedding @ embedding.astype(np.float64))
        worst_cos = min(worst_cos, cos)

        order_py = np.argsort(-scores, kind="stable")[: args.topk]
        order_rs = np.argsort(-rust_scores, kind="stable")[: args.topk]
        top_py = [label_paths[i] for i in order_py]
        top_rs = [label_paths[i] for i in order_rs]
        tags_py = tag(scores, label_paths, manifest)
        tags_rs = entry["tags"]

        same_topk = set(top_py) == set(top_rs)
        same_order = top_py == top_rs
        same_tags = tags_py == tags_rs
        if not same_topk:
            failures.append(f"{path.name}: top-{args.topk} differs\n  py {top_py}\n  rs {top_rs}")
        if not same_tags:
            failures.append(f"{path.name}: emitted tags differ\n  py {tags_py}\n  rs {tags_rs}")

        report.append(
            {
                "image": path.name,
                "max_abs_delta": float(delta.max()),
                "embedding_cosine": cos,
                "topk_same_set": same_topk,
                "topk_same_order": same_order,
                "tags_same": same_tags,
                "top": [
                    {"path": label_paths[i], "python": float(scores[i]), "rust": float(rust_scores[i])}
                    for i in order_py
                ],
                "tags": tags_rs,
            }
        )
        flag = "ok " if same_topk and same_tags else "FAIL"
        print(
            f"{flag} {path.name:28s} maxΔ={delta.max():.2e} cos={cos:.7f} "
            f"top1={top_rs[0]} ({rust_scores[order_rs[0]]:.4f})  tags={tags_rs}"
        )

    print()
    print(f"encoder                : python={args.encoder}  rust=ort")
    print(f"images                 : {len(rust['images'])}")
    print(f"max |Δscore|           : {worst_delta:.3e}   ({worst_where})")
    print(f"min embedding cosine   : {worst_cos:.8f}")
    print(f"top-{args.topk} set agreement  : {len(rust['images']) - len(failures)}/{len(rust['images'])} images")

    if args.json:
        args.json.write_text(
            json.dumps(
                {
                    "encoder": args.encoder,
                    "max_abs_delta": worst_delta,
                    "min_embedding_cosine": worst_cos,
                    "images": report,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )

    if failures:
        print("\n" + "\n".join(failures))
        return fail(f"{len(failures)} parity failures")
    if worst_delta > args.max_delta:
        return fail(f"max |Δscore| {worst_delta:.3e} exceeds --max-delta {args.max_delta}")
    print("\nPARITY OK")
    return 0


def fail(message: str) -> int:
    print(f"PARITY FAILED: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
