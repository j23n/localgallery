# build_model_pack

Builds the on-device tagging model pack: an ONNX image encoder plus the
precomputed text embeddings for every taxonomy label. The app ships no text
tower — tagging is a dot product against this matrix — so this script is where
the model choice, the label set and the thresholds are all decided.

The pack format is defined by `core/gallery-ml/src/pack.rs`; that rustdoc is
the spec, this is the producer.

## Build

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python build_pack.py --out ../../build/model_packs
```

~350 MB of downloads (torch dominates) plus ~600 MB of model weights that
`open_clip` fetches from Hugging Face on first run and caches in
`~/.cache/huggingface`. Output goes to `build/model_packs/<version>/`, which is
git-ignored — **the pack is not committed**, this script is.

Useful flags: `--version` (pack name and directory), `--photo-tools` (checkout
to read the taxonomy from; defaults to a sibling `photo-tools/`), `--clean`,
`--verify-determinism` (re-export and re-embed, assert both hashes reproduce),
`--objects-threshold` / `--scenes-threshold`.

## What it produces

`mobileclip-s2-v1`, 148.2 MB total:

| File | Size | |
| --- | --- | --- |
| `image_encoder.onnx` | 143.0 MB | MobileCLIP-S2 visual tower, fp32, opset 17 |
| `label_embeddings.f32` | 4.9 MB | 2 386 × 512 little-endian f32, row-major, `labels.json` order |
| `labels.json` | 242 KB | taxonomy path + the prompt each row was embedded from |
| `manifest.json` | 893 B | file hashes, input/output names, mean/std, resize filter, thresholds |

## Model choice

**MobileCLIP-S2 (`datacompdr`)**, via `open_clip_torch`. It was the first
choice and the export worked, so the documented SigLIP fallback is not what
ships. Four things had to be true at once:

* **Single-input/single-output graph, no dynamic control flow** — what
  `OrtEncoder` can drive and what the CPU EP optimizes.
* **Preprocessing the core already implements.** `open_clip`'s transform for
  this model is `Resize(shortest side, bilinear) + CenterCrop`, which is
  exactly `gallery_ml::preprocess`. No new resize path, no new golden tensor
  hashes. (SigLIP would have meant a *squash* resize to 224×224 with no crop —
  a preprocessing change, a `PREPROCESS_VERSION` bump and new goldens.)
* **Speed.** 36 M visual parameters; measured 36 ms/image single-threaded on an
  M-series CPU over a 312-photo library.
* **Quality.** Zero-shot accuracy above ViT-B/32 (what photo-tools'
  `clip_tagger` uses) at a third of the FLOPs.

Note the unusual normalization: MobileCLIP trains on unnormalized `[0,1]`
pixels, so `mean=(0,0,0)`, `std=(1,1,1)` — not the CLIP constants. The script
asserts the manifest matches `open_clip`'s own pretrained cfg rather than
trusting these constants, because a mismatch here would show up only as
quietly worse tags.

## Label set

Every distinct `Objects/*` and `Scenes/*` target path in photo-tools'
`src/photo_tools/data/ram_tag_mapping.yaml` — **2 386 labels** (2 010 Objects,
376 Scenes), sorted by path. Deriving rather than curating means every tag the
core can write is one photo-tools already knows how to read.

`People/*` is excluded (face recognition, Phase 2); `Landmarks/*` and
`Places/*` are excluded (geocoding, stays desktop-side).

### Prompt template

photo-tools has no prompt phrasing to mirror — RAM++ is a trained multi-label
classifier, and its `clip_tagger.py` only produces image embeddings. So the
phrasing is ours, and it was picked by measurement. Top-1 correct on the nine
reference photos whose content the taxonomy actually covers:

| Template | Top-1 correct |
| --- | --- |
| `{leaf}` | 7/9 |
| `a photo of {leaf}` | 6/9 |
| **`a photo of a/an {leaf}`** (shipped) | **8/9** |

The article matters more than it looks: without it `moon` loses to
`Scenes/Sky/Comet`, and with the article-less template it loses to
`Objects/Food/Bread/Crescent`. The one remaining miss is `brick.jpg`, where the
taxonomy has no brick-wall leaf that beats `Scenes/Urban/Street/Sidewalk`; it
scores 0.2418 and so is correctly emitted as *no tag* at the shipped threshold.

Three mechanical deviations from the template, all in `labels.py`: `a`/`an` by
first letter with a short exception list; hand-written `OVERRIDES` for the
eight `*/General` catch-alls, the `Scenes/Weather/*` adjectives and a few mass
nouns; and a `, a kind of {parent}` suffix on the 61 leaf words used by more
than one path, so `Objects/Food/Fruit/Apple` and `Objects/Plant/Tree/Apple`
do not share an embedding.

## Thresholds

Shipped: **Objects ≥ 0.265, Scenes ≥ 0.250**, caps 8 and 6 (the caps are
photo-tools' `taxonomy.CATEGORY_CONFIG` verbatim).

These are cosine similarities against L2-normalized MobileCLIP-S2 embeddings.
They are **not transferable to another model** and cannot be guessed: because
of the modality gap, every label scores in a narrow band, and the whole useful
range is about 0.05 wide. Measured over the 16-photo reference set
(`reference_images.py`), all 2 386 labels × 16 images:

```
p50=0.0987  p90=0.1539  p99=0.2022  p99.9=0.2448  p99.99=0.2815  p100=0.3142
```

### Method

`calibrate.py` scores a set of real photographs whose content is known, then
prints where the correct labels land against where the first wrong label lands.
The threshold goes in the gap:

* **Objects at 0.265** sits between the lowest *correct* tag it keeps (the
  astronaut portrait's `Person/Profession/Astronaut`, 0.2686) and the highest
  *wrong* tag it drops (the greyscale clock face's `Clothing/Accessory/Bead`,
  0.2612 — the top of a run of round-object labels).
* **Scenes at 0.250** sits above the highest wrong scene tag observed (a lawn
  close-up scoring `Urban/Square` 0.2469) and below the correct ones on the
  only true scene in the set (the Hubble deep field's `Sky/Galaxy` 0.2706 and
  `Sky/Constellation` 0.2511).

Both are deliberately strict. Phase 1's acceptance floor is "no wrong
high-confidence tags; sparse is fine", and a wrong tag costs a user more than a
missing one.

**This is a 16-image calibration.** It is enough to place the bar in an
observed gap, not enough for per-label thresholds — `calibrate.py --bias` shows
the labels that fire on everything (`charcoal`, `compost`), and `labels.json`
supports a per-label `threshold` override, but using it wants a background
corpus of a few thousand photographs that this repo does not have and must not
invent.

`hysteresis_epsilon` is 0.02: an owned tag is retracted only below `T − ε`. That
is an order of magnitude above the measured cross-stack score drift (2.2e-3)
and an order of magnitude below the gap between a photo that shows a cat and
one that does not, so float drift cannot flap tags.

## Validation

Two scripts, both requiring a built pack.

**Parity** — the gate. Scores the same images through the Python reference and
through the Rust pipeline and compares label-for-label. Both sides read the
*same* label embeddings out of the pack, so the label matrix cancels and what
is compared is the image half:

```
Python:  PIL decode -> PIL Resize(bilinear) -> CenterCrop -> torch or ORT encoder
Rust:    zune-jpeg  -> fast_image_resize     -> center crop -> ORT encoder
```

```sh
cargo run -p gallery-ml --release --example dump_scores -- \
    build/model_packs/mobileclip-s2-v1 /tmp/refimgs/*.jpg > /tmp/rust.json
.venv/bin/python parity.py --pack ../../build/model_packs/mobileclip-s2-v1 \
    --rust /tmp/rust.json --encoder onnx
```

These cannot agree bit-for-bit and are not meant to, so the gate is
behavioural: identical top-k label sets and identical emitted tags per image,
with max |Δscore| reported. `--encoder torch` compares the full stack;
`--encoder onnx` holds the encoder identical so the residue is purely the
resize. Current result on the 16-photo set, both encoders: **16/16 top-10 set
agreement, identical tags, max |Δscore| 2.2e-3, min embedding cosine
0.9999144**.

**Calibration** — `calibrate.py`, above. Consumes the same `dump_scores` JSON.

### Reference images

`reference_images.py --out /tmp/refimgs --all` writes scikit-image's bundled
sample photographs as JPEG. Neither repo ships photographic fixtures —
`gallery-ml/tests/fixtures` is gradients and stripes (they pin resize geometry,
not meaning) and `generate_test_library.py` renders labelled colour gradients —
and zero-shot scores on synthetic images are noise, because there is no cat in
them for the cat label to win on. Three of the 19 samples (`eagle`, `lily`,
`skin`) need the optional `pooch` dependency to download and are skipped
without it; the 16 that remain are the calibration and parity set.

## Determinism

Two builds of one pack version must produce the same bytes: the manifest hashes
are what the app verifies and what the sidecar sentinel records. Seeds fixed,
`torch.set_num_threads(1)`, weights pinned by `open_clip` pretrained tag, labels
sorted by path, JSON with `sort_keys=True`, embeddings written as raw
little-endian f32 with no padding. `--verify-determinism` checks it.

`requirements.txt` is exactly pinned for the same reason: every one of those
packages can move the bytes.

The FastViT trunk is reparameterized (`timm.utils.reparameterize_model`) before
export, folding the over-parameterized train-time branches into single
convolutions. Done before export rather than left to ORT's graph optimizer: the
folded graph is smaller, faster, and free of branch structure a future ORT
version might fold differently. The fold moves raw embedding components by up
to 0.017 on vectors of norm ~40; the cosine between folded and unfolded is 1.0
to f32 precision.
