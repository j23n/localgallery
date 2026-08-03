#!/usr/bin/env python3
"""Measure the pack's score distribution and pick root thresholds from it.

    cargo run -p gallery-ml --release --example dump_scores -- \
        build/model_packs/mobileclip-s2-v1 /tmp/refimgs/*.jpg > /tmp/rust.json
    .venv/bin/python calibrate.py --pack build/model_packs/mobileclip-s2-v1 \
        --scores /tmp/rust.json

# Why thresholds cannot be guessed

A cosine against L2-normalized CLIP-family embeddings is not a probability and
has no absolute meaning. MobileCLIP-S2's image and text towers sit on opposite
sides of the usual modality gap, so *every* label scores in a narrow band —
empirically 0.10 to 0.32 on real photographs — and the interesting signal is
the top ~0.05 of that band. A threshold copied from another model, or from
intuition about what "70% confident" means, is wrong by more than the entire
useful range.

So the number comes from measurement: score a set of real photographs whose
content is known, look at where the correct labels land versus where the first
wrong label lands, and put the bar in the gap. `--report` prints exactly that,
per image, so the choice is auditable rather than asserted.

# The per-label view

`--bias` additionally reports each label's *mean* score across the corpus. Some
prompts are close to the centre of the image cone and score high on everything
("charcoal", "compost"); those are the labels that produce the junk tags at any
global threshold. `labels.json` supports a per-label `threshold` override for
exactly this, and the printed table is the input to that decision. v1 ships
global root thresholds only — a per-label calibration wants a background corpus
of a few thousand photographs, which this repo does not have and must not
invent.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument(
        "--scores", type=Path, required=True, help="dump_scores JSON (the Rust side)"
    )
    parser.add_argument("--report", type=int, default=12, help="labels to print per image")
    parser.add_argument("--bias", type=int, default=0, help="print the N highest-mean labels")
    parser.add_argument(
        "--grid",
        type=str,
        default="0.22,0.23,0.24,0.25,0.26,0.27,0.28",
        help="comma-separated thresholds to tabulate",
    )
    args = parser.parse_args()

    manifest = json.loads((args.pack / "manifest.json").read_text())
    dump = json.loads(args.scores.read_text())
    label_paths = dump["labels"]
    roots = np.array([p.split("/", 1)[0] for p in label_paths])
    scores = np.array([entry["scores"] for entry in dump["images"]], dtype=np.float64)
    names = [Path(entry["path"]).name for entry in dump["images"]]

    print(f"pack {manifest['pack_version']}  {scores.shape[0]} images x {scores.shape[1]} labels")
    flat = scores.reshape(-1)
    qs = [50, 90, 99, 99.9, 99.99, 100]
    print("all-score quantiles: " + "  ".join(f"p{q}={np.percentile(flat, q):.4f}" for q in qs))
    print()

    for i, name in enumerate(names):
        order = np.argsort(-scores[i])[: args.report]
        print(f"--- {name}  (max {scores[i].max():.4f})")
        for j in order:
            print(f"    {scores[i][j]:.4f}  {label_paths[j]}")
    print()

    for root in sorted(set(roots)):
        mask = roots == root
        print(f"=== {root}: {mask.sum()} labels")
        header = f"{'threshold':>10} {'imgs w/ tag':>12} {'mean tags':>10} {'max tags':>9}"
        print(header)
        for threshold in [float(t) for t in args.grid.split(",")]:
            cap = manifest["roots"][root]["max_tags"]
            counts = np.minimum((scores[:, mask] >= threshold).sum(axis=1), cap)
            print(
                f"{threshold:10.3f} {int((counts > 0).sum()):12d} "
                f"{counts.mean():10.2f} {int(counts.max()):9d}"
            )
        print()

    if args.bias:
        means = scores.mean(axis=0)
        order = np.argsort(-means)[: args.bias]
        print(f"=== highest mean score across the corpus (the 'fires on anything' labels)")
        for j in order:
            print(f"    mean={means[j]:.4f} max={scores[:, j].max():.4f}  {label_paths[j]}")


if __name__ == "__main__":
    main()
