#!/usr/bin/env python3
"""Write a small set of *real photographs* to a directory, as JPEG.

Neither repo ships photographic fixtures: `core/gallery-ml/tests/fixtures` is
seeded gradients and stripes (deliberately — they exist to pin resize geometry,
not to mean anything), and `scripts/generate_test_library.py` renders labelled
colour gradients. Zero-shot scores on those are noise: there is no cat in them,
so "does the cat label win" has no answer.

So the reference set comes from `scikit-image`'s bundled sample data, which is
a pip dependency like any other, ships real photographs with known content, and
is redistributable. Each image below has an obvious expected tag, which is what
makes it useful for both threshold calibration and the "would a human call
these tags sane" check.

    python3 reference_images.py --out /tmp/refimgs

`--all` additionally fetches the samples scikit-image downloads on demand from
its own release registry.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

#: `name -> (skimage.data function, what a human would tag it)`. The expectation
#: strings are documentation for the report, not assertions: the taxonomy may
#: not even contain a leaf for some of them.
BUNDLED = {
    "astronaut": "a portrait of a person (Objects/Person/*)",
    "chelsea": "a cat (Objects/Animal/Mammal/Cat)",
    "coffee": "a cup of coffee (Objects/Food/Drink/Coffee, Objects/Container/Cup)",
    "rocket": "a rocket launching (Objects/Vehicle/*/Rocket)",
    "camera": "a photographer with a tripod, greyscale",
    "hubble_deep_field": "a deep-field star field (Scenes/Sky/Galaxy)",
    "moon": "the moon, greyscale",
    "page": "a scanned page of text",
    "text": "close-up of printed text",
    "clock": "a clock face, greyscale",
    "immunohistochemistry": "a microscopy slide — deliberately out of taxonomy",
}

#: Downloaded from scikit-image's own release assets on first use.
DOWNLOADED = {
    "cat": "a cat's face (Objects/Animal/Mammal/Cat)",
    "eagle": "an eagle, greyscale (Objects/Animal/Bird/Eagle)",
    "grass": "a lawn close-up (Scenes/Nature/Landscape/Grassland)",
    "gravel": "gravel texture",
    "brick": "a brick wall",
    "retina": "a retina fundus photograph — out of taxonomy",
    "lily": "a fluorescence microscopy image — out of taxonomy",
    "skin": "a histology slide — out of taxonomy",
}


def to_rgb(array: np.ndarray) -> Image.Image:
    if array.ndim == 2:
        array = np.stack([array] * 3, axis=-1)
    if array.ndim == 3 and array.shape[2] == 4:
        array = array[:, :, :3]
    if array.dtype != np.uint8:
        lo, hi = float(array.min()), float(array.max())
        span = hi - lo if hi > lo else 1.0
        array = ((array - lo) / span * 255.0).round().astype(np.uint8)
    return Image.fromarray(array, "RGB")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--all", action="store_true", help="also fetch the downloaded samples")
    parser.add_argument("--quality", type=int, default=92)
    args = parser.parse_args()

    import skimage.data as data

    args.out.mkdir(parents=True, exist_ok=True)
    wanted = dict(BUNDLED)
    if args.all:
        wanted.update(DOWNLOADED)

    notes = []
    for name in sorted(wanted):
        try:
            array = getattr(data, name)()
        except Exception as e:  # network off, or the sample moved
            print(f"skip {name}: {e}")
            continue
        image = to_rgb(np.asarray(array))
        path = args.out / f"{name}.jpg"
        image.save(path, "JPEG", quality=args.quality, optimize=False)
        notes.append(f"{path.name}\t{image.size[0]}x{image.size[1]}\t{wanted[name]}")

    (args.out / "EXPECTED.txt").write_text("\n".join(notes) + "\n")
    print("\n".join(notes))
    print(f"\n{len(notes)} images in {args.out}")


if __name__ == "__main__":
    main()
